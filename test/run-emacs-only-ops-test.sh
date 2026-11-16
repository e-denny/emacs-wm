#!/bin/bash
# Interactive move/resize plumbing: real key press -> op start -> river deltas
# -> op end -> rect reported back.  Pointer movement itself is not exercisable
# here (no virtual pointer client); see test/be-tests.el for the geometry.
set -u
bash "$(dirname "$0")/cleanup-ours.sh" >/dev/null 2>&1
# keyinject is the test-only input helper; build it if needed.
if [ ! -x "$(dirname "$0")/tools/target/debug/keyinject" ]; then
    ( cd "$(dirname "$0")/keyinject" && cargo build --offline ) || exit 1
fi
rm -f /tmp/ops-app-input.txt /tmp/keyinject.log /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
rm -f /run/user/<uid>/emacs-wm.*.sock

( WLR_WL_OUTPUTS=1 EMACS_WM_TEST_EL=~/src/emacs-wm/test/elisp-ops.el \
  EMACS_WM_BE_LOG_LEVEL=debug \
  timeout 60 ~/src/river/zig-out/bin/river -log-level debug -log-scopes wm \
     -c ~/src/emacs-wm/test/run-emacs-only.sh \
     >/tmp/ops-river.log 2>&1 & )
sleep 28

echo "=== frontend ==="
grep -E "op test|pressing Super|ending the op|op-done|8s \(|13s \(|17s \(|21s \(|injecting" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -16
echo
echo "=== backend: op lifecycle ==="
grep -E "op move started|river op_start_pointer|river op_end|op_delta|op move finished" \
     /tmp/emacs-wm-be.log 2>/dev/null | head -16
echo "=== app received after the op ==="
od -c /tmp/ops-app-input.txt 2>/dev/null | head -3 || echo "(nothing)"
echo "=== river panics: $(grep -c panic /tmp/ops-river.log 2>/dev/null) ==="
echo "=== leftovers ==="
bash "$(dirname "$0")/cleanup-ours.sh"
