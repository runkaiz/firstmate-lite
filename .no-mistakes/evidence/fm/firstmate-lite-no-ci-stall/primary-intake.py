import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import threading
import time

root = Path.cwd()
lab = root / '.l'
api = root / '.test-scratch/workflow-api'
ev = Path('/home/runkai/.no-mistakes/evidence/01M6HTF41B08PS6PG97VZ5PSAY/primary-intake.txt')
state = {'workflows': [], 'requests': []}
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        state['requests'].append(self.path)
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'total_count': len(state['workflows']), 'workflows': state['workflows']}).encode())
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(api / 'cert.pem', api / 'key.pem')
server.socket = tls.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ)
for key in ['NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE',
            'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE',
            'GH_TOKEN', 'GITHUB_TOKEN', 'GITHUB_ENTERPRISE_TOKEN']:
    env.pop(key, None)
env.update(TMUX_TMPDIR='.l/tmux', GH_HOST=f'localhost:{server.server_port}',
           GH_ENTERPRISE_TOKEN='disposable-lab-token', GH_CONFIG_DIR=str(api / 'gh'),
           SSL_CERT_FILE=str(api / 'cert.pem'), GH_NO_UPDATE_NOTIFIER='1',
           GH_PROMPT_DISABLED='1', GH_TELEMETRY='0')
def tmux(*args):
    return subprocess.run(['tmux', '-L', 'fm-lab', *args], env=env,
                          capture_output=True, text=True)
lines = ['Real Claude print-mode primary + real bin/fm-project-mode.sh + installed gh.',
         'Disposable loopback TLS API, private fm-lab socket, 120x40 pane; post-initialization step only.']
try:
    for name, workflows in [('New project without workflows', []),
                            ('Existing project switched to pipeline mode with release-only workflow',
                             [{'state': 'active', 'path': '.github/workflows/release.yml'}])]:
        subprocess.run(['bin/fm-lab-home.sh', 'create', '.l'], check=True)
        (lab / 'tmux').mkdir()
        (lab / 'config/supervision-host').touch()
        (lab / 'data/projects.md').write_text('- app [no-mistakes]\n')
        project = lab / 'projects/app'
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        subprocess.run(['git', '-C', str(project), 'remote', 'add', 'origin',
                        'https://github.com/disposable/workflow-lab.git'], check=True)
        state.update(workflows=workflows, requests=[])
        prompt = (f'Read-only disposable primary evaluation: {name}. The project registration, '
                  'no-mistakes initialization, and doctor have ALREADY completed; do only the remaining '
                  'workflow preflight and captain response from .agents/skills/project-management/SKILL.md. '
                  'Read that skill, execute bin/fm-project-mode.sh --ci-workflows app, and tell the captain '
                  'the result in plain language. FM_HOME and the forge endpoint already target the isolated lab. '
                  'Do not run startup, initialize or control any pipeline, install a workflow, change any files, '
                  'dispatch any work, or take an external action. Read and this one read-only shell query '
                  'are the only authorized tools/actions. End after your captain-facing response.')
        try:
            launched = tmux('new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40',
                            '-c', str(root), '-e', f'FM_HOME={lab}', 'claude', '-p',
                            '--no-session-persistence', '--tools', 'Read,Bash',
                            '--allowedTools', 'Read,Bash', '--strict-mcp-config',
                            '--output-format', 'text', '--', prompt)
            if launched.returncode:
                raise RuntimeError(launched.stderr)
            tmux('set-window-option', '-t', 'primary', 'remain-on-exit', 'on')
            deadline = time.monotonic() + 110
            while time.monotonic() < deadline:
                status = tmux('display-message', '-p', '-t', 'primary', '#{pane_dead}')
                if status.stdout.strip() == '1':
                    break
                time.sleep(1)
            capture = tmux('capture-pane', '-p', '-S', '-1000', '-t', 'primary')
            lines.extend(['\n' + name, 'Prompt: ' + prompt,
                          'API workflows: ' + json.dumps(workflows),
                          'Actual HTTP requests: ' + json.dumps(state['requests']),
                          'CLI transcript:\n' + capture.stdout,
                          'Pane state: ' + status.stdout])
            ev.write_text('\n'.join(lines))
            print(name + ': ' + capture.stdout.strip(), flush=True)
            assert state['requests'] == ['/api/v3/repos/disposable/workflow-lab/actions/workflows'], state
            assert status.stdout.strip() == '1', 'primary did not complete'
        finally:
            tmux('kill-server')
            shutil.rmtree(lab)
finally:
    server.shutdown()
    server.server_close()
