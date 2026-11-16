#!/bin/bash
# Diagnose river's silent "attempt to use null value" panic on the injection path.
#
#   test/diag-panic.sh [log-level] [child-script] [seconds]
#
# Defaults: level=warning (the failing config), child=test/run-elisp.sh (the
# harness that reproduced it 8/8), 50s.
#
# river runs *under gdb* (ptrace_scope=1 forbids attaching to a non-child) with
# breakpoints on debug.defaultPanic, so the panic is caught at its origin
# instead of printing one line and hanging in the trace printer.
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

set -u

LEV=${1:-warning}
CHILD=${2:-$REPO/test/run-elisp.sh}
SECS=${3:-50}

GDBLOG=/tmp/diag-gdb-$LEV.log

pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'elisp-app' 2>/dev/null
pkill -f 'elisp-test.el' 2>/dev/null
sleep 1
rm -f "$GDBLOG" /tmp/elisp-session.log /tmp/emacs-wm-elisp.log \
      /tmp/elisp-app-input.txt /tmp/wm-keys.log

cat >/tmp/diag.gdb <<'EOF'
set pagination off
set confirm off
set width 0
break debug.defaultPanic
break std.debug.defaultPanic
run
printf "\n########## PANIC SITE ##########\n"
printf "--- thread backtrace ---\n"
bt 40
printf "--- message register (rdi = slice ptr) ---\n"
info registers rdi rsi
x/s $rdi
printf "--- all threads ---\n"
thread apply all bt 15
printf "########## END ##########\n"
kill
quit
EOF

echo "=== river level=$LEV child=$CHILD (gdb as parent) ==="
( timeout $((SECS + 70)) gdb -batch -x /tmp/diag.gdb --args \
    "$RIVER" -log-level "$LEV" -log-scopes wm \
    -c "$CHILD" >"$GDBLOG" 2>&1 ) &
GDBPID=$!

sleep "$SECS"

echo "=== gdb: panic site ==="
sed -n '/PANIC SITE/,/END ####/p' "$GDBLOG" | head -150
echo
echo "=== panic lines in river output: $(grep -c 'panic:' "$GDBLOG" 2>/dev/null) ==="
grep -n 'panic:' "$GDBLOG" 2>/dev/null | head -3
echo "=== last gdb/river lines ==="
tail -6 "$GDBLOG"
echo
echo "=== daemon: injection + focus ==="
grep -E "injected|focus|manage_start|render: wid" /tmp/elisp-session.log 2>/dev/null | tail -12
echo "=== app received ==="
cat /tmp/elisp-app-input.txt 2>/dev/null || echo "(nothing)"
echo "=== elisp log tail ==="
tail -6 /tmp/emacs-wm-elisp.log 2>/dev/null

kill $GDBPID 2>/dev/null
pkill -x river 2>/dev/null; sleep 1; pkill -9 -x river 2>/dev/null
pkill -f 'wm-poc/target' 2>/dev/null
pkill -f 'elisp-app' 2>/dev/null
pkill -f 'elisp-test.el' 2>/dev/null
