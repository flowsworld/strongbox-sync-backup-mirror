"""Release CLI rejection paths. Never compile, sign, install or launch an app."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]
RELEASES = ROOT / "macos-app" / "build" / "releases"


class ReleaseTest(unittest.TestCase):
    def run_release(self, *arguments):
        return subprocess.run(
            ["/bin/zsh", str(ROOT / "macos-app" / "release.zsh"), *arguments],
            capture_output=True, text=True, timeout=10,
        )

    def test_malformed_and_unsupported_release_requests_are_rejected(self):
        for arguments in [
            (), ("development", "1.2", "1"),
            ("development", "1.2.3", "0"),
            ("development", "1.2.3/other", "1"),
            ("development", "1.2.3", "../other"),
            ("development", "1.2.3", "1", "-"),
            ("app-store", "1.2.3", "1"),
        ]:
            with self.subTest(arguments=arguments):
                result = self.run_release(*arguments)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Building for", result.stdout + result.stderr)

    def test_direct_release_never_falls_back_to_ad_hoc_signing(self):
        result = self.run_release("direct", "1.2.3", "1", "-")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("explicit Developer ID", result.stderr)

    def test_existing_release_is_preserved_without_compilation(self):
        RELEASES.mkdir(parents=True, exist_ok=True)
        build = str(uuid.uuid4().int)
        with tempfile.TemporaryDirectory(prefix="release-marker-") as temporary:
            target = Path(temporary)
            marker = target / "previous.zip"
            marker.write_bytes(b"existing release fixture")
            release = RELEASES / f"development-1.2.3-{build}"
            release.symlink_to(target, target_is_directory=True)
            self.addCleanup(release.unlink, missing_ok=True)
            result = self.run_release("development", "1.2.3", build)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("already exists", result.stderr)
            self.assertTrue(release.is_symlink())
            self.assertEqual(marker.read_bytes(), b"existing release fixture")
            self.assertFalse(Path(str(release) + ".lock").exists())

    def test_concurrent_packager_lock_is_preserved(self):
        RELEASES.mkdir(parents=True, exist_ok=True)
        build = str(uuid.uuid4().int)
        lock = RELEASES / f"development-1.2.3-{build}.lock"
        lock.mkdir()
        self.addCleanup(lock.rmdir)
        result = self.run_release("development", "1.2.3", build)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("already being packaged", result.stderr)
        self.assertTrue(lock.is_dir())


if __name__ == "__main__":
    unittest.main()
