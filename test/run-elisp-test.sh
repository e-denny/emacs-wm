#!/bin/bash
# Drive the elisp end-to-end test and print the evidence.
pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'elisp-app' 2>/dev/null
pkill -f 'elisp-test.el' 2>/dev/null
sleep 1
rm -f /tmp/elisp-session.log /tmp/elisp-app-input.txt /tmp/emacs-wm-elisp.log

(timeout 55 ~/src/river/zig-out/bin/river -log-level debug -log-scopes wm \
    -c ~/src/emacs-wm/test/run-elisp.sh >/tmp/elisp-river.log 2>&1 &)
sleep 34

echo "=== elisp side (/tmp/emacs-wm-elisp.log) ==="
grep -vE "^$" /tmp/emacs-wm-elisp.log | tail -30
echo
echo "=== daemon side ==="
grep -E "listening|client handshake|frame [0-9]+ is window|layout gen|injected|queued client binding" /tmp/elisp-session.log | tail -20
echo
echo "=== app window received ==="
cat /tmp/elisp-app-input.txt 2>/dev/null || echo "(nothing)"
echo "=== river panics: $(grep -c panic /tmp/elisp-river.log 2>/dev/null) ==="

pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'elisp-app' 2>/dev/null
pkill -f 'elisp-test.el' 2>/dev/null
