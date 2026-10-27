#!/usr/bin/env python3
"""Compile the ORM browser entry and run it once in Chrome.

The page posts its own text. This script does not invent that text.
A pass is one page session. It is not a power-loss result.
"""

import http.server
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

PACKAGE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRY = os.path.join(PACKAGE, "tool", "chrome_orm.dart")
HTML = os.path.join(PACKAGE, "tool", "chrome_orm.html")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    dart = os.environ.get("DART", "dart")
    chrome = os.environ.get("CHROME", "google-chrome")
    serve = tempfile.mkdtemp(prefix="sqlite-plus-chrome-")
    profile = tempfile.mkdtemp(prefix="sqlite-plus-chrome-profile-")
    posted = {}
    port = free_port()

    def compile_js():
        output = os.path.join(serve, "chrome_orm.dart.js")
        with open(os.path.join(serve, "compile.log"), "w", encoding="utf-8") as log:
            subprocess.run(
                [dart, "compile", "js", ENTRY, "-o", output],
                cwd=PACKAGE,
                check=True,
                stdout=log,
                stderr=log,
            )
        shutil.copy(HTML, os.path.join(serve, "chrome_orm.html"))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            name = "chrome_orm.html" if self.path in ("/", "/chrome_orm.html") else self.path.lstrip("/")
            path = os.path.join(serve, name)
            if not os.path.isfile(path):
                self.send_error(404)
                return
            content_type = "text/html" if name.endswith(".html") else "text/javascript"
            data = open(path, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.path != "/result":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", "0"))
            posted["body"] = self.rfile.read(length).decode("utf-8", "replace")
            self.send_response(204)
            self.end_headers()

        def log_message(self, fmt, *args):
            return

    compile_js()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    chrome_version = subprocess.run(
        [chrome, "--version"], check=True, text=True, capture_output=True
    ).stdout.strip()
    dart_run = subprocess.run(
        [dart, "--version"], check=False, text=True, capture_output=True
    )
    dart_version = (dart_run.stdout or dart_run.stderr).strip()
    process = subprocess.Popen(
        [
            chrome,
            "--headless=new",
            "--no-sandbox",
            "--disable-gpu",
            "--disable-dev-shm-usage",
            "--no-first-run",
            "--disable-extensions",
            f"--user-data-dir={profile}",
            f"http://127.0.0.1:{port}/chrome_orm.html",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.time() + 60
    while "body" not in posted and time.time() < deadline:
        if process.poll() is not None:
            time.sleep(0.5)
            break
        time.sleep(0.2)
    if process.poll() is None:
        process.kill()
        process.wait()
    stderr = process.stderr.read() if process.stderr else ""
    server.shutdown()
    body = posted.get("body", "")
    header = "\n".join(
        [
            f"chrome: {chrome_version}",
            f"dart: {dart_version}",
            "os: Linux x86_64",
            f"url: http://127.0.0.1:{port}/chrome_orm.html",
            "page:",
            body if body.endswith("\n") or body == "" else body + "\n",
        ]
    )
    sys.stdout.write(header)
    if "result=pass" not in body or "placement=browser" not in body:
        sys.stderr.write(stderr)
        return 1
    if "durabilityPromised=true" in body:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
