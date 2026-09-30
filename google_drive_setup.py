#!/usr/bin/env python3
"""One-time browser sign-in for the read-only Google Drive upload check."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
import time
from urllib.parse import parse_qs, urlencode, urlsplit
import webbrowser

from google_drive import (MY_DRIVE, Credentials, DriveError, GoogleDrive, SCOPE, TOKEN_URL,
                         load_credentials, object_value, request_json,
                         save_credentials, string_value, validate_id)

AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"


def parse_folder(value: str) -> str:
    """Returns the folder ID, or the MY_DRIVE alias for My Drive itself."""
    if re.fullmatch(r"[A-Za-z0-9_-]{1,256}", value):
        return validate_id(value)
    try:
        parsed = urlsplit(value)
    except ValueError:
        # For example an unclosed "[" in the host of a mistyped address.
        parsed = urlsplit("")
    if parsed.scheme != "https" or parsed.netloc != "drive.google.com":
        raise DriveError("Invalid Drive folder URL or folder ID.")
    if re.fullmatch(r"/drive/(?:u/[0-9]+/)?my-drive/?", parsed.path):
        return MY_DRIVE
    match = re.fullmatch(r"/drive/(?:u/[0-9]+/)?folders/([A-Za-z0-9_-]{1,256})/?", parsed.path)
    if not match:
        raise DriveError("Invalid Drive folder URL or folder ID.")
    return validate_id(match[1])


def read_client(path: Path) -> tuple[str, str]:
    try:
        with path.open("rb") as source:
            raw = source.read(1048577)
        if len(raw) > 1048576:
            raise ValueError
        value = object_value(json.loads(raw))
        installed = object_value(value.get("installed"))
        client_id = string_value(installed.get("client_id"))
        client_secret = string_value(installed.get("client_secret"))
        if not re.fullmatch(r"[A-Za-z0-9_-]+\.apps\.googleusercontent\.com", client_id):
            raise ValueError
        Credentials(client_id, client_secret, "validation")
        return client_id, client_secret
    except (OSError, ValueError, UnicodeError, DriveError):
        raise DriveError("Invalid OAuth client file. Use the JSON of a Desktop app client.") from None


def authorize(client_id: str, client_secret: str) -> Credentials:
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    result = {}

    class Callback(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def log_message(self, format, *args):
            pass

        def send_error(self, code, message=None, explain=None):
            body = b"Invalid local OAuth request."
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

        def do_GET(self):
            try:
                parsed = urlsplit(self.path)
                query = parse_qs(parsed.query, max_num_fields=20)
            except ValueError:
                parsed = urlsplit("/")
                query = {}
            valid = (not parsed.scheme and not parsed.netloc and
                     parsed.path == "/oauth2/callback" and
                     query.get("state") == [state] and not result)
            if valid and len(query.get("code", [])) == 1 and "error" not in query:
                result["code"] = query["code"][0]
            elif valid and len(query.get("error", [])) == 1:
                result["error"] = True
            else:
                valid = False
            # Never reflect query parameters or Google errors in browser responses.
            body = ("Sign-in received. You can close this window." if valid else
                    "Invalid sign-in response.").encode("utf-8")
            self.send_response(200 if valid else 400)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    try:
        with HTTPServer(("127.0.0.1", 0), Callback) as server:
            redirect_uri = f"http://127.0.0.1:{server.server_port}/oauth2/callback"
            parameters = {
                "client_id": client_id, "redirect_uri": redirect_uri,
                "response_type": "code", "scope": SCOPE, "state": state,
                "code_challenge": challenge, "code_challenge_method": "S256",
                "access_type": "offline", "prompt": "consent",
            }
            print("Opening the Google sign-in in the browser. Please finish within 5 minutes.")
            if not webbrowser.open(AUTH_URL + "?" + urlencode(parameters)):
                raise DriveError("Could not open the browser. Check the default browser.")
            deadline = time.monotonic() + 300
            while not result:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise DriveError("Google sign-in cancelled after 5 minutes.")
                server.timeout = min(1, remaining)
                server.handle_request()
    except OSError:
        raise DriveError("Local OAuth sign-in receiver not available.") from None
    if "error" in result:
        raise DriveError("Google sign-in was denied or cancelled.")
    token = request_json(TOKEN_URL, data={
        "client_id": client_id, "client_secret": client_secret,
        "code": string_value(result.get("code")), "code_verifier": verifier,
        "redirect_uri": redirect_uri, "grant_type": "authorization_code",
    })
    if "scope" in token and token["scope"] != SCOPE:
        raise DriveError("Google did not grant exactly the read-only metadata access.")
    return Credentials(client_id, client_secret, string_value(token.get("refresh_token")))


def save_config(state_dir: Path, folder_id: str) -> None:
    """Writes upload-check.json, which turns the check on. It holds no secrets."""
    temporary = None
    try:
        state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir=state_dir, prefix=".upload-check-",
                                         delete=False) as target:
            temporary = Path(target.name)
            os.chmod(target.name, 0o600)
            json.dump({"provider": "google-drive", "folder_id": folder_id}, target)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, state_dir / "upload-check.json")
        temporary = None
    except OSError:
        raise DriveError("Could not save the upload check configuration.") from None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def display_text(value):
    # Drive folder names must not run terminal control sequences.
    return "".join(char if char.isprintable() else "?" for char in value)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Sign in once for the Google Drive upload check.")
    parser.add_argument("--client-json", type=Path, required=True,
                        help="OAuth client JSON of a Desktop app")
    parser.add_argument("--folder-url", required=True, help="Drive folder URL or folder ID")
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--name", required=True, help="File name of the database in the Drive folder")
    args = parser.parse_args(argv)
    args.client_json = args.client_json.expanduser()
    args.state_dir = args.state_dir.expanduser()
    try:
        folder_id = parse_folder(args.folder_url)
        client_id, client_secret = read_client(args.client_json)
        credentials = authorize(client_id, client_secret)
        drive = GoogleDrive(credentials)
        email = drive.account_email()
        folder = drive.get_folder(folder_id)
        # Drive lists files under the real ID, also for MY_DRIVE.
        folder_id = string_value(folder.get("id"))
        file = drive.find_file(folder_id, args.name)
        print(f"Google account: {display_text(email)}")
        print(f"Drive target folder: {display_text(folder['name'])} ({folder_id})")
        print(f"{display_text(args.name)}: " + ("present" if file else "not in the cloud folder yet"))
        confirmation = input("Save this access for the upload check? [yes/No] ")
        if confirmation.strip().lower() != "yes":
            print("Cancelled. Access and configuration were not saved.")
            return 1
        try:
            previous = load_credentials()
        except DriveError:
            # Missing or unreadable: there is no working access to keep.
            previous = None
        try:
            save_credentials(credentials)
            save_config(args.state_dir, folder_id)
        except (DriveError, KeyboardInterrupt) as error:
            # The old folder configuration must keep its matching credentials,
            # also when the keychain write only failed its read-back check.
            if previous is None:
                raise
            reason = "Setup cancelled." if isinstance(error, KeyboardInterrupt) else str(error)
            try:
                save_credentials(previous)
            except (DriveError, KeyboardInterrupt):
                raise DriveError(f"{reason} The previous Google access could not be restored "
                                 "either. Run the setup again.") from None
            raise DriveError(f"{reason} The previous Google access was kept.") from None
        print("Upload check set up. The sync job was not installed or started.")
        return 0
    except (EOFError, KeyboardInterrupt):
        print("Setup cancelled.", file=sys.stderr)
        return 1
    except DriveError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
