#!/usr/bin/env python3
import http.server
import os

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(os.getenv('WTC_COLLECTION', 'standalone').encode())

server = http.server.ThreadingHTTPServer(('127.0.0.1', int(os.getenv('PORT', '3000'))), Handler)
print(f'WEB_READY port={server.server_port}', flush=True)
server.serve_forever()
