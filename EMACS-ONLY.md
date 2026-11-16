# emacs-wm, Emacs only

Status: **the Rust daemon is gone.  A second Emacs is the window manager.**
Layout parity with the Rust implementation is reached and measured (see
*Evidence*).  Borders, focus, injection, bindings, per-output desktops, the
bar state file and daemon-restart resync all work through the unchanged
frontend.  What is *not* re-verified yet is listed under *Not yet
re-verified*.

Run it:

```
river -c test/run-emacs-only.sh          # nested, interactive

# scripted suites, each prints its evidence and ends with the leftovers check
test/run-emacs-only-test.sh              # single output: layout, borders, inject
test/run-emacs-only-multi-test.sh        # two outputs, per-output desktops
test/run-emacs-only-keys-test.sh         # real key presses (builds keyinject)
test/run-emacs-only-hotplug-test.sh      # output removal (frontend side)
test/run-emacs-only-ops-test.sh          # move/resize op lifecycle
test/run-emacs-only-pointer-test.sh      # a real pointer drags a window
test/run-emacs-only-visual-test.sh       # border pixels, sampled from a capture
test/run-emacs-only-lock-test.sh         # ext-session-lock, lock and unlock
test/run-emacs-only-wedge-test.sh        # ping watchdog vs a SIGSTOPped backend
test/run-emacs-only-features-test.sh     # chords, simulate, restart/resync
test/run-session-test.sh                 # the login-session entry point
test/run-emacs-only-simulate-test.sh     # :simulate translation + pass-through
test/run-config-test.sh                  # 22 unit tests for the configuration
test/run-be-tests.sh                     # 27 unit tests, no compositor needed
test/check-leftovers.sh                  # after any session: must say (none)
```

## Shape

```
river (compositor: input routing, rendering, frame deadlines)
  ├─ backend Emacs    -Q --fg-daemon  (lisp/emacs-wm-be.el)
  │    the river_window_manager_v1 client; holds no policy
  │    speaks Wayland itself, through emacs-wm-wl.el
  │    └─ $XDG_RUNTIME_DIR/emacs-wm.$WAYLAND_DISPLAY.sock   (printed sexps)
  └─ frontend Emacs   (lisp/emacs-wm.el, unchanged semantics)
       your session: desktops, rules, focus, key policy, borders
```

