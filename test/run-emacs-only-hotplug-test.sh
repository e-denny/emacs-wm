#!/bin/bash
# Output removal, as far as it can be driven inside a nested session: the
# frontend side of `output-removed'.  See test/elisp-hotplug.el for what
# remains untestable here and why.
set -u
bash "$(dirname "$0")/cleanup-ours.sh" >/dev/null 2>&1
rm -f /tmp/hotplug-app-input.txt /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
rm -f /run/user/<uid>/emacs-wm.*.sock

( WLR_WL_OUTPUTS=2 EMACS_WM_TEST_EL=~/src/emacs-wm/test/elisp-hotplug.el \
  EMACS_WM_BE_LOG_LEVEL=debug \
  timeout 50 ~/src/river/zig-out/bin/river -log-level debug -log-scopes wm \
     -c ~/src/emacs-wm/test/run-emacs-only.sh \
     >/tmp/hotplug-river.log 2>&1 & )
sleep 28

echo "=== frontend: output bookkeeping ==="
grep -E "hotplug|removing output|after removal|focused wid after|5s \(|9s \(|19s \(|TIMER ERROR" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -20
echo
echo "=== did the layout recover? (backend) ==="
grep -E "layout gen|output .* non-exclusive|frame [0-9]+ is window" /tmp/emacs-wm-be.log 2>/dev/null | tail -8
echo "=== app received on the surviving output ==="
od -c /tmp/hotplug-app-input.txt 2>/dev/null | head -3 || echo "(nothing)"
echo "=== river panics: $(grep -c panic /tmp/hotplug-river.log 2>/dev/null) ==="
echo "=== leftovers ==="
bash "$(dirname "$0")/cleanup-ours.sh"
