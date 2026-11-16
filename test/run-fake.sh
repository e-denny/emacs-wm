#!/bin/bash
# Nested session for socket tests: wm-poc + one app window whose input we can
# inspect, no Emacs, no bar.
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

set -u
LOG=/tmp/fake-session.log
exec >"$LOG" 2>&1
echo "=== fake session start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
rm -f /tmp/wm-cmd.fifo /tmp/fake-app-input.txt
mkfifo /tmp/wm-cmd.fifo
exec 9<>/tmp/wm-cmd.fifo

$REPO/legacy/wm-poc/target/debug/wm-poc </tmp/wm-cmd.fifo &
sleep 1

kitty -1 --title "fake-app" -o remember_window_size=no \
      sh -c 'while IFS= read -r l; do printf "%s\n" "$l" >> /tmp/fake-app-input.txt; done'
sleep infinity
