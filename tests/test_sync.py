"""Isolated tests with artificial files. No access to real backups."""
import os
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]


class StrongboxFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.backup_root = self.base / "Source with spaces"
        self.backup_root.mkdir()
        self.identifier = "11111111-1111-1111-1111-111111111111"
        self.source = self.backup_root / self.identifier
        self.target = self.base / "Drive & Folder"
        self.source.mkdir()
        self.target.mkdir()
        self.state = self.base / "state"
        self.database_name = "Passwords.kdbx"
        self.destination = self.target / self.database_name
        self.preferences = self.base / "preferences.plist"
        self.write_metadata(self.identifier)
        self.env = dict(os.environ, STRONGBOX_DATABASE_NAME=self.database_name,
                        STRONGBOX_BACKUP_ROOT=str(self.backup_root),
                        STRONGBOX_PREFERENCES=str(self.preferences),
                        STRONGBOX_TARGET_DIR=str(self.target),
                        STRONGBOX_STATE_DIR=str(self.state), STRONGBOX_NOTIFY="0",
                        STRONGBOX_PYTHON=sys.executable,
                        STRONGBOX_CLOUD_WARNING_SECONDS="1800")

    def write_metadata(self, identifier, ambiguous=False, database_name="Passwords.kdbx", extra=()):
        """extra: further (identifier, URL path) pairs, already percent-encoded."""
        objects = ["$null"]

        def ref(value):
            objects.append(value)
            return plistlib.UID(len(objects) - 1)

        def entry(identifier, url):
            uuid = ref(identifier)
            url_ref = ref({"NS.relative": ref(url), "NS.base": plistlib.UID(0)})
            objects.append({"uuid": uuid, "fileUrl": url_ref})

        # Strongbox builds the URL with URLComponents.path, which percent-encodes the name.
        entry(identifier, f"strongbox-cloud:/{quote(database_name)}?uuid={identifier}")
        for other_identifier, path in extra:
            entry(other_identifier, f"strongbox-cloud:/{path}")
        entry("99999999-9999-9999-9999-999999999999",
              f"sb-sync-managed-file:///Drive/{database_name}")
        entry("88888888-8888-8888-8888-888888888888", "strongbox-cloud:/unrelated.kdbx")
        if ambiguous:
            entry("22222222-2222-2222-2222-222222222222", f"strongbox-cloud:/{database_name}")
        archive = plistlib.dumps({"$objects": objects}, fmt=plistlib.FMT_BINARY)
        self.preferences.write_bytes(plistlib.dumps({"databases": archive}))


