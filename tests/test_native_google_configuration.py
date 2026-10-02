import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "macos-app/scripts/configure-google-client.py"
spec = importlib.util.spec_from_file_location("native_google_configuration", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeGoogleConfigurationTests(unittest.TestCase):
    def test_accepts_explicit_native_client_configuration(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "client.env"
            path.write_text("GOOGLE_DRIVE_NATIVE_PROJECT_ID=native-drive-test\nGOOGLE_DRIVE_NATIVE_CLIENT_ID=123-fixture.apps.googleusercontent.com\nGOOGLE_DRIVE_NATIVE_CLIENT_SECRET=GOCSPX-fixture\n")
            values = module.read_configuration(path)
            self.assertEqual(values["GOOGLE_DRIVE_NATIVE_CLIENT_ID"], "123-fixture.apps.googleusercontent.com")

    def test_rejects_shell_text_duplicate_keys_and_foreign_credentials(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "client.env"
            for contents in ["GOOGLE_DRIVE_NATIVE_CLIENT_ID=$(touch /tmp/never-run)\n", "GOOGLE_DRIVE_NATIVE_CLIENT_ID=123.apps.googleusercontent.com\nGOOGLE_DRIVE_NATIVE_CLIENT_ID=456.apps.googleusercontent.com\n", "GOOGLE_REFRESH_TOKEN=fake\n", "GOOGLE_DRIVE_NATIVE_CLIENT_ID=web.example.com\n"]:
                with self.subTest(contents=contents):
                    path.write_text(contents)
                    with self.assertRaises(ValueError):
                        module.read_configuration(path)

    def test_rejects_symlinks_and_oversized_files(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / "target.env"
            target.write_text("GOOGLE_DRIVE_NATIVE_CLIENT_ID=123.apps.googleusercontent.com\n")
            link = Path(root) / "link.env"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                module.read_configuration(link)
            target.write_bytes(b"x" * 65_537)
            with self.assertRaises(ValueError):
                module.read_configuration(target)
