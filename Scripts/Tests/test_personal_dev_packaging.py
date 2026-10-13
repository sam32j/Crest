"""Personal builds stay isolated and preserve Chromium's executable-memory signing."""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "chromium_packager", Path(__file__).resolve().parents[1] / "control-plane/package-chromium-host.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PersonalDevPackagingTests(unittest.TestCase):
    def test_personal_mode_refuses_product_and_provisioning(self):
        for forbidden in (["--product"], ["--baseline"], ["--distribution"],
                          ["--provisioning-profile", "/tmp/profile"], ["--entitlements", "/tmp/entitlements"]):
            with self.subTest(forbidden=forbidden), patch.object(sys, "argv", [
                "package", "--browser", "/tmp/browser.app", "--output", "/tmp/output.app",
                "--personal", "--signing-identity=-", *forbidden
            ]), contextlib.redirect_stderr(io.StringIO()) as error:
                with self.assertRaises(SystemExit) as refused:
                    packager.main()
                self.assertEqual(refused.exception.code, 2)
                self.assertIn("isolated review package", error.getvalue())

    def sign_fixture(self, identity):
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Review.app"
            for name in ("Chromium Helper (Renderer).app", "Chromium Helper (GPU).app", "Chromium Helper.app"):
                helper = app / "Contents/Frameworks/Engine.framework/Versions/A/Helpers" / name
                helper.mkdir(parents=True)
            def record(command, **kwargs):
                entitlements = {}
                if "--entitlements" in command:
                    entitlements = plistlib.loads(Path(command[command.index("--entitlements") + 1]).read_bytes())
                calls.append((command, entitlements))
            with patch.object(packager.subprocess, "run", side_effect=record):
                packager.sign_for_distribution(app, identity, {})
        return calls

    def test_personal_signing_preserves_renderer_and_gpu_jit(self):
        calls = self.sign_fixture("-")
        for helper in ("Chromium Helper (Renderer).app", "Chromium Helper (GPU).app"):
            signed = next(entitlements for command, entitlements in calls if Path(command[-1]).name == helper)
            self.assertTrue(signed["com.apple.security.cs.allow-jit"])
        for command, _ in calls:
            self.assertEqual(command[command.index("--sign") + 1], "-")
            self.assertNotIn("runtime", command)
            self.assertIn("--timestamp=none", command)

    def test_distribution_signing_retains_hardened_runtime(self):
        for command, _ in self.sign_fixture("Developer ID Application: Fixture"):
            self.assertIn("--timestamp", command)
            self.assertEqual(command[command.index("--options") + 1], "runtime")


if __name__ == "__main__":
    unittest.main()
