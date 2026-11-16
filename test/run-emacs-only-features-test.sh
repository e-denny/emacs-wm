#!/bin/bash
# Drive test/elisp-features.el against the Emacs-only backend: simulation keys,
# chords/submaps, dynamic desktops, backend restart/resync and the bar state
# file.
#
#   test/run-emacs-only-features-test.sh
#
set -u
. "$(dirname "$0")/lib.sh"
cd "$REPO"
require_river
bash "$(dirname "$0")/cleanup-ours.sh" >/dev/null 2>&1
pkill -f 'feat-app' 2>/dev/null
clear_sockets
rm -f /tmp/emacs-only-features-session.log /tmp/feat-app-input.txt \
      /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log \
      "$(state_file)"

( timeout 85 "$RIVER" -log-level debug -log-scopes wm \
    -c "$REPO/test/run-emacs-only-features.sh" \
    >/tmp/emacs-only-features-river.log 2>&1 & )
sleep 50

echo "=== frontend decisions ==="
grep -E "desktops|switching|simulating|submap|resync|re-attached|state file now|buffers after|focused wid after|TIMER ERROR" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -22
echo
echo "=== backend: injection, chords, epochs ==="
grep -E "injected|ate an unbound|backend starting|handshake|replaying state|virtual keyboard" \
     /tmp/emacs-wm-be.log 2>/dev/null | head -20
echo
echo "=== restart evidence (session script) ==="
grep -E "===" /tmp/emacs-only-features-session.log 2>/dev/null | head -8
echo
echo "=== app received (od -c: ^A proves Ctrl was held) ==="
od -c /tmp/feat-app-input.txt 2>/dev/null | head -3 || echo "(nothing)"
echo "=== state file for the bar ==="
cat "$(state_file)" 2>/dev/null | head -c 400; echo
echo "=== river panics: $(grep -c panic /tmp/emacs-only-features-river.log 2>/dev/null) ==="
echo "=== sequence balance ==="
printf "manage_start=%s manage_finish=%s render_start=%s render_finish=%s\n" \
  "$(grep -c 'manage_start #' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'sent manage_finish' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'event river_window_manager_v1.render_start' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'sent render_finish' /tmp/emacs-wm-be.log 2>/dev/null)"

echo "=== leftovers (must be none) ==="
bash "$(dirname "$0")/cleanup-ours.sh"
pkill -f 'feat-app' 2>/dev/null
