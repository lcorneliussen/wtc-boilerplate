#!/usr/bin/env python3
"""Local-only tunnel stand-in. It never exposes a public endpoint."""
import http.client
import http.server
import os

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        # The upstream host is fixed; the request target only ever selects a path.
        upstream = http.client.HTTPConnection('127.0.0.1', int(os.environ['PORT']), timeout=2)
        try:
            upstream.request('GET', self.path)
            response = upstream.getresponse()
            self.send_response(response.status)
            self.end_headers()
            self.wfile.write(response.read())
        finally:
            upstream.close()

server = http.server.ThreadingHTTPServer(('127.0.0.1', int(os.environ['RELAY_PORT'])), Handler)
print(f'ENDPOINT_READY port={server.server_port}', flush=True)
server.serve_forever()