| file | lines | role |
|---|---|---|
| `lisp/emacs-wm-wl.el` | 478 | a Wayland client in Elisp: protocol XML -> tables, wire format, object table, event dispatch |
| `lisp/emacs-wm-be.el` | 1739 | the backend: globals, manage/render sequences, layout application, injection, bindings, state file |
| `lisp/emacs-wm.el` | 1594 | the frontend: policy engine, spawning/supervising the backend, a sexp transport, keymap and command machinery |
| `lisp/emacs-wm-config.el` | 254 | the configuration: command names, Super bindings, window rules, appearance, autostart. Policy, not mechanism |
| `lisp/emacs-wm-session.el` | 30 | the login-session entry point: load the user config, enable, start autostart commands |
| `contrib/emacs-wm.desktop` | 10 | the greeter session entry (`Exec` runs the session script) |
| `contrib/emacs-wm-session` | 124 | session script: find river, be river's init child, start and supervise the frontend Emacs, keep logs |
| `lisp/protocol/` | – | vendored protocol XML (river's four, `virtual-keyboard-unstable-v1`, a minimal `wayland-core.xml`) |

Why two Emacsen rather than one: river stops **processing input** while a
manage sequence is open (`river/Seat.zig`: events are queued until
`server.wm.state == .idle`).  Whatever sits in the WM slot is therefore a hard
latency dependency for the whole session.  Keeping it a `-Q` Emacs that loads
only two files means your editing Emacs -- GC, debugger, `call-process` -- can
never stall river.

## Configuration and session entry

Everything a user might want to change lives in one Elisp file, and the code
holds no bindings or rules of its own:

- `lisp/emacs-wm-config.el` is the built-in default.  It is loaded when
  `emacs-wm` is loaded, so a bare `(require 'emacs-wm) (emacs-wm-enable)` still
  has working keys.
- `$XDG_CONFIG_HOME/emacs-wm/config.el` is the user's file.  The session entry
  point loads it *after* the built-in one, so `setq` there wins; a missing file
  is not an error.  Tests never load it, so a driver cannot pick up somebody's
  personal configuration.

What is in it: `emacs-wm-commands` (the list of commands a binding may name,
with descriptions), `emacs-wm-key-bindings` (the Super bindings), window rules
with `:simulate` samples for Firefox, borders, desktop count, pointer buttons,
supervision knobs, `emacs-wm-allow-when-locked`, and the autostart list.

`:simulate` maps an **Emacs binding** to the key an application expects, which
is the point of the feature -- muscle memory keeps working per application:

```
C-v  scroll-up          -> <next>    (page down)
M-v  scroll-down        -> <prior>   (page up)
C-s  isearch-forward    -> C-f       (find in page)
C-l  recenter           -> C-l       (location bar, same key, browser meaning)
C-w  kill-region        -> C-w       (close tab)
C-t  transpose-chars    -> C-t       (new tab)
C-a  move-beginning     -> C-a       (select all)
M-x  execute-extended   -> C-l       (address bar)
```

For that to be safe, an intercepted key must be *given back* when no rule
matches.  A press is handled in this order (`emacs-wm--handle-key`):

1. a `:simulate` rule for the focused window -> translate and inject;
2. a WM binding (`emacs-wm-key-bindings`) -> run its command;
3. a key some rule translates, but not for this window -> inject the key
   unchanged, so C-v is still `C-v` in a terminal;
4. anything else (`C-x`, `M-x`, ...) -> an Emacs event, as before.

Two properties are worth stating because they used to be two lists that could
disagree:

- **A bound key is an intercepted key.**  `emacs-wm-key-bindings` is the only
  list: registration with river is derived from it, plus
  `emacs-wm-intercepted-prefixes` for prefixes that have no WM binding of their
  own (`C-x`, `C-c`, `M-x`) and the keys only a `:simulate` rule uses.
- **A name that does not exist is an error.**  Binding `"s-t"` to
  `"no-such-command"` fails loudly when the bindings are applied instead of
  producing a key that arrives and does nothing.

`M-x emacs-wm-reload-config` loads the file again, rebuilds the keymap,
re-defines the global keys, and unbinds-then-re-registers with the backend, so
a key added or removed in the editor takes effect without restarting the
session.

Session entry: `contrib/emacs-wm.desktop` runs `contrib/emacs-wm-session`,
which execs river; river runs the same script back with `--wm`, and that child
starts the frontend Emacs with `lisp/emacs-wm-session.el` (load config, enable,
start autostart commands).  The script owns only environment and hygiene: it
sets `XDG_CURRENT_DESKTOP=emacs-wm`, puts the session, frontend and backend logs
in `$XDG_STATE_HOME/emacs-wm/`, and keeps the traps that stop an orphaned
frontend from re-attaching to a later compositor on the same
`WAYLAND_DISPLAY`.  It prefers the patched river next to this repository over
`river` from `$PATH`, because a stock 0.5 cannot inject from an fd-less virtual
keyboard and `:simulate` rules would silently do nothing.

A `:simulate` key is typed with the same injection path as `emacs-wm-inject`:
river's virtual keyboard, one manage sequence per key sequence.  Logout is the
`s-<f12>` binding, which sends river's `exit_session` request (legal outside a
manage sequence, since it is not window-management state).

## The Wayland client (`emacs-wm-wl.el`)

- Protocol XML is parsed at load with `libxml-parse-xml-region`; each interface
  gets request/event hashes with opcodes in declaration order.  No code
  generation step, no build.
