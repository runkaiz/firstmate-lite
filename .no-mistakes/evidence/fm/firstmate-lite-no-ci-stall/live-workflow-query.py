import http.server
import json
import os
from pathlib import Path
import ssl
import subprocess
import threading

root = Path.cwd()
lab = root / '.test-scratch/workflow-api'
lab.mkdir()
evidence = Path('/home/runkai/.no-mistakes/evidence/01M6HTF41B08PS6PG97VZ5PSAY/workflow-query-live.txt')
subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                '-keyout', str(lab / 'key.pem'), '-out', str(lab / 'cert.pem'),
                '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
state = {'workflows': [], 'error': False, 'requests': []}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        state['requests'].append(self.path)
        self.send_response(503 if state['error'] else 200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'message': 'lab unavailable'} if state['error'] else
                                   {'total_count': len(state['workflows']), 'workflows': state['workflows']}).encode())
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(lab / 'cert.pem', lab / 'key.pem')
server.socket = tls.wrap_socket(server.socket, server_side=True)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
env = dict(os.environ)
for key in ['GH_TOKEN', 'GITHUB_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'FM_ROOT_OVERRIDE',
            'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_PROJECTS_OVERRIDE']:
    env.pop(key, None)
env.update(FM_HOME=str(lab), GH_HOST=f'localhost:{server.server_port}',
           GH_ENTERPRISE_TOKEN='disposable-lab-token', GH_CONFIG_DIR=str(lab / 'gh'),
           SSL_CERT_FILE=str(lab / 'cert.pem'), GH_NO_UPDATE_NOTIFIER='1',
           GH_PROMPT_DISABLED='1', GH_TELEMETRY='0')
project = lab / 'projects/app'
subprocess.run(['git', 'init', '-q', str(project)], check=True)
subprocess.run(['git', '-C', str(project), 'remote', 'add', 'origin',
                'https://github.com/disposable/workflow-lab.git'], check=True)
lines = ['Real bin/fm-project-mode.sh + installed gh; disposable TLS GitHub API on loopback.',
         'No production GitHub data, credentials, or configuration used.']
def query(label, expected, workflows=None, error=False, name='app', request=True):
    state.update(workflows=workflows or [], error=error, requests=[])
    result = subprocess.run(['bin/fm-project-mode.sh', '--ci-workflows', name], env=env,
                            capture_output=True, text=True, timeout=25)
    lines.extend([f'\n{label}', f'$ bin/fm-project-mode.sh --ci-workflows {name}',
                  f'API input: {json.dumps(state["workflows"]) if not error else "HTTP 503"}',
                  f'stdout: {result.stdout.strip()}', f'exit: {result.returncode}',
                  f'HTTP requests: {json.dumps(state["requests"])}'])
    evidence.write_text('\n'.join(lines) + '\n')
    assert result.returncode == 0 and result.stdout.strip() == expected, result
    assert bool(state['requests']) == request, state
    if request:
        assert state['requests'] == ['/api/v3/repos/disposable/workflow-lab/actions/workflows'], state
try:
    query('Repository without CI', 'none')
    query('Active repository workflow', 'present', [{'state': 'active', 'path': '.github/workflows/ci.yml'}])
    query('Release-only workflow remains present, per accepted scope', 'present',
          [{'state': 'active', 'path': '.github/workflows/release.yml'}])
    query('Dynamic Dependabot does not masquerade as repository CI', 'none',
          [{'state': 'active', 'path': 'dynamic/dependabot/dependabot-updates'}])
    query('Disabled workflow does not masquerade as active CI', 'none',
          [{'state': 'disabled_manually', 'path': '.github/workflows/ci.yml'}])
    query('Unavailable forge is unknown rather than no CI', 'unknown', error=True)
    query('Missing clone is unknown and makes no request', 'unknown', name='missing', request=False)
    subprocess.run(['git', '-C', str(project), 'remote', 'set-url', 'origin',
                    'https://gitlab.com/disposable/workflow-lab.git'], check=True)
    query('Unsupported forge is unknown and makes no request', 'unknown', request=False)
    lines.append('\nAll live workflow-query scenarios passed.')
    evidence.write_text('\n'.join(lines) + '\n')
    print(evidence.read_text())
finally:
    server.shutdown()
    server.server_close()