class SyncTest(StrongboxFixture):
    def run_sync(self, expected=0):
        result = subprocess.run(["/bin/zsh", str(ROOT / "sync.zsh")],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stderr)
        self.assertFalse(list(self.target.glob(f".{self.database_name}.*")))
        return result

    def test_copy_unchanged_and_replace(self):
        backup = self.source / "20260926_120000_001.bak"
        backup.write_bytes(b"encrypted fixture one")
        self.run_sync()
        self.assertEqual(self.destination.read_bytes(), backup.read_bytes())
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o600)
        original = self.destination.stat()
        self.run_sync()
        self.assertEqual(self.destination.stat().st_ino, original.st_ino)
        self.assertEqual(self.destination.stat().st_mtime_ns, original.st_mtime_ns)
        backup.write_bytes(b"encrypted fixture two")
        self.run_sync()
        self.assertEqual(self.destination.read_bytes(), backup.read_bytes())

    def test_missing_and_empty_source_preserve_target(self):
        self.destination.write_bytes(b"keep me")
        self.run_sync(1)
        log = (self.state / "sync.log").read_text()
        self.run_sync(1)
        self.assertEqual((self.state / "sync.log").read_text(), log)
        backup = self.source / "20260926_120000_001.bak"
        backup.touch()
        self.run_sync(1)
        self.assertEqual(self.destination.read_bytes(), b"keep me")
        backup.write_bytes(b"recovered")
        self.run_sync()
        self.assertFalse((self.state / "last-error").exists())

    def test_source_emptied_after_selection_preserves_target(self):
        self.destination.write_bytes(b"valid previous mirror")
        (self.source / "test.bak").write_bytes(b"new backup")
        # Empties the selected backup right before the copy's first stat call.
        result = subprocess.run([
            "/bin/zsh", "-fc",
            'stat() { [[ -s "$3" ]] && : > "$3"; /usr/bin/stat "$@"; }; f=$1; shift; source "$f"',
            "sync-test", str(ROOT / "sync.zsh"),
        ], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("empty", result.stderr)
        self.assertEqual(self.destination.read_bytes(), b"valid previous mirror")

    def test_missing_drive_is_not_created(self):
        (self.source / "test.bak").write_bytes(b"backup")
        self.target.rmdir()
        self.run_sync(1)
        self.assertFalse(self.target.exists())

    def test_symlink_target_is_rejected(self):
        other = self.base / "other"
        other.write_bytes(b"keep me")
        self.destination.symlink_to(other)
        (self.source / "test.bak").write_bytes(b"backup")
        self.run_sync(1)
        self.assertEqual(other.read_bytes(), b"keep me")

    def test_running_job_is_not_duplicated(self):
        self.state.mkdir()
        lock = self.state / "sync.lock"
        lock.touch()
        # A second process holds the lock like a running job.
        holder = subprocess.Popen(["/bin/zsh", "-fc", 'zmodload zsh/system; zsystem flock -f fd "$1"; print locked; sleep 30',
                                   "holder", str(lock)], stdout=subprocess.PIPE, text=True)
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        self.assertEqual(holder.stdout.readline(), "locked\n")
        (self.source / "test.bak").write_bytes(b"backup")
        self.run_sync()
        self.assertFalse(self.destination.exists())

    def test_stale_lock_with_a_reused_pid_does_not_block(self):
        self.state.mkdir()
        # Left behind by a killed run; the PID now belongs to another live process.
        (self.state / "sync.lock").write_text(f"{os.getpid()}\n")
        (self.source / "test.bak").write_bytes(b"backup")
        self.run_sync()
        self.assertEqual(self.destination.read_bytes(), b"backup")

    def test_lock_failure_is_reported_and_foreign_lock_preserved(self):
        self.state.mkdir()
        lock = self.state / "sync.lock"
        lock.mkdir()
        (self.source / "test.bak").write_bytes(b"backup")
        self.run_sync(1)
        self.assertFalse(self.destination.exists())
        self.assertTrue(lock.is_dir())
        self.assertIn("lock", (self.state / "sync.log").read_text())
        self.assertTrue((self.state / "last-error").is_file())

    def test_log_failure_stops_copy_and_is_reported(self):
        self.state.mkdir()
        (self.state / "sync.log").mkdir()
        (self.source / "test.bak").write_bytes(b"backup")
        result = self.run_sync(1)
        self.assertFalse(self.destination.exists())
        self.assertIn("log file", result.stderr)
        self.assertTrue((self.state / "last-error").is_file())
        # The failed run released its lock.
        (self.state / "sync.log").rmdir()
        self.run_sync()
        self.assertEqual(self.destination.read_bytes(), b"backup")

    def test_malformed_metadata_error_is_stable_across_runs(self):
        self.preferences.write_bytes(plistlib.dumps({"databases": plistlib.dumps({})}))
        self.run_sync(1)
        error = (self.state / "last-error").read_text()
        log = (self.state / "sync.log").read_text()
        self.run_sync(1)
        self.assertEqual((self.state / "last-error").read_text(), error)
        self.assertEqual((self.state / "sync.log").read_text(), log)

    def test_launchd_configuration_without_installation(self):
        result = subprocess.run(["/bin/zsh", str(ROOT / "install.zsh"), "--print-plist"],
                                env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = plistlib.loads(result.stdout)
        self.assertEqual(config["WatchPaths"],
                         [str(self.source), str(self.backup_root), str(self.preferences)])
        self.assertEqual(config["EnvironmentVariables"], {
            name: self.env[name] for name in [
                "STRONGBOX_DATABASE_NAME", "STRONGBOX_BACKUP_ROOT", "STRONGBOX_PREFERENCES", "STRONGBOX_TARGET_DIR",
                "STRONGBOX_STATE_DIR", "STRONGBOX_NOTIFY",
                "STRONGBOX_PYTHON", "STRONGBOX_CLOUD_WARNING_SECONDS",
            ]
        })
        self.assertEqual(config["StandardOutPath"], str(self.state / "launchd.log"))
        self.assertEqual(config["StandardErrorPath"], str(self.state / "launchd.log"))
        self.assertEqual(config["StartCalendarInterval"],
                         [{"Minute": minute} for minute in [0, 15, 30, 45]])
        self.assertTrue(config["RunAtLoad"])
        self.assertEqual(config["ProgramArguments"], ["/bin/zsh", "-f", str(ROOT / "sync.zsh")])

    def test_job_ignores_the_users_zshenv(self):
        result = subprocess.run(["/bin/zsh", str(ROOT / "install.zsh"), "--print-plist"],
                                env=self.env, capture_output=True)
        job = plistlib.loads(result.stdout)
        zdotdir = self.base / "zdotdir"
        zdotdir.mkdir()
        (zdotdir / ".zshenv").write_text('print -u2 "tool loaded"\nsetopt KSH_ARRAYS\n')
        (self.source / "test.bak").write_bytes(b"backup")
        result = subprocess.run(job["ProgramArguments"], capture_output=True, text=True, env={
            "HOME": os.environ["HOME"], "ZDOTDIR": str(zdotdir), **job["EnvironmentVariables"]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.destination.read_bytes(), b"backup")

    def test_upload_check_runs_after_copy_and_when_unchanged(self):
        # A Python stand-in records checker invocations, without credentials/network.
        fake_python = self.base / "python-stand-in"
        calls = self.base / "cloud-calls"
        fake_python.write_text('#!/bin/zsh\n[[ $1 == -c ]] && exit 0\nprint -r -- "$@" >> "$CLOUD_CALLS"\nexit 1\n')
        fake_python.chmod(0o700)
        self.env.update(STRONGBOX_PYTHON=str(fake_python), CLOUD_CALLS=str(calls))
        self.state.mkdir()
        (self.state / "upload-check.json").write_text(json.dumps({"provider": "google-drive", "folder_id": "folder"}))
        backup = self.source / "test.bak"
        backup.write_bytes(b"local copy works despite cloud failure")
        self.run_sync(1)
        self.assertEqual(self.destination.read_bytes(), backup.read_bytes())
        self.assertFalse((self.state / "last-error").exists())
        inode = self.destination.stat().st_ino
        self.run_sync(1)
        self.assertEqual(self.destination.stat().st_ino, inode)
        self.assertEqual(calls.read_text().count("upload_check.py"), 2)

    def test_missing_or_old_python_replaces_stale_confirmation_and_preserves_local_copy(self):
        # The stand-in reports Python 3.9 to the version check, like /usr/bin/python3.
        old_python = self.base / "old-python"
        old_python.write_text('#!/bin/zsh\nexit 1\n')
        old_python.chmod(0o700)
        for python in (self.base / "missing-python", old_python):
            with self.subTest(python=python.name):
                self.setUp()
                self.env["STRONGBOX_PYTHON"] = str(python)
                self.state.mkdir()
                (self.state / "upload-check.json").write_text('{"provider":"google-drive","folder_id":"folder"}')
                status = self.state / "cloud-status.json"
                status.write_text(json.dumps({"status": "confirmed", "message": "Upload confirmed"}))
                backup = self.source / "test.bak"
                backup.write_bytes(b"local backup")
                self.run_sync(1)
                self.assertEqual(self.destination.read_bytes(), backup.read_bytes())
                self.assertFalse((self.state / "last-error").exists())
                current = json.loads(status.read_text())
                self.assertEqual(current["status"], "error")
                self.assertIn("Python", current["message"])
                self.assertIsNone(current["last_confirmed_at"])
                self.assertEqual(status.stat().st_mode & 0o777, 0o600)
                log = (self.state / "sync.log").read_text()
                self.run_sync(1)
                self.assertEqual((self.state / "sync.log").read_text(), log)

    def fake_osascript(self):
        """Records notifications; fails while the returned marker file exists."""
        script, calls, failing = self.base / "osascript", self.base / "notifications", self.base / "osascript-fails"
        script.write_text('#!/bin/zsh -f\nprint -r -- "$2" >> "$NOTIFICATIONS"\n[[ ! -e "$OSASCRIPT_FAILS" ]]\n')
        script.chmod(0o700)
        self.env.update(STRONGBOX_OSASCRIPT=str(script), STRONGBOX_NOTIFY="1",
                        NOTIFICATIONS=str(calls), OSASCRIPT_FAILS=str(failing))
        failing.touch()
        return calls, failing

    def test_failed_error_notification_is_retried_once_delivered(self):
        calls, failing = self.fake_osascript()
        self.run_sync(1)
        failing.unlink()
        self.run_sync(1)
        self.run_sync(1)
        self.assertEqual(calls.read_text().count("No Strongbox backup found."), 2)
        self.assertEqual((self.state / "sync.log").read_text().count("No Strongbox backup found."), 1)

    def test_failed_python_notification_is_retried_once_delivered(self):
        calls, failing = self.fake_osascript()
        self.env["STRONGBOX_PYTHON"] = str(self.base / "missing-python")
        self.state.mkdir()
        (self.state / "upload-check.json").write_text('{"provider":"google-drive","folder_id":"folder"}')
        (self.source / "test.bak").write_bytes(b"backup")
        self.run_sync(1)
        self.assertTrue(json.loads((self.state / "cloud-status.json").read_text())["notification_pending"])
        failing.unlink()
        self.run_sync(1)
        self.run_sync(1)
        self.assertEqual(calls.read_text().count("Python"), 2)
        self.assertEqual((self.state / "sync.log").read_text().count("CLOUD: Python"), 1)
        self.assertFalse(json.loads((self.state / "cloud-status.json").read_text())["notification_pending"])

    def test_orphaned_temporary_copy_is_removed(self):
        orphan = self.target / f".{self.database_name}.AbCd1234"
        orphan.write_bytes(b"interrupted copy")
        unrelated = self.target / f".{self.database_name}.keep"
        unrelated.write_bytes(b"not ours")
        (self.source / "test.bak").write_bytes(b"backup")
        result = subprocess.run(["/bin/zsh", str(ROOT / "sync.zsh")],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(orphan.exists())
        self.assertTrue(unrelated.exists())

    def test_state_dir_must_not_overlap_the_target(self):
        for state in (self.target / "state", self.base, Path("/")):
            with self.subTest(state=str(state)):
                env = dict(self.env, STRONGBOX_STATE_DIR=str(state))
                result = subprocess.run(["/bin/zsh", str(ROOT / "install.zsh"), "--print-plist"],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("must not contain each other", result.stderr)

    def test_python_must_be_an_absolute_path(self):
        env = dict(self.env, STRONGBOX_PYTHON="relative-python")
        result = subprocess.run(["/bin/zsh", str(ROOT / "install.zsh"), "--print-plist"],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("PYTHON must be an absolute path", result.stderr)

    def test_invalid_configuration_writes_nothing(self):
        # A state folder inside the mirror must not receive log or lock files.
        state = self.target / "state"
        self.env["STRONGBOX_STATE_DIR"] = str(state)
        (self.source / "test.bak").write_bytes(b"backup")
        result = subprocess.run(["/bin/zsh", str(ROOT / "sync.zsh")],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("must not contain each other", result.stderr)
        self.assertFalse(state.exists())
        self.assertFalse(self.destination.exists())

    def test_missing_personal_configuration_is_reported(self):
        for name in ("STRONGBOX_DATABASE_NAME", "STRONGBOX_TARGET_DIR"):
            with self.subTest(name=name):
                env = dict(self.env)
                del env[name]
                # An isolated copy keeps a developer's config.local.zsh out of the test.
                project = self.base / f"project-{name}"
                project.mkdir()
                for script in ("sync.zsh", "config.zsh", "strongbox-source.zsh", "install.zsh",
                               "launchagent.zsh"):
                    (project / script).write_bytes((ROOT / script).read_bytes())
                result = subprocess.run(["/bin/zsh", str(project / "sync.zsh")],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                # Without config.local.zsh the message says how to start.
                self.assertIn("Copy config.local.example.zsh to config.local.zsh", result.stderr)
                result = subprocess.run(["/bin/zsh", str(project / "install.zsh"), "--print-plist"],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn("config.local.zsh", result.stderr)

    def test_ambiguous_metadata_preserves_target(self):
        self.destination.write_bytes(b"keep me")
        (self.source / "test.bak").write_bytes(b"wrong")
        self.write_metadata(self.identifier, ambiguous=True)
        self.run_sync(1)
        self.assertEqual(self.destination.read_bytes(), b"keep me")

class SourceTest(StrongboxFixture):
    def run_source(self, command="latest-backup", expected=0):
        result = subprocess.run([
            "/bin/zsh", str(ROOT / "strongbox-source.zsh"), command,
            str(self.preferences), str(self.backup_root), self.database_name,
        ], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stderr)
        if expected:
            self.assertEqual(result.stdout, "")
            self.assertTrue(result.stderr.strip())
        else:
            self.assertEqual(result.stderr, "")
        return result

    def test_watch_directory_can_be_empty(self):
        self.assertEqual(self.run_source("watch-dir").stdout.strip(), str(self.source))
        self.run_source(expected=1)

    def test_disappearing_backup_has_stable_error(self):
        errors = []
        for filename in ["first.bak", "second.bak"]:
            (self.source / filename).write_bytes(b"backup")
            # Remove the selected fixture immediately before the real stat call.
            # This makes Strongbox backup rotation deterministic for this test.
            result = subprocess.run([
                "/bin/zsh", "-c",
                'stat() { /bin/rm -- "$3"; /usr/bin/stat "$@"; }; '
                'source "$1" latest-backup "$2" "$3" "$4"',
                "source-test", str(ROOT / "strongbox-source.zsh"),
                str(self.preferences), str(self.backup_root), self.database_name,
            ], env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout, "")
            errors.append(result.stderr)
        self.assertEqual(errors[0], errors[1])
        self.assertEqual(errors[0], "Could not check a backup.\n")

    def test_latest_empty_file_is_rejected_even_with_older_backup(self):
        backup = self.source / "old.bak"
        backup.write_bytes(b"valid")
        time.sleep(0.02)
        (self.source / "new.bak").touch()
        self.run_source(expected=1)

    def test_non_backup_and_non_regular_files_are_ignored(self):
        backup = self.source / "old.bak"
        backup.write_bytes(b"valid")
        time.sleep(0.02)
        (self.source / "new.txt").write_bytes(b"not a backup")
        (self.source / "directory.bak").mkdir()
        (self.source / "link.bak").symlink_to(backup)
        self.assertEqual(self.run_source().stdout.strip(), str(backup))

    def test_missing_and_ambiguous_mapping_fail(self):
        self.write_metadata(self.identifier, database_name="other.kdbx")
        self.assertIn("Check DATABASE_NAME", self.run_source(expected=1).stderr)
        self.write_metadata(self.identifier, ambiguous=True)
        self.assertIn("unambiguously", self.run_source(expected=1).stderr)

    def test_creation_time_not_modification_time(self):
        older = self.source / "20260926_120000_001.bak"
        older.write_bytes(b"old")
        time.sleep(1.1)
        newer = self.source / "20260926_121500_001.bak"
        newer.write_bytes(b"new")
        os.utime(older, (time.time() + 3600, time.time() + 3600))
        self.assertEqual(self.run_source().stdout.strip(), str(newer))

    def test_subsecond_creation_order_beats_filename_order(self):
        (self.source / "z.bak").write_bytes(b"old")
        time.sleep(0.02)
        newer = self.source / "a.bak"
        newer.write_bytes(b"new")
        self.assertEqual(self.run_source().stdout.strip(), str(newer))

    def test_changed_uuid_is_resolved_on_next_run(self):
        (self.source / "test.bak").write_bytes(b"old location")
        self.assertEqual(self.run_source().stdout.strip(), str(self.source / "test.bak"))
        new_id = "33333333-3333-3333-3333-333333333333"
        new_source = self.backup_root / new_id
        new_source.mkdir()
        (new_source / "test.bak").write_bytes(b"new location")
        self.write_metadata(new_id)
        self.assertEqual(self.run_source().stdout.strip(), str(new_source / "test.bak"))

    def test_encoded_names_select_their_own_database(self):
        names = {self.identifier: "My Passwords.kdbx", "44444444-4444-4444-4444-444444444444": "My%20Passwords.kdbx",
                 "55555555-5555-5555-5555-555555555555": "Pässwörter.kdbx"}
        for identifier, name in names.items():
            (self.backup_root / identifier).mkdir(exist_ok=True)
        self.write_metadata(self.identifier, database_name=names[self.identifier],
                            extra=[(identifier, quote(name)) for identifier, name in names.items()
                                   if identifier != self.identifier])
        for identifier, name in names.items():
            with self.subTest(name=name):
                self.database_name = name
                self.assertEqual(self.run_source("watch-dir").stdout.strip(),
                                 str(self.backup_root / identifier))

    def test_malformed_encoding_is_not_a_match(self):
        self.write_metadata(self.identifier, database_name="other.kdbx",
                            extra=[(self.identifier, "Passw%2.kdbx")])
        self.database_name = "Passw%2.kdbx"
        self.run_source("watch-dir", expected=1)

    def test_unrelated_database_is_ignored(self):
        (self.source / "test.bak").write_bytes(b"right")
        other = self.backup_root / "99999999-9999-9999-9999-999999999999"
        other.mkdir()
        (other / "test.bak").write_bytes(b"wrong")
        self.assertEqual(self.run_source().stdout.strip(), str(self.source / "test.bak"))


if __name__ == "__main__":
    unittest.main()
