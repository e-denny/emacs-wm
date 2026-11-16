#!/bin/bash
# Nested session for test/elisp-features.el with the *Emacs-only* backend.
#
# Unlike test/run-emacs-only.sh this RESTARTS the backend half way through, so
# the frontend's supervision (spawn -> kill -> respawn -> hello with a new
# epoch -> replay -> reattach by identifier) is exercised for real.
set -u
WD=~/src/emacs-wm
LOG=/tmp/emacs-only-features-session.log
exec >"$LOG" 2>&1
echo "=== features session start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

rm -f /tmp/feat-app-input.txt /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
export EMACS_WM_BE_LOG_LEVEL="${EMACS_WM_BE_LOG_LEVEL:-debug}"

emacs -Q -L "$WD/lisp" -l "$WD/test/elisp-features.el" &
EMACSPID=$!
trap 'kill "$EMACSPID" 2>/dev/null' EXIT TERM INT HUP
sleep 26

echo "=== killing the backend to force a resync $(date -Is)"
pgrep -af 'emacs[-]wm-be' | head -2
pkill -f 'emacs[-]wm-be'
sleep 5
echo "=== the frontend should have respawned it $(date -Is)"
pgrep -af 'emacs[-]wm-be' | head -2

sleep 17
kill "$EMACSPID" 2>/dev/null
wait "$EMACSPID" 2>/dev/null
echo "=== features session end $(date -Is)"
