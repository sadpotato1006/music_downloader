#!/usr/bin/env python3
"""Serve a disposable HTTPS school SSO fixture to the real WebKitGTK test."""
import json
import os
from pathlib import Path
import resource
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs, urlencode, urlsplit


SSO = 'https://sso.ustb.edu.cn'
RETURN_URL = SSO + '/idp/authCenter/authenticateByLck?thirdPartyAuthCode=microQr&lck=test'
QR_QUERY = urlencode(dict(appid='test', return_url=RETURN_URL, rand_token='test', embed_flag='1'))
QR_URL = 'https://sis.ustb.edu.cn/connect/qrpage?' + QR_QUERY
CALLBACK = 'https://127.0.0.1:9010/callback?code=test&state=test'


class SchoolProxy(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self, tls):
        super().__init__(('127.0.0.1', 0), SchoolRequest)
        self.tls = tls
        self.requests = []
        self.connections = []
        self.errors = []


class SchoolRequest(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            line = self.rfile.readline().decode('ascii').strip().split()
            if len(line) != 3 or line[0] != 'CONNECT':
                self.server.errors.append('Expected a TLS proxy connection')
                return
            host = line[1].rsplit(':', 1)[0]
            self.server.connections.append(host)
            if host not in {'sis.ustb.edu.cn', 'sso.ustb.edu.cn', 'yunpan.ustb.edu.cn'}:
                self.server.errors.append('Unexpected host: ' + host)
                self.wfile.write(b'HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n')
                return
            while self.rfile.readline() not in {b'\r\n', b'\n', b''}:
                pass
            self.wfile.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            self.wfile.flush()
            with self.server.tls.wrap_socket(self.connection, server_side=True) as connection:
                reader = connection.makefile('rb')
                line = reader.readline().decode('ascii').strip().split()
                if len(line) != 3:
                    return  # WebKit can abandon a speculative connection.
                headers = {}
                while True:
                    raw = reader.readline()
                    if raw in {b'\r\n', b'\n', b''}:
                        break
                    key, value = raw.decode('ascii').split(':', 1)
                    headers[key.lower()] = value.strip()
                self.server.requests.append((host, line[1]))
                status, extra, body = self.response(host, line[1], headers)
                body = body.encode('utf-8')
                response = (f'HTTP/1.1 {status}\r\nContent-Length: {len(body)}\r\n'
                            'Content-Type: text/html; charset=utf-8\r\nConnection: close\r\n'
                            + extra + '\r\n').encode('ascii')
                connection.sendall(response + body)
        except (ssl.SSLError, ConnectionError, OSError):
            pass  # Cancellation and speculative TLS handshakes are normal.

    def response(self, host, target, headers):
        url = urlsplit(target)
        if host == 'sso.ustb.edu.cn' and url.path == '/ac/':
            return ('200 OK', 'Set-Cookie: school_session=test; Path=/; Secure; SameSite=Lax\r\n',
                    '<!doctype html><iframe src="' + QR_URL.replace('&', '&amp;') + '"></iframe>')
        if host == 'sis.ustb.edu.cn' and url.path == '/connect/qrpage':
            assert parse_qs(url.query)['return_url'] == [RETURN_URL]
            # Match the real school's poll -> window.top.location.href flow.
            return ('200 OK', '', '''<!doctype html><p id="state">Scanned</p><script>
                setTimeout(async () => {
                    const result = await (await fetch('/connect/state')).json();
                    if (result.code === 1) {
                        window.top.location.href = ''' + json.dumps(RETURN_URL) + '''
                            + '&appid=test&auth_code=' + result.data + '&rand_token=test';
                    }
                }, 50);
                </script>''')
        if host == 'sis.ustb.edu.cn' and url.path == '/connect/state':
            return '200 OK', '', json.dumps(dict(code=1, data='test'))
        if host == 'sso.ustb.edu.cn' and url.path == '/idp/authCenter/authenticateByLck':
            if 'school_session=test' not in headers.get('cookie', ''):
                self.server.errors.append('SSO session cookie was lost')
                return '401 Unauthorized', '', 'Missing school session'
            if parse_qs(url.query).get('auth_code') != ['test']:
                self.server.errors.append('Scan authorization result was lost')
                return '400 Bad Request', '', 'Missing authorization result'
            return '302 Found', 'Location: https://yunpan.ustb.edu.cn/oauth2/complete\r\n', ''
        if host == 'yunpan.ustb.edu.cn' and url.path == '/oauth2/complete':
            return '302 Found', 'Location: ' + CALLBACK + '\r\n', ''
        return '404 Not Found', '', 'Unknown fixture route'


def main():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    with tempfile.TemporaryDirectory(prefix='qingting-login-test-') as directory:
        cert = Path(directory) / 'school.pem'
        key = Path(directory) / 'school.key'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cert), '-days', '1',
                        '-subj', '/CN=sso.ustb.edu.cn', '-addext',
                        'subjectAltName=DNS:sso.ustb.edu.cn,DNS:sis.ustb.edu.cn,DNS:yunpan.ustb.edu.cn'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        with SchoolProxy(tls) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env = dict(os.environ, QINGTING_LOGIN_TEST_PROXY=f'http://127.0.0.1:{server.server_address[1]}',
                       QINGTING_LOGIN_TEST_CERT=str(cert), LIBGL_ALWAYS_SOFTWARE='1',
                       WEBKIT_DISABLE_DMABUF_RENDERER='1')
            try:
                result = subprocess.run([str(Path(sys.argv[1]).resolve())], env=env, timeout=45)
                if result.returncode:
                    print('Fixture connections:', server.connections, flush=True)
                    print('Fixture requests:', [(host, urlsplit(target).path) for host, target in server.requests], flush=True)
                    print('Fixture errors:', server.errors, flush=True)
                    raise SystemExit(result.returncode)
                assert not server.errors, server.errors
                assert '127.0.0.1' not in server.connections, 'OAuth callback was loaded over the network'
                assert any(host == 'yunpan.ustb.edu.cn' for host, _ in server.requests), 'OAuth redirects did not finish'
            except subprocess.TimeoutExpired:
                print('Fixture connections:', server.connections, flush=True)
                print('Fixture errors:', server.errors, flush=True)
                print('Fixture requests:', [(host, urlsplit(target).path) for host, target in server.requests], flush=True)
                raise
            finally:
                server.shutdown()
                thread.join(timeout=5)
    print('School QR promotion, SSO cookies and intercepted OAuth callback passed')


if __name__ == '__main__':
    main()
