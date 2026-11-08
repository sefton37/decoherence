#!/usr/bin/env python3
"""tests/fake_ollama.py -- Spec #519 A1: a stdlib-only fake of the slice of the Ollama API the game uses.

Loopback only, scratch port, no GPU, no model. Every request is appended to --out as one
JSON object per line: {"phase", "method", "path", "body"}. Answers:
  GET  /api/tags   -> the model list (empty with --mode nomodel, so the boot gate fails honestly)
  POST /api/chat   -> NDJSON stream when body.stream is true; a valid router action when
                      body.format is set; a one-word reply otherwise (the gate warm-up)
Anything else is a 404, which the recorder still logs (a stray /v1 call shows up in the log).
"""
import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL = "qwen3:14b"
ACTION = {"action": "open_module", "args": {"module": "chat"}, "say": "ROUTING YOU TO THE CHAT MODULE."}


def make_handler(out_path, phase, mode):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def _record(self, body):
            with open(out_path, "a", encoding="utf-8") as f:
                f.write(json.dumps({"phase": phase, "method": self.command, "path": self.path, "body": body}) + "\n")

        def _send(self, code, payload, ndjson=False):
            raw = payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/x-ndjson" if ndjson else "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            self._record(None)
            if self.path == "/api/tags":
                models = [] if mode == "nomodel" else [{"name": MODEL, "model": MODEL}]
                self._send(200, {"models": models})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            n = int(self.headers.get("Content-Length", "0") or 0)
            try:
                body = json.loads(self.rfile.read(n).decode("utf-8"))
            except ValueError:
                body = None
            self._record(body)
            if self.path != "/api/chat" or not isinstance(body, dict):
                self._send(404, {"error": "not found"})
                return
            if body.get("stream"):
                lines = [
                    {"model": MODEL, "message": {"role": "assistant", "content": "Hello"}, "done": False},
                    {"model": MODEL, "message": {"role": "assistant", "content": " there."}, "done": False},
                    {"model": MODEL, "message": {"role": "assistant", "content": ""}, "done": True, "done_reason": "stop"},
                ]
                self._send(200, ("\n".join(json.dumps(x) for x in lines) + "\n").encode("utf-8"), ndjson=True)
            elif body.get("format") is not None:
                self._send(200, {"model": MODEL, "message": {"role": "assistant", "content": json.dumps(ACTION)},
                                 "done": True, "done_reason": "stop", "prompt_eval_count": 700, "eval_count": 30})
            else:
                self._send(200, {"model": MODEL, "message": {"role": "assistant", "content": "ok"},
                                 "done": True, "done_reason": "length", "prompt_eval_count": 4, "eval_count": 1})

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--phase", required=True)
    ap.add_argument("--mode", choices=["ok", "nomodel"], default="ok")
    a = ap.parse_args()
    srv = HTTPServer(("127.0.0.1", a.port), make_handler(a.out, a.phase, a.mode))
    print("FAKE_OLLAMA_LISTENING port=%d phase=%s mode=%s" % (a.port, a.phase, a.mode), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
