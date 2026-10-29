import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'patch-dockerfile.py'
spec = importlib.util.spec_from_file_location('patch_dockerfile', SCRIPT)
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)
UPSTREAM = (ROOT / 'tests' / 'fixtures' / 'Dockerfile.85728b72').read_text(encoding='utf-8')


class DockerfilePatchTests(unittest.TestCase):
    def test_runtime_check_runs_after_native_dependencies_are_copied(self):
        result = patch.patch_dockerfile(UPSTREAM)
        build, runtime = result.split('FROM node:20-alpine\n', 1)
        self.assertIn('  gcompat \\\n', build)
        self.assertIn('  gcompat \\\n', runtime)
        self.assertLess(runtime.index('COPY --from=build /usr/src/app/node_modules'),
                        runtime.index('RUN node ./vcp-ci-smoke-triviumdb.cjs'))
        self.assertIn('COPY --from=build /usr/src/app/vcp-ci-smoke-triviumdb.cjs', runtime)
        self.assertIn(patch.MARKER, build)

    def test_repeated_patch_is_identical(self):
        once = patch.patch_dockerfile(UPSTREAM)
        self.assertEqual(patch.patch_dockerfile(once), once)

    def test_existing_plugin_patch_still_gets_runtime_fix(self):
        anchor = '\n# 查找所有插件目录下的 requirements.txt'
        older_patch = UPSTREAM.replace(anchor, '\n' + patch.BLOCK + anchor, 1)
        updated = patch.patch_dockerfile(older_patch)
        self.assertEqual(updated.count(patch.MARKER), 1)
        self.assertEqual(updated.count(patch.SMOKE_MARKER), 1)
        self.assertEqual(updated.count('  gcompat \\\n'), 2)

    def test_upstream_stage_changes_require_review(self):
        with self.assertRaises(ValueError):
            patch.patch_dockerfile(UPSTREAM.replace('node:20-alpine', 'node:20-bookworm'))
        with self.assertRaises(ValueError):
            patch.patch_dockerfile(UPSTREAM.replace('COPY --from=build /usr/src/app/AdminPanel-Vue/dist ./AdminPanel-Vue/dist',
                                                   'COPY --from=build /another/dist ./dist'))

    def test_cli_stages_reviewed_probe_in_upstream_build_context(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / 'Dockerfile'
            target.write_bytes(UPSTREAM.replace('\n', '\r\n').encode('utf-8'))
            command = [sys.executable, str(SCRIPT), str(target)]
            first = subprocess.run(command, capture_output=True, check=True)
            self.assertNotIn(b'\r\n', target.read_bytes())
            probe = target.with_name(patch.SMOKE_NAME)
            self.assertEqual(probe.read_bytes(), patch.SMOKE_SOURCE.read_bytes().replace(b'\r\n', b'\n'))
            saved = target.read_bytes()
            subprocess.run(command, capture_output=True, check=True)
            self.assertEqual(target.read_bytes(), saved)
            self.assertEqual(first.returncode, 0)


if __name__ == '__main__':
    unittest.main()
