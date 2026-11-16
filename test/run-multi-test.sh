#!/bin/bash
# Drive the multi-output test: a nested river with TWO outputs, the daemon, and
# Emacs as the WM's brain. Prints the per-output desktop evidence.
set -u
pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'multi-app' 2>/dev/null
pkill -f 'elisp-multi.el' 2>/dev/null
sleep 1
rm -f /tmp/elisp-session.log /tmp/multi-app-input.txt /tmp/emacs-wm-elisp.log

(WLR_WL_OUTPUTS=2 \
 EMACS_WM_TEST_EL=~/src/emacs-wm/test/elisp-multi.el \
 timeout 70 ~/src/river/zig-out/bin/river \
    -log-level debug -log-scopes wm \
    -c ~/src/emacs-wm/test/run-elisp.sh >/tmp/multi-river.log 2>&1 &)
sleep 40

echo "=== outputs the daemon saw ==="
grep -E "output [0-9]+ is|pointer on output" /tmp/elisp-session.log | head -10
echo
echo "=== per-output desktop decisions (elisp) ==="
grep -E "outputs=|switching output|moving wid|adopted|created desktop" /tmp/emacs-wm-elisp.log | head -20
echo
echo "=== frames shown/hidden per output (daemon render pass) ==="
grep -E "render: frame fid=.*oid=" /tmp/elisp-session.log | tail -12
echo
echo "=== app window received ==="
cat /tmp/multi-app-input.txt 2>/dev/null || echo "(nothing)"
echo "=== river panics: $(grep -c panic /tmp/multi-river.log 2>/dev/null) ==="

pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'multi-app' 2>/dev/null
pkill -f 'elisp-multi.el' 2>/dev/null
