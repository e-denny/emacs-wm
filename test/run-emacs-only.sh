#!/bin/bash
# Nested river session with the *Emacs-only* implementation.
#
# There is no Rust daemon here.  This script starts one Emacs.  That Emacs
# spawns the backend (a minimal `-Q --fg-daemon' Emacs, lisp/emacs-wm-be.el)
# which is the river window manager, and then behaves as the WM's brain.
#
#   river -c test/run-emacs-only.sh
#
# Paths are derived from this file's location; the drivers pass the scenario to
# load in EMACS_WM_TEST_EL (a bare name is resolved against this directory), so
# a checkout works from anywhere.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
LOG=${EMACS_WM_SESSION_LOG:-/tmp/emacs-only-session.log}
exec >"$LOG" 2>&1
echo "=== emacs-only session start $(date -Is) WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

# Keep /tmp clean so a run is self-contained.
rm -f /tmp/elisp-app-input.txt /tmp/emacs-wm-elisp.log /tmp/emacs-wm-be.log

# The backend inherits this; `debug' is needed today because river misbehaves
# at `-log-level warning' (see EMACS-ONLY.md, open issue 1).
export EMACS_WM_BE_LOG_LEVEL="${EMACS_WM_BE_LOG_LEVEL:-debug}"

# Scenario to load: an absolute path, or a name relative to test/.
TEST_EL=${EMACS_WM_TEST_EL:-elisp-test.el}
case $TEST_EL in
    /*) ;;
    *) TEST_EL=$HERE/$TEST_EL ;;
esac

# The scenarios spawn the native helpers (keyinject, screenshot, ...) from here.
export EMACS_WM_TEST_TOOLS=${EMACS_WM_TEST_TOOLS:-$HERE/tools/target/debug}
export EMACS_WM_REPO=${EMACS_WM_REPO:-$REPO}

emacs -Q -L "$REPO/lisp" -l "$TEST_EL" &
EMACSPID=$!

# This script is river's child.  It must take Emacs with it: an orphaned
# frontend keeps running, and a later river reusing the same WAYLAND_DISPLAY
# lets it attach to the new session, where two WMs fight and spin at 100% CPU.
trap 'kill "$EMACSPID" 2>/dev/null' EXIT TERM INT HUP

COMPOSITOR_SOCK="${XDG_RUNTIME_DIR:-/tmp}/$WAYLAND_DISPLAY"
COMPOSITOR_INO=$(stat -c %i "$COMPOSITOR_SOCK" 2>/dev/null || echo none)
while kill -0 "$EMACSPID" 2>/dev/null; do
    sleep 2
    now=$(stat -c %i "$COMPOSITOR_SOCK" 2>/dev/null || echo none)
    [ "$now" = "$COMPOSITOR_INO" ] || break
done
kill "$EMACSPID" 2>/dev/null
wait "$EMACSPID" 2>/dev/null
