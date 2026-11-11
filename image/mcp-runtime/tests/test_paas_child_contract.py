"""Pinned SDK 1 child plus PaaS guards, against a disposable loopback daemon."""
import asyncio
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
import os
from pathlib import Path
import sys
import threading
import unittest
from urllib.parse import unquote

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get('PAAS_MCP_ROOT', HERE.parent))
HA = ROOT / 'ha' if (ROOT / 'ha').is_dir() else ROOT
VENDOR = HA / 'vendor' if (HA / 'vendor').is_dir() else ROOT
sys.path[:0] = [str(VENDOR / 'apps/opendesign/vendor'), str(VENDOR / 'apps/runtime'),
                str(VENDOR / 'apps/opendesign'), str(HA), str(ROOT)]

IMPORTED = 'Imported.Design_2026'
PATH = '設計/首頁.html'


class Daemon(BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def reply(self, status, body, media='application/json'):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', media)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = unquote(self.path)
        self.requests.append(('GET', path))
        base = '/api/projects/' + IMPORTED
        if path == base:
            return self.reply(200, {'project': {'id': IMPORTED}})
        if path == base + '/files':
            return self.reply(200, {'files': [{'name': PATH, 'path': PATH, 'type': 'file', 'size': 6}]})
        if path == base + '/files/' + PATH:
            return self.reply(200, 'hello\n'.encode(), 'application/octet-stream')
        return self.reply(404, {'error': {'code': 'NOT_FOUND'}})

    def do_POST(self):
        self.requests.append(('POST', self.path))
        if self.path != '/api/chat':
            return self.reply(404, {})
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if body.get('projectId') != IMPORTED:
            return self.reply(400, {})
        stream = (b'event: start\ndata: {"runId":"29a8b67a-faaf-44ae-b66f-8bf2479b5442",'
                  b'"projectId":"Imported.Design_2026"}\n\n'
                  b'event: end\ndata: {"status":"succeeded","code":0}\n\n')
        return self.reply(200, stream, 'text/event-stream')

    def do_DELETE(self):
        self.requests.append(('DELETE', unquote(self.path)))
        if unquote(self.path) == '/api/projects/' + IMPORTED:
            return self.reply(200, {'ok': True})
        return self.reply(404, {})


SERVER = ThreadingHTTPServer(('127.0.0.1', 0), Daemon)
threading.Thread(target=SERVER.serve_forever, daemon=True).start()
os.environ['OD_API_BASE'] = 'http://127.0.0.1:%d' % SERVER.server_address[1]
logging.getLogger('httpx').setLevel(logging.WARNING)

from bounded_tools import BoundedTools  # noqa: E402
from ha_opendesign_mcp import child as ha_child, od_tools  # noqa: E402
from paas_opendesign_mcp.child_contract import prepare  # noqa: E402

prepare(ha_child)
od_tools.install(ha_child.launch.mcp, ha_child.launch.od)
WORKERS = BoundedTools(ha_child.launch.mcp, capacity=4)


def call(name, arguments):
    async def run():
        return await ha_child.launch.mcp.call_tool(name, arguments)
    try:
        result = asyncio.run(run())
    except Exception as error:
        return True, str(error)
    content = result[0] if isinstance(result, tuple) else result
    return False, ''.join(getattr(item, 'text', '') for item in content)


class Child(unittest.TestCase):
    def setUp(self):
        Daemon.requests = []

    def test_imported_project_and_cjk_read(self):
        for name, args in (('get_project', {'project_id': IMPORTED}),
                           ('list_project_files', {'project_id': IMPORTED}),
                           ('get_file_info', {'project_id': IMPORTED, 'file_path': PATH}),
                           ('read_file', {'project_id': IMPORTED, 'file_path': PATH})):
            with self.subTest(name=name):
                error, _ = call(name, args)
                self.assertFalse(error)
        self.assertEqual(len(Daemon.requests), 5)  # read_file: list + file GET

    def test_imported_project_send_message_to_fake_only(self):
        error, content = call('send_message', {'project_id': IMPORTED, 'prompt': 'hi'})
        self.assertFalse(error)
        result = json.loads(content)
        self.assertEqual(result['projectId'], IMPORTED)
        self.assertEqual(result['status'], 'succeeded')
        self.assertEqual([method for method, _ in Daemon.requests], ['GET', 'POST'])

    def test_imported_project_delete_to_fake_only(self):
        error, _ = call('delete_project', {'project_id': IMPORTED})
        self.assertFalse(error)
        self.assertEqual(Daemon.requests, [('DELETE', '/api/projects/' + IMPORTED)])

    def test_unsafe_arguments_refused_before_backend(self):
        for name, args in (('get_project', {'project_id': '../x'}),
                           ('delete_project', {'project_id': '../x'}),
                           ('list_project_files', {'project_id': 'x%2fy'}),
                           ('get_file_info', {'project_id': IMPORTED, 'file_path': '../x'}),
                           ('read_file', {'project_id': IMPORTED, 'file_path': '.env'}),
                           ('send_message', {'project_id': 'a/b', 'prompt': 'hi'})):
            with self.subTest(name=name):
                error, content = call(name, args)
                self.assertTrue(error)
                self.assertTrue(content.endswith(': INVALID_ARGUMENTS')
                                or content.endswith(': FILE_PATH_REFUSED'), content)
        self.assertEqual(Daemon.requests, [])

    def test_guarded_descriptions_and_no_fake_delete(self):
        tools = ha_child.launch.mcp._tool_manager._tools
        self.assertEqual(len(tools), 15)
        for name in ('get_project', 'delete_project', 'list_project_files', 'get_file_info',
                     'read_file', 'send_message'):
            self.assertIn('Safe project ID', tools[name].description)
        self.assertFalse(any(method == 'DELETE' for method, _ in Daemon.requests))


if __name__ == '__main__':
    try:
        unittest.main(verbosity=1)
    finally:
        WORKERS.close()
        SERVER.shutdown()
