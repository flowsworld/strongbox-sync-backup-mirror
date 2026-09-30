"""Isolated HTTP, OAuth, and keychain tests without real credentials."""
import base64
import email.message
from dataclasses import asdict
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.response import addinfourl

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import google_drive
import google_drive_setup
from remote import CheckError, RemoteFile

CREDENTIALS = google_drive.Credentials("fixture.apps.googleusercontent.com", "fixture-secret", "fixture-refresh")
FILE = {"id": "file123", "name": "Passwords.kdbx", "parents": ["folder123"],
        "trashed": False, "size": "8", "md5Checksum": "a" * 32}


class ApiTest(unittest.TestCase):
    def test_refresh_once_and_find_across_empty_page(self):
        with patch("google_drive.request_json", side_effect=[
                {"access_token": "fixture-access"}, {"files": [], "nextPageToken": "next"},
                {"files": [dict(FILE)]}, {"user": {"emailAddress": "flo@example.test"}}]) as request:
            drive = google_drive.GoogleDrive(CREDENTIALS)
            self.assertEqual(drive.find_file("folder123", "Passwords.kdbx"), FILE)
            self.assertEqual(drive.account_email(), "flo@example.test")
        self.assertEqual(request.call_count, 4)
        self.assertEqual(request.call_args_list[0].kwargs["data"]["grant_type"], "refresh_token")
        self.assertIn("pageToken=next", request.call_args_list[2].args[0])
        self.assertIn("parents", parse_qs(urlsplit(request.call_args_list[1].args[0]).query)["q"][0])
        self.assertNotIn("alt=media", str(request.call_args_list))

    def find(self, pages):
        with patch("google_drive.request_json", side_effect=[{"access_token": "fixture-access"}, *pages]):
            return google_drive.GoogleDrive(CREDENTIALS).find_file("folder123", "Passwords.kdbx")

    def test_no_match_is_pending(self):
        self.assertIsNone(self.find([{"files": []}]))

    def test_duplicates_across_pages_fail(self):
        with self.assertRaisesRegex(google_drive.DriveError, "Multiple"):
            self.find([{"files": [dict(FILE)], "nextPageToken": "next"}, {"files": [dict(FILE)]}])

    def test_untrusted_metadata_is_rejected(self):
        changes = [{"parents": ["wrong"]}, {"trashed": True}, {"size": -1},
                   {"md5Checksum": "not-a-checksum"}, {"sha256Checksum": 12},
                   {"id": "../path"}, {"name": "other.kdbx"}]
        for change in changes:
            with self.subTest(change=change), self.assertRaises(google_drive.DriveError):
                self.find([{"files": [{**FILE, **change}]}])
        with self.assertRaisesRegex(google_drive.DriveError, "incomplete"):
            self.find([{"files": [], "incompleteSearch": True}])
        with self.assertRaises(google_drive.DriveError):
            self.find([{"files": [], "nextPageToken": "next"}, {"files": [], "nextPageToken": "next"}])
        with self.assertRaisesRegex(google_drive.DriveError, "file size"):
            self.find([{"files": [{key: value for key, value in FILE.items() if key != "size"}]}])

    def test_missing_hashes_allow_pending_and_hex_is_normalized(self):
        file = {key: value for key, value in FILE.items() if key != "md5Checksum"}
        self.assertEqual(self.find([{"files": [file]}]), file)
        self.assertEqual(self.find([{"files": [{**FILE, "md5Checksum": "A" * 32}]}])["md5Checksum"], "a" * 32)

    def test_folder_rejects_shortcut_and_trash(self):
        folder = {"id": "folder123", "name": "Target", "trashed": False,
                  "mimeType": "application/vnd.google-apps.folder"}
        for change in ({}, {"trashed": True}, {"mimeType": "application/vnd.google-apps.shortcut"}):
            with patch("google_drive.request_json", side_effect=[{"access_token": "fixture-access"}, {**folder, **change}]):
                drive = google_drive.GoogleDrive(CREDENTIALS)
                if change:
                    with self.assertRaises(google_drive.DriveError):
                        drive.get_folder("folder123")
                else:
                    self.assertEqual(drive.get_folder("folder123"), folder)

    def test_http_errors_never_include_response_or_url(self):
        for failure in (HTTPError("https://private.invalid/sensitive", 400, "fixture-secret", {},
                                  io.BytesIO(b"fixture-refresh")),
                        HTTPError("https://private.invalid/sensitive", 403, "fixture-secret", {},
                                  io.BytesIO(b"fixture-refresh")), URLError("fixture-secret")):
            with patch("google_drive.build_opener") as opener:
                opener.return_value.open.side_effect = failure
                with self.assertRaises(google_drive.DriveError) as caught:
                    google_drive.request_json(google_drive.TOKEN_URL, data={"refresh_token": "fixture-refresh"})
            self.assertNotIn("fixture", str(caught.exception))
            self.assertNotIn("https", str(caught.exception))

    def test_http_timeout_and_redirect_protection(self):
        with patch("google_drive.build_opener") as opener:
            opener.return_value.open.return_value = io.BytesIO(b'{"files":[]}')
            self.assertEqual(google_drive.request_json(google_drive.API_URL + "files", access_token="fixture-access"), {"files": []})
            self.assertEqual(opener.return_value.open.call_args.kwargs["timeout"], 20)
        with self.assertRaises(google_drive.DriveError):
            google_drive._NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid")
        with self.assertRaises(google_drive.DriveError):
            google_drive.request_json("http://www.googleapis.com/drive/v3/files")
        with self.assertRaises(google_drive.DriveError):
            google_drive.request_json(google_drive.API_URL + "files", access_token="bad\r\nheader")

    def test_redirect_does_not_forward_the_token(self):
        requests = []

        def https_open(handler, request):
            # A real urllib opener processes this answer; only the network is fake.
            requests.append(request.full_url)
            if len(requests) == 1:
                headers = email.message.Message()
                headers["Location"] = "https://other.invalid/steal"
                response = addinfourl(io.BytesIO(b""), headers, request.full_url, 302)
            else:
                response = addinfourl(io.BytesIO(b"{}"), email.message.Message(), request.full_url, 200)
            response.msg = "fixture"
            return response
        with patch("urllib.request.HTTPSHandler.https_open", https_open):
            with self.assertRaisesRegex(google_drive.DriveError, "redirect"):
                google_drive.request_json(google_drive.API_URL + "files", access_token="fixture-access")
        self.assertEqual(requests, [google_drive.API_URL + "files"])

    def test_provider_checks_folder_and_maps_file(self):
        folder = {"id": "folder123", "name": "Target", "trashed": False,
                  "mimeType": "application/vnd.google-apps.folder"}
        file = {**FILE, "sha256Checksum": "B" * 64}
        with patch("google_drive.load_credentials", return_value=CREDENTIALS) as load, \
                patch("google_drive.request_json", side_effect=[
                    {"access_token": "fixture-access"}, folder, {"files": [file]},
                    folder, {"files": []}]) as request:
            provider = google_drive.provider_from_config({"provider": "google-drive", "folder_id": "folder123"})
            load.assert_not_called()
            self.assertEqual(provider.location, "folder123")
            remote = provider.find("Passwords.kdbx")
            self.assertEqual(remote, RemoteFile("file123", 8, {"sha256": "b" * 64, "md5": "a" * 32}))
            self.assertEqual(list(remote.checksums), ["sha256", "md5"])
            self.assertIsNone(provider.find("Passwords.kdbx"))
        load.assert_called_once()
        self.assertIn("files/folder123", request.call_args_list[1].args[0])
        for config in ({}, {"folder_id": ""}, {"folder_id": "../folder"}):
            # The core only knows CheckError.
            with self.subTest(config=config), self.assertRaises(CheckError):
                google_drive.provider_from_config(config)

    def test_keychain_credentials_use_stdin_and_verify_readback(self):
        encoded = base64.b64encode(json.dumps(asdict(CREDENTIALS)).encode()).decode()
        results = [subprocess.CompletedProcess([], 0, "", ""),
                   subprocess.CompletedProcess([], 0, encoded + "\n", "")]
        with patch("google_drive.subprocess.run", side_effect=results) as run:
            google_drive.save_credentials(CREDENTIALS)
        write = run.call_args_list[0]
        self.assertEqual(write.args[0], ["/usr/bin/security", "-i"])
        self.assertIn(encoded, write.kwargs["input"])
        self.assertNotIn(CREDENTIALS.refresh_token, repr(write.args))
        self.assertNotIn(CREDENTIALS.refresh_token, repr(CREDENTIALS))
        self.assertEqual(run.call_args_list[1].args[0][-1], "-w")
        with patch("google_drive.subprocess.run", return_value=subprocess.CompletedProcess([], 44, "", "sensitive")):
            with self.assertRaisesRegex(google_drive.DriveError, "keychain"):
                google_drive.load_credentials()


