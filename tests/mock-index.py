# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation

"""Serve a directory as a mock package index on a loopback port, for tests.

Usage: python3 -I mock-index.py <root_dir> <port_file>

Binds 127.0.0.1 on a free port, writes the port number to <port_file>
and serves GET requests until killed. A request for /a/b answers with
the bytes of <root_dir>/a/b, or 404 when that file is absent. When
<root_dir>/a/b.status exists, it answers with the HTTP status code that
file holds and an empty body instead. When <root_dir>/a/b.redirect
exists, it answers 302 with the Location that file holds.
"""

from __future__ import annotations

import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def make_handler(root: Path) -> type[BaseHTTPRequestHandler]:
    """Return a request handler class serving files under root."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            relative = self.path.split("?", 1)[0].lstrip("/")
            target = (root / relative).resolve()
            if root not in target.parents:
                self.send_error(404)
                return
            status_file = target.with_name(target.name + ".status")
            redirect_file = target.with_name(target.name + ".redirect")
            if status_file.is_file():
                self.send_response(int(status_file.read_text().strip()))
                self.send_header("Content-Length", "0")
                self.end_headers()
            elif redirect_file.is_file():
                self.send_response(302)
                self.send_header("Location", redirect_file.read_text().strip())
                self.send_header("Content-Length", "0")
                self.end_headers()
            elif target.is_file():
                body = target.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                _ = self.wfile.write(body)
            else:
                self.send_error(404)

    return Handler


def main(argv: list[str]) -> int:
    """Serve the mock index until killed."""
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(root))
    port_file = Path(argv[2])
    _ = port_file.with_suffix(".tmp").write_text(f"{server.server_address[1]}\n")
    _ = port_file.with_suffix(".tmp").replace(port_file)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
