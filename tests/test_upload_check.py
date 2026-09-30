"""Upload check core with artificial files and a fake provider."""
from contextlib import redirect_stdout
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import upload_check
from remote import CheckError, RemoteFile


class CloudCheckTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.target = self.base / "Passwords.kdbx"
        self.target.write_bytes(b"encrypted fixture")
        self.state_dir = self.base / "state"
        self.state_dir.mkdir()
        self.write_config({"provider": "fake", "folder": "folder"})
        # The registry loads a fake provider whose location follows the config.
        self.find = Mock(return_value=self.metadata())
        provider = SimpleNamespace(provider_from_config=lambda config: SimpleNamespace(
            location=config["folder"], find=self.find))
        patch.dict(upload_check.PROVIDERS, {"fake": "fake_provider"}).start()
        patch.dict(sys.modules, {"fake_provider": provider}).start()
        self.addCleanup(patch.stopall)

    def write_config(self, config):
        (self.state_dir / "upload-check.json").write_text(json.dumps(config))

    def metadata(self, content=b"encrypted fixture", sha256=True):
        checksums = {"md5": hashlib.md5(content).hexdigest()}
        if sha256:
            checksums = {"sha256": hashlib.sha256(content).hexdigest(), **checksums}
        return RemoteFile("file", len(content), checksums)

    def run_check(self, now=1000, expected=0, notify=False):
        with redirect_stdout(io.StringIO()):
            result = upload_check.check(self.target, self.state_dir, self.target.name, 1800, notify, now)
        self.assertEqual(result, expected)
        return json.loads((self.state_dir / "cloud-status.json").read_text())

    def test_confirmation_and_repeated_checks_do_not_repeat_log(self):
        state = self.run_check()
        self.assertEqual(state["status"], "confirmed")
        self.assertEqual(state["last_confirmed_at"], 1000)
        self.assertEqual(state["context"], "fake:folder/Passwords.kdbx")
        self.assertEqual(state["remote_file_id"], "file")
        log = (self.state_dir / "sync.log").read_text()
        state = self.run_check(1900)
        self.assertEqual(state["last_confirmed_at"], 1900)
        self.assertEqual((self.state_dir / "sync.log").read_text(), log)
        self.assertEqual((self.state_dir / "cloud-status.json").stat().st_mode & 0o777, 0o600)

    def test_md5_fallback_and_sha256_precedence(self):
        self.find.return_value = self.metadata(sha256=False)
        self.assertEqual(self.run_check()["status"], "confirmed")
        md5 = self.metadata().checksums["md5"]
        self.find.return_value = RemoteFile("file", 17, {"sha256": "0" * 64, "md5": md5})
        self.assertEqual(self.run_check(1900)["status"], "pending")

    def test_provider_order_decides_and_unsupported_algorithms_are_skipped(self):
        checksums = self.metadata().checksums
        self.find.return_value = RemoteFile("file", 17, {"md5": checksums["md5"], "sha256": "0" * 64})
        self.assertEqual(self.run_check()["status"], "confirmed")
        self.find.return_value = RemoteFile("file", 17, {"quickxor": "0", "sha256": checksums["sha256"]})
        self.assertEqual(self.run_check(1900)["status"], "confirmed")

    def test_size_also_needs_to_match(self):
        self.find.return_value = RemoteFile("file", 1, self.metadata().checksums)
        self.assertEqual(self.run_check()["status"], "pending")

    def test_missing_or_unknown_provider_is_error(self):
        for config in ({"folder": "folder"}, {"provider": "unknown", "folder": "folder"}):
            with self.subTest(config=config):
                self.write_config(config)
                state = self.run_check(expected=1)
                self.assertEqual(state["status"], "error")
                self.assertIn("provider", state["message"])
        self.find.assert_not_called()

    def test_missing_file_is_pending_then_overdue_then_recovers(self):
        self.find.return_value = None
        self.assertEqual(self.run_check()["status"], "pending")
        self.assertEqual(self.run_check(1900)["pending_seconds"], 900)
        self.assertEqual(self.run_check(2800, expected=1)["status"], "overdue")
        self.find.return_value = self.metadata()
        self.assertEqual(self.run_check(3700)["status"], "confirmed")

    def test_api_error_pauses_pending_timer_and_preserves_copy(self):
        self.find.return_value = self.metadata(b"older")
        self.run_check()
        self.run_check(1900)
        self.find.side_effect = CheckError("Provider not reachable.")
        state = self.run_check(2800, expected=1)
        self.assertEqual(state["status"], "error")
        self.assertEqual(state["pending_seconds"], 900)
        self.assertIsNone(state["previous_mismatch_at"])
        self.find.side_effect = None
        self.assertEqual(self.run_check(10000)["pending_seconds"], 900)
        self.assertEqual(self.run_check(10900, expected=1)["status"], "overdue")
        self.assertEqual(self.target.read_bytes(), b"encrypted fixture")

    def test_wakeup_does_not_count_entire_sleep_as_wait(self):
        self.find.return_value = None
        self.run_check()
        self.assertEqual(self.run_check(100000)["pending_seconds"], 900)

    def test_changed_content_and_changed_folder_restart_wait(self):
        self.find.return_value = None
        self.run_check()
        self.run_check(1900)
        self.target.write_bytes(b"new encrypted fixture")
        self.assertEqual(self.run_check(2800)["pending_seconds"], 0)
        self.run_check(3700)
        self.write_config({"provider": "fake", "folder": "other-folder"})
        self.assertEqual(self.run_check(4600)["pending_seconds"], 0)

    def test_no_supported_checksum_is_error_not_confirmation(self):
        for checksums in ({}, {"quickxor": "0"}):
            with self.subTest(checksums=checksums):
                self.find.return_value = RemoteFile("file", 17, checksums)
                state = self.run_check(expected=1)
                self.assertEqual(state["status"], "error")
                self.assertIn("no supported checksum", state["message"])

    def test_file_change_during_request_cannot_confirm_upload(self):
        def changed_file(*args):
            self.target.write_bytes(b"new content")
            return self.metadata()
        self.find.side_effect = changed_file
        state = self.run_check(expected=1)
        self.assertEqual(state["status"], "error")
        self.assertIn("changed", state["message"])

    def test_notifications_deduplicated_without_exposing_response(self):
        self.find.side_effect = CheckError("Sign-in expired.")
        with patch.object(upload_check.subprocess, "run", return_value=Mock(returncode=0)) as notify:
            self.run_check(expected=1, notify=True)
            self.run_check(1900, expected=1, notify=True)
            self.target.write_bytes(b"new fixture")
            self.run_check(2800, expected=1, notify=True)
        self.assertEqual(notify.call_count, 1)

    def test_invalid_saved_status_is_reported_once_and_replaced(self):
        (self.state_dir / "cloud-status.json").write_text('{"status":"pending","pending_seconds":"bad"}')
        with patch.object(upload_check.subprocess, "run", return_value=Mock(returncode=0)) as notify:
            state = self.run_check(expected=1, notify=True)
        self.assertEqual(state["status"], "error")
        self.assertIn("reset", state["message"])
        self.assertEqual(notify.call_count, 1)
        self.find.assert_not_called()
        self.assertEqual(self.run_check(1900)["status"], "confirmed")

    def test_broken_log_reports_failure_but_saves_current_status(self):
        (self.state_dir / "sync.log").mkdir()
        with self.assertRaises(OSError):
            self.run_check()
        state = json.loads((self.state_dir / "cloud-status.json").read_text())
        self.assertEqual(state["status"], "confirmed")

    def test_notification_failure_cannot_leave_stale_confirmation(self):
        for failure in (Mock(returncode=1), subprocess.TimeoutExpired("osascript", 15)):
            with self.subTest(failure=type(failure).__name__):
                self.find.side_effect = None
                self.run_check()
                self.find.side_effect = CheckError("Provider not reachable.")
                with patch.object(upload_check.subprocess, "run") as notify:
                    if isinstance(failure, Exception):
                        notify.side_effect = failure
                    else:
                        notify.return_value = failure
                    with self.assertRaises((CheckError, subprocess.TimeoutExpired)):
                        self.run_check(1900, expected=1, notify=True)
                state = json.loads((self.state_dir / "cloud-status.json").read_text())
                self.assertEqual(state["status"], "error")
                self.assertEqual(state["checked_at"], 1900)


if __name__ == "__main__":
    unittest.main()
