"""MCP client probe of the built-in OpenDesign MCP server (test-only; prints results, never the token).

Adapted from the HA add-on 0.2.0's mcp-runtime/tests/e2e/mcp_probe.py for the PaaS sidecar: the probe runs in the
pod's network namespace and talks to the gateway on 127.0.0.1:<port>, as nginx does.

usage: MCP_TOKEN=... python mcp_probe.py <base-url> <check> [...]
checks (each prints JSON lines; each exits 1 on a failed expectation):
  auth      no Bearer -> 401 + WWW-Authenticate; wrong Bearer -> 401; Bearer + Origin -> 403
  bearer    initialize -> initialized -> tools/list (exactly the 15 tools) -> read tools answer (Bearer)
  secret    the same over /private_<token>/mcp with an Origin header (Claude.ai style); wrong secret -> 404
  calls     every tool that is not a plain read is DISPATCHED, never refused by the gateway: read_file,
            list_connectors, delete_project, create_project, send_message (bogus ids / an agent that does not exist,
            so nothing is created or deleted)
  tools     print the tools/list names and count (Bearer)
  count=N   tools/list must list exactly N tools (Bearer)
  refused=T tools/call T must be refused by the policy (HTTP 200 JSON-RPC -32602 "Unknown tool")
  health    tools/call health; HEALTH_EXPECT=ok|error decides the expectation
  status    HTTP status of a Bearer initialize only; STATUS_EXPECT=<code> decides the expectation
  ready     GET /health/ready; READY_EXPECT=<code>
  claudeai  the Claude.ai connector sequence over /private_<token>/mcp (server/discover -> -32601, initialize
            2025-11-25 with _meta, unknown request/notification, tools/list, tools/call, ping)
  refusals  refused tools/call -> HTTP 200 JSON-RPC errors without input echo; without a session 403
  protect   the HA 0.2.1 protections on a real project (PROJECT_ID, made by run-e2e.sh): read_file returns a text
            file, refuses secret file names (.env, *.pem, id_rsa), a file over the size limit and a binary file without
            returning their content; send_message with an agent that cannot run (Claude Code without a login
            or key) reports the failure instead of a success
The token comes only from MCP_TOKEN and is redacted from all output.
"""
import json
import os
import sys
import uuid

import httpx

TOKEN = os.environ.get('MCP_TOKEN', '')
ACCEPT = 'application/json, text/event-stream'
PROTOCOL = '2025-06-18'
EXPECTED = sorted(('health', 'version', 'list_agents', 'list_connectors', 'list_projects', 'get_project',
                   'create_project', 'delete_project', 'list_project_files', 'read_file', 'get_file_info',
                   'send_message', 'list_runs', 'list_plugins', 'list_skills'))
WRITE = ('create_project', 'delete_project', 'send_message')
FAILED = []


def redact(text):
    return text.replace(TOKEN, '[REDACTED]') if TOKEN else text


def out(**fields):
    print(redact(json.dumps(fields, ensure_ascii=False, sort_keys=True)), flush=True)


def expect(condition, what):
    if not condition:
        FAILED.append(what)
        out(FAIL=what)


def rpc_result(response):
    """Parse a JSON or SSE reply into the JSON-RPC message."""
    media = response.headers.get('content-type', '').split(';')[0]
    if media == 'text/event-stream':
        for event in response.text.split('\n\n'):
            data = '\n'.join(line[5:].lstrip() for line in event.splitlines() if line.startswith('data:'))
            if data.strip():
                return json.loads(data)
        raise ValueError('no SSE data')
    return response.json()


def rpc_or_status(response):
    try:
        return response.status_code, rpc_result(response)
    except Exception:  # noqa: BLE001 - only the status matters then
        return response.status_code, None


