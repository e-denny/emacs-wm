#!/bin/bash
# Does the login-session entry point actually bring the WM up?
#
#   test/run-session-test.sh
#
# This is the only suite that exercises contrib/emacs-wm-session: a nested
# river runs its --wm branch exactly the way the greeter path does (river -c
# 'sh -c ...' -> emacs-wm-session --wm -> emacs -l emacs-wm-session), with
# XDG_CONFIG_HOME and XDG_STATE_HOME pointed at a temporary directory so the
# real personal configuration and logs are untouched.
#
# What it asserts: the frontend loaded the user configuration (and the shipped
# defaults it overrides), the WM became river's window manager, the
# configuration's own extra binding reached river, and the autostart list from
# the temporary configuration suppressed the bar.
set -u
. "$(dirname "$0")/lib.sh"
cd "$REPO"
require_river

bash test/cleanup-ours.sh >/dev/null 2>&1
clear_sockets

TMP=$(mktemp -d /tmp/emacs-wm-session-test.XXXXXX)
mkdir -p "$TMP/config/emacs-wm" "$TMP/state"
cat >"$TMP/config/emacs-wm/config.el" <<'EOF'
;;; user configuration for the session test -*- lexical-binding: t; -*-
;; The real bar is not started here: a nested test session must not spawn the
;; user's live bar.
(setq emacs-wm-startup-commands nil)
;; Distinctive values, so "was this file loaded?" is answerable from the logs.
(setq emacs-wm-border-width 3)
(setq emacs-wm-key-bindings
      (append emacs-wm-key-bindings '(("s-<f9>" . "toggle-float"))))
EOF

( XDG_CONFIG_HOME="$TMP/config" XDG_STATE_HOME="$TMP/state" \
  WLR_WL_OUTPUTS=1 EMACS_WM_RIVER_LOG_LEVEL=warning \
  timeout 40 "$RIVER" -c "$REPO/contrib/emacs-wm-session --wm" \
      >"$TMP/river.log" 2>&1 & )
sleep 18

STATE_DIR=$TMP/state/emacs-wm
SESSION_LOG=$STATE_DIR/session.log
FRONTEND_LOG=$STATE_DIR/frontend.log
BACKEND_LOG=$STATE_DIR/backend.log

echo "=== files the session created ==="
ls -l "$STATE_DIR" 2>/dev/null | tail -4
echo
echo "=== session script ==="
grep -E "=== wm|exec |warning" "$SESSION_LOG" 2>/dev/null | head -5
echo
echo "=== configuration loading (frontend) ==="
grep -E "loading configuration|connected, |no user configuration" \
     "$FRONTEND_LOG" 2>/dev/null | head -5
echo
echo "=== bindings the configuration brought up (frontend) ==="
grep -E 'registered "(s-f|s-2|s-<f9>|C-v|M-v|C-s)"' "$FRONTEND_LOG" 2>/dev/null | head -6
echo
echo "=== the keysyms river was asked to intercept (backend) ==="
grep -E "binding [0-9]+ = (s-f|s-2|s-<f9>|C-v|M-v) " "$BACKEND_LOG" 2>/dev/null | head -5
echo
echo "=== the WM applied a layout (backend) ==="
grep -E "layout gen [0-9]+:" "$BACKEND_LOG" 2>/dev/null | tail -2
echo
echo "=== autostart (must be empty: the test config sets it to nil) ==="
grep -c "autostart" "$FRONTEND_LOG" 2>/dev/null || echo 0

echo "=== verdict ==="
FAILED=0
verdict () {
    name=$1; shift
    if "$@" >/dev/null 2>&1; then
        echo "OK       $name"
    else
        echo "MISMATCH $name"
        FAILED=1
    fi
}
verdict "session script ran and logged" grep -qF "=== wm start" "$SESSION_LOG"
verdict "frontend loaded the user configuration" \
        grep -qF "loading configuration $TMP/config/emacs-wm/config.el" "$FRONTEND_LOG"
verdict "WM connected to river as the window manager" \
        grep -qF "connected to " "$FRONTEND_LOG"
verdict "shipped binding became an intercepted key" \
        grep -qE 'binding [0-9]+ = s-f \(keysym 0x66 mods 0x40\)' "$BACKEND_LOG"
verdict "the configuration's extra binding became an intercepted key" \
        grep -qE 'registered "s-<f9>" as bid [0-9]+' "$FRONTEND_LOG"
verdict "the firefox :simulate keys (Emacs keys) are intercepted too" \
        grep -qE 'registered "C-v" as bid [0-9]+' "$FRONTEND_LOG"
verdict "layout applied" grep -qE "layout gen [0-9]+:" "$BACKEND_LOG"
verdict "autostart suppressed by the configuration" \
        bash -c '! grep -q autostart "$1"' _ "$FRONTEND_LOG"
echo "=== river panics: $(grep -c panic "$TMP/river.log" 2>/dev/null) ==="
echo "=== leftovers ==="
bash test/cleanup-ours.sh
if [ -n "${EMACS_WM_KEEP_TMP:-}" ]; then
    echo "kept $TMP"
else
    rm -rf "$TMP"
fi
exit "$FAILED"
