#!/bin/bash
# Real key presses, end to end, through river's binding path.
#
#   test/run-emacs-only-keys-test.sh
#
# keyinject creates a virtual keyboard like any client (with a keymap fd), so
# river attaches it as a normal input device: keys go through river's own
# binding matching and arrive as river_xkb_binding_v1.pressed, not as WM
# injection which bypasses it.
set -u
. "$(dirname "$0")/lib.sh"
cd "$REPO"
require_river
bash "$(dirname "$0")/cleanup-ours.sh" >/dev/null 2>&1
# keyinject is the test-only input helper; build it if needed.
need_tool keyinject
rm -f /tmp/keys-app-input.txt /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
clear_sockets

( WLR_WL_OUTPUTS=1 EMACS_WM_TEST_EL=elisp-keys.el \
  EMACS_WM_BE_LOG_LEVEL=debug \
  timeout 60 "$RIVER" -log-level debug -log-scopes wm \
     -c "$SESSION_SCRIPT" \
     >/tmp/keys-river.log 2>&1 & )
sleep 34

echo "=== frontend: key events and their effects ==="
grep -E "keyinject|key bid|toggle-float|output .* -> desktop|before keys|after Super|after typing|typing into|spawning" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -24
echo
echo "=== backend: river delivered the presses ==="
grep -E "river_xkb_binding_v1.pressed|river_xkb_binding_v1.released|key.*bid" \
     /tmp/emacs-wm-be.log 2>/dev/null | head -10
echo
echo "=== what the app received (real typing) ==="
od -c /tmp/keys-app-input.txt 2>/dev/null | head -3 || echo "(nothing)"
echo "=== river panics: $(grep -c panic /tmp/keys-river.log 2>/dev/null) ==="
echo "=== leftovers ==="
bash "$(dirname "$0")/cleanup-ours.sh"
