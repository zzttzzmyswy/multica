#!/usr/bin/env python3
"""Local GitHub + GHCR stub for the release guard's tests.

The guard decides whether a tag is free by *asking*, and the defect this stub
exists to reproduce is about how answers are interpreted: a 403 read as "the
tag is free", a bare `not found` on stderr read as absence. A test that replaced
the query with an injected 0/1 exit code would never reach that code, so these
tests run the real `curl`/`jq` path against this server. Nothing here reaches
github.com or ghcr.io, and it can only be reached on 127.0.0.1.

Behaviour comes from a JSON config that is re-read on every request, so a test
can change one answer between two guard runs without restarting the server.

Usage:
    myswy-release-guard-stub.py <config.json> <port-file> [<request-log>]

Config:
    {
      "release_status": 404,              # GET /repos/<o>/<r>/releases/tags/<tag>
      "release_body": {...},              # optional body for a non-404 answer
      "token_status": 200,                # registry token for an authenticated request
      "anonymous_token_status": 403,      # registry token for an anonymous request
      "unauthenticated_manifest_status": 401,
      "repositories": {
        "owner/name": {
          "tags_list": {"status": 200},
          "tags": ["v0.9.0-myswy.1"],
          "manifests": {"<tag>": {"status": 200}},
          "default_manifest_status": 404
        }
      }
    }

A 404 answer carries the OCI error code the real registry sends (`NAME_UNKNOWN`
for an unknown repository, `MANIFEST_UNKNOWN` for a missing tag). Setting
`"error_code": ""` on an entry emits a bare 404 instead, which the guard must not
accept as proof of absence.

Request log lines are `<method> <path> auth=<yes|no>` so a test can prove no
write verb was ever attempted.
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

CONFIG = sys.argv[1]
PORT_FILE = sys.argv[2]
LOG_FILE = sys.argv[3] if len(sys.argv) > 3 else None

_lock = threading.Lock()
_port = [0]


def _config():
    with open(CONFIG, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _log(entry):
    if not LOG_FILE:
        return
    with _lock:
        with open(LOG_FILE, "a", encoding="utf-8") as handle:
            handle.write(entry + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def _json(self, payload, status):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, status, code, message):
        self._json({"errors": [{"code": code, "message": message}]}, status)

    def _authenticated(self):
        return bool(self.headers.get("Authorization"))

    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlparse(self.path)
        authed = self._authenticated()
        _log("%s %s auth=%s" % (self.command, self.path, "yes" if authed else "no"))
        config = _config()
        parts = [part for part in parsed.path.split("/") if part]

        # GitHub release API.
        if len(parts) == 6 and parts[0] == "repos" and parts[3] == "releases" and parts[4] == "tags":
            status = config.get("release_status", 404)
            if status == 200:
                self._json(config.get("release_body", {"tag_name": parts[5]}), 200)
            elif status == 404:
                self._json({"message": "Not Found"}, 404)
            elif status in (401, 403):
                self._json({"message": "Resource not accessible by integration"}, status)
            else:
                self._json({"message": "Server Error"}, status)
            return

        # Registry token endpoint.
        if parsed.path == "/token":
            if not authed:
                status = config.get("anonymous_token_status", 403)
                if status == 200:
                    self._json({"token": "anonymous-token"}, 200)
                else:
                    self._error(status, "DENIED", "requested access to the resource is denied")
                return
            status = config.get("token_status", 200)
            if status == 200:
                self._json({"token": "stub-token"}, 200)
            else:
                self._error(status, "DENIED", "denied")
            return

        # /v2/<owner>/<name>/(tags/list|manifests/<tag>)
        if len(parts) < 4 or parts[0] != "v2":
            self._error(404, "NOT_FOUND", "unknown endpoint")
            return
        repository = "%s/%s" % (parts[1], parts[2])
        rest = parts[3:]

        if not authed:
            self._error(config.get("unauthenticated_manifest_status", 401),
                        "UNAUTHORIZED", "authentication required")
            return

        spec = config.get("repositories", {}).get(repository)
        if spec is None:
            # No package yet: the real registry answers NAME_UNKNOWN here, which
            # is what distinguishes "nothing published" from "not allowed".
            self._reply(spec={}, status=404, code="NAME_UNKNOWN",
                        message="repository name not known to registry")
            return

        if rest == ["tags", "list"]:
            entry = spec.get("tags_list", {"status": 200})
            status = entry.get("status", 200)
            if status == 200:
                self._json({"name": repository, "tags": spec.get("tags", [])}, 200)
            else:
                self._error_or_bare(entry, status, "NAME_UNKNOWN",
                                    "repository name not known to registry")
            return

        if len(rest) == 2 and rest[0] == "manifests":
            entry = spec.get("manifests", {}).get(rest[1])
            if entry is None:
                entry = {"status": spec.get("default_manifest_status", 404)}
            status = entry.get("status", 404)
            if status == 200:
                self._json(
                    {
                        "schemaVersion": 2,
                        "mediaType": "application/vnd.oci.image.index.v1+json",
                        "manifests": [],
                    },
                    200,
                )
            else:
                self._error_or_bare(entry, status, "MANIFEST_UNKNOWN", "manifest unknown")
            return

        self._error(404, "NOT_FOUND", "unknown endpoint")

    def _error_or_bare(self, entry, status, default_code, default_message):
        code = entry.get("error_code", default_code)
        if not code:
            # A bare 404 with no OCI error code: what a proxy or a misconfigured
            # client produces, and the shape that must never read as absence.
            self._json({"message": "Not Found"}, status)
            return
        self._error(status, code, entry.get("message", default_message))

    def _reply(self, spec, status, code, message):
        self._error_or_bare({"error_code": code}, status, code, message)

    # Any mutating verb is logged and refused: the guard is read-only, and a test
    # asserts none of these ever arrives.
    def _reject_write(self):
        _log("%s %s auth=%s WRITE" % (self.command, self.path,
                                      "yes" if self._authenticated() else "no"))
        self._error(405, "DENIED", "this stub accepts no writes")

    do_PUT = _reject_write  # noqa: N815
    do_POST = _reject_write  # noqa: N815
    do_PATCH = _reject_write  # noqa: N815
    do_DELETE = _reject_write  # noqa: N815


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    _port[0] = server.server_address[1]
    with open(PORT_FILE, "w", encoding="utf-8") as handle:
        handle.write(str(_port[0]))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
