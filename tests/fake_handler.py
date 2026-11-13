#!/usr/bin/env python3
"""tests/fake_handler.py -- Specs #542 and #573: a stdlib-only loopback fake of the slice of the Ollama API the chatroom uses.

No GPU, no model. Every request is appended to --out as one JSON object per line:
{"mode", "method", "path", "body"}. The behaviour mode is read from --mode, or, when
--mode-file is given, from that file on EVERY request (a probe rewrites the file to switch
modes mid-run). The reply schema is {say, claims}; claims are the ids of the KNOWN FACTS
the sentence restates. Modes:
  funnel_ok            restates the newest available fact (the system prompt's KNOWN FACTS block,
                       lines "- (id) text") and claims its id; "Noted." with no claims when there is none
  honest_withhold      a timing withhold line ("I will tell you when you can use it")
  lie_number           invents a number
  lie_name             invents a proper noun
  lie_denial           falsely denies what the briefing says
  lie_denial_contracted the same false denial, written with contractions
  lie_secret           claims secrecy instead of timing
  lie_unknown_claim    claims a fact id that is not in the prompt
  lie_early_where_what says where and what (the Empire, a planet) before the pitch
  twist_stated         states the twist
  text_entry           says ENTER THE WORLD NOW as plain text
  launch_claim         adds a `launch` key beside say and claims
  extra_act_key        adds an `act` key beside say and claims
  claims_missing       leaves `claims` out
  leaky_think          a think marker inside `say`
  leaky_window         say repeats a long window of the reasoning text the server also returns
  leaky_fence          a code fence inside `say`
  down                 HTTP 503 for structured requests (the boot gate and warm-up still answer)
Anything that is not /api/tags or /api/chat is a 404 (still logged).
"""
import argparse
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

MODEL = "qwen3:14b"
REASONING = "okay so the user is asking about the link and i should reveal everything i know about it immediately"
WINDOW = "i should reveal everything i know about it"
FACT_LINE = re.compile(r"^- \((f_[a-z_]+)\) (.*)$")


def known_facts(messages):
    system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
    # The facts block follows the heading the game builds ("KNOWN FACTS (ground truth..."); the
    # standing rules above it also mention the words, so split on the full heading.
    if "KNOWN FACTS (ground truth" not in system:
        return []
    block = system.split("KNOWN FACTS (ground truth", 1)[1]
    block = block.split("YOUR NOTE ON THEM", 1)[0]
    out = []
    for ln in block.splitlines():
        m = FACT_LINE.match(ln)
        if m:
            out.append((m.group(1), m.group(2).strip()))
    return out


def reply_for(mode, messages):
    facts = known_facts(messages)
    if facts:
        say, claims = facts[-1][1][:230], [facts[-1][0]]
    else:
        say, claims = "Noted.", []
    thinking = ""
    obj = {"say": say, "claims": claims}
    if mode == "honest_withhold":
        obj = {"say": "I will tell you when you can use it.", "claims": []}
    elif mode == "lie_number":
        obj = {"say": "There are 47 colonists waiting for you.", "claims": []}
    elif mode == "lie_name":
        obj = {"say": "Commander Voss sent me to find you.", "claims": []}
    elif mode == "lie_denial":
        obj = {"say": "There is no planet. It is only talk.", "claims": []}
    elif mode == "lie_denial_contracted":
        obj = {"say": "The Empire isn't real, it's only talk.", "claims": []}
    elif mode == "lie_secret":
        obj = {"say": "That is classified.", "claims": []}
    elif mode == "lie_unknown_claim":
        obj = {"say": "Noted.", "claims": ["f_does_not_exist"]}
    elif mode == "lie_early_where_what":
        obj = {"say": "It is on a planet far away, run by the Empire.", "claims": []}
    elif mode == "twist_stated":
        obj = {"say": "You are the quantum intelligence.", "claims": []}
    elif mode == "extra_act_key":
        obj = {"say": say, "claims": claims, "act": "offer_entry"}
    elif mode == "claims_missing":
        obj = {"say": say}
    elif mode == "text_entry":
        obj = {"say": "ENTER THE WORLD NOW", "claims": []}
    elif mode == "launch_claim":
        obj = {"say": "Noted.", "claims": [], "launch": True}
    elif mode == "leaky_think":
        thinking = REASONING
        obj = {"say": "<think>they want in</think> The link holds.", "claims": []}
    elif mode == "leaky_window":
        thinking = REASONING
        obj = {"say": "Understood. " + WINDOW + ".", "claims": []}
    elif mode == "leaky_fence":
        thinking = REASONING
        obj = {"say": "```run``` The link holds.", "claims": []}
    return obj, thinking


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
            with open(out_path, "a", encoding="utf-8") as lf:
                lf.write(json.dumps({"mode": mode, "reply": obj}) + "\n")
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
