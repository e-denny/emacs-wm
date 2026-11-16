#!/bin/bash
# Stress the synced-virtual-keyboard path: repeated "app-inject" -> "desktop N"
# cycles, which is the sequence that used to produce river's silent
# "attempt to use null value" panic. Run as the child of river:
#
#   river -log-level warning -c test/stress-inject.sh
#
# Evidence: /tmp/stress-session.log (want/daemon), /tmp/stress-keys.log (what
# actually reached Emacs), /tmp/stress-app-input.txt (what reached the app).
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

set -u

WD=$REPO
FIFO=/tmp/stress.fifo
LOG=/tmp/stress-session.log
KEYS=/tmp/stress-keys.log
CYCLES=${STRESS_CYCLES:-40}

exec >"$LOG" 2>&1
echo "=== stress start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY cycles=$CYCLES"

rm -f "$FIFO" "$KEYS" /tmp/stress-app-input.txt
mkfifo "$FIFO"
exec 9<>"$FIFO"

RUST_LOG=info "$WD/legacy/wm-poc/target/debug/wm-poc" <"$FIFO" &
WMPID=$!
echo "wm-poc pid $WMPID"
sleep 1

emacs -Q --eval '(progn
  (defun stress-log (tag fmt &rest args)
    (append-to-file (apply (function format) (concat tag ": " fmt "\n") args)
                    nil "/tmp/stress-keys.log"))
  (set-frame-name "wm-frame:1")
  (modify-frame-parameters nil (quote ((undecorated . t) (internal-border-width . 0))))
  (make-frame (quote ((name . "wm-frame:2") (undecorated . t))))
  (advice-add (quote self-insert-command) :before
              (lambda (&rest _) (stress-log "insert" "%S" last-command-event)))
  (select-frame-set-input-focus (car (frame-list)))
  (stress-log "info" "emacs ready frames=%S" (mapcar (lambda (f) (frame-parameter f (quote name))) (frame-list))))' &
EMACSPID=$!
echo "emacs pid $EMACSPID"
sleep 5

echo "=== $CYCLES cycles of app-inject/desktop ==="
i=1
while [ "$i" -le "$CYCLES" ]; do
	echo "app-inject j" >&9
	echo "desktop 2" >&9
	echo "desktop 1" >&9
	# alternate the injected keysym so the app path is exercised both ways
	echo "app-inject J" >&9
	sleep 0.4
	i=$((i + 1))
done
echo "=== cycles done $(date -Is) ==="
echo status >&9
sleep 3
echo quit >&9
sleep 1
kill "$EMACSPID" 2>/dev/null
wait "$WMPID" 2>/dev/null
echo "=== stress end $(date -Is) ==="
