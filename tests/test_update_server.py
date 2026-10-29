"""Isolated deployment regression tests; Docker and HTTP calls are never real."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import re
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1] / 'deploy'
spec = importlib.util.spec_from_file_location('prepare', HERE / 'prepare-server-compose.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)

DOCKER_MOCK = r'''
import json, os, pathlib, re, sys
p = pathlib.Path(os.environ['MOCK_STATE'])
s = json.loads(p.read_text())
a = sys.argv[1:]
s['calls'].append(a)
code = 0
if a[:2] == ['compose', 'ps']:
    if '-q' in a: print('running-container')
elif a[:1] == ['inspect']:
    print(s['running_ref'] if a[2] == '{{.Config.Image}}' else s['running_id'])
elif a[:2] == ['image', 'tag']:
    s['images'][a[3]] = s['images'].get(a[2], a[2])
elif a[:1] == ['pull']:
    s['images'][a[1]] = os.environ.get('MOCK_PULLED_ID', 'sha256:new')
elif a[:2] == ['image', 'inspect']:
    print(s['images'][a[-1]])
elif a[:2] == ['compose', 'up']:
    override = pathlib.Path('docker-compose.override.yml').read_text()
    value = re.search(r'^\s+image:\s*(.*)$', override, re.M).group(1)
    ref = json.loads(value) if value.startswith('"') else value
    s['running_ref'], s['running_id'] = ref, s['images'][ref]
elif a[:2] == ['compose', 'exec']:
    sys.stdin.read()
    code = int(os.environ.get('MOCK_HEALTH_FAIL', '0'))
elif a[:1] == ['compose'] and 'config' in a:
    pass
else:
    print('Unexpected mock Docker invocation: ' + repr(a), file=sys.stderr)
    code = 2
p.write_text(json.dumps(s))
sys.exit(code)
'''


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / 'production with spaces'
        self.base.mkdir()
        self.config = self.base / 'config.env'
        self.config.write_text('API_Key=production-secret\nTDB_KNOWLEDGE_MODEL=user-model\n', encoding='utf-8')
        (self.base / 'rag_params.json').write_text('{"userSetting": 7}', encoding='utf-8')
        (self.base / 'knowledge').mkdir()
        (self.base / 'knowledge' / 'user source.md').write_text('irreplaceable source', encoding='utf-8')
        (self.base / 'dailynote').mkdir()
        (self.base / 'docker-compose.yml').write_text('services:\n  app:\n    image: repo/same:abc\n')
        self.override = self.base / 'docker-compose.override.yml'
        self.old_override = 'services:\n  app:\n    image: repo/same:abc\n'
        self.override.write_text(self.old_override)
        self.env = dict(os.environ, DEPLOY_DIR=self.base.as_posix(), TARGET_IMAGE='repo/same:abc',
                        FORCE='1', HEALTH_ATTEMPTS='1', HEALTH_DELAY_SECONDS='0', HEALTH_URL='')
        for name in ('KNOWLEDGE_SOURCE_DIR', 'TDB_STORE_DIR', 'RAG_PARAMS_FILE',
                     'TDB_KNOWLEDGE_ROOT_PATH', 'TDB_KNOWLEDGE_STORE_PATH'):
            self.env.pop(name, None)

    def render(self, **updates):
        env = dict(self.env, **updates)
        output = self.root / 'candidate.yml'
        prepare.prepare(HERE / 'docker-compose.deploy.yml', output, env)
        return output.read_text(encoding='utf-8')

    def assert_data_preserved(self):
        self.assertEqual(self.config.read_text(), 'API_Key=production-secret\nTDB_KNOWLEDGE_MODEL=user-model\n')
        self.assertEqual((self.base / 'rag_params.json').read_text(), '{"userSetting": 7}')
        self.assertEqual((self.base / 'knowledge' / 'user source.md').read_text(), 'irreplaceable source')

    def test_missing_rag_fails_without_creating_path_or_database(self):
        (self.base / 'rag_params.json').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing rag_params'):
            self.render()
        self.assertFalse((self.base / 'rag_params.json').exists())
        self.assertFalse((self.base / 'VectorStoreTDB').exists())

    def test_existing_config_paths_and_explicit_host_paths_are_consistent(self):
        self.config.write_text('TDB_KNOWLEDGE_ROOT_PATH="/custom/冷知识" # keep\n'
                               "TDB_KNOWLEDGE_STORE_PATH='relative/db'\nAPI_Key=private\n", encoding='utf-8')
        output = self.render(KNOWLEDGE_SOURCE_DIR='custom source', TDB_STORE_DIR='custom $db')
        self.assertEqual(output.count('"/custom/冷知识"'), 2)
        self.assertEqual(output.count('"/usr/src/app/relative/db"'), 2)
        self.assertIn('custom $$db', output)
        self.assertNotIn('private', output)
        self.assertTrue((self.base / 'custom source').is_dir())
        self.assertTrue((self.base / 'custom $db').is_dir())

    def test_overlapping_and_application_hiding_mounts_are_rejected(self):
        for updates in ({'TDB_KNOWLEDGE_ROOT_PATH': '/usr/src/app/node_modules'},
                        {'TDB_KNOWLEDGE_STORE_PATH': '/usr/src/app/knowledge/db'},
                        {'TDB_STORE_DIR': 'knowledge/db'}):
            with self.subTest(updates=updates), self.assertRaisesRegex(ValueError, 'overlap'):
                self.render(**updates)

    @unittest.skipIf(os.name == 'nt', 'POSIX ownership/mode semantics')
    def test_new_store_inherits_knowledge_mode_and_owner(self):
        source = self.base / 'knowledge'
        source.chmod(0o750)
        self.render()
        store = self.base / 'VectorStoreTDB'
        self.assertEqual(store.stat().st_mode & 0o777, 0o750)
        self.assertEqual((store.stat().st_uid, store.stat().st_gid), (source.stat().st_uid, source.stat().st_gid))
        self.assertEqual(source.stat().st_mode & 0o777, 0o750)

    def run_script(self, pulled='sha256:new', health_fail=False):
        bash = shutil.which('bash')
        if not bash:
            self.skipTest('bash not installed')
        binary = self.root / 'bin'
        binary.mkdir(exist_ok=True)
        implementation = self.root / 'mock-docker.py'
        implementation.write_text(DOCKER_MOCK, encoding='utf-8')
        for name, command in [('docker', f'exec "{Path(sys.executable).as_posix()}" "$MOCK_IMPL" "$@"'),
                              ('python3', f'exec "{Path(sys.executable).as_posix()}" "$@"')]:
            wrapper = binary / name
            wrapper.write_text('#!/usr/bin/env bash\n' + command + '\n', encoding='utf-8', newline='\n')
            wrapper.chmod(0o755)
        state = self.root / 'docker-state.json'
        state.write_text(json.dumps({'running_ref': 'repo/same:abc', 'running_id': 'sha256:old',
                                    'images': {'repo/same:abc': 'sha256:old'}, 'calls': []}))
        env = dict(self.env, PATH=str(binary) + os.pathsep + os.environ['PATH'],
                   MOCK_IMPL=implementation.as_posix(), MOCK_STATE=state.as_posix(),
                   MOCK_PULLED_ID=pulled, MOCK_HEALTH_FAIL=str(int(health_fail)))
        result = subprocess.run([bash, str(HERE / 'update-server.sh')], env=env,
                                capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=30)
        return result, json.loads(state.read_text())

    def test_same_tag_new_image_id_rebuilds_and_preserves_production(self):
        result, state = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state['running_id'], 'sha256:new')
        tag_index = next(i for i, a in enumerate(state['calls']) if a[:2] == ['image', 'tag'])
        pull_index = next(i for i, a in enumerate(state['calls']) if a[:1] == ['pull'])
        self.assertLess(tag_index, pull_index)
        self.assert_data_preserved()

    def test_health_failure_restores_old_image_even_when_tag_was_reused(self):
        result, state = self.run_script(health_fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state['running_id'], 'sha256:old', result.stdout + result.stderr)
        self.assertEqual(state['images']['repo/same:abc'], 'sha256:old')
        self.assertEqual(self.override.read_text(), self.old_override)
        self.assert_data_preserved()

    def test_same_image_and_rendered_config_skip_recreation_after_pull(self):
        self.override.write_text(self.render(), encoding='utf-8', newline='\n')
        self.env['FORCE'] = '0'
        result, state = self.run_script(pulled='sha256:old')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(a[:1] == ['pull'] for a in state['calls']))
        self.assertFalse(any(a[:2] == ['compose', 'up'] for a in state['calls']))

    def test_force_recreates_same_image_to_reload_production_config(self):
        self.override.write_text(self.render(), encoding='utf-8', newline='\n')
        result, state = self.run_script(pulled='sha256:old')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(a[:2] == ['compose', 'up'] for a in state['calls']))

    def test_runtime_health_checks_configured_ports_and_actual_cold_database(self):
        node = shutil.which('node')
        if not node:
            self.skipTest('node not installed')
        script = (HERE / 'update-server.sh').read_text(encoding='utf-8')
        javascript = re.search(r"<<'NODE'\n(.*?)\nNODE\n", script, re.S).group(1)
        for enabled, initialized, expected in [(True, True, 0), (True, False, 1), (False, False, 0)]:
            config = {'PORT': '7431', 'TDB_KNOWLEDGE_ENABLED': str(enabled).lower(),
                      'AdminUsername': 'test', 'AdminPassword': 'test-only'}
            profile = {'profile': {'tdbKnowledge': {'enabled': enabled, 'initialized': initialized,
                                                  'metaDb': {'open': initialized}}}}
            harness = '''
const mockConfig = CONFIG;
const mockProfile = PROFILE;
const loader = require('module');
const originalLoader = loader._load;
loader._load = function(name, ...args) {
  if (name === 'dotenv') return { parse: () => mockConfig };
  if (name === 'fs') return { statSync: () => ({isDirectory: () => true}), accessSync: () => {},
    constants: {R_OK: 4, W_OK: 2}, readFileSync: () => '{}' };
  return originalLoader.call(this, name, ...args);
};
global.fetch = async function(url) {
  const parsed = new URL(url);
  if (!['7431', '7432'].includes(parsed.port)) throw new Error('incorrect configured port');
  if (parsed.pathname.includes('memory/profile')) {
    if (parsed.port !== '7431') throw new Error('profile must use main service');
    return {ok: true, json: async () => mockProfile};
  }
  return {status: 200};
};
'''.replace('CONFIG', json.dumps(config)).replace('PROFILE', json.dumps(profile))
            env = {k: v for k, v in os.environ.items() if not k.startswith('TDB_KNOWLEDGE_') and k != 'PORT'}
            result = subprocess.run([node, '-'], input=harness + javascript, text=True,
                                    capture_output=True, env=env, timeout=10)
            with self.subTest(enabled=enabled, initialized=initialized):
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