class SetupTest(unittest.TestCase):
    def test_folder_urls_and_installed_client(self):
        for folder in ("folder123", "https://drive.google.com/drive/folders/folder123?usp=sharing",
                       "https://drive.google.com/drive/u/1/folders/folder123"):
            self.assertEqual(google_drive_setup.parse_folder(folder), "folder123")
        for folder in ("https://drive.google.com.evil/drive/folders/folder123", "https://user@drive.google.com/drive/folders/folder123", "../folder",
                       "https://[drive.google.com/drive/folders/folder123"):
            with self.assertRaises(google_drive.DriveError):
                google_drive_setup.parse_folder(folder)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "client.json"
            path.write_text(json.dumps({"installed": {"client_id": CREDENTIALS.client_id,
                            "client_secret": CREDENTIALS.client_secret,
                            "token_uri": "https://evil.invalid"}}))
            self.assertEqual(google_drive_setup.read_client(path), (CREDENTIALS.client_id, CREDENTIALS.client_secret))
            path.write_text(json.dumps({"web": {"client_id": CREDENTIALS.client_id}}))
            with self.assertRaises(google_drive.DriveError):
                google_drive_setup.read_client(path)
            # A lone surrogate cannot be sent to Google.
            path.write_text('{"installed": {"client_id": "%s", "client_secret": "abc\\ud800"}}' % CREDENTIALS.client_id)
            with self.assertRaises(google_drive.DriveError):
                google_drive_setup.read_client(path)

    def sign_in(self, token_response):
        """Runs authorize() against a fake browser and callback server.

        Returns the recorded browser URLs, callback replies, token request mock,
        and stdout. authorize() errors propagate to the caller.
        """
        opened = []
        replies = []

        class FakeServer:
            server_port = 12345

            def __init__(self, address, handler):
                self.address, self.handler, self.calls = address, handler, 0

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def handle_request(self):
                parameters = parse_qs(urlsplit(opened[0]).query)
                self.calls += 1
                callback = object.__new__(self.handler)
                callback.path = "/oauth2/callback?" + urlencode({
                    "code": "fixture-code", "state": "invalid" if self.calls == 1 else parameters["state"][0]})
                callback.wfile = io.BytesIO()
                callback.send_response = lambda status: None
                callback.send_header = lambda *args: None
                callback.end_headers = lambda: None
                callback.do_GET()
                replies.append(callback.wfile.getvalue())

        def browser(url):
            opened.append(url)
            return True

        with patch("google_drive_setup.HTTPServer", FakeServer), patch("google_drive_setup.webbrowser.open", side_effect=browser), \
                patch("google_drive_setup.request_json", return_value=token_response) as request, \
                patch("sys.stdout", new_callable=io.StringIO) as output:
            self.credentials = google_drive_setup.authorize(CREDENTIALS.client_id, CREDENTIALS.client_secret)
        return opened, replies, request, output

    def test_oauth_pkce_state_and_no_callback_reflection(self):
        opened, replies, request, output = self.sign_in({"refresh_token": "fixture-refresh", "scope": google_drive.SCOPE})
        self.assertEqual(self.credentials, CREDENTIALS)
        parameters = parse_qs(urlsplit(opened[0]).query)
        token_data = request.call_args.kwargs["data"]
        expected_challenge = base64.urlsafe_b64encode(google_drive_setup.hashlib.sha256(token_data["code_verifier"].encode()).digest()).rstrip(b"=").decode()
        self.assertEqual(parameters["code_challenge"], [expected_challenge])
        self.assertEqual(parameters["code_challenge_method"], ["S256"])
        self.assertEqual(parameters["scope"], [google_drive.SCOPE])
        self.assertEqual(request.call_args.args[0], google_drive.TOKEN_URL)
        self.assertEqual(len(replies), 2)
        self.assertTrue(all(b"fixture-code" not in reply for reply in replies))
        self.assertNotIn("https://", output.getvalue())

    def test_oauth_rejects_a_broader_scope(self):
        with self.assertRaisesRegex(google_drive.DriveError, "read-only metadata"):
            self.sign_in({"refresh_token": "fixture-refresh",
                          "scope": "https://www.googleapis.com/auth/drive"})

    def test_oauth_timeout_is_bounded(self):
        with patch("google_drive_setup.HTTPServer") as server, patch("google_drive_setup.webbrowser.open", return_value=True), \
                patch("google_drive_setup.time.monotonic", side_effect=[0, 301]), patch("sys.stdout", new_callable=io.StringIO):
            server.return_value.__enter__.return_value.server_port = 12345
            with self.assertRaisesRegex(google_drive.DriveError, "5 minutes"):
                google_drive_setup.authorize(CREDENTIALS.client_id, CREDENTIALS.client_secret)

    def test_rejected_confirmation_writes_nothing(self):
        with patch("google_drive_setup.read_client", return_value=(CREDENTIALS.client_id, CREDENTIALS.client_secret)), \
                patch("google_drive_setup.authorize", return_value=CREDENTIALS), patch("google_drive_setup.GoogleDrive") as drive, \
                patch("google_drive_setup.save_credentials") as save, patch("google_drive_setup.save_config") as config, \
                patch("builtins.input", return_value="No"), patch("sys.stdout", new_callable=io.StringIO) as output:
            drive.return_value.account_email.return_value = "flo@example.test"
            drive.return_value.get_folder.return_value = {"id": "folder123", "name": "fixture folder"}
            drive.return_value.find_file.return_value = None
            self.assertEqual(google_drive_setup.main(["--client-json", "fixture.json", "--folder-url", "folder123",
                                               "--state-dir", "state", "--name", "Custom.kdbx"]), 1)
        drive.return_value.find_file.assert_called_once_with("folder123", "Custom.kdbx")
        self.assertIn("Custom.kdbx: not in the cloud folder yet", output.getvalue())
        save.assert_not_called()
        config.assert_not_called()

    def run_confirmed_setup(self, keychain, save_config, save_credentials=None):
        """Confirms a setup with new credentials against a fake keychain list."""
        def save(credentials):
            keychain.append(credentials)
        with patch("google_drive_setup.read_client", return_value=(CREDENTIALS.client_id, CREDENTIALS.client_secret)), \
                patch("google_drive_setup.authorize", return_value=CREDENTIALS), patch("google_drive_setup.GoogleDrive") as drive, \
                patch("google_drive_setup.load_credentials", side_effect=lambda: keychain[-1]), \
                patch("google_drive_setup.save_credentials", side_effect=save_credentials or save), \
                patch("google_drive_setup.save_config", side_effect=save_config), \
                patch("builtins.input", return_value="yes"), patch("sys.stdout", new_callable=io.StringIO), \
                patch("sys.stderr", new_callable=io.StringIO) as errors:
            drive.return_value.account_email.return_value = "flo@example.test"
            drive.return_value.get_folder.return_value = {"id": "folder456", "name": "fixture folder"}
            drive.return_value.find_file.return_value = None
            result = google_drive_setup.main(["--client-json", "fixture.json", "--folder-url", "folder456",
                                              "--state-dir", "state", "--name", "Passwords.kdbx"])
        return result, errors.getvalue()

    def test_failed_config_restores_previous_credentials(self):
        previous = google_drive.Credentials(CREDENTIALS.client_id, CREDENTIALS.client_secret, "previous-refresh")
        keychain = [previous]
        failure = google_drive.DriveError("Could not save the upload check configuration.")
        result, errors = self.run_confirmed_setup(keychain, failure)
        self.assertEqual(result, 1)
        self.assertEqual(keychain[-1], previous)
        self.assertIn("previous Google access was kept", errors)

    def test_failed_restore_is_reported(self):
        previous = google_drive.Credentials(CREDENTIALS.client_id, CREDENTIALS.client_secret, "previous-refresh")
        keychain = [previous]

        def save(credentials):
            if credentials == previous:
                raise google_drive.DriveError("Could not save Google access in the macOS keychain.")
            keychain.append(credentials)
        failure = google_drive.DriveError("Could not save the upload check configuration.")
        result, errors = self.run_confirmed_setup(keychain, failure, save)
        self.assertEqual(result, 1)
        self.assertIn("could not be restored", errors)

    def test_my_drive_root_is_saved_with_its_real_id(self):
        for folder in ("https://drive.google.com/drive/my-drive", "https://drive.google.com/drive/u/1/my-drive", "root"):
            with self.subTest(folder=folder), tempfile.TemporaryDirectory() as directory:
                state = Path(directory)
                with patch("google_drive_setup.read_client", return_value=(CREDENTIALS.client_id, CREDENTIALS.client_secret)), \
                        patch("google_drive_setup.authorize", return_value=CREDENTIALS), \
                        patch("google_drive_setup.load_credentials", side_effect=google_drive.DriveError("missing")), \
                        patch("google_drive_setup.save_credentials"), \
                        patch("google_drive.request_json", side_effect=[
                            {"access_token": "fixture-access"}, {"user": {"emailAddress": "flo@example.test"}},
                            {"id": "0AMyDriveRoot", "name": "My Drive", "trashed": False,
                             "mimeType": "application/vnd.google-apps.folder"},
                            {"files": []}]) as request, \
                        patch("builtins.input", return_value="yes"), patch("sys.stdout", new_callable=io.StringIO):
                    self.assertEqual(google_drive_setup.main(["--client-json", "fixture.json", "--folder-url", folder,
                                                              "--state-dir", str(state), "--name", "Passwords.kdbx"]), 0)
                self.assertIn("files/root", request.call_args_list[2].args[0])
                self.assertIn("'0AMyDriveRoot' in parents", parse_qs(urlsplit(request.call_args_list[3].args[0]).query)["q"][0])
                self.assertEqual(json.loads((state / "upload-check.json").read_text())["folder_id"], "0AMyDriveRoot")

    def test_failed_readback_restores_previous_credentials(self):
        previous = google_drive.Credentials(CREDENTIALS.client_id, CREDENTIALS.client_secret, "previous-refresh")
        keychain = [previous]

        def save(credentials):
            # The keychain took the new entry, but reading it back failed.
            keychain.append(credentials)
            if credentials != previous:
                raise google_drive.DriveError("Could not save Google access in the macOS keychain.")
        result, errors = self.run_confirmed_setup(keychain, None, save)
        self.assertEqual(result, 1)
        self.assertEqual(keychain[-1], previous)
        self.assertIn("previous Google access was kept", errors)

    def test_cancel_while_saving_restores_previous_credentials(self):
        previous = google_drive.Credentials(CREDENTIALS.client_id, CREDENTIALS.client_secret, "previous-refresh")
        keychain = [previous]
        result, errors = self.run_confirmed_setup(keychain, KeyboardInterrupt)
        self.assertEqual(result, 1)
        self.assertEqual(keychain[-1], previous)
        self.assertIn("cancelled", errors)
        self.assertIn("previous Google access was kept", errors)

    def test_atomic_public_config_has_restricted_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            google_drive_setup.save_config(state, "folder123")
            config = state / "upload-check.json"
            self.assertEqual(json.loads(config.read_text()), {"provider": "google-drive", "folder_id": "folder123"})
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            google_drive_setup.save_config(state, "folder456")
            self.assertEqual(json.loads(config.read_text()), {"provider": "google-drive", "folder_id": "folder456"})
            self.assertEqual(list(state.glob(".upload-check-*")), [])


if __name__ == "__main__":
    unittest.main()
