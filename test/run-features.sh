#!/bin/bash
# Nested session for test/elisp-features.el: unlike run-elisp.sh it RESTARTS the
# daemon half way through, so reconnect/resync is exercised.
set -u
WD=~/src/emacs-wm
LOG=/tmp/features-session.log
exec >"$LOG" 2>&1
echo "=== features session start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

rm -f /tmp/feat.fifo /tmp/feat-app-input.txt /tmp/emacs-wm-elisp.log
mkfifo /tmp/feat.fifo
exec 9<>/tmp/feat.fifo

RUST_LOG=info "$WD/legacy/wm-poc/target/debug/wm-poc" </tmp/feat.fifo &
WMPID=$!
echo "wm-poc pid $WMPID (epoch 1)"
sleep 1

emacs -Q -L "$WD/lisp" -l "$WD/test/elisp-features.el" &
EMACSPID=$!
sleep 26

echo "=== killing the daemon (pid $WMPID) to force a resync $(date -Is)"
kill "$WMPID" 2>/dev/null
wait "$WMPID" 2>/dev/null
sleep 3
RUST_LOG=info "$WD/legacy/wm-poc/target/debug/wm-poc" </tmp/feat.fifo &
WMPID=$!
echo "wm-poc restarted pid $WMPID (epoch 2) $(date -Is)"

sleep 20
kill "$EMACSPID" 2>/dev/null
kill "$WMPID" 2>/dev/null
echo "=== features session end $(date -Is)"
