#!/bin/bash
# A real pointer drag moves a window: virtual pointer -> river pointer binding
# -> op start -> op_delta -> window moves -> op release -> rect reported back.
set -u
cd "$(dirname "$0")/.." || exit 1
if [ ! -x test/tools/target/debug/pointerinject ]; then
    ( cd test/tools && cargo build --offline ) || exit 1
fi
bash test/cleanup-ours.sh >/dev/null 2>&1
rm -f /tmp/pointerinject.log /tmp/visual-dragged.ppm /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
rm -f /run/user/<uid>/emacs-wm.*.sock

( WLR_WL_OUTPUTS=1 EMACS_WM_TEST_EL=~/src/emacs-wm/test/elisp-pointer.el \
  EMACS_WM_BE_LOG_LEVEL=debug \
  timeout 60 ~/src/river/zig-out/bin/river -log-level debug -log-scopes wm \
     -c ~/src/emacs-wm/test/run-emacs-only.sh \
     >/tmp/pointer-river.log 2>&1 & )
sleep 31

echo "=== frontend ==="
grep -E "pointer test|pointer drag|op-done|8s \(|14s \(|20s \(|24s \(|screenshot after" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -14
echo
echo "=== backend: binding, op, deltas ==="
grep -E "pointer binding|op (move|resize) started|op_delta \(:dx [1-9]|op (move|resize) finished" \
     /tmp/emacs-wm-be.log 2>/dev/null | head -20
echo "=== pointerinject output ==="
cat /tmp/pointerinject.log 2>/dev/null | head -5
echo "=== river panics: $(grep -c panic /tmp/pointer-river.log 2>/dev/null) ==="
echo "=== leftovers ==="
bash test/cleanup-ours.sh
