"""Policy checks for the GitHub Actions workflows."""
from pathlib import Path
import unittest

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML ships with the GitHub ubuntu images
    yaml = None

WORKFLOWS = Path(__file__).resolve().parents[1] / ".github" / "workflows"


def load(name):
    return yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))


@unittest.skipUnless(yaml, "PyYAML is not installed")
class WorkflowPolicyTests(unittest.TestCase):
    def test_desktop_update_failure_does_not_fail_the_build(self):
        job = load("vcp-build-release.yml")["jobs"]["deploy-chat"]
        self.assertIs(job.get("continue-on-error"), True)
        notices = [s for s in job["steps"] if str(s.get("if", "")).strip() == "failure()"]
        self.assertEqual(len(notices), 1, "a failed client update must leave a visible warning")
        self.assertIn("::warning", notices[0]["run"])

    def test_windows_powershell_blocks_are_ascii(self):
        # PowerShell 5.1 on the self-hosted runner reads run blocks in the system
        # code page (GBK); non-ASCII text there breaks quoting at run time.
        for name in ("vcp-build-release.yml", "vcp-deploy-sync.yml"):
            for job_id, job in load(name)["jobs"].items():
                for step in job.get("steps", []):
                    if step.get("shell") == "powershell" and "run" in step:
                        with self.subTest(workflow=name, job=job_id, step=step.get("name")):
                            step["run"].encode("ascii")


if __name__ == "__main__":
    unittest.main()
