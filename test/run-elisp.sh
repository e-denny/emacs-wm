#!/bin/bash
# Nested river session running wm-poc + Emacs as the WM's brain.
#   river -c .../run-elisp.sh
set -u
LOG=/tmp/elisp-session.log
exec >"$LOG" 2>&1
echo "=== elisp session start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

rm -f /tmp/wm-cmd.fifo /tmp/elisp-app-input.txt /tmp/emacs-wm-elisp.log
mkfifo /tmp/wm-cmd.fifo
exec 9<>/tmp/wm-cmd.fifo

RUST_LOG=debug ~/src/emacs-wm/legacy/wm-poc/target/debug/wm-poc </tmp/wm-cmd.fifo &
sleep 1

TEST_EL=${EMACS_WM_TEST_EL:-~/src/emacs-wm/test/elisp-test.el}
emacs -Q -L ~/src/emacs-wm/lisp -l "$TEST_EL" &
sleep infinity
