#!/usr/bin/env bash
## tests/verify_crash_recovery_n3.sh -- Spec #501 N=3 rule for flake #828.
##
## tests/verify_crash_recovery.sh intermittently fails ASSERT-A-NO-REPLY (the live LLM
## round trip does not answer in time -- flake #828, unrelated to this slice). This
## wrapper runs it THREE times, unconditionally (never short-circuits: an intermittent
## failure is only visible across runs), printing one line per run:
##     N3_RUN <k> exit=<ec> tags=<FAIL tags, comma separated, or "none">
## Exit 0 iff
##   * 3 of 3 runs exit 0, OR
##   * at least 1 of 3 exits 0 AND every failing run's ONLY failure tag is
##     ASSERT-A-NO-REPLY.
## Any other tag (ASSERT-B/C/D/E ...) in ANY run, or a failing run with no recognisable
## tag (a precondition error, a crash), fails the whole check: those are real regressions,
## not the flake.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/tests/verify_crash_recovery.sh"
[ -x "$SCRIPT" ] || { echo "verify_crash_recovery_n3: $SCRIPT is not executable" >&2; exit 2; }

passes=0
bad=0
for k in 1 2 3; do
    out="$("$SCRIPT" </dev/null 2>&1)"
    ec=$?
    tags="$(printf '%s\n' "$out" | grep -oE '^FAIL-ASSERT-[A-Z]-[A-Z0-9-]+' | sed 's/^FAIL-//' | sort -u | paste -sd, -)"
    echo "N3_RUN $k exit=$ec tags=${tags:-none}"
    if [ "$ec" -eq 0 ]; then
        passes=$((passes + 1))
    elif [ "$tags" != "ASSERT-A-NO-REPLY" ]; then
        bad=$((bad + 1))
    fi
done

if [ "$passes" -eq 3 ]; then
    echo "N3_VERDICT pass (3/3 exit 0)"
    exit 0
fi
if [ "$passes" -ge 1 ] && [ "$bad" -eq 0 ]; then
    echo "N3_VERDICT pass ($passes/3 exit 0; every failure was the #828 flake only)"
    exit 0
fi
echo "N3_VERDICT fail ($passes/3 exit 0; $bad run(s) failed with something other than ASSERT-A-NO-REPLY)"
exit 1
