#!/usr/bin/env python3
"""
Enhanced status server with command execution capability
Add this to V73 ramdisk at /usr/local/sbin/zl1-status-server-enhanced.py
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import subprocess
import json
from urllib.parse import parse_qs

class EnhancedStatusHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        """Return system status (original functionality)"""
        if self.path == '/':
            # Original status dump code here
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            # ... existing status collection ...

    def do_POST(self):
        """Execute commands via HTTP POST"""
        content_length = int(self.headers.get('Content-Length', 0))
        post_data = self.rfile.read(content_length).decode('utf-8')
        params = parse_qs(post_data)

        if self.path == '/exec':
            # Execute shell command
            cmd = params.get('cmd', [''])[0]
            if not cmd:
                self.send_error(400, "No command provided")
                return

            try:
                result = subprocess.check_output(
                    cmd,
                    shell=True,
                    stderr=subprocess.STDOUT,
                    timeout=30
                )
                self.send_response(200)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(result)
            except subprocess.CalledProcessError as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f"Exit {e.returncode}:\n{e.output}".encode())
            except subprocess.TimeoutExpired:
                self.send_error(408, "Command timeout")

        elif self.path == '/read':
            # Read file
            path = params.get('path', [''])[0]
            try:
                with open(path, 'rb') as f:
                    content = f.read()
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.end_headers()
                self.wfile.write(content)
            except Exception as e:
                self.send_error(500, str(e))
        else:
            self.send_error(404)

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8080), EnhancedStatusHandler)
    print("Enhanced status server listening on port 8080")
    server.serve_forever()
