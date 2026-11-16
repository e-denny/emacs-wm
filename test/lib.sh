#!/bin/bash
# Shared paths for the test drivers.  Source it, do not run it:
#
#     . "$(dirname "$0")/lib.sh"
#
# Everything is derived from where this file lives, so a checkout works from any
# directory and from any user's home.  Overrides:
#
#   EMACS_WM_REPO    repository root (default: the parent of test/)
#   EMACS_WM_RIVER   river binary (default: <repo>/../river/zig-out/bin/river,
#                    then `river' in $PATH)
#   XDG_RUNTIME_DIR  where the Wayland socket, the WM socket and the state file
#                    live (default: /tmp)
#
# What it deliberately does *not* do: change shell options, start anything, or
# touch the filesystem.  Sourcing must be inert.

REPO=${EMACS_WM_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
LISP=$REPO/lisp
TOOLS=$REPO/test/tools/target/debug
RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp}
SESSION_SCRIPT=$REPO/test/run-emacs-only.sh

# The WM needs river 0.6 with the patches in river-patches/.  The default is a
# river build next to this repository (the layout the project is developed in);
# anything else has to be pointed at explicitly.
find_river () {
    if [ -n "${EMACS_WM_RIVER:-}" ]; then
        printf '%s\n' "$EMACS_WM_RIVER"
    elif [ -x "$REPO/../river/zig-out/bin/river" ]; then
        printf '%s\n' "$REPO/../river/zig-out/bin/river"
    else
        command -v river 2>/dev/null || true
    fi
}
RIVER=$(find_river)

require_river () {
    if [ -z "$RIVER" ] || [ ! -x "$RIVER" ]; then
        echo "no river binary found: build one from river-patches/ and either" >&2
        echo "put it next to this checkout (../river/zig-out/bin/river) or set" >&2
        echo "EMACS_WM_RIVER=/path/to/river" >&2
        exit 1
    fi
}

# need_tool NAME: build the Rust helpers on first use.
need_tool () {
    if [ ! -x "$TOOLS/$1" ]; then
        ( cd "$REPO/test/tools" && cargo build --offline ) || exit 1
    fi
}

# Remove backend sockets of *other* displays.  A socket belongs to the display
# named in its file name, so the display this shell runs on (your live session)
# is never touched: a run started from inside a session cannot break it.  The
# frontend also probes and replaces a stale socket by itself; this is belt and
# braces for the nesting where a killed display name gets reused.
clear_sockets () {
    local file display
    for file in "$RUNTIME_DIR"/emacs-wm.*.sock; do
        [ -e "$file" ] || continue
        display=${file##*/emacs-wm.}
        display=${display%.sock}
        if [ -n "${WAYLAND_DISPLAY:-}" ] && [ "$display" = "$WAYLAND_DISPLAY" ]; then
            continue
        fi
        rm -f "$file"
    done
}

# The state file the bar reads, for drivers that print it.
state_file () {
    printf '%s\n' "$RUNTIME_DIR/emacs-wm.state.json"
}
