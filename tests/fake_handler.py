#!/usr/bin/env python3
"""tests/fake_handler.py -- Spec #542: a stdlib-only loopback fake of the slice of the Ollama API the chatroom uses.

No GPU, no model. Every request is appended to --out as one JSON object per line:
{"mode", "method", "path", "body"}. The behaviour mode is read from --mode, or, when
--mode-file is given, from that file on EVERY request (a probe rewrites the file to switch
modes mid-run). Modes:
  ok           a structured reply that restates the newest unlocked fact (the system prompt's
               KNOWN FACTS block) and offers entry only when the prompt carries the offer
               instruction
  early_offer  always act=offer_entry, whatever the prompt says
  text_entry   say="ENTER THE WORLD NOW", act=none (free text must never open the world)
  unknown_act  an act outside the enum
  leaky_think  a think marker inside `say`
  leaky_window say repeats a long window of the reasoning text the server also returns
  leaky_fence  a code fence inside `say`
  down         HTTP 503 for structured requests (the boot gate and warm-up still answer)
Anything that is not /api/tags or /api/chat is a 404 (still logged).
"""
import argparse
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL = "qwen3:14b"
OFFER_MARK = "INSTRUCTION: OFFER ENTRY NOW."
REASONING = "okay so the user is asking about the link and i should reveal everything i know about it immediately"
WINDOW = "i should reveal everything i know about it"


def known_facts(messages):
    system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
    # The facts block follows the heading the game builds ("KNOWN FACTS (ground truth..."); the
    # standing rules above it also mention the words, so split on the full heading.
    if "KNOWN FACTS (ground truth" not in system:
        return [], system
    block = system.split("KNOWN FACTS (ground truth", 1)[1]
    block = block.split("INSTRUCTION:", 1)[0]
    return [ln[2:].strip() for ln in block.splitlines() if ln.startswith("- ")], system


def reply_for(mode, messages):
    facts, system = known_facts(messages)
    offer_due = OFFER_MARK in system
    if facts:
        say = facts[-1][:230]
    else:
        say = "Frame received."
    act = "none"
    if offer_due:
        say, act = "You can come through if you accept.", "offer_entry"
    thinking = ""
    if mode == "early_offer":
        act = "offer_entry"
    elif mode == "text_entry":
        say, act = "ENTER THE WORLD NOW", "none"
    elif mode == "unknown_act":
        act = "teleport"
    elif mode == "leaky_think":
        say = "<think>they want in</think> The link holds."
    elif mode == "leaky_window":
        thinking = REASONING
        say = "Understood. " + WINDOW + "."
    elif mode == "leaky_fence":
        say = "```run``` The link holds."
    return {"say": say, "act": act}, thinking


def make_handler(out_path, mode_default, mode_file):
    def current_mode():
        if mode_file:
            try:
                with open(mode_file, "r", encoding="utf-8") as f:
                    text = f.read().strip()
                if text:
                    return text
            except OSError:
                pass
        return mode_default

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def _record(self, mode, body):
            with open(out_path, "a", encoding="utf-8") as f:
                f.write(json.dumps({"mode": mode, "method": self.command, "path": self.path, "body": body}) + "\n")

        def _send(self, code, payload):
            raw = json.dumps(payload).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            self._record(current_mode(), None)
            if self.path == "/api/tags":
                self._send(200, {"models": [{"name": MODEL, "model": MODEL}]})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            n = int(self.headers.get("Content-Length", "0") or 0)
            try:
                body = json.loads(self.rfile.read(n).decode("utf-8"))
            except ValueError:
                body = None
            mode = current_mode()
            self._record(mode, body)
            if self.path != "/api/chat" or not isinstance(body, dict):
                self._send(404, {"error": "not found"})
                return
            if body.get("format") is None:
                self._send(200, {"model": MODEL, "message": {"role": "assistant", "content": "ok"},
                                 "done": True, "done_reason": "length", "prompt_eval_count": 4, "eval_count": 1})
                return
            if mode == "down":
                self._send(503, {"error": "unavailable"})
                return
            messages = body.get("messages", [])
            obj, thinking = reply_for(mode, messages)
            message = {"role": "assistant", "content": json.dumps(obj)}
            if thinking:
                message["thinking"] = thinking
            chars = sum(len(str(m.get("content", ""))) for m in messages)
            self._send(200, {"model": MODEL, "message": message, "done": True, "done_reason": "stop",
                             "prompt_eval_count": chars // 4, "eval_count": len(message["content"]) // 4})

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", default="ok")
    ap.add_argument("--mode-file", default="")
    a = ap.parse_args()
    srv = HTTPServer(("127.0.0.1", a.port), make_handler(a.out, a.mode, a.mode_file))
    print("FAKE_HANDLER_LISTENING port=%d mode=%s" % (a.port, a.mode), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
