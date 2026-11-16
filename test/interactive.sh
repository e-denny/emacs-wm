#!/bin/bash
# Interactive wm-poc session. Intended to be run *nested* inside an existing
# Wayland session, so river's wayland backend forwards the real keyboard to it
# and the actual key bindings can be exercised:
#
#   ~/src/river/zig-out/bin/river -c ~/src/emacs-wm/test/interactive.sh
#
# A window appears on your current desktop: click it, then
#
#   Super+1 / Super+2        switch desktop (frames, not window configs)
#   Super+j                  focus the app window and type "j" into it
#   Super+q                  close the focused window
#   Super+Shift+q            quit wm-poc (river then sits there with no WM)
#
# If your host compositor grabs Super combos, every action also exists as
# Ctrl+Alt+<key> (Ctrl+Alt+Shift+q to quit).
#
# Live log: the kitty window runs `tail -f` on it, so you can see the WM react.
#
# Retired driver: needs legacy/wm-poc/ (not in this repository).  It also
# calls `pkill -x river', which would kill a live session -- run it only
# while you have no session you care about.
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
. "$HERE/lib.sh"

set -u

WD=$REPO
LOG=/tmp/wm-interactive.log

exec >"$LOG" 2>&1
echo "=== interactive wm-poc start $(date -Is) ==="
echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo "config: bar=$([ "${WM_POC_NO_BAR:-0}" = "0" ] && echo on || echo off)" \
     "float_apps=${WM_POC_FLOAT_APPS:-blueman}" \
     "popup_cmd=${WM_POC_POPUP_CMD:-blueman-manager}"

rm -f /tmp/wm-cmd.fifo /tmp/wm-app-received.log
mkfifo /tmp/wm-cmd.fifo
exec 9<>/tmp/wm-cmd.fifo

"$WD/legacy/wm-poc/target/debug/wm-poc" </tmp/wm-cmd.fifo &
echo "wm-poc pid $!"
sleep 1

emacs -Q --eval '(progn
  (defun wm-log (tag fmt &rest args)
    (append-to-file (apply (function format) (concat tag ": " fmt "\n") args)
                    nil "/tmp/wm-keys.log"))
  (set-frame-name "wm-frame:1")
  (modify-frame-parameters nil (quote ((undecorated . t) (internal-border-width . 0))))
  (make-frame (quote ((name . "wm-frame:2") (undecorated . t))))
  (select-frame-set-input-focus (car (frame-list)))
  (add-hook (quote post-self-insert-hook)
            (lambda ()
              (wm-log "insert" "%S on frame=%S" last-command-event
                      (frame-parameter (selected-frame) (quote name)))))
  (message "wm-poc: Super+1/2 desktop, Super+j focus app + type j, Super+q close, Super+Shift+q quit")
  (wm-log "info" "emacs ready"))' &
echo "emacs pid $!"

sleep 1

# Real bar, on by default (per-display instance; does not touch a bar running on
# the host session). Disable with WM_POC_NO_BAR=1.
#
# Noctalia's per-display socket/lock files ($XDG_RUNTIME_DIR/noctalia-$WAYLAND_DISPLAY.*)
# outlive the session that created them, and river reuses display names, so a
# leftover from an earlier nested session makes a new instance hand off to a
# dead one and exit silently. Start it, and if it dies immediately, clear the
# state for *this* display (never the host's) and try once more.
start_bar() {
	if ! command -v noctalia >/dev/null; then
		echo "WM_POC_BAR set but noctalia not found"
		return
	fi
	echo "starting noctalia inside this session (display $WAYLAND_DISPLAY)"
	noctalia &
	local pid=$!
	sleep 2
	if kill -0 "$pid" 2>/dev/null; then
		echo "noctalia running (pid $pid)"
		return
	fi
	echo "noctalia exited immediately; clearing stale state for $WAYLAND_DISPLAY"
	rm -f "$XDG_RUNTIME_DIR/noctalia-$WAYLAND_DISPLAY.lock" \
	      "$XDG_RUNTIME_DIR/noctalia-$WAYLAND_DISPLAY.sock"
	noctalia &
	sleep 2
	if kill -0 "$!" 2>/dev/null; then
		echo "noctalia running (pid $!) after cleanup"
	else
		echo "noctalia still failed, see the log above"
	fi
}

# Apps launched through D-Bus / systemd --user (bar widgets, desktop files,
# xdg-open) inherit the *user manager's* environment, not this session's. In a
# nested test that means they open on the host desktop; in a real session it
# means they open wherever the manager was configured at login. Say so instead
# of leaving it to be discovered as "my window went somewhere else".
manager_display=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^WAYLAND_DISPLAY=//p')
if [ -n "$manager_display" ] && [ "$manager_display" != "$WAYLAND_DISPLAY" ]; then
	echo "NOTE: systemd --user has WAYLAND_DISPLAY=$manager_display," \
	     "this session is $WAYLAND_DISPLAY."
	echo "NOTE: dbus/service-activated apps (bar widgets, xdg-open) will open" \
	     "outside this session. For a real session run:"
	echo "NOTE:   systemctl --user import-environment WAYLAND_DISPLAY DISPLAY"
fi

if [ "${WM_POC_NO_BAR:-0}" = "0" ]; then
	start_bar
else
	echo "bar disabled by WM_POC_NO_BAR"
fi

# The app window: a reader loop, so an injected key sequence is unmistakable.
# (An injected key lands in whatever the focused client is; with `tail` it would
# be invisible because tail ignores stdin.)
kitty -1 --title "wm-poc-log" -o remember_window_size=no \
      -o initial_window_width=100 -o initial_window_height=24 \
      sh -c '
        printf "\n  wm-poc demo window\n"
        printf "  Ctrl+Alt+j  -> this window is focused and a key SEQUENCE\n"
        printf "                 (j then Return) is typed into it, in the same\n"
        printf "                 manage sequence as the focus change.\n"
        printf "  Ctrl+Alt+1/2 -> switch desktop    Ctrl+Alt+q -> close app window\n\n"
        while :; do
          printf "wm-poc> "
          IFS= read -r line || break
          printf ">>> INJECTED LINE: %s\n" "$line"
          printf "%s\n" "$line" >> /tmp/wm-app-received.log
        done'
echo "kitty exited"

# Keep the session alive even if the terminal is closed.
sleep infinity
