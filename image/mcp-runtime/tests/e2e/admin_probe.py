"""Admin probe of the built-in OpenDesign MCP server (test-only), speaking to admin.sock exactly as the chart's nginx
does for /mcp-admin/ (location ^~ /mcp-admin/ -> http://unix:/run/od-mcp/admin.sock:/ with X-Remote-User-Id set to the
basic-auth user and X-Ingress-Path /mcp-admin). Run in a container that mounts the od-mcp-run volume (the auth proxy
stand-in); never in the daemon container.

usage: python admin_probe.py <admin.sock> <action>
  checks        page + bootstrap as the basic-auth user; fixed backend refused; missing / duplicated user header and
                a missing CSRF token refused (JSON lines; exit 1 on a failed expectation)
  reveal        print ONLY the current token (for capture into a shell variable; never into a file)
  rotate        print ONLY the new token
  revoke        print the HTTP status
  disable=T     disable tool T (keeps the write grants); print status
  enable-all    no disabled tool, every write grant; print status
"""
import json
import sys

import httpx

USER = 'admin'  # the chart's basic-auth user name (authProxy.basicAuth.username)
PREFIX = '/mcp-admin'
GRANTS = ['create_project', 'delete_project', 'send_message']
FAILED = []


def expect(condition, what):
    if not condition:
        FAILED.append(what)
        print(json.dumps({'FAIL': what}))


def headers(user=USER, duplicate=False):
    value = [('X-Ingress-Path', PREFIX)]
    if user is not None:
        value.append(('X-Remote-User-Id', user))
        if duplicate:
            value.append(('X-Remote-User-Id', 'second-user'))
    return value


def main():
    sock, action = sys.argv[1], sys.argv[2]
    transport = httpx.HTTPTransport(uds=sock)
    with httpx.Client(transport=transport, base_url='http://localhost', timeout=15, trust_env=False) as client:
        def bootstrap(**kw):
            return client.get('/api/bootstrap', headers=headers(**kw))

        def mutate(name, body=None, method='POST'):
            boot = bootstrap().json()
            extra = [('X-CSRF-Token', boot['csrf'])]
            if body is None:
                return client.request(method, '/api/' + name, headers=headers() + extra)
            return client.request(method, '/api/' + name, headers=headers() + extra + [('Content-Type', 'application/json')],
                                  content=json.dumps(body))

        if action == 'checks':
            page = client.get('/', headers=headers())
            print(json.dumps({'case': 'admin page', 'status': page.status_code,
                              'base_injected': PREFIX in page.text,
                              'csp': page.headers.get('content-security-policy', '')[:60]}))
            expect(page.status_code == 200 and PREFIX in page.text, 'admin page served with the /mcp-admin base')
            boot = bootstrap()
            data = boot.json()
            tools = data.get('tools', {})
            facts = {'case': 'bootstrap', 'status': boot.status_code, 'product': data.get('product'),
                     'connection_configured': data.get('connection_configured'), 'endpoint': data.get('endpoint'),
                     'token_active': data.get('token_active'), 'writes_enabled': data.get('writes_enabled'),
                     'enabled_write_tools': data.get('enabled_write_tools'), 'disabled': data.get('disabled'),
                     'tool_count': len(tools), 'write_tools': sorted(k for k, v in tools.items() if v.get('write')),
                     'health': data.get('health')}
            print(json.dumps(facts, sort_keys=True))
            expect(boot.status_code == 200 and data.get('product') == 'opendesign', 'bootstrap 200')
            expect(len(tools) == 15, 'bootstrap: 15 tools')
            expect(sorted(data.get('enabled_write_tools') or []) == GRANTS, 'bootstrap: every write grant on')
            expect(data.get('disabled') == [], 'bootstrap: nothing disabled')
            expect(data.get('connection_configured') is True, 'bootstrap: fixed backend configured')
            expect(data.get('token_active') is True, 'bootstrap: token active')
            fixed = mutate('backend', {'connection': {'url': 'http://example.invalid:7457'}}, 'PUT')
            print(json.dumps({'case': 'PUT backend (fixed loopback daemon)', 'status': fixed.status_code}))
            expect(fixed.status_code == 403, 'PUT backend refused')
            for case, response in (('no X-Remote-User-Id', bootstrap(user=None)),
                                   ('two X-Remote-User-Id', bootstrap(duplicate=True)),
                                   ('token/reveal without CSRF', client.post('/api/token/reveal', headers=headers()))):
                print(json.dumps({'case': case, 'status': response.status_code}))
                expect(response.status_code == 403, case + ' -> 403')
        elif action in ('reveal', 'rotate'):
            r = mutate('token/' + action)
            r.raise_for_status()
            sys.stdout.write(r.json()['token'])
        elif action == 'revoke':
            status = mutate('token/revoke').status_code
            print(json.dumps({'case': 'token/revoke', 'status': status}))
            expect(status == 204, 'revoke -> 204')
        elif action.startswith('disable='):
            r = mutate('policy', {'writes_enabled': False, 'disabled': [action[8:]], 'enabled_write_tools': GRANTS}, 'PUT')
            print(json.dumps({'case': 'policy disable ' + action[8:], 'status': r.status_code}))
            expect(r.status_code == 200, 'policy saved')
        elif action == 'enable-all':
            r = mutate('policy', {'writes_enabled': False, 'disabled': [], 'enabled_write_tools': GRANTS}, 'PUT')
            print(json.dumps({'case': 'policy enable all', 'status': r.status_code}))
            expect(r.status_code == 200, 'policy saved')
        else:
            raise SystemExit('unknown action')
    if FAILED:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