- Framing is the real thing: 8-byte header (`object id`, `size<<16 | opcode`),
  4-byte-aligned little-endian arguments.  Supported argument types: `int`,
  `uint`, `fixed`, `string`, `object`, `new_id`, `array`.
- `fd` is deliberately unsupported and errors loudly.  Passing a file
  descriptor needs `SCM_RIGHTS` ancillary data, which a `make-network-process`
  stream cannot carry.  That is the one real limit of this design; see
  *Residual costs*.
- Server-allocated ids (river hands out `river_window_v1` ids like
  `4278190086`) and client-allocated ids (`new_id`) are both tracked; a
  `new_id` argument uses the id the caller registered rather than allocating a
  second one.

Verified: a registry round-trip against river returns all 40+ globals, and the
four river protocols parse to the expected opcodes (`manage_finish`=2,
`set_borders`=8, ...).

## The backend (`emacs-wm-be.el`)

A faithful, policy-free port of `wm-poc`'s protocol engine.  It answers from
cached state only, and **never** calls into the frontend synchronously.

Manage sequence (`manage_start`):

1. apply queued binding create/destroy + `enable`
2. apply queued `ensure_next_key_eaten` / cancel (chords)
3. apply queued close / fullscreen / exit-fullscreen
4. create and `sync_keyboard` the virtual keyboard once the seat exists
5. `--reconcile-layout`: per frame `propose_dimensions` + `inform_maximized` +
   `set_tiled`, per window borders (frontend policy), tiling edges, proposed
   size, then `set_default` on each layer-shell output
6. `--reconcile-focus`: `focus_window` on the layout's window or frame, else
   `clear_focus`; skipped while a layer surface has exclusive focus
7. flush injected keys through the synced virtual keyboard
8. `manage_finish`

Render sequence (`render_start`): positions (`river_node_v1.set_position`),
visibility (`show`/`hide`), clip boxes, and stacking (`place_bottom` for
frames, `place_top` for apps, focused window last).  Only deltas are sent, and
stacking only when the layout changed -- a render sequence happens every frame
and must stay request-free in steady state.

Both sequence handlers are wrapped in `unwind-protect` + `condition-case`:
whatever the engine does, river gets its `finish`.  A sequence left open is
the failure mode where river silently stops processing input.

Other properties carried over from the Rust daemon:

- layout snapshots are deduped (`frames`, `windows` and `focus` compared);
  `gen` is monotonic per `epoch`
- borders are part of the snapshot and applied before the fullscreen
  early-return, so a colour change while fullscreen is not lost
- every window and frame is replayed to a freshly connected frontend
  (`output` -> `frame` -> `window`/`title`/`app-id`/`identifier`/`size`)
- `epoch` is clock-seeded, so a restarted backend is visibly a new generation
  and the frontend resyncs, reattaching buffers by `identifier`
- the bar state file is written atomically after every applied layout

## Frontend changes (`emacs-wm.el`)

Semantics are untouched; only the plumbing moved:

- transport is one printed sexp per line (`prin1-to-string` / `read-from-string`)
  instead of JSON.  Both ends are Emacs, so booleans are plain `nil`/`t` and
  integers never round.  This is the rau model; NDJSON was the alternative we
  rejected because it needs escaping rules on both sides for no gain.
- `emacs-wm-start-backend` / `emacs-wm-connect`: the frontend spawns the
  backend when the socket is not *live* and waits for it.  Liveness is probed
  by connecting, never by `file-exists-p`: a backend killed with SIGKILL
  leaves a socket file behind, and connecting to that corpse is how a whole
  afternoon disappears (the fresh frontend then talks to a process whose
  Wayland connection is gone and sees `replaying state: 0 output(s)`).
  `emacs-wm--reconnect` respawns a dead backend, but only while the
  compositor socket exists.
- `(require 'subr-x)` -- the file had been getting `hash-table-keys`
  transitively from `json.el`, which is gone.

## River: five local patches

