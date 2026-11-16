#!/bin/bash
# Nested session for socket tests: wm-poc + one app window whose input we can
# inspect, no Emacs, no bar.
set -u
LOG=/tmp/fake-session.log
exec >"$LOG" 2>&1
echo "=== fake session start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
rm -f /tmp/wm-cmd.fifo /tmp/fake-app-input.txt
mkfifo /tmp/wm-cmd.fifo
exec 9<>/tmp/wm-cmd.fifo

~/src/emacs-wm/legacy/wm-poc/target/debug/wm-poc </tmp/wm-cmd.fifo &
sleep 1

kitty -1 --title "fake-app" -o remember_window_size=no \
      sh -c 'while IFS= read -r l; do printf "%s\n" "$l" >> /tmp/fake-app-input.txt; done'
sleep infinity
