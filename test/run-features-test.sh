#!/bin/bash
# Drive test/elisp-features.el: simulation keys, submaps, dynamic desktops,
# daemon restart/resync and the bar state file.
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

set -u
pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'feat-app' 2>/dev/null
pkill -f 'elisp-features.el' 2>/dev/null
sleep 1
rm -f /tmp/features-session.log /tmp/feat-app-input.txt /tmp/emacs-wm-elisp.log \
      "$XDG_RUNTIME_DIR/emacs-wm.state.json"

(timeout 90 "$RIVER" -log-level debug -log-scopes wm \
    -c $REPO/test/run-features.sh >/tmp/features-river.log 2>&1 &)
sleep 52

echo "=== elisp decisions ==="
grep -E "desktops|switching|simulating|submap|resync|re-attached|brought|buffer" /tmp/emacs-wm-elisp.log | head -25
echo
echo "=== daemon: injection, chords, restart ==="
grep -E "injected|eat|ate an unbound|epoch|restart|handshake" /tmp/features-session.log | head -20
echo
echo "=== app received (od -c: 0x01 proves Ctrl was held) ==="
od -c /tmp/feat-app-input.txt 2>/dev/null | head -3 || echo "(nothing)"
echo "=== state file for the bar ==="
cat "${XDG_RUNTIME_DIR:-/tmp}/emacs-wm.state.json" 2>/dev/null | head -c 800; echo
echo "=== river panics: $(grep -c panic /tmp/features-river.log 2>/dev/null) ==="

pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'feat-app' 2>/dev/null
pkill -f 'elisp-features.el' 2>/dev/null
