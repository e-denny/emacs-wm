#!/bin/bash
# Nested session for test/elisp-features.el with the *Emacs-only* backend.
#
# Unlike test/run-emacs-only.sh this RESTARTS the backend half way through, so
# the frontend's supervision (spawn -> kill -> respawn -> hello with a new
# epoch -> replay -> reattach by identifier) is exercised for real.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
WD=$(cd "$HERE/.." && pwd)
LOG=/tmp/emacs-only-features-session.log
exec >"$LOG" 2>&1
echo "=== features session start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

rm -f /tmp/feat-app-input.txt /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
export EMACS_WM_BE_LOG_LEVEL="${EMACS_WM_BE_LOG_LEVEL:-debug}"

export EMACS_WM_TEST_TOOLS=${EMACS_WM_TEST_TOOLS:-$HERE/tools/target/debug}
export EMACS_WM_REPO=${EMACS_WM_REPO:-$WD}

emacs -Q -L "$WD/lisp" -l "$HERE/elisp-features.el" &
EMACSPID=$!
trap 'kill "$EMACSPID" 2>/dev/null' EXIT TERM INT HUP
sleep 26

echo "=== killing the backend to force a resync $(date -Is)"
# The frontend logs the pid it started ("backend pid N", again after every
# respawn), so kill exactly that process: a pattern like `pkill -f emacs-wm-be'
# would also hit another checkout's backend on the same machine.
BACKEND=$(grep -o 'backend pid [0-9]*' /tmp/emacs-wm-elisp.log 2>/dev/null \
          | tail -1 | awk '{print $3}')
if [ -n "${BACKEND:-}" ]; then
    ps -p "$BACKEND" -o pid=,args= 2>/dev/null | head -1
    kill -9 "$BACKEND" 2>/dev/null
else
    echo "no backend pid in the frontend log" >&2
fi
sleep 5
echo "=== the frontend should have respawned it $(date -Is)"
grep -o 'backend pid [0-9]*' /tmp/emacs-wm-elisp.log 2>/dev/null | tail -1

sleep 17
kill "$EMACSPID" 2>/dev/null
wait "$EMACSPID" 2>/dev/null
echo "=== features session end $(date -Is)"
