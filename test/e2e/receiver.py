# The webhook gladios-notify posts to: keeps each body as /tmp/hook-<n>.json, or answers 500
# while /tmp/hook-fail exists.
import glob
import os
from http.server import BaseHTTPRequestHandler, HTTPServer


class Hook(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if os.path.exists('/tmp/hook-fail'):
            self.send_response(500)
        else:
            with open('/tmp/hook-%d.json' % (len(glob.glob('/tmp/hook-*.json')) + 1), 'wb') as f:
                f.write(body)
            self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


HTTPServer(('127.0.0.1', 9999), Hook).serve_forever()
