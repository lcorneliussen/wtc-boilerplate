#!/usr/bin/env python3
"""Local-only tunnel stand-in. It never exposes a public endpoint."""
import http.server
import os
import urllib.request

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with urllib.request.urlopen(f'http://127.0.0.1:{os.environ["PORT"]}{self.path}', timeout=2) as upstream:
            self.send_response(upstream.status)
            self.end_headers()
            self.wfile.write(upstream.read())

server = http.server.ThreadingHTTPServer(('127.0.0.1', int(os.environ['RELAY_PORT'])), Handler)
print(f'ENDPOINT_READY port={server.server_port}', flush=True)
server.serve_forever()