Applied to `85b0088` in this order; each one applies to pristine `HEAD` on top
of the ones before it (`test/` does not depend on them being upstream):

| patch | why |
|---|---|
| `fix-stale-environ.patch` | `river -c` segfaulted on the inherited environment |
| `fix-silent-panic.patch` | panics printed one line and hung instead of aborting |
| `fix-vkb-active-keyboard.patch` | dangling seat keyboard after a synced virtual keyboard died |
| `fix-vkb-keymap-fallback.patch` | a WM that cannot pass an fd could not inject at all |
| `fix-log-callback-panic.patch` | `std.log` from a wlroots callback panicked and wedged the session |

The last two are new in this rewrite.

**#4 keymap fallback.** Injection needs a keymap on the virtual keyboard, and
`zwp_virtual_keyboard_v1.keymap` carries an fd Elisp cannot send. River's
`NoKeymapVirtKeyboard` refused to attach a synced virtual keyboard until a
keymap arrived, so a fd-less client's keys were dropped. The patch attaches it
immediately on `sync_keyboard`, borrows the seat's keyboard-group keymap for
both the source `wlr_keyboard` and the synced state, and sets
`has_keymap = true`. Measured with `wev` and a daemon that never sends a keymap:

```
wl_keyboard keymap: format 1 (xkb v1), size 35758
wl_keyboard key: serial 9; key 44; state pressed
                 sym: j (106), utf8: 'j'
```

**#5 logger.** With the Elisp backend the session reproducibly wedged at
`-log-level warning` (one panic line, no manage sequence, input dead). A
backtrace taken at the panic shows:

```
TextInput.handleCommit      river/TextInput.zig:79   (log.err "inactive text input tried to commit")
log.scoped(.input).err
main.logFn                  river/main.zig:351
log.defaultLog              std/log.zig:106
debug.lockStderr            std/debug.zig:302
Io.Threaded.lockStderr      panics: "attempt to use null value"
```

i.e. logging *from* a wlroots callback panics inside Zig's locked-stderr path,
and `panicFn` then recurses into the same lock, so nothing aborts. `logFn` now
writes with `std.os.linux.write` (no locks, no `Io`), keeping the level and
scope prefix. Two consecutive runs at `-log-level warning` afterwards: injected
`j` delivered, 29/29 sequences, 0 panics.

## Feature parity

| feature | state |
|---|---|
| Emacs frames as desktops, hide (not unmap) | **ported, verified** (4 frames, `wm-frame:<oid>:<n>`) |
| per-output desktops | **ported, verified** (2 outputs, 4 desktops each, independent switching, move-to-desktop) |
| window rules (`:float`, per-rule borders) | **ported** (kitty floated: `float=t rect=(253 264 758 792)`) |
| borders (focused/unfocused, width, edges) | **ported** (border-only 2->3->2 visible in the layout) |
| focus (window, frame, clear) | **ported** (focus follows desktop switch) |
| fullscreen / minimise / close | **ported, verified** (close: river `window 'wev' unmapped` -> backend `window ... closed`; kitty in the test harness ignores the close, which is the client's behaviour, not the WM's) |
| injection + `:simulate` | **ported, verified** (`injected j as keycode 36`, app received `j`; per-app `:simulate` sent `^A h i`) |
| bindings (`bind`/`unbind`) | **ported** (27 bindings created, keysyms resolved) |
| chords / `eat-next` | **ported, verified** (`submap key "f" -> emacs-wm-toggle-float`, unbound key leaves the submap) |
| backend restart / resync / `epoch` | **ported, verified** (kill -> respawn in ~2 s -> `replaying state`, `re-attached ... via identifier`) |
| bar state file | **ported, verified** (`{"desktop":2,"desktops":4,...}`) |
| layout dedupe + `gen` | **ported, verified** ("layout gen N is identical to the applied one") |
| backend liveness | **verified**: ping every 5 s, 3 s timeout; a SIGSTOPped backend was detected, killed, respawned, and its buffers reattached |
| real key presses | **verified** through river's own binding matching (see `keyinject` below) |
| interactive move/resize | **implemented**; lifecycle verified, pointer motion not (no virtual pointer client here) |
| pointer bindings (`Super`+button) | **implemented**; not exercisable without a pointer |
| explicit stacking order | **implemented** (`order[]`, raise/lower, raise-on-click) |
| decoration policy (`use_csd`/`use_ssd`) | **implemented** per rule (`:decor "csd"|"ssd"`), hint forwarded |

