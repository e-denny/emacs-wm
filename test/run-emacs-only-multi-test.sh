#!/bin/bash
# Multi-output exercise of the *Emacs-only* implementation: a nested river with
# two outputs, no Rust daemon.  The frontend spawns the backend Emacs itself.
#
#   test/run-emacs-only-multi-test.sh
#
set -u
bash "$(dirname "$0")/cleanup-ours.sh" >/dev/null 2>&1
pkill -f 'multi-app' 2>/dev/null
rm -f /run/user/<uid>/emacs-wm.*.sock
rm -f /tmp/emacs-only-multi-session.log /tmp/multi-app-input.txt \
      /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log

( WLR_WL_OUTPUTS=2 \
  EMACS_WM_TEST_EL=~/src/emacs-wm/test/elisp-multi.el \
  EMACS_WM_BE_LOG_LEVEL=debug \
  timeout 75 ~/src/river/zig-out/bin/river \
     -log-level debug -log-scopes wm \
     -c ~/src/emacs-wm/test/run-emacs-only.sh \
     >/tmp/emacs-only-multi-river.log 2>&1 & )
sleep 52

echo "=== outputs the backend saw ==="
grep -E "non-exclusive area|frame [0-9]+ is window" /tmp/emacs-wm-be.log 2>/dev/null | head -12
echo
echo "=== per-output desktop decisions (frontend) ==="
grep -E "outputs=|switching output|moving wid|adopted|created desktop|pointer on output" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -24
echo
echo "=== layouts (backend) ==="
grep -E "layout gen [0-9]+: " /tmp/emacs-wm-be.log 2>/dev/null | tail -8
echo
echo "=== app window received ==="
cat /tmp/multi-app-input.txt 2>/dev/null || echo "(nothing)"
echo "=== river panics: $(grep -c panic /tmp/emacs-only-multi-river.log 2>/dev/null) ==="
echo "=== sequence balance ==="
printf "manage_start=%s manage_finish=%s render_start=%s render_finish=%s\n" \
  "$(grep -c 'manage_start #' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'sent manage_finish' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'event river_window_manager_v1.render_start' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'sent render_finish' /tmp/emacs-wm-be.log 2>/dev/null)"

echo "=== leftovers (must be none) ==="
bash "$(dirname "$0")/cleanup-ours.sh"
pkill -f 'multi-app' 2>/dev/null
