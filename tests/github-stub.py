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
# A stand-in for GitHub's REST API, for tests/smoke.sh: just the endpoints herdquay-github calls.
# It runs inside the test container on loopback, needs only Python's standard library and openssl,
# and checks every App JWT the way GitHub does (RS256 signature against the test App's public key,
# an allowed iss, a live iat/exp window of at most ten minutes).
#
# Usage: github-stub.py <port> <public-key.pem> <app-id>[,<app-id>...]
#
# Repositories of owner "o" are installed (installation 1), "o/missing" is not. Test-only
# endpoints: GET /_stub/mints lists every token minted ({path, repositories, token}),
# POST /_stub/expires-in with a number of seconds sets the lifetime of the tokens minted next, and
# POST /_stub/git-delay with a number of seconds makes Git's endpoint
# (GET /<owner>/<repo>.git/info/refs) refuse the tokens minted next with a 404 for that long, as
# github.com can; GET /_stub/git-polls lists the tokens it was asked about.

import base64
import datetime
import json
import os
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
PUBLIC_KEY = sys.argv[2]
APP_IDS = set(sys.argv[3].split(","))
mints = []
expires_in = 3600
git_delay = 0
git_polls = []


def b64url_decode(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def valid_jwt(authorization):
    if not authorization.startswith("Bearer "):
        return False
    try:
        header, payload, signature = authorization[len("Bearer "):].split(".")
        if json.loads(b64url_decode(header)).get("alg") != "RS256":
            return False
        claims = json.loads(b64url_decode(payload))
        now = time.time()
        if str(claims["iss"]) not in APP_IDS:
            return False
        if not claims["iat"] <= now < claims["exp"] or claims["exp"] - claims["iat"] > 600:
            return False
        with tempfile.TemporaryDirectory() as scratch:
            signed = os.path.join(scratch, "signed")
            sig = os.path.join(scratch, "sig")
            with open(signed, "w") as f:
                f.write(header + "." + payload)
            with open(sig, "wb") as f:
                f.write(b64url_decode(signature))
            check = subprocess.run(
                ["openssl", "dgst", "-sha256", "-verify", PUBLIC_KEY, "-signature", sig, signed],
                capture_output=True,
            )
        return check.returncode == 0
    except (ValueError, KeyError, TypeError):
        return False


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def app_authorized(self):
        if valid_jwt(self.headers.get("Authorization", "")):
            return True
        self.reply(401, {"message": "A JSON web token could not be decoded"})
        return False

    def git_info_refs(self):
        authorization = self.headers.get("Authorization", "")
        try:
            user, _, token = base64.b64decode(authorization[len("Basic "):]).decode().partition(":")
        except ValueError:
            user, token = "", ""
        git_polls.append(token)
        mint = next((m for m in mints if m["token"] == token), None)
        repository = self.path.split("/")[2].removesuffix(".git")
        if (not authorization.startswith("Basic ") or user != "x-access-token" or mint is None
                or repository not in (mint["repositories"] or [repository])
                or time.time() < mint["usable_at"]):
            self.reply(404, {"message": "Repository not found."})
        else:
            self.reply(200, {})

    def do_GET(self):
        path = self.path
        if path == "/_stub/mints":
            self.reply(200, [{k: m[k] for k in ("path", "repositories", "token")} for m in mints])
        elif path == "/_stub/git-polls":
            self.reply(200, git_polls)
        elif path.startswith("/o/") and path.endswith(".git/info/refs?service=git-upload-pack"):
            self.git_info_refs()
        elif path in ("/users/herdquay-test%5Bbot%5D", "/users/herdquay-test[bot]"):
            self.reply(200, {"login": "herdquay-test[bot]", "id": 4242})
        elif not self.app_authorized():
            pass
        elif path == "/app":
            self.reply(200, {"id": 12345, "slug": "herdquay-test"})
        elif path == "/app/installations":
            self.reply(200, [{"id": 1}])
        elif path.startswith("/repos/o/") and path.endswith("/installation") and path != "/repos/o/missing/installation":
            self.reply(200, {"id": 1})
        else:
            self.reply(404, {"message": "Not Found"})

    def do_POST(self):
        global expires_in, git_delay
        body = self.body()
        if self.path == "/_stub/expires-in":
            expires_in = int(body)
            self.reply(200, {"expires_in": expires_in})
        elif self.path == "/_stub/git-delay":
            git_delay = float(body)
            self.reply(200, {"git_delay": git_delay})
        elif self.path != "/app/installations/1/access_tokens":
            self.reply(404, {"message": "Not Found"})
        elif self.app_authorized():
            repositories = json.loads(body or b"{}").get("repositories")
            token = "ghs_%d_%d_%s" % (PORT, len(mints) + 1, "-".join(repositories) if repositories else "all")
            expires = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=expires_in)
            mints.append({"path": self.path, "repositories": repositories, "token": token,
                          "usable_at": time.time() + git_delay})
            self.reply(201, {"token": token, "expires_at": expires.strftime("%Y-%m-%dT%H:%M:%SZ")})

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