## Evidence

All three suites, run today against the Elisp backend.  Every driver ends with
`test/check-leftovers.sh`, and each run reported `(none)`.

**Single output** (`test/run-emacs-only-test.sh`) -- repeated runs, last three:

- backend: `listening` -> `connected` -> seat + `river_xkb_bindings_seat_v1` +
  `virtual keyboard synced` -> output `non-exclusive area 1264x1386`
  -> 4 frames recognised -> `handshake complete` -> `replaying state`
- 21+ layout generations; identical snapshots deduped
- kitty mirrored, floated by rule, border-only change 2->3->2, inject delivered `j`
- sequences balanced: 29/29, 35/35, 42/42; **river panics: 0**
- state file: `{"desktop":2,"desktops":4,"generation":13,...}`

**Two outputs** (`test/run-emacs-only-multi-test.sh`):

```
output 4278190080 non-exclusive area 1264x1386 at 0,0
output 4278190081 non-exclusive area 1264x1386 at 1264,0
frame 1..4 = wm-frame:4278190081:1..4      frame 5..8 = wm-frame:4278190080:1..4
switch ...80 -> desktop 2        switch ...81 -> desktop 2
switch ...80 -> desktop 1        after switching back: focused wid=<app>
switch ...80 -> desktop 2        on desktop 2: focused wid=nil
inject into the app              app received: o
move app to desktop 3            after move: focused wid=<app> desktop=3
final desktops: ...81 -> 2, ...80 -> 3
sequences 34/34, panics 0
```

**Features** (`test/run-emacs-only-features-test.sh`):

```
injected a as keycode 30 (mods=0x4) ... app received: \001 h i \n
entered submap "test" (2 keys) -> submap key "f" -> emacs-wm-toggle-float -> submap=nil
unbound key eaten (leaving submap "test") -> submap=nil
backend killed -> backend starting (new epoch) -> replaying state: 1 output(s), 5 window(s)
resync: keeping 1 buffers -> re-attached "feat-app [kitty]" via identifier
post-restart inject -> injected r -> app received: r
sequences 40/40, panics 0
```

**Warning-level logging** (`-log-level warning`, the configuration that used to
wedge): injected `j` delivered, 29/29 sequences, 0 panics, twice in a row.

## Test-only tools

- `test/tools/` (one Rust crate, `cargo build --offline`): the four native
  helpers whose only justification is the one thing Elisp cannot do -- receive
  or pass a file descriptor.
  - `keyinject`: types keys as a **real input device** through
    `zwp_virtual_keyboard_v1` (keymap fd), so river attaches it like a physical
    keyboard and its keys go through river's binding matching
    (`river_xkb_binding_v1.pressed`), unlike the WM's own injection which
    deliberately bypasses it.  This is what finally exercised the key path, and
    it immediately found a real bug: `emacs-wm-enable` called
    `(lookup-key emacs-wm-command-map "s-2")` with a *string* instead of a key
    sequence, got nil, and `define-key` therefore unbound every WM key.  Keys
    arrived, were pushed as events, and found nothing.
  - `pointerinject`: `zwlr_virtual_pointer_v1` drags with a held button and
    modifiers, so move/resize and pointer bindings are exercised by a real
    pointer rather than inferred.
  - `screenshot`: `zwlr_screencopy_v1` to a PPM, which is how borders and
    positions stopped being protocol-level claims.  (`wf-recorder` hangs in a
    nested session; this does not.)
  - `lockclient`: takes and releases an ext-session-lock lock and paints every
    output, so the WM's behaviour while locked can be observed.
