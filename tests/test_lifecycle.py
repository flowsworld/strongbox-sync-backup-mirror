"""Install, update, and uninstall in a temporary HOME.

Stand-ins replace launchctl and security, so no real job or keychain entry is touched.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from test_sync import ROOT, StrongboxFixture

LABEL = "cloud.diesis.strongbox-sync-backup-mirror"
GOOGLE_SERVICE = f"{LABEL}.google-drive"
SECRET = "c2VjcmV0LWNyZWRlbnRpYWxz"

# Loaded jobs are files in $FAKE_LAUNCHD/loaded; every call is appended to calls.
FAKE_LAUNCHCTL = r"""#!/bin/zsh
print -r -- "$*" >> "$FAKE_LAUNCHD/calls"
case "$1" in
    print) [[ -f "$FAKE_LAUNCHD/loaded/${2:t}" ]] ;;
    bootout) rm -f -- "$FAKE_LAUNCHD/loaded/${2:t}" ;;
    bootstrap) touch "$FAKE_LAUNCHD/loaded/$(/usr/bin/plutil -extract Label raw -o - "$3")" ;;
    *) exit 1 ;;
esac
"""

# Entries are files named "service@account" in $FAKE_KEYCHAIN.
FAKE_SECURITY = r"""#!/bin/zsh
command="$1"; shift
if [[ "$command" == -i ]]; then
    read -r line
    set -- ${(z)line}
    command="$1"; shift
fi
service='' account='*' secret='' print_secret=0
while (( $# )); do
    case "$1" in
        -s) service="$2"; shift 2 ;;
        -a) account="$2"; shift 2 ;;
        -w) if [[ "$command" == add-generic-password ]]; then secret="$2"; shift 2; else print_secret=1; shift; fi ;;
        *) shift ;;
    esac
