"""Static checks for deploy/update-chat.ps1 (it only runs on the Windows runner)."""
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "deploy" / "update-chat.ps1"


class UpdateChatScriptTests(unittest.TestCase):
    def setUp(self):
        self.raw = SCRIPT.read_bytes()
        self.text = self.raw.decode("utf-8-sig")

    def test_keeps_utf8_bom(self):
        # PowerShell 5.1 reads a BOM-less script in the system code page (GBK).
        self.assertTrue(self.raw.startswith(b"\xef\xbb\xbf"))

    def test_user_data_is_moved_aside_before_anything_deletes_the_install(self):
        # The packaged client keeps chats and settings in <install>\AppData.
        stash = self.text.index("Move-Item -LiteralPath $dataDir -Destination $dataKeep")
        uninstall = self.text.index("$uninst = Get-ChildItem $InstallDir")
        wipe = self.text.index("if (Test-Path $InstallDir) { Remove-Item $InstallDir")
        self.assertLess(stash, uninstall)
        self.assertLess(stash, wipe)

    def test_user_data_is_restored_after_install_and_on_failure(self):
        install_done = self.text.index('Log "解压完成"')
        restore_after_install = self.text.index("Restore-UserData", install_done)
        shortcut = self.text.index("# ---- 5.5.")
        self.assertLess(restore_after_install, shortcut)
        failure = self.text.index('Log "更新失败: $_"')
        self.assertIn("try { Restore-UserData }", self.text[failure:])

    def test_backup_copy_skips_user_data(self):
        self.assertIn('if ($item.Name -eq "AppData") { continue }', self.text)


if __name__ == "__main__":
    unittest.main()
