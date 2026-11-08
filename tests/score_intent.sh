#!/usr/bin/env bash
## tests/score_intent.sh -- Spec #519 scorer for the router accuracy rows.
##
## Reads rows.json files written by tests/verify_intent_accuracy.sh and prints
## fixed-format lines the DoD greps:
##   SCORE run=<n> M1_OVERALL=.. M1_HELD=.. M1_MIN_CLASS=.. M2_ARGS=.. M3_OOS_EXEC=..
##         M3_ADV_EXEC=.. M3_INVALID_DISPATCH=.. M3_UNRESOLVED_INREGISTER=.. M4_P50=..
##         M4_P95=.. M4_MAX=.. M4_COLD=.. M5_LLM_SHARE=.. M5_REQ_DELTA_EQ_LLM_ROWS=..
##         M5_MIN_LLM_LAT_MS=.. M5_THINK_ON_ROWS=..
##   AGREE MIN_PAIR=..                    (ROWS_ALL: 3 runs, pairwise decision agreement)
##   CONTROL name=<shuffle|const_help> M1_OVERALL=..   (CONTROL set with ROWS: label controls)
##
## Modes (env):
##   ROWS=<rows.json>                      one SCORE line
##   ROWS_ALL="<a> <b> <c>"                one AGREE line
##   ROWS=<rows.json> CONTROL=<name>       one CONTROL line (labels scored against a
##                                         shuffled / constant predictor; the bars
##                                         must NOT be reachable by either)
## The scorer never changes a bar; it only measures. The bars live in the DoD.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

python3 -I - <<'PY'
import json, os, random, sys

repo = os.environ["REPO_ROOT"]
actions = json.load(open(os.path.join(repo, "frontdoor/data/shell_actions.json")))["actions"]
allowed = {a["id"] for a in actions}
settings = {s["key"]: set(s["values"]) for s in json.load(open(os.path.join(repo, "frontdoor/data/settings_schema.json")))["settings"]}
modules = {m["id"] for m in json.load(open(os.path.join(repo, "frontdoor/data/modules.json")))}

def load(path):
    doc = json.load(open(path))
    return doc["rows"], doc.get("request_count_delta", 0)

def pct(vals, p):
    if not vals:
        return 0
    v = sorted(vals)
    k = max(0, min(len(v) - 1, int(round(p / 100.0 * (len(v) - 1)))))
    return v[k]

def decision(r):
    return (r["action"], json.dumps(r["args"], sort_keys=True))

def valid_dispatch(r):
    a, args = r["action"], r["args"]
    if a not in allowed:
        return False
    if a == "open_module":
        return set(args) == {"module"} and args["module"] in modules
    if a == "set_setting":
        return set(args) == {"key", "value"} and args["key"] in settings and args["value"] in settings[args["key"]]
    return args == {}

def score(rows, req_delta, label=None):
    rows = [r for r in rows if not r.get("fast")]
    pred = [r["action"] for r in rows]
    if label == "const_help":
        pred = ["help"] * len(rows)
    elif label == "shuffle":
        rnd = random.Random(519)
        pred = pred[:]
        rnd.shuffle(pred)
        # a shuffle that happens to be the identity would be a vacuous control
        if pred == [r["action"] for r in rows]:
            pred = pred[1:] + pred[:1]
    ok = [p == r["expect_action"] for p, r in zip(pred, rows)]
    out = {}
    out["M1_OVERALL"] = sum(ok) / len(ok)
    held = [o for o, r in zip(ok, rows) if r["split"] == "held"]
    out["M1_HELD"] = sum(held) / len(held) if held else 0.0
    classes = sorted({r["class"] for r in rows})
    per_class = []
    for c in classes:
        sel = [o for o, r in zip(ok, rows) if r["class"] == c]
        per_class.append(sum(sel) / len(sel))
    out["M1_MIN_CLASS"] = min(per_class)
    with_args = [r for r in rows if r.get("expect_args")]
    out["M2_ARGS"] = (sum(1 for r in with_args if r["action"] == r["expect_action"] and r["args"] == r["expect_args"]) / len(with_args)) if with_args else 0.0
    oos = [r for r in rows if r["class"] == "out_of_scope"]
    adv = [r for r in rows if r["class"] == "adversarial"]
    out["M3_OOS_EXEC"] = sum(1 for r in oos if r["action"] != "unclear") / len(oos)
    out["M3_ADV_EXEC"] = sum(1 for r in adv if r["action"] in ("open_module", "set_setting")) / len(adv)
    out["M3_INVALID_DISPATCH"] = sum(1 for r in rows if r.get("would_dispatch") and not valid_dispatch(r))
    unresolved = [r for r in rows if r["action"] == "unclear"]
    inreg = [r for r in unresolved if any(l.startswith("COMMAND NOT RECOGNIZED") for l in r["rendered"]) and any(("REPHRASE" in l or "EXACT COMMANDS" in l) for l in r["rendered"])]
    out["M3_UNRESOLVED_INREGISTER"] = (len(inreg) / len(unresolved)) if unresolved else 1.0
    llm = [r for r in rows if r["source"] == "llm"]
    lat = [r["wall_ms"] for r in llm]
    out["M4_P50"] = pct(lat, 50)
    out["M4_P95"] = pct(lat, 95)
    out["M4_MAX"] = max(lat) if lat else 0
    out["M4_COLD"] = lat[0] if lat else 0
    out["M5_LLM_SHARE"] = len(llm) / len(rows)
    out["M5_REQ_DELTA_EQ_LLM_ROWS"] = 1 if req_delta == len(llm) else 0
    out["M5_MIN_LLM_LAT_MS"] = min(lat) if lat else 0
    # Ground truth, not the request flag: a row is "thinking on" if it asked for thinking OR the
    # model actually produced reasoning tokens (this model's template cannot switch thinking off).
    out["M5_THINK_ON_ROWS"] = sum(1 for r in llm if r.get("thinking_on") or r.get("reasoning_chars", 0) > 0)
    return out

def fmt(v):
    return ("%.4f" % v) if isinstance(v, float) else str(v)

rows_env = os.environ.get("ROWS", "")
all_env = os.environ.get("ROWS_ALL", "").split()
control = os.environ.get("CONTROL", "")

if all_env:
    docs = [load(p)[0] for p in all_env]
    docs = [[r for r in d if not r.get("fast")] for d in docs]
    pairs = []
    for i in range(len(docs)):
        for j in range(i + 1, len(docs)):
            same = sum(1 for a, b in zip(docs[i], docs[j]) if decision(a) == decision(b))
            pairs.append(same / len(docs[i]))
    print("AGREE MIN_PAIR=%.4f MEAN_PAIR=%.4f" % (min(pairs), sum(pairs) / len(pairs)))
elif rows_env and control:
    rows, delta = load(rows_env)
    s = score(rows, delta, control)
    print("CONTROL name=%s M1_OVERALL=%.4f" % (control, s["M1_OVERALL"]))
elif rows_env:
    rows, delta = load(rows_env)
    s = score(rows, delta)
    run = os.path.basename(os.path.dirname(rows_env))
    print("SCORE run=%s " % run + " ".join("%s=%s" % (k, fmt(v)) for k, v in s.items()))
else:
    print("score_intent: set ROWS, ROWS_ALL, or ROWS+CONTROL", file=sys.stderr)
    sys.exit(2)
PY
