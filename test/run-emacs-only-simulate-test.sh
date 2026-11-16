#!/bin/bash
# :simulate translation, and the pass-through that makes Emacs keys usable as
# simulation keys.
#
#   test/run-emacs-only-simulate-test.sh
#
# Two terminal windows, one whose title matches a `:simulate' rule for C-t and
# one that does not.  C-t is pressed as a *real* key (keyinject), so river
# intercepts it as a binding:
#
#   mapped window  C-t -> C-a m Return   (the rule translated it)
#   plain window   C-g -> C-g            (no rule: the key reached the app)
set -u
. "$(dirname "$0")/lib.sh"
cd "$REPO"
require_river
need_tool keyinject

bash test/cleanup-ours.sh >/dev/null 2>&1
rm -f /tmp/sim-mapped.txt /tmp/sim-plain.txt /tmp/keyinject.log \
      /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log
clear_sockets

( WLR_WL_OUTPUTS=1 EMACS_WM_TEST_EL=elisp-simulate.el \
  EMACS_WM_BE_LOG_LEVEL=debug \
  timeout 40 "$RIVER" -log-level debug -log-scopes wm \
     -c "$SESSION_SCRIPT" \
     >/tmp/simulate-river.log 2>&1 & )
sleep 24

echo "=== frontend: which rule applied ==="
grep -E "simulate|passing the key through|focusing|pressing C-" \
     /tmp/emacs-wm-elisp.log 2>/dev/null | head -10
echo
echo "=== what each app received (od -c) ==="
echo "-- mapped window (C-t translated to C-a m Return):"
od -c /tmp/sim-mapped.txt 2>/dev/null || echo "(nothing)"
echo "-- plain window (C-g passed through unchanged, so ^G):"
od -c /tmp/sim-plain.txt 2>/dev/null || echo "(nothing)"

echo "=== verdict ==="
FAILED=0
verdict () {
    name=$1; shift
    if "$@" >/dev/null 2>&1; then echo "OK       $name"; else echo "MISMATCH $name"; FAILED=1; fi
}
verdict "the rule translated C-t in the mapped window" \
        grep -qF 'simulate ("C-a" "m" "Return") as' /tmp/emacs-wm-elisp.log
verdict "the mapped app received the translation (^A m)" \
        test -s /tmp/sim-mapped.txt
verdict "the unbound window got the key passed through" \
        grep -qF 'no "C-g" rule for this window' /tmp/emacs-wm-elisp.log
verdict "the plain app received C-g itself (^G, 0x07)" \
        bash -c 'od -An -tx1 "$1" | tr -d " \n" | grep -qx 070a' _ /tmp/sim-plain.txt
echo "=== river panics: $(grep -c panic /tmp/simulate-river.log 2>/dev/null) ==="
echo "=== leftovers ==="
bash test/cleanup-ours.sh
exit "$FAILED"
