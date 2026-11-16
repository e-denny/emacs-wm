#!/bin/bash
# Repeat a nested river harness at a given log level and count panics.
#
#   test/diag-repeat.sh <log-level> <child-script> <runs> [seconds]
#
# For each run it reports: whether river printed a panic, whether injection
# reached the app, and whether the WM serviced its manage sequences.
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

set -u

LEV=${1:-warning}
CHILD=${2:-$REPO/test/run.sh}
RUNS=${3:-3}
SECS=${4:-30}

RIVERLOG=/tmp/rep-river-$LEV.log
EVIDENCE=/tmp/wm-keys.log

pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'elisp-app' 2>/dev/null
pkill -f 'elisp-test.el' 2>/dev/null
pkill -f 'wm-frame:2' 2>/dev/null
sleep 1

for n in $(seq 1 "$RUNS"); do
  rm -f "$RIVERLOG" "$EVIDENCE" /tmp/elisp-app-input.txt /tmp/emacs-wm-test.log \
        /tmp/elisp-session.log /tmp/emacs-wm-elisp.log

  ( timeout $((SECS + 40)) "$RIVER" \
      -log-level "$LEV" -log-scopes wm -c "$CHILD" >"$RIVERLOG" 2>&1 ) &
  sleep "$SECS"

  panics=$(grep -c 'panic' "$RIVERLOG" 2>/dev/null || true)
  appgot=$(cat /tmp/elisp-app-input.txt 2>/dev/null | tr -d '\n' || true)
  keys=$(grep -c 'insert:' "$EVIDENCE" 2>/dev/null || true)
  status=$(grep -cE 'manage_start|manage sequence' /tmp/elisp-session.log /tmp/emacs-wm-test.log 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo "?")

  echo "run $n [$LEV] panics=$panics manage_events=$status inserted_keys=$keys app_got='$appgot'"
  if [ "${panics:-0}" -gt 0 ] 2>/dev/null; then
    grep -n 'panic' "$RIVERLOG" | head -3
    cp "$RIVERLOG" "/tmp/rep-panic-$LEV-$n.log"
  fi

  pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
  pkill -f 'wm-poc/target' 2>/dev/null
  pkill -f 'elisp-app' 2>/dev/null
  pkill -f 'elisp-test.el' 2>/dev/null
  pkill -f 'wm-frame:2' 2>/dev/null
  sleep 1
done