- `test/run-be-tests.sh`: 27 ERT tests for the pure parts -- pointer-op
  geometry (including that river's deltas are cumulative), the US
  keysym->keycode table, keysym-name resolution, frame-name parsing, and the
  Wayland codec's integer/string primitives.  These caught a second real bug:
  `\`` and `\\` are not contiguous with the rows beside them, so the table
  was off by one for every digit and for `z`-row punctuation.
- `test/cleanup-ours.sh` / `test/check-leftovers.sh`: kill or report every
  emacs-wm test process (never the user's Emacs).  Every driver runs them.

## Mitigations of the recorded disadvantages

| disadvantage | what this design does |
|---|---|
| Emacs in river's input hot path | the WM slot holds a `-Q` Emacs that loads two files and no user config; `gc-cons-threshold` 32 MiB / `gc-cons-percentage` 0.2; steady-state render sequences send zero requests; manage/render handlers never wait on the frontend |
| a wedged sequence freezes input | both handlers are `unwind-protect`ed to always send `finish`, and errors are logged loudly instead of propagating |
| backend death | the frontend supervises it: respawn, `river` re-sends windows, buffers reattach by `identifier`, `epoch` forces a resync |
| frontend death / stall | last layout keeps being applied; windows stay where they are |
| debugging | backend log file (`/tmp/emacs-wm-be.log`), env `EMACS_WM_BE_LOG_LEVEL`, `EMACS_WM_BE_LOG_FILE`; protocol errors from `wl_display.error` are decoded, not swallowed |
| no fd passing | nothing the WM role does needs one: none of the four river protocols has an `fd` argument, and injection now works without one |

Residual costs, honestly:

- no screencopy, so no visual verifier and no client-side decoration buffers
  (this is why borders stay compositor-drawn);
- layouts are still computed in the frontend, so a frontend GC pauses *layout
  changes*, not correctness;
- keysym -> evdev keycode uses a US-layout table; on another layout injected
  punctuation may differ (letters and named keys are fine).

## Interactive move/resize, stacking, decoration

- **Move/resize**: `s-<f7>` starts a move, `s-<f8>` a resize (or `Super`+left /
  right button once a pointer binding fires).  The frontend sends
  `op-start`; the backend queues `op_start_pointer` for the next manage
  sequence (it is window-management state), applies river's **cumulative**
  `op_delta` in the render pass while the op is live, and on `op_release` (or a
  frontend `op-end`) reports the final rect back with `op-done`.  The frontend
  stores that rect and floats the window, because a dragged window is the
  user's to place.  Two things needed care: river sends an `op_delta` for
  *every* manage sequence while an op is live, repeating the same cumulative
  value, so only a delta that changes the rect may request another sequence;
  and river's `.end` cancels without sending `op_release`, so the backend
  finalises the op itself.
- **Stacking**: the layout carries `order[]` (bottom->top).  Clicking a window
  raises it, `s-<up>`/`s-<down>` raise/lower explicitly, and the backend applies
  the order with one `place_top` pass.
- **Decoration**: rules may say `:decor "csd"` or `:decor "ssd"`; the backend
  calls `use_csd`/`use_ssd` once per change inside a manage sequence.  Without
  a rule nothing is requested, so the client's own preference wins (which is
  what happened before this existed).  The client's `decoration_hint` is
  forwarded as a `decor` event and stored in the window metadata.

## Open issues

1. ~~`-log-level warning` wedges river~~ **fixed** by `fix-log-callback-panic.patch`
   (see above). Two consecutive runs at warning level pass.
2. The stack trace in `panicFn` still prints nothing for this class of panic:
   the panic happened while the stderr lock was held, and `panicFn` cannot take
   it again. With #5 the triggering path no longer logs through that lock, but
   the general case (any panic inside `std.log`) is still a Zig/std matter.
3. Visual verification: `wf-recorder` (the only screencopy client installed)
   produces no frame in the nested session, so borders and positions remain
   protocol-level evidence.

## Process hygiene (a runaway, and what now prevents it)

Five test Emacsen were found spinning at ~100% CPU. They were **orphaned
frontends**: the drivers killed `river` but not the Emacs that lived in its
session, and since every nested river reuses `$XDG_RUNTIME_DIR/wayland-1`, a
later session's Emacs could attach to the *new* river while the old one was
still around -- several window managers for one session, each pushing layouts.
Three layers now make that impossible:

- every session script traps `EXIT/TERM/INT/HUP` to kill its Emacs, and watches
  the compositor socket's inode; if the socket disappears or is replaced, it
  exits and takes Emacs with it (measured: 0 of our processes left 2 s after
  `kill -9` of the compositor);
- every driver runs `test/cleanup-ours.sh` before and after a run, and prints
  `test/check-leftovers.sh` output at the end (must say `(none)`);
- the backend's main loop no longer busy-waits: with no live process
  `accept-process-output` returns immediately, which would pin a core for the
  life of a leftover backend. It now exits when the Wayland connection is gone.

`test/check-leftovers.sh` is the thing to run after any session. Both scripts
are relocatable: they derive the checkout from their own location and match
only processes whose arguments mention *that* `lisp/` or `test/` directory --
never a bare `emacs`, never a bare `river` -- so the user's own Emacs and a
live session running from another checkout are untouchable.

## Session lock (ext-session-lock-v1)

River owns the lock; the WM's job is to keep its hands off.  While
`river_window_manager_v1.session_locked` is set the backend refuses `op-start`
and drops injected keys, `reconcile-focus` does nothing, and the frontend
ignores every binding except `emacs-wm-allow-when-locked`.  The lock surface
itself is painted by the lock client, not by us: screencopy and lock clients
need fds, so the WM has neither.

Unlock has one non-obvious step.  River clears the seat's keyboard focus when
the session locks *and* when it unlocks, so the WM's record of "what is
focused" goes stale: after an unlock, layout focus equals the remembered focus,
no `focus_window` would be sent, and every key (injected or physical) would go
to nothing.  So the backend forgets its applied focus when the lock engages and
queues a `manage_dirty` when it releases; the next manage sequence re-asserts
focus from the layout.  Measured: focus is re-asserted 1 ms after
`session_unlocked`, and a key injected then reaches the app.

## Not yet re-verified

- **`river_output_v1.removed`** from river: tested only by feeding the frontend
  a synthetic `output-removed` (frames deleted, surviving output still works,
  `h` still delivered).  river 0.6 has no output-management protocol and a
  nested output is a host window, so a real unplug is not reproducible here.
  The backend's handler is three statements mirroring the tested path.
- **`use_csd`/`use_ssd`**: no window has been observed changing decorations;
  the request is sent once per change, but no client here asks for it.
- **stacking order at the pixel level**: `order[]`/`place_top` is used by
  raise-on-click and `s-<up>`/`s-<down>`, and rendering is exercised, but no
  capture has been sampled to prove one window is above another.
- animation, touch gestures, multiple/transient seats: unchanged scope, not
  started.

Verified visually (see *Test-only tools* and RESULTS.md): pointer motion with a
real virtual pointer, border pixels in both focus states, and session lock in
both directions.

## Next increments (in order)

1. stacking order sampled at the pixel level (a window over another window)
2. the desktop slide animation, when authorised
3. filing the five river patches upstream, when authorised

## Where the old implementation went

`wm-poc/` (the Rust daemon) is kept on the development machine as the
reference implementation and A/B baseline, at `legacy/wm-poc/`.  It is not part
of the published tree (`.gitignore` excludes `legacy/`); the same frontend can
drive either backend because the message semantics never changed, which is why
the older `test/run-elisp*.sh` and `test/run-fake*.sh` drivers still exist here.
