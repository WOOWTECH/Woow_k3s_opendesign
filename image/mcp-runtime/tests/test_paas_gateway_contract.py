"""PaaS gateway overlay: exact HA 0.2.15 schemas and authorization safety."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
from pydantic import ValidationError

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get('PAAS_MCP_ROOT', HERE.parent))
HA = ROOT / 'ha' if (ROOT / 'ha').is_dir() else ROOT
VENDOR = HA / 'vendor' if (HA / 'vendor').is_dir() else ROOT
sys.path[:0] = [str(VENDOR / 'packages' / 'mcp-admin-core'), str(HA), str(ROOT)]

from mcp_admin_core import policy  # noqa: E402
from mcp_admin_core.products import ProductStore, TOOLS  # noqa: E402
from paas_opendesign_mcp import launch, settings  # noqa: E402
from paas_opendesign_mcp.input_contract import REPLACEMENTS  # noqa: E402
from paas_opendesign_mcp import input_rules  # noqa: E402
from ha_opendesign_mcp import defaults, surface  # noqa: E402

RUNTIME = launch.place(settings({}))
TABLE = TOOLS['opendesign']
FIXTURE = json.loads((HERE / 'fixtures/ha-0.2.15-input-schemas.json').read_text())['input_schemas']
IMPORTED = 'Imported.Design_2026'


def request(name, arguments):
    return {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
            'params': {'name': name, 'arguments': arguments}}


class Schemas(unittest.TestCase):
    def test_changed_ha_pin_fails_closed(self):
        with mock.patch.object(input_rules, 'EXPECTED_HA_COMMIT', '0' * 40):
            with self.assertRaises(RuntimeError):
                input_rules.require_pin()

    def test_exact_fifteen_and_pinned_source_untouched(self):
        actual = {name: policy.declared_schema(tool.arguments) for name, tool in TABLE.items()}
        self.assertEqual(actual, FIXTURE)
        self.assertEqual(len(actual), 15)
        self.assertIs(surface.install(), TABLE)
        self.assertEqual({name for name, tool in TABLE.items() if tool.write},
                         {'create_project', 'delete_project', 'send_message'})
        self.assertEqual(len(REPLACEMENTS), 6)
        self.assertEqual(RUNTIME.CHILD_ENTRY, ROOT / 'paas_opendesign_mcp/child.py')

    def test_input_model_rules(self):
        for name in REPLACEMENTS:
            model = TABLE[name].arguments
            self.assertEqual(model.model_validate({'project_id': IMPORTED,
                                                    **({'file_path': '設計/首頁.html'} if name in ('read_file', 'get_file_info') else {}),
                                                    **({'prompt': 'hi'} if name == 'send_message' else {})}).project_id,
                             IMPORTED)
            with self.assertRaises(ValidationError):
                model.model_validate({'project_id': IMPORTED, 'acceptance_extra': 'ignored',
                                      **({'file_path': '設計/首頁.html'} if name in ('read_file', 'get_file_info') else {}),
                                      **({'prompt': 'hi'} if name == 'send_message' else {})})
        for bad in ('../escape', 'a/b', 'x%2fy', 'a?b', 'a#b', 'a' * 129):
            with self.subTest(project_id=bad), self.assertRaises(ValidationError):
                TABLE['get_project'].arguments.model_validate({'project_id': bad})
        for bad in ('../x', 'a/../b', '/absolute', 'a%2fb', 'a\\b', 'a//b'):
            with self.subTest(file_path=bad), self.assertRaises(ValidationError):
                TABLE['get_file_info'].arguments.model_validate({'project_id': IMPORTED, 'file_path': bad})
        self.assertEqual(TABLE['get_file_info'].arguments.model_validate(
            {'project_id': IMPORTED, 'file_path': '.env'}).file_path, '.env')
        with self.assertRaises(ValidationError):
            TABLE['read_file'].arguments.model_validate({'project_id': IMPORTED, 'file_path': '.env'})


class Authorization(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.store = ProductStore(Path(self.temporary.name), 'opendesign')
        self.store.update(connection={'url': 'http://127.0.0.1:7457'})
        defaults.apply(self.store)

    def tearDown(self):
        self.store.close()
        self.temporary.cleanup()

    def test_imported_id_and_cjk_path_authorized_without_backend_io(self):
        msg = request('read_file', {'project_id': IMPORTED, 'file_path': '設計/首頁.html'})
        policy.authorize(msg, TABLE, self.store.load())
        self.assertEqual(msg['params']['arguments'], {'project_id': IMPORTED, 'file_path': '設計/首頁.html'})

    def test_invalid_and_ungranted_refused(self):
        for name, args in (('read_file', {'project_id': IMPORTED, 'file_path': '.env'}),
                           ('get_file_info', {'project_id': IMPORTED, 'file_path': '../x'}),
                           ('delete_project', {'project_id': '../x'}),
                           ('health', {'acceptance_extra': 'ignored'})):
            with self.subTest(name=name), self.assertRaises(policy.ToolCallRefused) as caught:
                policy.authorize(request(name, args), TABLE, self.store.load())
            self.assertEqual(caught.exception.kind, 'invalid_params')
        self.store.update(writes_enabled=False, enabled_write_tools=[])
        with self.assertRaises(policy.ToolCallRefused) as caught:
            policy.authorize(request('delete_project', {'project_id': IMPORTED}), TABLE, self.store.load())
        self.assertEqual(caught.exception.kind, 'unknown_tool')


if __name__ == '__main__':
    unittest.main(verbosity=1)