done
matches=("$FAKE_KEYCHAIN/$service@"${~account}(N))
case "$command" in
    find-generic-password)
        (( ${#matches} )) || exit 44
        (( ! print_secret )) || cat -- "$matches[1]" ;;
    add-generic-password) print -r -- "$secret" > "$FAKE_KEYCHAIN/$service@$account" ;;
    delete-generic-password)
        # A locked keychain refuses deletions with a code other than 44.
        [[ ! -e "$FAKE_KEYCHAIN.locked" ]] || exit 36
        (( ${#matches} )) || exit 44
        rm -f -- "$matches[1]" ;;
    *) exit 1 ;;
esac
"""


class LifecycleTest(StrongboxFixture):
    def setUp(self):
        super().setUp()
        self.home = self.base / "home"
        self.project = self.base / "project"
        self.project.mkdir()
        for path in ROOT.iterdir():
            if path.suffix in {".zsh", ".py"} and path.name != "config.local.zsh":
                shutil.copy2(path, self.project / path.name)
        self.launchd = self.base / "launchd"
        (self.launchd / "loaded").mkdir(parents=True)
        self.keychain = self.base / "keychain"
        self.keychain.mkdir()
        tools = self.base / "tools"
        tools.mkdir()
        for name, script in (("launchctl", FAKE_LAUNCHCTL), ("security", FAKE_SECURITY)):
            (tools / name).write_text(script)
            (tools / name).chmod(0o700)
        # No STRONGBOX_* settings: the scripts read config.local.zsh like a real install.
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.home), "TMPDIR": str(self.base),
                    "STRONGBOX_LAUNCHCTL": str(tools / "launchctl"), "STRONGBOX_STOP_SECONDS": "1",
                    "STRONGBOX_SECURITY": str(tools / "security"),
                    "FAKE_LAUNCHD": str(self.launchd), "FAKE_KEYCHAIN": str(self.keychain)}
        self.agents = self.home / "Library/LaunchAgents"
        self.state = self.home / "Library/Application Support/strongbox-sync-backup-mirror"
        (self.source / "20260926_120000_001.bak").write_bytes(b"encrypted backup")
        self.write_config()

    def write_config(self, extra=""):
        (self.project / "config.local.zsh").write_text(
            f"DATABASE_NAME='{self.database_name}'\nTARGET_DIR='{self.target}'\n"
            f"BACKUP_ROOT='{self.backup_root}'\nPREFERENCES='{self.preferences}'\n{extra}")

    def run_script(self, *arguments, expected=0):
        result = subprocess.run(["/bin/zsh", str(self.project / arguments[0]), *arguments[1:]],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def calls(self):
        path = self.launchd / "calls"
        return path.read_text() if path.exists() else ""

    def loaded(self):
        return sorted(path.name for path in (self.launchd / "loaded").iterdir())

    def test_install_and_update_load_one_job(self):
        self.run_script("install.zsh")
        self.assertEqual(self.loaded(), [LABEL])
        self.assertTrue(self.state.is_dir())
        job = plistlib.loads((self.agents / f"{LABEL}.plist").read_bytes())
        self.assertEqual(job["EnvironmentVariables"]["STRONGBOX_STATE_DIR"], str(self.state))
        # Outside a git checkout, update.zsh only reinstalls.
        result = self.run_script("update.zsh")
        self.assertIn("Not a git checkout", result.stdout)
        self.assertEqual(self.loaded(), [LABEL])

    def test_failed_reinstall_restores_the_previous_job(self):
        self.run_script("install.zsh")
        before = (self.agents / f"{LABEL}.plist").read_bytes()
        # The stand-in rejects exactly one bootstrap, the one of the reinstall.
        launchctl = Path(self.env["STRONGBOX_LAUNCHCTL"])
        launchctl.write_text(launchctl.read_text().replace(
            "    bootstrap)", '    bootstrap) [[ -f "$FAKE_LAUNCHD/fail-once" ]] && { rm "$FAKE_LAUNCHD/fail-once"; exit 5; };'))
        (self.launchd / "fail-once").touch()
        self.write_config("NOTIFY=0\n")
        result = self.run_script("install.zsh", expected=5)
        self.assertIn("Restarted the job", result.stderr)
        self.assertEqual(self.loaded(), [LABEL])
        self.assertEqual((self.agents / f"{LABEL}.plist").read_bytes(), before)

    def reject_new_bootstrap(self, action):
        """Makes the stand-in run ACTION instead of loading the next bootstrap."""
        launchctl = Path(self.env["STRONGBOX_LAUNCHCTL"])
        launchctl.write_text(launchctl.read_text().replace(
            "    bootstrap)", f'    bootstrap) [[ -f "$FAKE_LAUNCHD/reject" ]] && {{ rm "$FAKE_LAUNCHD/reject"; {action}; }};'))
        (self.launchd / "reject").touch()

    def test_interrupted_reinstall_restores_the_previous_job(self):
        self.run_script("install.zsh")
        before = (self.agents / f"{LABEL}.plist").read_bytes()
        self.write_config("NOTIFY=0\n")
        # Ctrl-C while the new job loads.
        self.reject_new_bootstrap("kill -INT $PPID; sleep 1; exit 0")
        result = self.run_script("install.zsh", expected=130)
        self.assertIn("Restarted the job", result.stderr)
        self.assertEqual(self.loaded(), [LABEL])
        self.assertEqual((self.agents / f"{LABEL}.plist").read_bytes(), before)

    def test_interrupt_after_the_new_job_loaded_keeps_it(self):
        self.run_script("install.zsh")
        self.write_config("NOTIFY=0\n")
        self.reject_new_bootstrap(f'touch "$FAKE_LAUNCHD/loaded/{LABEL}"; kill -INT $PPID; sleep 1; exit 0')
        result = self.run_script("install.zsh", expected=130)
        self.assertNotIn("still stopping", result.stderr)
        self.assertEqual(self.loaded(), [LABEL])
        job = plistlib.loads((self.agents / f"{LABEL}.plist").read_bytes())
        self.assertEqual(job["EnvironmentVariables"]["STRONGBOX_NOTIFY"], "0")

    def test_failed_restore_is_reported(self):
        self.run_script("install.zsh")
        # Both the new bootstrap and the restore fail.
        launchctl = Path(self.env["STRONGBOX_LAUNCHCTL"])
        launchctl.write_text(launchctl.read_text().replace("    bootstrap)", "    bootstrap) exit 5;"))
        result = self.run_script("install.zsh", expected=5)
        self.assertIn("Could not restart the job", result.stderr)

    def test_uninstall_removes_the_plist_even_if_the_job_does_not_stop(self):
        self.run_script("install.zsh")
        launchctl = Path(self.env["STRONGBOX_LAUNCHCTL"])
        launchctl.write_text(launchctl.read_text().replace("    bootout) rm -f --", "    bootout) : "))
        result = self.run_script("uninstall.zsh", expected=1)
        self.assertIn("Could not stop the job", result.stderr)
        # Otherwise the job would come back at the next login.
        self.assertFalse((self.agents / f"{LABEL}.plist").exists())

    def test_uninstall_keeps_state_and_purge_removes_it(self):
        self.run_script("install.zsh")
        (self.state / "sync.log").write_text("log\n")
        (self.keychain / f"{GOOGLE_SERVICE}@oauth").write_text(SECRET + "\n")
        result = self.run_script("uninstall.zsh")
        self.assertIn(f"Kept {self.state}", result.stdout)
        self.assertFalse((self.agents / f"{LABEL}.plist").exists())
        self.assertEqual(self.loaded(), [])
        self.assertTrue((self.state / "sync.log").exists())
        self.assertTrue((self.keychain / f"{GOOGLE_SERVICE}@oauth").exists())
        # Without upload-check.json the sign-in must still go.
        self.run_script("uninstall.zsh", "--purge")
        self.assertFalse(self.state.exists())
        self.assertEqual(list(self.keychain.iterdir()), [])
        self.assertTrue((self.project / "config.local.zsh").exists())

    def test_purge_reports_a_keychain_entry_it_could_not_delete(self):
        self.run_script("install.zsh")
        (self.keychain / f"{GOOGLE_SERVICE}@oauth").write_text(SECRET + "\n")
        Path(f"{self.keychain}.locked").touch()
        result = self.run_script("uninstall.zsh", "--purge", expected=1)
        self.assertIn(f"Could not delete the keychain entry {GOOGLE_SERVICE}", result.stderr)
        self.assertEqual(self.loaded(), [])
        self.assertFalse(self.state.exists())

    def test_state_folder_is_not_a_user_setting(self):
        # uninstall.zsh --purge deletes the state folder as a whole, so it must
        # always be the tool's own folder.
        self.write_config(f"STATE_DIR='{self.base}'\n")
        self.run_script("install.zsh")
        job = plistlib.loads((self.agents / f"{LABEL}.plist").read_bytes())
        self.assertEqual(job["EnvironmentVariables"]["STRONGBOX_STATE_DIR"], str(self.state))

    def test_purge_removes_a_linked_state_folder_but_not_its_destination(self):
        external = self.base / "external"
        external.mkdir()
        (external / "sync.log").write_text("not ours")
        self.state.parent.mkdir(parents=True)
        self.state.symlink_to(external)
        self.run_script("uninstall.zsh", "--purge")
        self.assertFalse(self.state.is_symlink())
        self.assertEqual((external / "sync.log").read_text(), "not ours")

    def test_purge_keeps_a_mirror_inside_the_state_folder(self):
        # install.zsh rejects this layout, but a hand-made one must survive a purge.
        mirror = self.state / "mirror"
        mirror.mkdir(parents=True)
        (mirror / self.database_name).write_bytes(b"mirrored copy")
        (self.project / "config.local.zsh").write_text(
            f"DATABASE_NAME='{self.database_name}'\nTARGET_DIR='{mirror}'\n")
        result = self.run_script("uninstall.zsh", "--purge", expected=1)
        self.assertIn("TARGET_DIR lies inside it", result.stderr)
        self.assertEqual((mirror / self.database_name).read_bytes(), b"mirrored copy")

    def test_uninstall_works_with_a_broken_configuration(self):
        self.run_script("install.zsh")
        (self.state / "sync.log").write_text("log\n")
        (self.project / "config.local.zsh").write_text("if then\n")
        self.run_script("uninstall.zsh", "--purge")
        self.assertEqual(self.loaded(), [])
        self.assertFalse(self.state.exists())

    def test_keychain_service_matches_the_google_drive_provider(self):
        import google_drive
        self.assertEqual((google_drive.SERVICE, google_drive.ACCOUNT), (GOOGLE_SERVICE, "oauth"))

    def test_uninstall_knows_every_upload_check_provider(self):
        import upload_check
        result = subprocess.run(["/bin/zsh", "-c", 'source "$1"; print -rl -- $UPLOAD_CHECK_PROVIDERS',
                                 "test", str(ROOT / "launchagent.zsh")], capture_output=True, text=True)
        self.assertEqual(result.stdout.split(), sorted(upload_check.PROVIDERS))


if __name__ == "__main__":
    unittest.main()
