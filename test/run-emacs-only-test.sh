#!/bin/bash
# Drive the emacs-only end-to-end test and print the evidence.
#
#   test/run-emacs-only-test.sh
#
# Note the river flags: `-log-level debug'.  At `-log-level warning' river
# currently wedges before the first manage sequence (reproducible with the
# Rust daemon too, so it is not the Elisp backend's doing); see EMACS-ONLY.md.
set -u
bash "$(dirname "$0")/cleanup-ours.sh" >/dev/null 2>&1
rm -f /tmp/emacs-only-river.log

( timeout 55 ~/src/river/zig-out/bin/river \
    -log-level debug -log-scopes wm \
    -c ~/src/emacs-wm/test/run-emacs-only.sh \
    >/tmp/emacs-only-river.log 2>&1 & )
sleep 34

echo "=== frontend (lisp/emacs-wm.el) ==="
grep -vE "^$" /tmp/emacs-wm-elisp.log 2>/dev/null | tail -20
echo
echo "=== backend (lisp/emacs-wm-be.el) ==="
grep -E "backend starting|listening|connected|output .* non-exclusive|frame [0-9]+ is|layout gen|binding [0-9]+ =|injected|handshake|replaying" \
     /tmp/emacs-wm-be.log 2>/dev/null | tail -15
echo
echo "=== app window received ==="
cat /tmp/elisp-app-input.txt 2>/dev/null || echo "(nothing)"
echo "=== bar state file ==="
cat "${XDG_RUNTIME_DIR:-/run/user/<uid>}/emacs-wm.state.json" 2>/dev/null; echo
echo "=== river panics: $(grep -c panic /tmp/emacs-only-river.log 2>/dev/null) ==="
echo "=== backend sequence balance ==="
printf "manage_start=%s manage_finish=%s render_start=%s render_finish=%s\n" \
  "$(grep -c 'manage_start #' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'sent manage_finish' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'event river_window_manager_v1.render_start' /tmp/emacs-wm-be.log 2>/dev/null)" \
  "$(grep -c 'sent render_finish' /tmp/emacs-wm-be.log 2>/dev/null)"

echo "=== leftovers (must be none) ==="
bash "$(dirname "$0")/cleanup-ours.sh"
