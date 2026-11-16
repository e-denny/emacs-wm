#!/bin/bash
# Drive the fake-client test: nested river + wm-poc + kitty, then attach the fake
# Emacs client from outside and check that layouts and injection take effect.
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'fake-app' 2>/dev/null
pkill -f 'fake-client.py' 2>/dev/null
sleep 1
rm -f /tmp/fake-session.log /tmp/fake.log /tmp/fake-app-input.txt

(timeout 40 "$RIVER" -log-level debug -log-scopes wm \
    -c $REPO/test/run-fake.sh >/tmp/fake-river.log 2>&1 &)
sleep 10

DISP=$(grep -o 'WAYLAND_DISPLAY=wayland-[0-9]*' /tmp/fake-session.log | head -1 | cut -d= -f2)
SOCK="$XDG_RUNTIME_DIR/emacs-wm.$DISP.sock"
echo "display=$DISP socket=$SOCK"
ls -l "$SOCK" 2>/dev/null || echo "!! socket missing"

timeout 20 $REPO/test/fake-client.py "$SOCK" &
FAKE=$!
sleep 12
kill $FAKE 2>/dev/null

echo "=== fake client log ==="
cat /tmp/fake.log
echo "=== app window received ==="
cat /tmp/fake-app-input.txt 2>/dev/null || echo "(nothing)"
echo "=== daemon layout/renders ==="
grep -E "layout gen|frame [0-9]+ is window|client handshake|registered client binding" /tmp/fake-session.log | head -10

pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'fake-app' 2>/dev/null
pkill -f 'fake-client.py' 2>/dev/null
