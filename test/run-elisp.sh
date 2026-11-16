#!/bin/bash
# Nested river session running wm-poc + Emacs as the WM's brain.
#   river -c .../run-elisp.sh
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

set -u
LOG=/tmp/elisp-session.log
exec >"$LOG" 2>&1
echo "=== elisp session start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

rm -f /tmp/wm-cmd.fifo /tmp/elisp-app-input.txt /tmp/emacs-wm-elisp.log
mkfifo /tmp/wm-cmd.fifo
exec 9<>/tmp/wm-cmd.fifo

RUST_LOG=debug $REPO/legacy/wm-poc/target/debug/wm-poc </tmp/wm-cmd.fifo &
sleep 1

TEST_EL=${EMACS_WM_TEST_EL:-$REPO/test/elisp-test.el}
emacs -Q -L $REPO/lisp -l "$TEST_EL" &
sleep infinity
