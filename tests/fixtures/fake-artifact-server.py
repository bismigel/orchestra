#!/usr/bin/env python3
"""A fake Artifact Server for tests/artifact.sh: stdlib only, one behaviour per FAKE_MODE.

It binds 127.0.0.1 on a free port and prints that port on the first stdout line, then answers the upload-plan
flow (POST /api/v1/uploads, PUT the planned path, POST the commit URL). Every request is appended to FAKE_LOG as
one JSON line: {method, path, auth_ok, ua, ctype, idem, body}. The token is never written to the log, only whether
the Authorization header matched; `body` is the parsed JSON for JSON requests and {"len":N} for the PUT.

Env:
  FAKE_MODE   ok201 (default) | ok200 | other-origin | other-origin-commit | bad-path | bad-size | two-files |
              not-verified | create-401 | redirect-create | commit-500 | token-in-url | no-link
  FAKE_LOG    file the request log is appended to (no log when unset)
  FAKE_OTHER  origin of a second listener, used by other-origin, other-origin-commit and redirect-create
  FAKE_TOKEN  the API token the client is expected to send (default: dummy-token-never-print)
"""
import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

MODE = os.environ.get("FAKE_MODE", "ok201")
LOG = os.environ.get("FAKE_LOG", "")
OTHER = os.environ.get("FAKE_OTHER", "").rstrip("/")
TOKEN = os.environ.get("FAKE_TOKEN", "dummy-token-never-print")

PLAN_ID = "fake-plan"
UPLOAD_PATH = f"/api/v1/uploads/{PLAN_ID}/index.html"
COMMIT_PATH = f"/api/v1/uploads/{PLAN_ID}/commit"
REVIEW_PATH = "/review?x=1"

CREATE_STATUS = 200 if MODE == "ok200" else 201
COMMIT_STATUS = 200 if MODE == "ok200" else 201


def parse_json(raw):
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # one request per connection: no keep-alive bookkeeping in the fake

    def log_message(self, fmt, *args):
        pass  # the JSON request log is the only output

    # ---- plumbing -------------------------------------------------------------------------------------------------

    def origin(self):
        return f"http://127.0.0.1:{self.server.server_address[1]}"

    def other(self):
        return OTHER or self.origin()

    def read_body(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        return self.rfile.read(length) if length > 0 else b""

    def log_request_json(self, raw):
        ctype = self.headers.get("Content-Type") or ""
        if self.command == "PUT":
            body = {"len": len(raw)}
        elif "json" in ctype.lower():
            body = parse_json(raw)
        else:
            body = {"len": len(raw)}
        entry = {
            "method": self.command,
            "path": urllib.parse.urlsplit(self.path).path,
            "auth_ok": self.headers.get("Authorization") == f"Bearer {TOKEN}",
            "ua": self.headers.get("User-Agent") or "",
            "ctype": ctype,
            "idem": self.headers.get("Idempotency-Key") is not None,
            "body": body,
        }
        if LOG:
            with open(LOG, "a", encoding="utf-8") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def send_json(self, status, payload, headers=None):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    # ---- the upload-plan flow -------------------------------------------------------------------------------------

    def plan(self, size, path="index.html", upload_url="", second_file=False):
        origin = self.origin()
        files = [{
            "method": "PUT",
            "path": path,
            "size": size,
            "uploadUrl": upload_url or origin + UPLOAD_PATH,
        }]
        if second_file:
            files.append({
                "method": "PUT",
                "path": "extra.html",
                "size": size,
                "uploadUrl": origin + "/api/v1/uploads/fake-plan/extra.html",
            })
        return {"commitUrl": origin + COMMIT_PATH, "uploadId": PLAN_ID, "files": files}

    def create(self, raw):
        if MODE == "create-401":
            self.send_json(401, {"error": "unauthorized"})
            return
        if MODE == "redirect-create":
            self.send_json(302, {"error": "moved"}, {"Location": self.other() + "/api/v1/uploads"})
            return
        request = parse_json(raw)
        files = request.get("files") if isinstance(request.get("files"), list) else []
        size = files[0].get("size") if files and isinstance(files[0], dict) else 0
        if not isinstance(size, int) or isinstance(size, bool):
            size = 0
        if MODE == "other-origin":
            self.send_json(CREATE_STATUS, self.plan(size, upload_url=self.other() + UPLOAD_PATH))
        elif MODE == "other-origin-commit":
            plan = self.plan(size)
            plan["commitUrl"] = self.other() + COMMIT_PATH
            self.send_json(CREATE_STATUS, plan)
        elif MODE == "bad-path":
            self.send_json(CREATE_STATUS, self.plan(size, path="evil/../index.html"))
        elif MODE == "bad-size":
            self.send_json(CREATE_STATUS, self.plan(size + 1))
        elif MODE == "two-files":
            self.send_json(CREATE_STATUS, self.plan(size, second_file=True))
        else:
            self.send_json(CREATE_STATUS, self.plan(size))

    def upload(self, raw):
        if MODE == "not-verified":
            self.send_json(200, {"status": "pending", "path": "index.html"})
        else:
            self.send_json(200, {"status": "verified", "path": "index.html"})

    def commit(self, _raw):
        if MODE == "commit-500":
            self.send_json(500, {"error": "boom"})
            return
        if MODE == "no-link":
            self.send_json(COMMIT_STATUS, {})
            return
        if MODE == "token-in-url":
            self.send_json(COMMIT_STATUS, {"links": {"review": self.origin() + "/review?token=" + TOKEN}})
            return
        self.send_json(COMMIT_STATUS, {"links": {"review": self.origin() + REVIEW_PATH}})

    # ---- dispatch -------------------------------------------------------------------------------------------------

    def dispatch(self):
        raw = self.read_body()
        self.log_request_json(raw)
        path = urllib.parse.urlsplit(self.path).path
        if self.command == "POST" and path == "/api/v1/uploads":
            self.create(raw)
        elif self.command == "PUT" and path == UPLOAD_PATH:
            self.upload(raw)
        elif self.command == "POST" and path == COMMIT_PATH:
            self.commit(raw)
        else:
            self.send_json(404, {"error": "not found"})

    do_POST = dispatch
    do_PUT = dispatch
    do_GET = dispatch


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
