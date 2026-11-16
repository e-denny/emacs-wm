#!/bin/bash
# Kill every emacs-wm test process and *nothing else*; or report leftovers.
#
#   test/cleanup-ours.sh          kill them (default)
#   test/cleanup-ours.sh check    report only, exit 1 if any are left
#   test/check-leftovers.sh       the same as `check`
#
# The user's own Emacs never loads ~/src/emacs-wm/lisp, so matching
# that path is what separates ours from theirs.  Never match a bare "emacs".
#
# The drivers call this before and after every run.  Session scripts are
# matched by their exact file names so a driver's own command line can never
# match one of these patterns.
set -u

found_ours() {
    # Match on the *executable* (comm) as well as the arguments, so a shell or
    # grep whose command line merely mentions these paths is never mistaken for
    # one of ours -- that false positive once made this check useless.
    ps -eo pid,pcpu,comm,args --sort=-pcpu \
        | awk '($3 ~ /^emacs/ || $3 == "river") \
               && ($0 ~ /emacs-wm\/lisp/ || $0 ~ /zig-out\/bin\/river/) \
               {print $1, $2, substr($0, index($0,$3))}' \
        | head -20
}

report_ours() {
    local lines
    lines=$(found_ours)
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

kill_ours() {
    pkill -f '~/src/emacs-wm/lisp' 2>/dev/null
    pkill -f 'test/run-emacs-only\.sh' 2>/dev/null
    pkill -f 'test/run-emacs-only-features\.sh' 2>/dev/null
    pkill -f 'test/run-elisp\.sh' 2>/dev/null
    pkill -x river 2>/dev/null
    sleep 1
    pkill -9 -f '~/src/emacs-wm/lisp' 2>/dev/null
    pkill -9 -f 'test/run-emacs-only\.sh' 2>/dev/null
    pkill -9 -f 'test/run-emacs-only-features\.sh' 2>/dev/null
    pkill -9 -f 'test/run-elisp\.sh' 2>/dev/null
    pkill -9 -x river 2>/dev/null
    sleep 1
    rm -f /run/user/<uid>/emacs-wm.*.sock 2>/dev/null
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
