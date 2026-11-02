#!/usr/bin/env python3
"""Read-only image contract; run with the bundled SDK Python as uid 1001."""
import ast
import hashlib
from importlib.metadata import version
from importlib.util import find_spec
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def verify(app=Path('/app'), shared=Path('/usr/local/share/woow')):
    assert os.getuid() == 1001, 'contract must run as the daemon uid'
    assert version('omnigent') == '0.16.0'
    for key in ('OMNIGENT_CONFIG_HOME', 'OMNIGENT_DATA_DIR', 'OMNIGENT_SERVER',
                'OMNIGENT_TOKEN', 'OMNIGENT_USERNAME', 'OMNIGENT_PASSWORD',
                'OG_CONFIG_HOME', 'OG_DATA_DIR', 'OG_STATE_DIR', 'OG_SERVER'):
        assert key not in os.environ, f'image must not preset {key}'
    assert not Path('/usr/local/bin/omnigent-host-entry').exists(), 'legacy launcher present'
    assert not (Path.home() / '.omnigent').exists(), 'image contains legacy Omnigent state'
    native = app / 'apps/daemon/dist/integrations/omnigent'
    patches = shared / 'omnigent-sdk-patches'
    manifest = json.loads((patches / 'manifest.json').read_text())
    assert manifest['schemaVersion'] == 2 and manifest['sdkVersion'] == '0.16.0'
    assert len(manifest['patches']) == 5
    for name in ['apply.py', 'manifest.json'] + [p['patch'] for p in manifest['patches']]:
        assert (native / 'sdk-patches' / name).read_bytes() == (patches / name).read_bytes(), f'native SDK asset drift: {name}'
    sdk = Path(list(find_spec('omnigent').submodule_search_locations)[0])
    subprocess.run([sys.executable, '-I', '-B', str(patches / 'apply.py'), str(sdk),
                    str(patches / 'manifest.json'), '--check'], check=True)
    subprocess.run([sys.executable, '-I', '-B', str(patches / 'check_provider_merge.py'),
                    str(sdk / 'harnesses/opencode_native/provider.py')], check=True)
    kit = native / 'host-kit'
    assert (kit / 'manifest.json').read_bytes() == (shared / 'omnigent-host-kit.json').read_bytes(), 'host-kit manifest drift'
    for name, expected in json.loads((kit / 'manifest.json').read_text())['files'].items():
        assert hashlib.sha256((kit / name).read_bytes()).hexdigest() == expected, f'host-kit drift: {name}'
    for filename in (native / 'adapter.py', kit / 'og_helper.py'):
        ast.parse(filename.read_text())
    subprocess.run(['/bin/sh', '-n', str(kit / 'supervisor.sh')], check=True)
    for name in ('service.js', 'dependencies.js', 'onboarding.js'):
        assert (native / name).is_file(), f'missing compiled native module: {name}'
    assert (app / 'apps/daemon/dist/routes/omnigent.js').is_file()
    for plugin in ('woow-omnigent', 'woow-paseo'):
        data = json.loads((app / 'plugins/_official/woow' / plugin / 'open-design.json').read_text())
        assert data['name'] == plugin
        if plugin == 'woow-omnigent':
            assert data['od']['launch']['path'] == '/settings/omnigent'
    # Missing engines are reported, never installed. Exercise the shipped adapter
    # with an empty executable search path and no server/credentials.
    with tempfile.TemporaryDirectory(prefix='od-no-engines-') as directory:
        root = Path(directory)
        request = {'action': 'inventory', 'stateDir': str(root / 'state'),
                   'configHome': str(root / 'host'), 'dataDir': str(root / 'host')}
        result = subprocess.run([sys.executable, '-I', '-B', str(native / 'adapter.py')],
                                input=json.dumps(request), text=True, capture_output=True,
                                check=True, timeout=30, env={**os.environ, 'PATH': directory})
        inventory = json.loads(result.stdout)
        assert inventory['ok'] is True, 'missing-engine inventory failed'
        engines = inventory['data']['engines']
        assert set(engines) == {'claude', 'codex', 'pi', 'opencode'}
        assert all(engine['installed'] is False for engine in engines.values())
        assert not list(root.iterdir()), 'inventory must not install or persist anything'
    verify_pi_picker()
    print('native Omnigent runtime OK: SDK 0.16.0, five patches, dual OpenCode config, host-kit, GUI launcher, private defaults; Paseo retained')


def verify_pi_picker():
    """The Pi model picker asks Pi when its files name no provider, and never reads Pi's "No models available" notice as a model."""
    code = ('import json\n'
            'from omnigent.harnesses.pi_native.credentials import pi_own_login_model_options\n'
            'print(json.dumps([option["id"] for option in pi_own_login_model_options()]))\n')
    with tempfile.TemporaryDirectory(prefix='od-pi-picker-') as directory:
        root = Path(directory)
        (root / 'agent').mkdir()
        (root / 'bin').mkdir()
        (root / 'agent' / 'auth.json').write_text('{}')
        pi = root / 'bin' / 'pi'
        env = {**os.environ, 'HOME': str(root), 'PI_CODING_AGENT_DIR': str(root / 'agent'),
               'PATH': str(root / 'bin') + os.pathsep + os.environ.get('PATH', '')}

        def ask(output):
            pi.write_text("#!/bin/sh\ncat <<'EOF'\n" + output + 'EOF\n')
            pi.chmod(0o755)
            result = subprocess.run([sys.executable, '-I', '-B', '-c', code], env=env, text=True,
                                    capture_output=True, check=True, timeout=60)
            return json.loads(result.stdout)

        assert ask('provider  model  context\nopenrouter  vendor/model-a:free  1M\n') == ['openrouter/vendor/model-a:free'], \
            'Pi picker: a provider known only to the Pi CLI is not offered'
        assert ask('No models available. Use /login to log into a provider via OAuth or API key. See:\n  /docs/providers.md\n') == [], \
            "Pi picker: Pi's notice was read as a model"


if __name__ == '__main__':
    verify()
