#!/usr/bin/env bash
## tests/ollama_ready.sh -- Spec #519 (amended 2026-11-08) ollama-mode precondition + post-run witness.
## Exit 0 and print "READY pipeline_starts=N model=... ctx=..." only when ALL hold:
##   - Ollama answers (`ollama ps` exits 0) and $MODEL is pulled
##   - $MODEL is either resident at $CTX with PROCESSOR "100% GPU", or not resident and >= $NEED_MIB VRAM is free
##   - no chat model other than $MODEL is resident (embedding models are ignored)
##   - neither sieve nor sieve-geo has a pipeline in flight (last "=== Pipeline" line is "started")
##   - mean GPU utilisation over 6 samples <= $MAX_UTIL
## Otherwise exit 2 and print "UNMET <reason>". Reads only; never loads a model.
set -u
MODEL="${OLLAMA_MODEL:-qwen3:14b}"; CTX="${OLLAMA_CTX:-16384}"
NEED_MIB="${NEED_MIB:-12000}"; MAX_UTIL="${MAX_UTIL:-40}"
unmet() { echo "UNMET $*"; exit 2; }
## Witness mode: SINCE_EPOCH and UNTIL_EPOCH set -> print PIPELINE_STARTS_SINCE=<n> (sieve + sieve-geo "=== Pipeline started"
## lines inside that window) and exit 0 without evaluating readiness. Used after a run to prove no pipeline overlapped it.
if [ -n "${SINCE_EPOCH:-}" ] && [ -n "${UNTIL_EPOCH:-}" ]; then
  w=0
  for u in sieve sieve-geo; do
    n="$(journalctl -u "$u" --since "@$SINCE_EPOCH" --until "@$UNTIL_EPOCH" --no-pager -o cat 2>/dev/null | /usr/bin/grep -c '=== Pipeline started' || true)"
    w=$((w + ${n:-0}))
  done
  echo "PIPELINE_STARTS_SINCE=$w"; exit 0
fi
PS="$(ollama ps 2>/dev/null)" || unmet "ollama unreachable"
ollama list 2>/dev/null | awk -v m="$MODEL" '$1==m{f=1} END{exit !f}' || unmet "$MODEL not pulled"
row="$(printf '%s\n' "$PS" | awk -v m="$MODEL" '$1==m')"
others="$(printf '%s\n' "$PS" | awk -v m="$MODEL" 'NR>1 && $1!=m && $1 !~ /embed/{print $1}')"
[ -z "$others" ] || unmet "another chat model is resident: $others"
if [ -n "$row" ]; then
  printf '%s' "$row" | /usr/bin/grep -q '100% GPU' || unmet "$MODEL resident but not 100% GPU: $row"
  have="$(printf '%s\n' "$row" | awk '{for(i=1;i<=NF;i++) if($i=="GPU"){print $(i+1); exit}}')"
  [ "$have" = "$CTX" ] || unmet "$MODEL resident at context $have, need $CTX"
else
  free="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)"
  [ "${free:-0}" -ge "$NEED_MIB" ] || unmet "$MODEL not resident and only ${free:-0} MiB VRAM free (need $NEED_MIB)"
fi
starts=0
for u in sieve sieve-geo; do
  out="$(journalctl -u "$u" --since '-3 hours' --no-pager -o cat 2>/dev/null)"
  last="$(printf '%s\n' "$out" | awk '/=== Pipeline started/{s="started"} /=== Pipeline (complete|failed)/{s="done"} END{print s}')"
  [ "$last" = "started" ] && unmet "$u pipeline is running"
  n="$(printf '%s\n' "$out" | /usr/bin/grep -c '=== Pipeline started' || true)"
  starts=$((starts + ${n:-0}))
done
tot=0
for _ in 1 2 3 4 5 6; do u="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits | head -1)"; tot=$((tot + ${u:-100})); sleep 0.5; done
[ $((tot / 6)) -le "$MAX_UTIL" ] || unmet "GPU busy: mean utilisation $((tot / 6))% > $MAX_UTIL%"
echo "READY pipeline_starts=$starts model=$MODEL ctx=$CTX"
