"""A stand-in for Time Tracker's server, for the tests only.

Usage: python3 fake_server.py <dir>

Listens on a free local port, written to <dir>/port, and appends each request
to <dir>/requests.jsonl as {"route", "authorization", "body"}. It answers:

  .../computer-pairing/start   a code, valid 600 s, polled with no delay
  .../computer-pairing/status  the first line of <dir>/statuses, removing it
                               unless it is the last
  anything else (heartbeats)   the status code in <dir>/status (default 200),
                               after the seconds in <dir>/delay (default 0)
"""

import json
import os
import socketserver
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]


def read(name, default):
    try:
        with open(os.path.join(DIR, name)) as f:
            return f.read().strip() or default
    except FileNotFoundError:
        return default


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        text = self.rfile.read(length).decode() if length else ""
        route = self.path.rstrip("/").split("/")[-1]
        with open(os.path.join(DIR, "requests.jsonl"), "a") as f:
            f.write(
                json.dumps(
                    {
                        "route": route,
                        "authorization": self.headers.get("authorization"),
                        "body": json.loads(text) if text else None,
                    }
                )
                + "\n"
            )

        if route == "start":
            self.reply(200, {"user_code": "WDJBMJHT", "expires_in": 600, "interval": 0})
        elif route == "status":
            path = os.path.join(DIR, "statuses")
            with open(path) as f:
                statuses = f.read().split()
            if len(statuses) > 1:
                with open(path, "w") as f:
                    f.write("\n".join(statuses[1:]))
            self.reply(200, {"status": statuses[0]})
        else:
            time.sleep(float(read("delay", "0")))
            self.reply(int(read("status", "200")), {})

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer's own server_bind looks up the host's name, which can
        # take seconds on macOS; nothing here needs it.
        socketserver.TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


server = Server(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
