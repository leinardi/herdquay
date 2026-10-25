#!/usr/bin/env python3
#
# MIT License
#
# Copyright (c) 2026 Roberto Leinardi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# A stand-in for a Docker daemon's API, for tests/smoke.sh: just the ping and the info that
# `herdquay doctor` reads. It runs inside the test container on loopback and needs only Python's
# standard library.
#
# Usage: docker-stub.py <port> rootless|rootful

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
SECURITY_OPTIONS = ["name=seccomp,profile=builtin", "name=cgroupns"]
if sys.argv[2] == "rootless":
    SECURITY_OPTIONS.append("name=rootless")


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, content_type, data):
        self.send_response(code)
        self.send_header("Api-Version", "1.47")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/_ping":
            self.reply(200, "text/plain", b"OK")
        elif path.endswith("/info"):
            info = {"ServerVersion": "29.0.0-stub", "SecurityOptions": SECURITY_OPTIONS}
            self.reply(200, "application/json", json.dumps(info).encode())
        else:
            self.reply(404, "application/json", b'{"message": "page not found"}')

    do_HEAD = do_GET

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