class Session:
    def __init__(self, client, url, headers):
        self.client, self.url, self.headers, self.next_id = client, url, dict(headers), 1

    def post(self, message, extra=None, timeout=None):
        headers = {'Accept': ACCEPT, 'Content-Type': 'application/json', **self.headers, **(extra or {})}
        kwargs = {} if timeout is None else {'timeout': timeout}
        return self.client.post(self.url, headers=headers, content=json.dumps(message), **kwargs)

    def request(self, method, params=None, timeout=None):
        message = {'jsonrpc': '2.0', 'id': self.next_id, 'method': method}
        if params is not None:
            message['params'] = params
        self.next_id += 1
        response = self.post(message, timeout=timeout)
        response.raise_for_status()
        return rpc_result(response)

    def initialize(self):
        response = self.post({'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {
            'protocolVersion': PROTOCOL, 'capabilities': {}, 'clientInfo': {'name': 'paas-od-mcp-probe', 'version': '0'}}})
        response.raise_for_status()
        result = rpc_result(response)['result']
        self.headers['mcp-session-id'] = response.headers['mcp-session-id']
        self.headers['mcp-protocol-version'] = result['protocolVersion']
        note = self.post({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
        return result, note.status_code

    def call(self, name, arguments=None, timeout=None):
        reply = self.request('tools/call', {'name': name, 'arguments': arguments or {}}, timeout=timeout)
        result = reply.get('result') or {}
        text = ''.join(item.get('text', '') for item in result.get('content', []) if item.get('type') == 'text')
        return {'isError': bool(result.get('isError')), 'error': reply.get('error'), 'text': text[:300]}

    def tools(self):
        return self.request('tools/list')['result']['tools']

    def close(self):
        self.client.delete(self.url, headers=self.headers)


def flow(client, url, headers, label):
    session = Session(client, url, headers)
    result, initialized = session.initialize()
    out(check=label, step='initialize', serverInfo=result.get('serverInfo'), protocolVersion=result.get('protocolVersion'),
        capabilities=result.get('capabilities'), initialized_status=initialized)
    expect((result.get('serverInfo') or {}).get('name') == 'woow-mcp-opendesign', label + ': serverInfo name')
    tools = session.tools()
    names = sorted(t['name'] for t in tools)
    writes = sorted(t['name'] for t in tools if (t.get('annotations') or {}).get('readOnlyHint') is not True
                    and t['name'] in WRITE)
    out(check=label, step='tools/list', count=len(tools), names=names, write_tools_listed=writes)
    expect(names == EXPECTED, label + ': tools/list is exactly the 15 tools')
    for name in ('health', 'version', 'list_projects', 'list_agents'):
        reply = session.call(name)
        out(check=label, step='tools/call ' + name, **reply)
        expect(reply['error'] is None and not reply['isError'], label + ': ' + name + ' answers')
    session.close()


def calls(client, base):
    """Every non-trivial tool is dispatched to the daemon: the reply is the tool's own result or tool error,
    never the gateway's policy refusal (JSON-RPC -32602)."""
    session = Session(client, base + '/mcp', {'Authorization': 'Bearer ' + TOKEN})
    session.initialize()
    bogus = str(uuid.uuid4())
    cases = [
        ('list_connectors', {}),
        ('read_file', {'project_id': bogus, 'file_path': 'index.html'}),
        ('delete_project', {'project_id': bogus}),
        ('create_project', {'prompt': 'probe: no agent run', 'agent_id': 'woow-probe-no-such-agent'}),
        ('send_message', {'project_id': bogus, 'prompt': 'probe', 'agent_id': 'woow-probe-no-such-agent'}),
    ]
    for name, arguments in cases:
        reply = session.call(name, arguments, timeout=90)
        out(check='calls', tool=name, **reply)
        expect(reply['error'] is None, 'calls: ' + name + ' dispatched (no JSON-RPC policy error)')
    session.close()


CLAUDE_UA = 'Claude-User'
META = {'traceparent': '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'}  # W3C example value, not a secret
MARKER = 'probe-input-marker-' + 'q' * 12  # an argument value: must never be echoed back in a refusal


def claudeai(client, base):
    url = base + '/private_' + TOKEN + '/mcp'
    session = Session(client, url, {'Origin': 'https://claude.ai', 'User-Agent': CLAUDE_UA})
    status, reply = rpc_or_status(session.post({'jsonrpc': '2.0', 'id': 1, 'method': 'server/discover',
                                                'params': {'_meta': META}}, {'MCP-Protocol-Version': '2026-07-28'}))
    error = (reply or {}).get('error') or {}
    out(check='claudeai', step='server/discover', status=status, error=error)
    expect(status == 200 and error.get('code') == -32601, 'claudeai: server/discover -> -32601')
    response = session.post({'jsonrpc': '2.0', 'id': 2, 'method': 'initialize', 'params': {
        '_meta': META, 'protocolVersion': '2025-11-25',
        'capabilities': {'extensions': {'io.modelcontextprotocol/ui': {'mimeTypes': ['text/html;profile=mcp-app']}}},
        'clientInfo': {'name': 'Anthropic/ClaudeAI', 'version': '1.0.0'}}})
    status, reply = rpc_or_status(response)
    result = (reply or {}).get('result') or {}
    out(check='claudeai', step='initialize 2025-11-25', status=status, protocolVersion=result.get('protocolVersion'),
        serverInfo=result.get('serverInfo'))
    expect(status == 200 and result.get('protocolVersion') == '2025-11-25', 'claudeai: initialize')
    session.headers['mcp-session-id'] = response.headers['mcp-session-id']
    session.headers['mcp-protocol-version'] = result['protocolVersion']
    r = session.post({'jsonrpc': '2.0', 'method': 'notifications/initialized', 'params': {'_meta': META}})
    out(check='claudeai', step='notifications/initialized', status=r.status_code)
    r = session.post({'jsonrpc': '2.0', 'method': 'notifications/claudeai/unknown', 'params': {'_meta': META}})
    out(check='claudeai', step='unknown notification', status=r.status_code)
    expect(r.status_code == 202, 'claudeai: unknown notification -> 202')
    status, reply = rpc_or_status(session.post({'jsonrpc': '2.0', 'id': 4, 'method': 'tools/list', 'params': {'_meta': META}}))
    tools = ((reply or {}).get('result') or {}).get('tools', [])
    out(check='claudeai', step='tools/list', status=status, count=len(tools))
    expect(len(tools) == 15, 'claudeai: 15 tools')
    status, reply = rpc_or_status(session.post({'jsonrpc': '2.0', 'id': 5, 'method': 'tools/call', 'params': {
        '_meta': {**META, 'progressToken': 7}, 'name': 'health', 'arguments': {}}}))
    result = (reply or {}).get('result') or {}
    out(check='claudeai', step='tools/call health', status=status, isError=bool(result.get('isError')))
    expect(status == 200 and not result.get('isError'), 'claudeai: health')
    status, reply = rpc_or_status(session.post({'jsonrpc': '2.0', 'id': 6, 'method': 'ping', 'params': {'_meta': META}}))
    out(check='claudeai', step='ping', status=status, result=(reply or {}).get('result'))
    session.close()


def refusals(client, base):
    bearer = {'Authorization': 'Bearer ' + TOKEN}
    session = Session(client, base + '/mcp', bearer)
    session.initialize()
    cases = [
        ('unknown tool', {'name': 'no_such_tool', 'arguments': {'value': MARKER}}),
        ('invalid arguments (get_project, extra field)', {'name': 'get_project', 'arguments': {'unexpected': MARKER}}),
        ('invalid argument (read_file path traversal)', {'name': 'read_file', 'arguments': {
            'project_id': str(uuid.uuid4()), 'file_path': '../' + MARKER}}),
        ('invalid argument (create_project empty prompt)', {'name': 'create_project', 'arguments': {'prompt': ''}}),
    ]
    for ident, (case, params) in enumerate(cases, start=10):
        response = session.post({'jsonrpc': '2.0', 'id': ident, 'method': 'tools/call', 'params': params})
        status, reply = rpc_or_status(response)
        error = (reply or {}).get('error') or {}
        echoed = MARKER in response.text
        out(check='refusals', case=case, status=status, code=error.get('code'), message=error.get('message'),
            argument_value_echoed=echoed)
        expect(status == 200 and error.get('code') == -32602 and not echoed, 'refusals: ' + case)
    no_session = Session(client, base + '/mcp', bearer).post({'jsonrpc': '2.0', 'id': 30, 'method': 'tools/call',
                                                              'params': {'name': 'no_such_tool', 'arguments': {}}})
    out(check='refusals', case='refused tools/call without a session', status=no_session.status_code)
    expect(no_session.status_code == 403, 'refusals: no session -> 403')
    session.close()


SECRET_MARKER = 'woow-e2e-secret-marker'  # written by run-e2e.sh into every file that must not be returned


def protect(client, base):
    project = os.environ['PROJECT_ID']
    session = Session(client, base + '/mcp', {'Authorization': 'Bearer ' + TOKEN})
    session.initialize()
    reply = session.call('read_file', {'project_id': project, 'file_path': 'index.html'})
    out(check='protect', case='read_file index.html', **reply)
    expect(reply['error'] is None and not reply['isError'] and 'woow-e2e-page' in reply['text'], 'protect: text file read')
    for name in ('.env', 'server.pem', 'id_rsa', 'big.txt', 'image.png'):
        try:
            reply = session.call('read_file', {'project_id': project, 'file_path': name})
        except httpx.HTTPStatusError as exc:
            reply = {'http_status': exc.response.status_code, 'error': None, 'isError': True, 'text': ''}
        # Refused by the runtime's protection: the tool's own error, or an argument refusal. "Unknown tool" does not
        # count: that is the policy hiding read_file altogether, not a protection.
        error = reply.get('error') or {}
        refused = (bool(error) and error.get('message') != 'Unknown tool') or reply['isError']
        out(check='protect', case='read_file ' + name, refused=refused, content_returned=SECRET_MARKER in reply['text'],
            error=error or None, text=reply['text'][:160])
        expect(refused and SECRET_MARKER not in reply['text'], 'protect: read_file ' + name + ' refused')
    # Claude Code with no login and no API key in the pod fails at once: the run's failure must come back as one.
    reply = session.call('send_message', {'project_id': project, 'prompt': 'e2e: this agent cannot run',
                                          'agent_id': os.environ.get('FAILING_AGENT', 'claude')}, timeout=200)
    text = reply['text'].lower()
    error = reply['error'] or {}
    reported = (bool(error) and error.get('message') != 'Unknown tool') or reply['isError'] or '"failed"' in text
    out(check='protect', case='send_message with an agent that cannot run', reported_failure=reported, **reply)
    expect(reported and '"succeeded"' not in text, 'protect: send_message failure reported')
    session.close()


def main():
    base, checks = sys.argv[1].rstrip('/'), sys.argv[2:]
    with httpx.Client(timeout=httpx.Timeout(40, connect=5), trust_env=False) as client:
        bearer = {'Authorization': 'Bearer ' + TOKEN}
        init = {'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {
            'protocolVersion': PROTOCOL, 'capabilities': {}, 'clientInfo': {'name': 'probe', 'version': '0'}}}
        for check in checks:
            if check == 'auth':
                s = Session(client, base + '/mcp', {})
                r = s.post(init)
                out(check='auth', case='no Authorization', status=r.status_code, www_authenticate=r.headers.get('www-authenticate'))
                expect(r.status_code == 401 and r.headers.get('www-authenticate') == 'Bearer', 'auth: no Bearer -> 401')
                r = s.post(init, {'Authorization': 'Bearer wrong-' + 'x' * 38})
                out(check='auth', case='wrong Bearer', status=r.status_code)
                expect(r.status_code == 401, 'auth: wrong Bearer -> 401')
                r = s.post(init, {**bearer, 'Origin': 'https://example.invalid'})
                out(check='auth', case='Bearer + Origin', status=r.status_code)
                expect(r.status_code == 403, 'auth: Bearer + Origin -> 403')
            elif check == 'bearer':
                flow(client, base + '/mcp', bearer, 'bearer')
            elif check == 'secret':
                flow(client, base + '/private_' + TOKEN + '/mcp', {'Origin': 'https://claude.ai'}, 'secret')
                r = Session(client, base + '/private_' + 'y' * 43 + '/mcp', {'Origin': 'https://claude.ai'}).post(init)
                out(check='secret', case='wrong secret', status=r.status_code)
                expect(r.status_code == 404, 'secret: wrong secret -> 404')
            elif check == 'calls':
                calls(client, base)
            elif check == 'tools' or check.startswith('count='):
                session = Session(client, base + '/mcp', bearer)
                session.initialize()
                tools = session.tools()
                out(check='tools', count=len(tools), names=sorted(t['name'] for t in tools))
                if check.startswith('count='):
                    expect(len(tools) == int(check[6:]), 'tools: count %s' % check[6:])
                session.close()
            elif check.startswith('refused='):
                name = check[8:]
                session = Session(client, base + '/mcp', bearer)
                session.initialize()
                reply = session.request('tools/call', {'name': name, 'arguments': {}})
                error = reply.get('error') or {}
                out(check='refused', tool=name, code=error.get('code'), message=error.get('message'))
                expect(error.get('code') == -32602 and error.get('message') == 'Unknown tool', 'refused: ' + name)
                session.close()
            elif check == 'health':
                session = Session(client, base + '/mcp', bearer)
                session.initialize()
                reply = session.call('health')
                out(check='health', **reply)
                want = os.environ.get('HEALTH_EXPECT', 'ok')
                expect(reply['error'] is None and reply['isError'] == (want == 'error'), 'health: ' + want)
                session.close()
            elif check == 'status':
                r = Session(client, base + '/mcp', bearer).post(init)
                out(check='status', case='Bearer initialize', status=r.status_code)
                if os.environ.get('STATUS_EXPECT'):
                    expect(r.status_code == int(os.environ['STATUS_EXPECT']), 'status: ' + os.environ['STATUS_EXPECT'])
            elif check == 'claudeai':
                claudeai(client, base)
            elif check == 'refusals':
                refusals(client, base)
            elif check == 'protect':
                protect(client, base)
            elif check == 'ready':
                r = client.get(base + '/health/ready')
                out(check='ready', status=r.status_code, body=r.text[:200])
                if os.environ.get('READY_EXPECT'):
                    expect(r.status_code == int(os.environ['READY_EXPECT']), 'ready: ' + os.environ['READY_EXPECT'])
            else:
                raise SystemExit('unknown check ' + check)
    if FAILED:
        raise SystemExit(1)


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as exc:  # report, without the token, and fail
        out(error=type(exc).__name__, detail=str(exc)[:300])
        raise SystemExit(1)
