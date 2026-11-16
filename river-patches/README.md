# River patches this window manager needs

`emacs-wm` is a `river_window_manager_v1` client, so it needs a river that is
new enough (0.6) and that can inject keys from a virtual keyboard handed over
without a keymap fd — that is the one thing Elisp cannot do, and stock river
drops such a keyboard's keys.

These are five patches against river `85b0088` (0.6.0-dev, shallow clone of
`main`). They apply cleanly, in this order, to a pristine checkout:

```
cd path/to/river
git checkout 85b0088
for p in fix-stale-environ fix-silent-panic fix-vkb-active-keyboard \
         fix-vkb-keymap-fallback fix-log-callback-panic; do
    git apply /path/to/emacs-wm/river-patches/$p.patch
done
zig build -Dllvm          # Zig 0.17.1, wlroots 0.20
```

| patch | why |
|---|---|
| `fix-stale-environ.patch` | the init child inherited a stale environment block, so `-c` children could miss `WAYLAND_DISPLAY` and friends |
| `fix-silent-panic.patch` | a panic path that aborted without a message, which made the first wedges indistinguishable |
| `fix-vkb-active-keyboard.patch` | keys from a virtual keyboard without a keymap fd were dropped instead of routed to the seat's keyboard |
| `fix-vkb-keymap-fallback.patch` | a synced virtual keyboard with `has_keymap = false` needs the seat's keymap; without it wlroots drops keys before river sees them |
| `fix-log-callback-panic.patch` | `std.log` from a wlroots callback panics in Zig 0.17.1's locked-stderr path (and `panicFn` then recurses into the same lock), so `-log-level warning` wedged the compositor |

They are all small and local to river's input/environment/logging code. None of
them has been filed upstream.
