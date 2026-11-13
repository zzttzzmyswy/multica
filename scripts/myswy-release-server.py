#!/usr/bin/env python3
"""Local GitHub-Releases-compatible server for exercising `multica update`.

Serves a releases API and release archives entirely from a temporary
directory. It exists so the update path can be tested end to end against real
HTTP without touching GitHub, and so a test can assert the exact request paths
the CLI asked for.

Usage:
    serve.py <root-dir> <port-file>

Endpoints:
    GET /repos/<owner>/<name>/releases/latest
    GET /repos/<owner>/<name>/releases/tags/<tag>
    GET /releases/download/<tag>/<asset>
    GET /_requests            -> newline-separated request paths seen so far
"""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

ROOT = sys.argv[1]
PORT_FILE = sys.argv[2]

_requests = []
_lock = threading.Lock()


def _releases():
    path = os.path.join(ROOT, "releases.json")
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()
    # `PORT` is a placeholder substituted with the port this process actually
    # bound, so a fixture file can carry download URLs without knowing it.
    return json.loads(raw.replace("PORT", str(_port[0])))


# Set in main() once the socket is bound.
_port = [0]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path, content_type="application/octet-stream"):
        with open(path, "rb") as handle:
            body = handle.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        path = unquote(parsed.path)

        with _lock:
            _requests.append(path)

        if path == "/_requests":
            body = "\n".join(_requests).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        releases = _releases()

        if path.endswith("/releases/latest"):
            tag = releases.get("latest")
            if not tag:
                self._json({"message": "Not Found"}, 404)
                return
            self._json(releases["tags"][tag])
            return

        if "/releases/tags/" in path:
            tag = path.rsplit("/", 1)[-1]
            rel = releases.get("tags", {}).get(tag)
            if not rel:
                self._json({"message": "Not Found"}, 404)
                return
            self._json(rel)
            return

        if "/releases/download/" in path:
            tail = path.split("/releases/download/", 1)[1]
            tag, _, asset = tail.partition("/")
            candidate = os.path.join(ROOT, "assets", tag, asset)
            if not os.path.isfile(candidate):
                self._json({"message": "Not Found"}, 404)
                return
            self._file(candidate)
            return

        self._json({"message": "Not Found"}, 404)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    # The CLI closes the connection as soon as it has what it needs, and a
    # 404 response that arrives after the client gave up is normal here, not
    # an error worth a traceback on the test's stderr.
    server.handle_error = lambda _request, _client_address: None
    port = server.server_address[1]
    _port[0] = port
    with open(PORT_FILE, "w", encoding="utf-8") as handle:
        handle.write(str(port))
    server.serve_forever()


if __name__ == "__main__":
    main()
