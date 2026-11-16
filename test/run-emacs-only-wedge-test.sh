#!/bin/bash
# Does the frontend notice a *wedged* (SIGSTOPped) backend, restart it, and
# resync?  This is the ping watchdog's test.
set -u
. "$(dirname "$0")/lib.sh"
cd "$REPO"
require_river
bash "$(dirname "$0")/cleanup-ours.sh" >/dev/null 2>&1
rm -f /tmp/wedge-app-input.txt /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
clear_sockets

( WLR_WL_OUTPUTS=1 EMACS_WM_TEST_EL=elisp-wedge.el \
  EMACS_WM_BE_LOG_LEVEL=info \
  timeout 60 "$RIVER" -log-level debug -log-scopes wm \
     -c "$SESSION_SCRIPT" \
     >/tmp/wedge-river.log 2>&1 & )
sleep 38

echo "=== frontend: watchdog decisions ==="
grep -E "WEDGED|restarting backend|wedged .* times|stopping the backend|--- wedge|10s \(|20s \(|30s \(|after recovery" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -20
echo
echo "=== backend epochs (a restart is a new epoch) ==="
grep -E "backend starting|handshake|replaying state" /tmp/emacs-wm-be.log 2>/dev/null | head -8
echo "=== app received after recovery ==="
od -c /tmp/wedge-app-input.txt 2>/dev/null | head -3 || echo "(nothing)"
echo "=== river panics: $(grep -c panic /tmp/wedge-river.log 2>/dev/null) ==="
echo "=== leftovers ==="
bash "$(dirname "$0")/cleanup-ours.sh"
