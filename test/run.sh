#!/bin/bash
# Test harness for wm-poc. Run as:
#   river -c $REPO/test/run.sh
#
# Emacs roles:
#   wm-frame:1  -> desktop 1 (container frame)
#   wm-frame:2  -> desktop 2 (container frame)
#   app-window  -> an ordinary "app" window, tiled inside the current desktop
#
# F9 inside Emacs dumps which frame is selected/focused, so the harness can
# observe focus changes caused by the WM. All injected keys are logged with the
# frame that received them.
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

set -u

WD=$REPO
FIFO=/tmp/wm-cmd.fifo
KEYS=/tmp/wm-keys.log
LOG=/tmp/emacs-wm-test.log

exec > "$LOG" 2>&1
echo "=== harness start $(date -Is) ==="
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY DISPLAY=${DISPLAY:-unset}"

rm -f "$FIFO" "$KEYS" /tmp/wm-report.log
mkfifo "$FIFO"
exec 9<>"$FIFO"

"$WD/legacy/wm-poc/target/debug/wm-poc" <"$FIFO" &
WMPID=$!
echo "wm-poc pid $WMPID"
sleep 1

emacs -Q \
  --eval '(progn
  (require (quote cl-lib))
  (defun wm-log (tag fmt &rest args)
    (append-to-file (apply (function format) (concat tag ": " fmt "\n") args)
                    nil "/tmp/wm-keys.log"))
  (defun wm-frame-names ()
    (mapcar (lambda (f) (or (frame-parameter f (quote name)) "?")) (frame-list)))
  (set-frame-name "wm-frame:1")
  (modify-frame-parameters nil (quote ((undecorated . t) (internal-border-width . 0))))
  (make-frame (quote ((name . "wm-frame:2") (undecorated . t))))
  (make-frame (quote ((name . "app-window") (undecorated . t))))
  (select-frame-set-input-focus (car (frame-list)))
  ;; F9: report focus state, written to /tmp/wm-report.log
  (defun wm-report ()
    (interactive)
    (let ((sel (selected-frame)))
      (append-to-file
       (format "report: frames=%S selected=%S focus-state=%S\n"
               (wm-frame-names)
               (frame-parameter sel (quote name))
               (frame-focus-state sel))
       nil "/tmp/wm-report.log")))
  (global-set-key (kbd "<f9>") (function wm-report))
  ;; every command, with the frame that received it
  (add-hook (quote pre-command-hook)
            (lambda ()
              (condition-case err
                  (wm-log "cmd" "%S on frame=%S"
                          this-command
                          (frame-parameter (selected-frame) (quote name)))
                (error (wm-log "cmd-error" "%S" err)))))
  (add-hook (quote post-self-insert-hook)
            (lambda ()
              (wm-log "insert" "%S on frame=%S"
                      last-command-event
                      (frame-parameter (selected-frame) (quote name)))))
  (run-with-timer 0 0.5
                  (lambda ()
                    (wm-log "tick" "%s" (format-time-string "%H:%M:%S.%N"))))
  (wm-log "info" "ready frames=%S" (wm-frame-names)))' &
EMACSPID=$!
echo "emacs pid $EMACSPID"

sleep 4
echo "=== phase 1: initial state ==="
echo status >&9
sleep 1

echo "=== phase 2: desktop 2, then ask Emacs what is selected ==="
echo "desktop 2" >&9
sleep 2
echo "inject F9" >&9
sleep 2
echo status >&9
sleep 1

echo "=== phase 3: desktop 1, ask Emacs again ==="
echo "desktop 1" >&9
sleep 2
echo "inject F9" >&9
sleep 2
echo status >&9
sleep 1

echo "=== phase 4: focus the app window and inject j in one sequence ==="
echo "app-inject j" >&9
sleep 2
echo status >&9
sleep 1

echo "=== phase 5: same, but shifted (J) ==="
echo "app-inject J" >&9
sleep 2
echo status >&9
sleep 1

echo "=== phase 6: quit ==="
echo quit >&9
sleep 1
kill "$EMACSPID" 2>/dev/null
wait "$WMPID" 2>/dev/null
echo "=== harness done $(date -Is) ==="
