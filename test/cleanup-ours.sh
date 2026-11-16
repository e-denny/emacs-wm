#!/bin/bash
# Kill every emacs-wm test process belonging to *this checkout*, or report them.
#
#   test/cleanup-ours.sh          kill them (default)
#   test/cleanup-ours.sh check    report only, exit 1 if any are left
#   test/check-leftovers.sh       the same as `check`
#
# "Ours" is defined by paths, never by process name alone:
#
#   - an Emacs whose arguments mention this checkout's lisp directory (that is
#     what a frontend or backend loads; your own Emacs does not), or
#   - a river whose arguments mention this checkout's test directory (that is
#     the `-c` session script of a nested test session).
#
# Never a bare `emacs`, never a bare `river`: a live session of this same
# window manager, from another checkout, must survive a test run.  The match is
# a literal substring match (awk `index' via -v) so a path with regex
# metacharacters in it cannot widen it, and the *executable* name is checked
# too, so a shell or grep whose command line merely mentions these paths is not
# mistaken for a WM process.  That false positive once made this check useless.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

collect_ours () {
    ps -eo pid,pcpu,comm,args --sort=-pcpu \
        | awk -v lisp="$REPO/lisp/" -v tests="$REPO/test/" '
            ($3 ~ /^emacs/ || $3 == "river") \
            && (index($0, lisp) > 0 || index($0, tests) > 0) \
            {print $1, $2, substr($0, index($0,$3))}' \
        | head -20
}

report_ours () {
    local lines
    lines=$(collect_ours)
    if [ -z "$lines" ]; then
        echo "  (none)"
        return 1
    fi
    while read -r pid pcpu args; do
        [ -z "${pid:-}" ] && continue
        printf '  pid %-7s %5s%%  %s\n' "$pid" "$pcpu" "$args"
    done <<< "$lines"
    return 0
}

pids_ours () {
    ps -eo pid,comm,args \
        | awk -v lisp="$REPO/lisp/" -v tests="$REPO/test/" '
            ($2 ~ /^emacs/ || $2 == "river") \
            && (index($0, lisp) > 0 || index($0, tests) > 0) \
            {print $1}'
}

kill_ours () {
    local pids
    pids=$(pids_ours)
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null
        sleep 1
        pids=$(pids_ours)
        # shellcheck disable=SC2086
        [ -n "$pids" ] && kill -9 $pids 2>/dev/null
        sleep 1
    fi
    # No socket removal here: the drivers clear the sockets of the displays
    # they nest on (test/lib.sh), and a stale socket is replaced by the
    # frontend's own liveness probe.  Blasting every emacs-wm socket would
    # break a live session running from another checkout.
}

case "${1:-kill}" in
    check)
        echo "--- emacs-wm leftovers ---"
        if report_ours; then
            echo "--- LEFTOVERS PRESENT ---"
            exit 1
        fi
        exit 0
        ;;
    *)
        report_ours >/dev/null || true
        kill_ours
        echo "--- after cleanup ---"
        if report_ours; then
            echo "--- STILL PRESENT ---"
            exit 1
        fi
        exit 0
        ;;
esac
