# Results: river + Emacs-WM proof of concept

Everything here was measured on this machine: river `main` @ `85b0088` (2026-11-10,
0.6.0-dev) built with Zig 0.17.1 against system wlroots 0.20.2, Emacs 32.0.50
`--with-pgtk`, nested inside the host Wayland session.

## What was proven

| Claim | Evidence |
|---|---|
| River advertises everything the design needs | probe dump: `river_window_manager_v1` v6, `river_xkb_bindings_v1` v3, `river_virtual_keyboard_manager_v1` v1, `zwp_virtual_keyboard_manager_v1` v1, `river_layer_shell_v1` v1, `zwlr_layer_shell_v1` v4 |
| Emacs frames can be desktops, hidden per-desktop without being unmapped | two frames titled `wm-frame:1`/`wm-frame:2`; switching desktops sends `hide()` to the inactive one; **no `closed` events** for the frames across the whole run, so the `river_window_v1` objects survive |
| Hiding a frame does not stall Emacs | 0.5 s timer heartbeat: 44 ticks across the run, including across desktop switches and with a frame hidden. No gap. Manage sequences for the whole run: 8 (so no configure storm either) |
| Focus follows desktops | F9 injected after each switch; Emacs wrote `selected="wm-frame:2" focus-state=t` then `selected="wm-frame:1" focus-state=t` |
| Key injection works, including modifiers | `inject j` → Emacs `insert: 106 on frame="wm-frame:1"`; `inject J` → `insert: 74` (shift level exercised) |
| Focus + injection are atomic in one manage sequence | `app-inject j` focuses the app window and types in the same sequence: status shows `focus Some(428...084)` (the app) and Emacs logs `insert: 106 on frame="app-window"` |
| Window roles come from the protocol, not title hacks (for apps) | every `river_window_v1` carries `identifier`, e.g. `"eb9fb277523245910c62825bc9e5856a"`, unique per object |

Not exercised (and why):

- **Physical key bindings → WM.** `Super+1/2/j/q` were created and enabled and river
  accepted them, but the nested test has no physical keyboard, and injected keys
  deliberately bypass binding matching river-side (the vkb delivers straight to the
  focused client via `Seat.wlr_seat.keyboardNotifyKey`, not through `KeyboardGroup`
  matching). Driving real input would mean injecting `Super+j` into the *host*
  session and hoping focus lands on the nested river window — rude and flaky.
  The handler code path is exercised by the stdin commands instead; only the
  binding→handler wiring is unverified, and it is reka's exact pattern.
- **Visual correctness.** No screencopy tool installed (`grim` absent), so "the
  hidden frame is really gone from the screen" rests on protocol semantics plus the
  fact that river sends `pointer_enter` only for rendered surfaces (observed
  following the visible frame).
- **Multi-output, floating windows, layer-shell/bar, session lock.**

## River bugs found (both block this project as-is)

### 1. `river -c <command>` segfaults: stale environ

Any `river -c '...'` crashed inside `std.process.Environ.createMap`:

```
Segmentation fault at address 0x0
std/process/Environ.zig:188 putPosixBlock
std/process/Environ.zig:542 createMap
river/main.zig:169 main          var env_map = try init.environ.createMap(util.gpa);
```

Cause: `std.process.Init.Minimal.environ` caches a view of libc's `environ`
array; by the time the init-executable fork happens, some dependency has called
`setenv()` and glibc reallocated the array, so the cached slice dangles. Without
`-c` the same bug is masked because `defaultInitPath()` bails out first.

Fix (in `fix-stale-environ.patch`): build the env map at the top of `main`,
before wlroots initialises, and reuse it at the fork site.

```zig
var startup_env_map = try init.environ.createMap(util.gpa);
defer startup_env_map.deinit();
```

Careful: do not *copy* the map (`var env_map = startup_env_map;`) — `put()` can
realloc the backing store and the copy's pointers dangle, which I hit first as a
segfault inside `Environ.Map.deinit`.

### 2. Synced virtual keyboard panics the compositor on the next focus change

After the first injected key, river's seat has the virtual keyboard as its active
keyboard. `SyncedVirtKb.state` is a `wlr.Keyboard` created by river, but river
never sets its `data` field (unlike `KeyboardGroup`, which does
`group.state.data = group`). So:

```zig
// Seat.keyboardNotifyEnter
const group: *KeyboardGroup = @ptrCast(@alignCast(wlr_keyboard.data));  // null!
```

```
thread 29961 panic: cast causes pointer to be null
river/Seat.zig:1255 keyboardNotifyEnter
river/Seat.zig:1247 keyboardEnterOrLeave
river/Seat.zig:1226 focus
river/Seat.zig:1122 manageFinish      .window => |ref| seat.focus(...)
```

Debug/ReleaseSafe: hard panic the moment any focus change follows an injection.
ReleaseFast: undefined behaviour on a null pointer.

Fix (in `fix-vkb-active-keyboard.patch`): treat a keyboard without group data as
"no pressed keys", and forward its modifiers:

```zig
const group: ?*KeyboardGroup = if (wlr_keyboard.data) |ptr| @ptrCast(@alignCast(ptr)) else null;
...
} else {
    seat.wlr_seat.keyboardNotifyEnter(wlr_surface, &.{}, &wlr_keyboard.modifiers);
}
```

This is almost certainly the intended design intent being incomplete rather than a
disagreement: `SyncedVirtKb.destroy()` already handles "if this keyboard is the
seat's active keyboard" carefully.

## Gotchas that will bite the elisp side

- **`zwp_virtual_keyboard_v1.key` takes evdev keycodes**, i.e.
  `linux/input-event-codes.h` values, while libxkbcommon keycodes are offset by 8.
  Sending the xkb keycode for `j` (44) types `z`; the correct value is 36. Any
  `inject` message must therefore carry the keycode the daemon derived *and* the
  daemon must subtract 8 when talking to the compositor.
- **Keysym lookup flags matter.** `xkb_keysym_from_name("J", KEYSYM_CASE_INSENSITIVE)`
  folds `J` onto `j`, silently making every injected capital letter lowercase.
  Use no flags in the daemon, and search level 0 then level 1 to decide whether a
  shift modifier is needed.
- **Injected keys do not trigger WM bindings** (by design, see above), which is the
  right semantic for simulation keys but means a WM cannot use injection to test
  its own bindings.
- **`river_window_manager_v1` is first-binder-wins**; river sends `unavailable` to
  any later client. A WM that crashes and reconnects must be prepared to win the
  race again, and should log loudly if it does not.
- **`hide()` is not `unmap`.** Frames stay mapped, keep their `identifier`, and keep
  their Emacs window tree; `make-frame-invisible` would destroy the
  `river_window_v1` and mint a new identifier on return.

## Files

```
~/src/river                     river main @ 85b0088 + the two fixes above
~/src/river/fix-*.patch         the two upstream-able patches
~/src/river/probe-globals.c     registry dumper used to verify globals
~/src/emacs-wm/PROTOCOL.md      daemon <-> elisp protocol design
~/src/emacs-wm/wm-poc/          the proof-of-concept WM (Rust, ~1000 lines)
~/src/emacs-wm/test/run.sh      harness: fifo-driven commands + Emacs frames
/tmp/emacs-wm-test.log          last run: wm-poc log + harness phases
/tmp/wm-keys.log                last run: Emacs key/heartbeat log
/tmp/wm-report.log              last run: F9 focus reports
```

## Reproducing

```sh
# build river (zig 0.17.1 + system wlroots 0.20)
cd ~/src/river && PATH=$HOME/.local/opt/zig-0.17.1:$PATH zig build -Dllvm

# build the PoC
cd ~/src/emacs-wm/wm-poc && cargo build

# nested session, scripted scenarios, ~50 s
cd ~/src/river && ./zig-out/bin/river -log-level warning \
    -c ~/src/emacs-wm/test/run.sh
cat /tmp/wm-keys.log /tmp/wm-report.log

# interactive: control the WM from its stdin
./zig-out/bin/river -c 'sh -c "wm-poc/target/debug/wm-poc & emacs -Q & wait"'
#   then type at wm-poc's stdin: desktop 2 / inject j / app-inject j / status
```

Note the harness needs a writer on the fifo for the whole run (`exec 9<>fifo`),
otherwise wm-poc sees EOF and exits.

## Interactive testing (nested, real keyboard)

`test/interactive.sh` starts wm-poc, two desktop frames in Emacs, and a kitty
window running `tail -f` on the logs so bindings are observable:

```sh
cd ~/src/river
./zig-out/bin/river -c ~/src/emacs-wm/test/interactive.sh
```

Click the new window, then use `Super+1/2`, `Super+j` (focus app + type `j`),
`Super+q`, `Super+Shift+q`; `Ctrl+Alt+*` variants exist in case the host
compositor grabs `Super`. Nested river's wayland backend forwards the real
keyboard, so this is the only setup where the binding→handler path is exercised.

Verified interactively: `Super+j` → focus moves to the terminal and `j` is typed
into it in one manage sequence; `Super+1/2` swap which frame (and which set of
windows) is rendered; Emacs follows focus across frames.

### Flakiness I could not root-cause

In roughly half of my automated nested runs the sequence
`app-inject` → `desktop N` stops working: river prints

```
thread <river-pid> panic: attempt to use null value
```

to its stderr and then stops servicing `manage_dirty` requests (it keeps
rendering and keeps the WM object, so the session is frozen but alive). Notes:

- The message appears **without a backtrace**, and river does *not* exit. A Zig
  panic (verified with a 15-line test program) always prints a trace and aborts,
  so the writer is most likely a **forked child** that inherited river's stderr
  and main-thread TID (river only calls `fork()` for the init command, which
  immediately `execve`s — so this is unexplained).
- It did not reproduce in runs at river's default (debug) log level, nor with
  `-log-level debug -log-scopes wm`; it did reproduce consistently at
  `-log-level warning`. Timing-sensitive, not a logging bug per se.
- It correlates 1:1 with the stall: the runs where injection worked had no
  panic line, the runs where it did not had exactly one.
- Suspected area: the synced virtual keyboard path, i.e. the same code that
  produced the reproducible null-group panic earlier and that
  `fix-vkb-active-keyboard.patch` only partly addresses.

Until that is understood, treat synced-keyboard injection on river main as
"works, but not yet reliable".

### Test-infrastructure traps hit along the way

- `kitty` without `-1` is single-instance: a new run's `kitty --title ...`
  silently opens a window in an *old* instance living in a dead session, so the
  new session has no app window at all. The script now passes `-1`.
- Leaked `river` processes from previous runs keep rendering nested sessions and
  share the host seat; always `pkill -x river` and kill the test clients between
  runs, or results become meaningless.
- `WM_POC_NO_VKB=1` disables the virtual keyboard, for isolating injection from
  focus handling.

## Interactive session, round 2 (user-run, then verified)

Real-keyboard run by the user: `Ctrl+Alt+1/2` switched desktops visibly (Emacs
and a terminal, toggling both directions), `Super+Shift+Q` fired, no hidden-frame
artefacts. Injection was not tried in that run.

Making injection visible: the demo window now runs a line reader instead of
`tail` (a `tail` would silently swallow injected keys, since it ignores stdin),
and the binding injects a two-key sequence (`j`, `Return`) — EXWM-style
simulation keys are sequences, not single keys. Verified 3/3 runs:

```
run 1: injected=2 app_got='j' panic=0
run 2: injected=2 app_got='j' panic=0
run 3: injected=2 app_got='j' panic=0
```

i.e. the focused app window received `j` + `Return` as a line, and the WM sent
both keys during the same manage sequence as the focus change.

### Caveat: this only holds with river's debug logging on

Same scenario at `-log-level warning`: river panics

```
thread <pid> panic: attempt to use null value
```

before sending `manage_start`, the client's connection is reset, and no keys are
injected. 8/8 failures at warning level, 0/3 at `-log-level debug -log-scopes wm`
(and earlier 3/3). No core is produced, no backtrace is printed, and a control
test (a Zig program that panics in a thread) does produce both — so the panic is
not reaching the normal abort path. Candidate sites were instrumented
(`KeyboardGroup` release-without-press, `SyncedVirtKb` queue-after-destroy,
`Window.sendFrameDone` without a root surface); none fired.

Root cause is therefore unresolved, but it is clearly a timing/memory-reuse
sensitive bug in river's synced-virtual-keyboard path — the third defect found in
that area, after (a) the uninitialized `wlr_keyboard.data` cast and (b) the null
group dereference. Workaround for now: run nested tests with
`-log-level debug -log-scopes wm`.

## Interactive session, round 3: injection confirmed by the user

With the two-key sequence enabled by default and a prompt loop in the demo
window, a real keypress produced the full result:

```
wm-poc> j
>>> INJECTED LINE: j
wm-poc>
```

Log for that run (5 presses of `Ctrl+Alt+j`, each a focus change plus a 2-key
injection; the app window received exactly 5 lines):

```
binding pressed: ctrl+alt+j -> FocusAppInject(["j", "Return"])
injected j as keycode 36 (shift=false)
injected Return as keycode 28 (shift=false)
```

Important detail: the last press came *after* `Ctrl+Alt+1` / `Ctrl+Alt+2` /
`Ctrl+Alt+1`, i.e. after leaving the desktop and coming back, and still worked.
State (which window is the app, its rect, focus) survived desktop switches
without the WM observing its own surfaces in any special way.

So all three claims of the design are now validated with real input:

1. frames as desktops, hidden/shown without unmapping (no `closed` events);
2. focus follows desktops (Emacs reports `selected`/`focus-state` correctly);
3. a bound key can focus a window and type a sequence into it atomically in one
   manage sequence — the simulation-key primitive.

Two PoC bugs found by the user's own testing, both fixed:

- `Ctrl+Alt+q` closed `wm-frame:1` instead of an app window, because on that
  desktop the *frame* held focus. A WM must never close its own desktop frame;
  `CloseFocused` now refuses frames.
- Two-key injection was gated behind an environment variable that defaulted to
  off, so the first demo injected a bare `j` (visible only as a pty echo) with
  no line. Sequence injection is now the default; `WM_POC_SINGLE_KEY=1` opts out.

Also: the demo's received-lines file is now per-session (it was accumulating
across runs, which made 5 presses look like 6 lines).

## PoC gaps closed: bar space and floating windows

### Layer-shell exclusive zones (`non_exclusive_area`)

Implemented per the protocol design: bind `river_layer_shell_v1`, create a
`river_layer_shell_output_v1` per output, track `non_exclusive_area` (global
coordinates, converted to output-local), size/position desktop frames to the
usable rect, and `set_default` each manage sequence. Layer focus events
(`focus_exclusive` / `focus_non_exclusive` / `focus_none`) are tracked, and WM
focus requests are skipped while a layer surface has exclusive focus — river
ignores them anyway.

Verified with a self-contained test client (`test/testbar.c`, a 30px top bar with
exclusive zone 30):

```
non-exclusive area 1264x1386 at 0,0    (no bar)
non-exclusive area 1264x1356 at 0,30   (testbar mapped)
app window size=Some((1264, 1356)) rect=Some((0, 30, 1264, 1356))
```

Verified with the **real bar** (noctalia 5.4.1, the user's own config, running its
own per-display instance inside the nested session):

```
non-exclusive area 1264x1352 at 0,0    (noctalia bottom bar, 34px)
frames and the app window resized to 1264x1352 automatically
```

Noctalia keys its sockets by `WAYLAND_DISPLAY` (`noctalia-wayland-*.sock`), so a
nested instance coexists with a bar running on the host session — the live
instance (pid 904) was untouched. `WM_POC_BAR=1` starts it from
`test/interactive.sh`.

### Floating windows

- Windows with a `parent` float automatically (dialogs, pickers, popups).
- `Super+F` / `Ctrl+Alt+F` (or the `float` stdin command) toggles floating for
  the focused app window; frames refuse to float.
- Floating windows get 60% of the usable area, offset by 10%, `set_tiled(empty)`,
  no clip box, and are stacked above tiled windows.

Verified:

```
float -> window 4278190084 floating=true
size=Some((758, 813)) rect=Some((126, 165, 758, 813))   ; 60% of 1264x1356, +10% offset
```

### One more PoC bug the user found

`Ctrl+Alt+Q` closed `wm-frame:1` rather than the terminal: on that desktop the
*frame* held focus, and `CloseFocused` closed whatever was focused. Frames are
structure, not content — closing one destroys a desktop, so `CloseFocused` now
refuses frames and only closes app windows.

### Why the first `WM_POC_BAR=1` run showed no bar (two harness bugs, not WM bugs)

1. **The bar block was unreachable.** `interactive.sh` ran `kitty` in the
   foreground, and the bar's start-up block had been appended *after* it, so it
   only ran once the terminal was closed. Fixed by starting the bar before the
   terminal.
2. **A stale per-display noctalia instance lock.** Noctalia keys its socket and
   lock by `WAYLAND_DISPLAY` (`noctalia-wayland-N.{lock,sock}`) and those files
   outlive the session. River reuses display names, so a nested session can
   inherit a lock from an earlier one; the new instance then hands off to a dead
   one and exits silently, producing no output at all. `start_bar()` now starts
   noctalia, and if it dies within 2 s removes the state for *this* display
   (never the host's) and retries once.

After both fixes, verified in a nested session:

```
starting noctalia inside this session (display wayland-1)
noctalia v5.4.1 ... 1 bar(s) defined
new layer surface: namespace noctalia-wallpaper, layer background
new layer surface: namespace noctalia-bar-default, layer top
new layer surface: namespace noctalia-dock, layer top
non-exclusive area 1264x1352 at 0,0     (was 1264x1386 before the bar mapped)
```

Frames and app windows resized to 1264x1352, and the bar running on the host
session (pid 904, display wayland-0) was untouched.

Lesson for the daemon design: the `output.usable` push must be treated as
"may change at any time", including immediately after startup and while a
layout is being computed. It is delivered as a manage-sequence event, so no
polling or ordering assumptions are needed — but a WM that caches output
geometry without recomputing on `non_exclusive_area` will tile under the bar.

### Bar start-up is now on by default

The `WM_POC_BAR` environment gate was too easy to miss (a run without it simply
never starts the bar and logs nothing about it). The bar now starts by default;
`WM_POC_NO_BAR=1` disables it, and the first lines of the session log state the
configuration:

```
config: bar=on float_apps=blueman popup_cmd=blueman-manager
```

## Floating windows: rules, and the real use case

The PoC floats by rule as well as by toggle:

- rules come from `WM_POC_FLOAT_APPS` (comma-separated, case-insensitive
  substrings matched against `app_id` and `title`; default `blueman`)
- a match floats the window on first sight, before it is ever tiled
- floating geometry is 60% of the usable area, centred
- `Super+F` / `Ctrl+Alt+F`, or the `float` stdin command, toggles a focused app
- windows with a `parent` float automatically (dialogs, pickers)

Verified with blueman-manager, the app behind noctalia's bluetooth icon:

```
float rule 'blueman' matched window 4278190085 (app_id Some("blueman-manager")
                                               title Some("Bluetooth Devices"))
window 4278190085 role=App size=Some((758, 811)) rect=Some((253, 270, 758, 811))
window 4278190084 role=App size=Some((1264, 1352)) rect=Some((0, 0, 1264, 1352))
```

`758x811` centred in `1264x1352` (usable area with noctalia's 34px bar
subtracted), next to a tiled window filling that same area.

blueman-manager is a native Wayland client in this test (`app_id` lowercase);
under XWayland the same window arrives with `app_id` = `WM_CLASS`
(`Blueman-manager`), which is why the rules match case-insensitively. River
exposes X11 windows to the WM as ordinary `river_window_v1`s
(`Window.getAppId`: "X11 clients don't have an app_id but the class serves a
similar role"), so one rule covers both.

The PoC spawns the popup itself (`Super+Return` / `Ctrl+Alt+Return`, or
`spawn <cmd>` on stdin). That is a PoC shortcut: in the real architecture Emacs
spawns processes and the daemon only applies float rules to whatever appears —
exactly as it must for a window launched from a bar.

## Windows that open in the wrong session (launch environment, not WM policy)

Clicking the bluetooth icon in the nested noctalia bar started blueman-manager on
the **host** desktop, not inside the session, and the WM never saw a window. Not a
rule problem — the app never entered the session:

```
blueman-manager  ppid=782  /usr/lib/systemd/systemd --user
unit [Service] Type=dbus  BusName=org.blueman.Manager  ExecStart=/usr/bin/blueman-manager
env  WAYLAND_DISPLAY=wayland-0  DISPLAY=:0      # the host session's env
```

`org.blueman.Manager` is a D-Bus service (`SystemdService=`/`Type=dbus`), so the
**user manager** spawns it with *its* environment. The same applies to desktop
files, `xdg-open`, and every bar widget that activates an app. In a real session
the fix is one line, and it is the same one reka's launcher uses:

```sh
systemctl --user import-environment WAYLAND_DISPLAY DISPLAY
```

Everything the manager launched *before* that import keeps the old values, and
`set-environment` is not a substitute — it would repoint an already-running
session's activations at the new display. Do not do that while a live session is
using the same user manager.

The harness now detects the mismatch and says so at startup:

```
NOTE: systemd --user has WAYLAND_DISPLAY=wayland-0, this session is wayland-1.
NOTE: dbus/service-activated apps (bar widgets, xdg-open) will open outside this session.
```

Window *rules* are unaffected: they match on the window that appears, so they
behave identically whether the app was launched by the bar, by Emacs, or from a
shell inside the session.

## The Emacs client exists (socket + elisp brain)

`wm-poc` now listens on `$XDG_RUNTIME_DIR/emacs-wm.$WAYLAND_DISPLAY.sock` before
binding the WM global, speaks the NDJSON protocol from `PROTOCOL.md`, and treats
the last `layout` snapshot as authoritative. When no client is attached it falls
back to the old built-in behaviour, so the PoC still works standalone.

`lisp/emacs-wm.el` is a ~450-line client: frames-as-desktops, one `emacs-wm-mode`
buffer per app window, layout computed from Emacs' own window tree, window rules,
per-app focus, prefix interception and injection.

Verified end to end (`test/run-elisp-test.sh`, nested river):

```
elisp: window 4278190084: actions=(:float t) float=t rect=(253 264 758 792)
elisp: layout gen 7: 2 frame(s), 1 window(s), focus (:frame 1 :window 4278190084)
daemon: render: wid=4278190084 frame=Some(1) rect=(253, 264, 758, 792) float=true size=Some((758, 792))
elisp: inject ("j" "Return")
daemon: injected j as keycode 36 / injected Return as keycode 28
app:    j                              <- the focused app received the sequence
elisp: switching to desktop 2 via elisp
daemon: render: frame fid=2 visible=true / frame fid=1 visible=false
```

So, in one run: Emacs classified a window (float rule), sized and placed it, kept
focus in sync, typed into it through the WM, and switched desktop — all decisions
taken in elisp.

Things that had to be right in the daemon, learned the hard way:

- Binding creation/enabling is window-management state: doing it when a client
  message arrives (outside a manage sequence) makes river kill the connection with
  `invalid modification of window management state`. Requests are queued and
  applied at `manage_start`.
- Proposing dimensions that have not changed makes clients re-commit and can loop
  with a client that reacts to `size` events; the daemon now proposes only on
  change and ignores layout snapshots identical to the applied one.
- On attach, existing windows/frames must be re-sent (a client that connects late,
  or reconnects, has to reconstruct state).
- Elisp side: `plist-put` returns the new plist (storing the old one silently
  loses every title), `nreverse` corrupts a list you then measure, and a rule
  written as `((:app-id "x") . (:float t))` is a different shape from
  `((:app-id "x") (:float t))`.

### Try it

```sh
cd ~/src/river
./zig-out/bin/river -log-level debug -log-scopes wm \
    -c ~/src/emacs-wm/test/run-elisp.sh
```

Keys, all registered by elisp: `s-1` / `s-2` switch desktop, `s-f` toggles
floating for the focused app, `s-<return>` spawns `emacs-wm-popup-command`
(`blueman-manager`, floated by rule), and `C-x` / `C-c` / `M-x` reach Emacs as
usual because the WM intercepts them.

What it still is not: no click-to-focus, no fullscreen handling, no size-hint
clamping, single output, no decorations, and app buffers are bare placeholders
(the surface is composited on top of them). Injection is still only reliable with
river's debug logging on, per the unresolved panic above.

## Daily-driving features (added after the first elisp session)

| feature | behaviour | verified by |
|---|---|---|
| **click-to-focus** | river's `pointer_enter` is forwarded; elisp selects that app's buffer (or, for a frame's own surface, that desktop) and re-pushes focus | `pointer focus -> 4278190084 ("elisp-app [kitty]")`, `selected after pointer-enter: "elisp-app [kitty]"` |
| **fullscreen** | `super+F11` / app requests; queued and applied in a manage sequence, geometry owned by river | `window ... fullscreen=true`, `render: wid=... fullscreen`, then `fullscreen=false` |
| **size hints** | `dimensions_hint` stored and every proposal clamped to min/max | `window ... size hint min 107x61 max 0x0` (frames), `41x109` etc. |
| **minimise** | `super+m` (and app `minimize_requested`); daemon hides the surface, buffer buried; focus restores it | `render: wid=... minimised (hidden)` |
| **close** | `super+q`, queued op | `window ... asked to close` |
| **move to desktop** | `super+Shift+1/2` moves the buffer to that desktop frame | window re-tiled in frame 2 |
| **restore** | `super+r` re-displays a minimised window and focuses it | — |
| **spawn popup** | `super+Return` runs `emacs-wm-popup-command`, rules decide floating | earlier float runs |

Both remaining protocol traps were hit again while adding these, and both have the
same root cause: **anything that modifies window-management state has to be called
from inside a manage sequence**. Fullscreen and `close` called straight from a
client message both produced
`invalid modification of window management state` and river closed the connection
— which presents as "the WM died" but is a usage error. Ops are now queued
(`WindowOp::{Fullscreen, Close}`, plus bindings) and drained at `manage_start`.
That rule and the "propose only on change" rule are now written down in
`PROTOCOL.md` §10 so the real daemon does not relearn them.

### Keys in the elisp session

| key | action |
|---|---|
| `s-1` / `s-2` | switch desktop |
| `s-S-1` / `s-S-2` | move focused window to that desktop |
| `s-f` | toggle floating |
| `s-<f11>` | toggle fullscreen |
| `s-m` / `s-r` | minimise / restore |
| `s-q` | close focused window |
| `s-<return>` | spawn the popup command (floated by rule) |
| `C-x` `C-c` `M-x` | reach Emacs as usual |

### Still missing for full daily driving

- **Multi-output.** One output only: the daemon picks a primary output, and the
  desktop model (frame == desktop) assumes a single screen. Unplugging an output
  is not handled. This is the largest remaining item and needs a frame-per-output
  model in elisp.
- **Decorations/borders.** Undecorated frames; floating windows are just surfaces
  over the frame, with no border or titlebar.
- **Injection reliability.** Still needs river's debug log level, per the
  unresolved river panic.
- **Scroll events / pointer buttons to the frame** are river's business; clicks on
  an app go to the app, which is correct.

## Later session: injection re-diagnosed, borders, multi-output

### The injection panic is gone on the current tree

The "injection only works with river's debug log level" caveat no longer holds. Six
nested runs at the log level that previously failed 8/8 (`-log-level warning`, which
prints nothing at all, so a clean log is real evidence), zero panic lines:

| run | harness | injected | delivered | panic |
|---|---|---|---|---|
| 1 | `run.sh` under gdb | 4 keys | 4 | 0 |
| 2-4 | `run.sh` x3 | 4 keys each | 4 each | 0 |
| 5 | `stress-inject.sh` (40 desktop cycles) | 160 keys | 160 | 0 |
| 6 | elisp session under gdb | `j`,`Return` | app got `j` | 0 |

`test/diag-panic.sh` is the tool that produced this: river runs *under gdb*
(`ptrace_scope=1` forbids attaching to a non-child) with a breakpoint on
`debug.defaultPanic`, so a recurrence is caught at the site instead of printing one
line and hanging. `test/diag-repeat.sh` repeats any harness at any log level and
counts panics; `test/stress-inject.sh` runs N `app-inject`/`desktop` cycles in one
session.

Why the old evidence overstated it: every `.?` unwrap that can emit
`attempt to use null value` on this path is already guarded or instrumented in the
binary that produced the "8/8" runs (`SyncedVirtKb.queueModifiers`/`queueKeymap`,
`KeyboardGroup.handleKey`, `Window.sendFrameDone`), none of those probes fired, and
the harness at the time left leaked rivers running that shared the host seat — a
panic line from one of those, plus an unrelated timing stall, reproduces the reported
"1:1 correlation". That is an explanation, not a proof; the proven part is that the
current tree injects reliably without debug logging.

### Panics are no longer silent (river patch)

Zig 0.17.1's default panic handler prints the message and then unwinds with
`allow_unsafe_unwind = true`; inside a wlroots listener callback that frame-pointer
walk can loop forever, so the process prints one line, prints no trace, and never
aborts — which is exactly how these defects presented ("frozen but alive"). river now
overrides the panic namespace in `main.zig`:

```zig
pub const panic = std.debug.FullPanic(panicFn);   // message, safe unwind, abort
```

Verified by an env-gated `@panic` (temporary, then removed): message, full trace with
source lines, `aborting`, core dumped. Statically: 43 `FullPanic((function
'panicFn'))` symbols, `debug.defaultPanic` no longer referenced.

Second hardening, `SyncedVirtKb.destroy()` and `KeyboardGroup.unref()`: when the
destroyed keyboard was the seat's active one *and no keyboard group is left*, the
seat now gets `setKeyboard(null)` instead of keeping a pointer to freed memory (the
next `keyboardNotifyEnter` would cast it to a `*KeyboardGroup`). Not reachable in
nested tests — the nested backend always supplies a host keyboard — but reachable on
a session with no keyboard device, e.g. a daemon restart with the lid closed.

### Borders (compositor-drawn, policy in elisp)

river already has `river_window_v1.set_borders(edges, width, r,g,b,a)`: drawn by the
compositor, outside the content rect, hidden automatically while fullscreen, legal
inside the manage sequences the daemon already runs. No new bindings needed.

| piece | where | evidence |
|---|---|---|
| `Border` in the layout snapshot, deduped per window | `layout windows[].border = {w,edges,r,g,b,a}` | `border wid=4278190084 edges=0xf width=2 rgba=#7a7a7a7aa2a2a2a2f7f7f7f7ffffffff` |
| focused/unfocused colour, per-rule overrides | `emacs-wm-border-{width,color-focused,color-unfocused,edges}`, rule actions `:border-width` `:border-color` `:border-edges` | `#7aa2f7` focused / `#3b4261` unfocused |
| border-only change reaches the compositor | `layout gen 11` then `border ... width=3` | width 2 -> 3 -> 2 applied with no geometry change |

Two bugs found and fixed while wiring it:

- The daemon's "identical snapshot" guard did not compare borders, so a *focus-only*
  change (which only alters the border colour) was dropped as a no-op.
- The fullscreen early-`continue` in `reconcile_layout` skipped the border sync
  entirely, so a colour/width change sent while a window was fullscreen was lost.

Colours are converted in elisp (`#rrggbb` -> three 32-bit components, each 8-bit
value scaled by `#x01010101`), verified in batch: `#7aa2f7` ->
`(2054847098 2728567458 4160223223)`.

### Multi-output: independent desktops per output

Model: a desktop is a frame per output, named `wm-frame:<oid>:<desktop>`; each output
switches independently. `WLR_WL_OUTPUTS=2` gives the nested session two outputs.

| piece | behaviour | evidence |
|---|---|---|
| frame naming | `wm-frame:<oid>:<n>` parsed by the daemon into `Frame { desktop, output }` | `window 4278190083 title Some("wm-frame:4278190080:1") role Some(Frame { desktop: 1, output: Some(4278190080) })` |
| desktop per output | `emacs-wm--desktop-by-oid`, `s-1`/`s-2` act on the output under the pointer | `output 4278190080 -> desktop 2 ("wm-frame:4278190080:2")` |
| independence | switching one output leaves the other alone | same render pass: `frame fid=2 oid=4278190080 visible=true` (desktop 2) and `frame fid=4 oid=4278190081 visible=true` (desktop 1) |
| move to desktop | targets the window's own output | `moving wid 4278190087 to desktop 2 on its own output 4278190080`, then `render: wid=... frame=Some(2)` |
| output add/remove | `output` / `output-removed` messages; a removed output's frames are deleted | frame-per-output creation logged for both oids |
| new window placement | opens on the output under the pointer (`river_seat_v1.pointer_position`), reported as `window.output` | 2-output injection still delivered: app got `o` |

Bugs found and fixed on the way:

- Output ids are `u32` and exceed `i32::MAX` (a nested output is `4278190080`), so
  carrying the oid as `i32` in the layout made it negative and silently fell back to
  the primary output. It is `i64` end to end now, and part of the identity check.
- The initial Emacs frame was left un-adopted after the refactor: it became an
  ordinary "app" window, got mirrored into a desktop frame, and the mirror's title
  fed back into the frame title — a 500-generation runaway that shrank the frame by
  32px per iteration. The initial frame is adopted as the first desktop of the first
  output again, and frames are never mirrored.
- Frames without an explicit rect now use the *usable* area of their own output, so a
  bar's exclusive zone is respected instead of the frame being placed at the output
  origin.

Tests: `test/elisp-multi.el` + `test/run-multi-test.sh` (2 outputs),
`test/stress-inject.sh` (injection stress), `test/diag-panic.sh` (panic site under
gdb), `test/diag-repeat.sh` (N runs, panic count). `test/run-elisp.sh` honours
`EMACS_WM_TEST_EL`.

## Later session: bar state file, simulation keys, chords, resync, dynamic desktops

Six follow-ups from the previous plan, all exercised in one scripted session
(`test/elisp-features.el` + `test/run-features.sh`, which *restarts the daemon
mid-run* on purpose) plus the two existing suites. Zero river panics throughout.

### The bar state file (`emacs-wm.state.json`)

river implements no `ext_workspace_manager_v1`, so the daemon writes
`$XDG_RUNTIME_DIR/emacs-wm.state.json` (tmp + rename, once per applied layout). It is
deliberately outside the WM protocol: a bar that ignores it costs nothing.

```json
{"epoch":1794712810381,"gen":8,
 "focus":{"wid":4278190085,"title":"feat-app","app_id":"kitty","output":4278190080,"desktop":1},
 "outputs":[{"oid":4278190080,"x":0,"y":0,"w":1264,"h":1386,
             "usable":{"x":0,"y":0,"w":1264,"h":1386},
             "desktop":4,"desktops":4,"windows":{"1":0,"2":0,"3":0,"4":0}}]}
```

Captured immediately after switching to desktop 4, which is why `desktop` is 4 while
`focus` still names desktop 1 — both fields are read from the last applied layout.

### Per-app simulation keys (`:simulate`)

A rule can now translate a WM key into keys typed into *that app*:

```elisp
((:app-id "kitty") (:float t :simulate (("s-w" . ("C-a" "h" "i" "Return")))))
```

The daemon's `inject` entries grew an optional `mods` mask (ctrl 4, alt 8, shift 1,
super 64), applied around the key with `zwp_virtual_keyboard_v1.modifiers`. Evidence:
`injected a as keycode 30 (shift=false, mods=0x4)`, and the app's terminal forwarded
`ESC[97;6u` (kitty's key-report: 97 = `a`, 6 = ctrl) followed by the literal `hi` line
the test mapped. Keys not expressible as an Emacs event (`Return`, `Tab`, `space`) are
passed through as xkb keysym names, which is what the daemon resolves.

Two traps worth remembering: `emacs-wm--key->binding` yields a *character* for
printable keys (the daemon needs the keysym *name*, so `"a"` not `?a`), and a rule is
`(MATCH ACTIONS-PLIST)`, so `:simulate` is read from `(cadr rule)`.

### Chords / submaps

river's `river_xkb_bindings_seat_v1` is now bound (`ensure_next_key_eaten`,
`cancel_ensure_next_key_eaten`, `ate_unbound_key`), the daemon has an `eat-next`
command queued into the manage sequence, and `ate_unbound_key` is forwarded as
`{"t":"key-unbound"}`.

`emacs-wm-submaps` defines one-shot submaps; their keys are bound *only while the
submap is active* (and unbound on exit), so they do not swallow typing the rest of the
time:

```elisp
(setq emacs-wm-submaps '(("test" . (("f" . emacs-wm-toggle-float)))))
(emacs-wm-enter-submap "test")   ; next key is eaten by river
```

Evidence: `entered submap "test" (2 keys)` -> `submap key "f" -> emacs-wm-toggle-float`
-> `after submap key: submap=nil`; and for the escape hatch
`unbound key eaten (leaving submap "test")`.

### Restart / resync

The daemon's `epoch` is now seeded from the wall clock instead of counting from 0 —
a counter restarted at 0 made a new daemon indistinguishable from the old one, so the
client never resynchronised. With that fixed, killing the daemon mid-session and
starting a new one gives:

```
--- resync: keeping 1 buffers, dropping window ids ---
re-attached "feat-app [kitty]" to wid 4278190085 via identifier "7c5357a1c2d2aff89c2e12214753ef65"
```

i.e. buffers survive, window ids are forgotten, bindings are re-registered, the daemon
re-sends windows/outputs on attach, and each window is matched back to its buffer by
`identifier`. Injection after the restart still lands (`injected r as keycode 19`).
The elisp reconnects on its own (`emacs-wm-auto-reconnect`, 1.5 s).

### Dynamic desktops and frame adoption

- `emacs-wm-desktops-per-output` (default 4) replaces the hardcoded 2; `s-1`..`s-9` and
  `s-S-1`..`s-S-9` are generated, so desktops 3, 4, ... work without new keys.
  Verified by switching 1 -> 3 -> 4 -> 1 and with 4 frames per output in both suites.
- Every frame Emacs already has is **adopted** as a desktop before a new one is
  created. Adopting only the selected frame left the others to be mirrored as "app"
  windows, which is the runaway documented in the previous section (a mirror's title
  feeding back into the frame title). Verified: `adopted existing frame as
  "wm-frame:4278190081:1"` followed by `created desktop frame ... :2 :3 :4`.

---

# 2026-11-15: rewritten as Emacs only (no Rust daemon)

Everything above describes the Rust `wm-poc` daemon (now `legacy/wm-poc`, kept as the reference and A/B baseline).
That daemon is now
**replaced by a second Emacs**; the protocol, the frontend and its features are
unchanged. Design and rationale: `EMACS-ONLY.md`. This section is only the
measured evidence, taken with `test/run-emacs-only-test.sh`.

## Why it was possible at all

- A Wayland window manager needs no buffer allocation, so none of the four
  river protocols carries an `fd` argument. Elisp can therefore speak them
  with `make-network-process` + hand-rolled framing (`lisp/emacs-wm-wl.el`).
- The one fd in the whole area is `zwp_virtual_keyboard_v1.keymap`, needed for
  injection. A fourth local river patch (`fix-vkb-keymap-fallback.patch`) lets
  river borrow the seat's keymap when a client cannot send one; verified with
  `wev` (`key: 44, sym: j, utf8: 'j'`, keymap size 35758) and by a kitty that
  received an injected `j` from a backend that never sent a keymap.

## Measured, one run

```
backend: listening -> connected -> seat + xkb_bindings_seat + virtual keyboard synced
         output 4278190080 non-exclusive area 1264x1386 at 0,0
         frame 1..4 recognised from wm-frame:4278190080:1..4
         handshake complete -> replaying state: 1 output(s), 4 window(s)
frontend: 21 layout generations, identical snapshots deduped
         kitty mirrored, floated by rule: float=t rect=(253 264 758 792)
         border-only change 2 -> 3 -> 2 applied
         inject ("j" "Return") -> injected j as keycode 36 / Return as 28
app:     j
state:   {"desktop":2,"desktops":4,"generation":21,"windows":{"2":1},
          "focus":{"frame":2,"window":4278190086}}
balance: manage_start 33..42 / manage_finish same / render_start same /
         render_finish same, over three consecutive runs
panics:  0
```

The sequence balance is the important number: every sequence river opened was
closed by the backend, which is what keeps river from freezing input.

## New failure modes found, not yet fixed

1. **river at `-log-level warning` never reaches a manage sequence.** The stock
   Rust harness reproduces it too (one panic line, no manages), so it is not
   caused by the Elisp backend. Same harness at `-log-level debug -log-scopes
   wm` passes.
2. ~~`close` does not complete~~ **retracted**: tested with `wev` instead of
   kitty, the full path works -- river logs `window 'wev' unmapped`, the
   backend receives `closed`, logs `window 4278190086 closed`, and the
   frontend's buffer goes away.  kitty in the test harness simply ignores
   `xdg_toplevel.close`, which is the client's behaviour.
3. A river panic still prints without the `aborting` line from
   `fix-silent-panic.patch`, i.e. some panic paths bypass the configured
   handler.
4. `wf-recorder` (the only screencopy client installed) produces no frame in a
   nested session, so borders and positions remain protocol-level evidence.

## Traps found while making it run

- A backend killed with SIGKILL leaves its Unix socket behind.  A frontend
  that trusts `file-exists-p` then connects to the corpse and reports
  `replaying state: 0 output(s)`.  The frontend now probes liveness by
  connecting, and unlinks a stale socket before spawning.
- `hash-table-keys` comes from `subr-x`; `emacs-wm.el` had been getting it
  transitively through `json.el`, so dropping the JSON transport broke the
  frontend's first `emacs-wm-enable`.

## Not yet re-verified with the Elisp backend

`test/elisp-multi.el` (two outputs), `test/elisp-features.el` (chords,
per-app simulate, daemon restart, state file), and real physical key presses.

---

# 2026-11-15 (later): multi-output, features, warning level, and a runaway

All three suites now run against the Elisp backend (`test/run-emacs-only*.sh`).

## Multi-output: pass

```
output 4278190080 usable 1264x1386 at 0,0      output 4278190081 at 1264,0
8 frames: wm-frame:4278190081:1..4 and wm-frame:4278190080:1..4
switch ...81 only -> ...80 keeps its desktop
switch ...80 back to desktop 1 -> focused wid = the app (revealed again)
switch ...80 to desktop 2      -> focused wid = nil (hidden, by design)
inject                         -> app received "o"
move app to desktop 3          -> focused wid = app, desktop 3
final: ...81 -> 2, ...80 -> 3;  sequences 34/34; panics 0
```

Two bugs had to be fixed for this to be meaningful:

- **Startup race**: before the first layout every desktop frame is mapped and
  stacked, so `pointer_enter` landed on a random frame and `emacs-wm--focus-wid`
  switched the output to *that* desktop (desktops started at 2, not 1). The
  frontend now ignores `pointer-enter` for a frame that is not the visible
  desktop of its output (`pointer entered ... but output ... shows ...: ignored`).
- **Hidden windows were being resized**: a window on a desktop that is not
  shown is sent with `w=0 h=0`, and the backend was proposing 1x1 to it, which
  made the client resize itself into nothing (one kitty exited). Hidden windows
  now only get their border applied; geometry is left alone until they are
  shown.

## Features: pass

```
simulate s-w -> injected a as keycode 30 (mods=0x4) -> app received ^A h i
submap: entered "test" (2 keys) -> key "f" -> emacs-wm-toggle-float -> submap nil
unbound key eaten -> submap nil
backend killed -> respawned by the frontend (new epoch, "replaying state")
resync: keeping 1 buffers -> re-attached "feat-app [kitty]" via identifier
post-restart inject "r" -> app received r
sequences 40/40; panics 0
```

The "daemon restart" step now restarts the *backend Emacs*, and the frontend's
supervision recovers by itself (liveness probe -> spawn -> hello -> replay ->
reattach by identifier).

## `-log-level warning`: fixed (river patch #5)

Symptom: at warning level the session wedged after ~19 manage sequences, with
one `panic: attempt to use null value` line and no further processing (input
dead).  At debug it never happened.

Backtrace at the panic (breakpoint on the `unwrapNull` panic trampoline):

```
TextInput.handleCommit  river/TextInput.zig:79  (log.err "inactive text input ...")
log.scoped(.input).err
main.logFn              river/main.zig:351
log.defaultLog          std/log.zig:106
debug.lockStderr        std/debug.zig:302
Io.Threaded.lockStderr  -> panic: attempt to use null value
```

Logging from a wlroots callback panics inside Zig's locked-stderr path; panicFn
then recurses into the same lock, so nothing aborts and the compositor stays
alive but frozen.  `fix-log-callback-panic.patch` makes `logFn` write with
`std.os.linux.write` (no lock, no `Io`) and keeps `level(scope): message`.
Afterwards, two consecutive `-log-level warning` runs: `j` delivered, 29/29
sequences, 0 panics.

## Runaway Emacsen: post-mortem and prevention

Five test Emacsen were found at ~100% CPU.  They were **orphaned frontends**:
the drivers killed `river` but not the Emacs in its session, and since every
nested river reuses `wayland-1`, a later session's Emacs could attach to the
new river while the old one was still alive -- several WMs driving one session,
each pushing layouts (and a pgtk Emacs whose compositor vanished spins).

Prevention, three layers:

1. session scripts trap `EXIT/TERM/INT/HUP` and watch the compositor socket's
   inode; if it disappears or is replaced they exit and kill their Emacs.
   Measured: 0 of our processes left 2 s after `kill -9` of the compositor.
2. every driver runs `test/cleanup-ours.sh` before and after, and prints
   `test/check-leftovers.sh` at the end, which must say `(none)`.
3. the backend main loop never busy-waits: if `accept-process-output` returns
   without output and the Wayland connection is gone, it exits; otherwise it
   sleeps.  A leftover backend cannot pin a core.

`test/check-leftovers.sh` matches only our paths and never a bare `emacs`, so
the user's own Emacs is never at risk.  It is the check to run after any
session.

## River patch series

Five patches now, each applying to pristine `HEAD` on top of the previous ones:
`fix-stale-environ`, `fix-silent-panic`, `fix-vkb-active-keyboard`,
`fix-vkb-keymap-fallback`, `fix-log-callback-panic`.  Verified as a series in a
clean worktree.

---

# 2026-11-15 (third session): watchdog, real keys, hotplug, ops, stacking

Implemented in the order agreed: liveness watchdog, then verification, then
interactive move/resize, then pointer bindings / stacking / decoration.

## Key presses were never actually reaching Emacs

`test/keyinject` (new, Rust, test-only) types into a session through
`zwp_virtual_keyboard_v1` *with a keymap fd*, so river attaches it as an
ordinary input device and the keys go through river's own binding matching
(`river_xkb_binding_v1.pressed`), not through WM injection.  The first run
showed keys arriving and being pushed as events -- and nothing happening.  Cause:

```elisp
(define-key global-map key (lookup-key emacs-wm-command-map name))
```

`lookup-key` was given the *string* "s-2", i.e. the three characters s, -, 2,
so it returned nil and `define-key` **unbound** the key.  No WM command was
ever bound; every previous key test had called the commands directly instead of
pressing a key.  Fixed to look up the key sequence.  After that, with real
presses:

```
key bid 5 -> event 8388658      (Super+2)
output 4278190080 -> desktop 2 ("wm-frame:4278190080:2")
CMD emacs-wm-toggle-float       (Super+f)
keyinject: keycode 33 mods 0x40
app received: a b \n  ... then c \n after switching back
```

The same run also fixed the modifier bitmap in the injection helper (the old
Rust PoC sent `modifiers(1, mask, 0, 0)`, holding Shift and latching the real
modifiers; it is `modifiers(depressed, latched, locked, group)`).

## Watched backend liveness

`emacs-wm-ping-interval` / `-timeout` / `-max-respawns`: the frontend pings,
and a missing pong means the backend is *wedged*, not busy.  Test: SIGSTOP the
backend.

```
10s (healthy): epoch=3786252911 pongs=3 buffers=((4278190086 . "wedge-app"))
--- stopping the backend with SIGSTOP (wedged, not dead) ---
WEDGED: no pong for 3.0s (1 outstanding); restarting backend
restarting backend (attempt 1 of 5)
20s: epoch=3786272672 pongs=4 respawns=1 buffers=((4278190085 . "wedge-app"))
after recovery: inject -> app received c
```

New epoch, buffer kept, window reattached by identifier, no user action.

## Hotplug (frontend side)

A nested output is a host window and river has no output-management protocol,
so `river_output_v1.removed` cannot be produced here.  Feeding the frontend the
event it would send:

```
5s: oids=(...80 ...81) frames=8
removing output ...81 (synthetic output-removed)
9s: oids=(...80) frames=4
12s: new app mirrored on the survivor; inject -> app received h
```

## Interactive move/resize

`Super+F7` (move) / `Super+F8` (resize) or `Super`+left/right button.  The
frontend sends `op-start`; the backend queues `op_start_pointer` for the next
manage sequence (window-management state), applies river's *cumulative*
`op_delta` during render, and reports the final rect with `op-done`; the
frontend stores it and floats the window.

```
op move started for window 4278190086 at (253 264 758 792)
river op_start_pointer for 4278190086
op_delta (0 . 0)
river op_end for 4278190086
op move finished for window 4278190086: (253 264 758 792)
op-done: wid 4278190086 now at (253 264 758 792)
... inject -> app received m
```

Two traps: river sends an `op_delta` for *every* manage sequence while an op is
live, repeating the same cumulative value, so requesting a sequence on every
delta is a self-sustaining loop (it pinned a core at ~500 sequences/second until
the rect comparison was added); and river's `.end` cancels the op without
sending `op_release`, so the backend must finalise it itself.

Pointer *motion* was, at the time of this section, unverified: there was no
virtual-pointer client yet.  It is verified in the fourth-session section
below (`pointerinject`, a real drag by +200/+120 and a resize).
The geometry is covered by `test/run-be-tests.sh` (27 ERT tests), which caught
a second real bug: the US keycode table treated ``` ` ``` and `\` as contiguous
with the rows beside them, so every digit and the `z`-row punctuation were off
by one.

## Stacking and decoration

- `order[]` (bottom->top) in the layout; raise-on-click, `s-<up>`/`s-<down>`,
  applied with one `place_top` pass.
- rules may ask for `:decor "csd"`/`"ssd"`; the backend calls
  `use_csd`/`use_ssd` once per change.  The client's `decoration_hint` is
  forwarded as a `decor` event.

## All suites, after these changes

| suite | result |
|---|---|
| `run-emacs-only-test.sh` | 31/31 sequences, `j` delivered, 0 panics |
| `run-emacs-only-multi-test.sh` | 34/34, `o`, 0 panics |
| `run-emacs-only-keys-test.sh` | real keys: `a b`, `c`, desktop switches, 0 panics |
| `run-emacs-only-hotplug-test.sh` | `h` on the surviving output, 0 panics |
| `run-emacs-only-ops-test.sh` | op lifecycle + `op-done`, `m`, 0 panics |
| `run-emacs-only-wedge-test.sh` | SIGSTOP -> detect -> respawn -> `c`, 0 panics |
| `run-emacs-only-features-test.sh` | 42/42, `^A h i`, resync, `r`, 0 panics |
| `run-be-tests.sh` | 27/27 ERT |
| leftovers after every run | none |

# 2026-11-15 (fourth session): pointer motion, border pixels, session lock

The three things asked for in this order: move a window with a real pointer,
*see* the borders, and handle ext-session-lock.

## Pointer motion: pass

`test/tools/pointerinject` (zwlr_virtual_pointer_v1, its own crate since v1 has
no `-m MOD` shortcut) drags with button 272 while holding Super, so river itself
decides the pointer binding fires.  Move by +200/+120, then resize by +100/+80:

```
pointer binding 501: button 272 mods 0x40
pointer binding 501 pressed on window 4278190086
op move started for window 4278190086 at (8 0 1232 621)
op move finished for window 4278190086: (208 120 1232 621)
op resize started for window 4278190086 at (208 120 1232 621)
op resize finished for window 4278190086: (208 120 1332 701)
op-done: wid 4278190086 now at (208 120 1332 701)
14s (after the drag): focused=4278190086 override=(208 120 1232 621) float-override=t
```

The screenshot of the same run shows the focused border at the new place and
none at the old one.  Nothing in the Elisp changed to make this work: the
geometry path was already unit-tested (`test/run-be-tests.sh`), only the
*witness* was missing.

## Border pixels: pass, and it found a real bug

`test/tools/screenshot` (zwlr_screencopy, needs an fd, hence native) captures
the output; the driver samples the border pixels of both tiled windows in both
focus states.  River draws borders *outside* the window box, so the sample is
`(x-1, y+h/2)` etc.

```
wid ...086 focused=False left   (7,310)  pixel=(59, 66, 97)   want=(59, 66, 97) OK
wid ...086 focused=False right  (1240,310) pixel=(59, 66, 97) want=(59, 66, 97) OK
wid ...087 focused=True  left   (7,961)  pixel=(122, 162, 247) want=(122, 162, 247) OK
wid ...087 focused=True  right  (1240,961) pixel=(122, 162, 247) want=(122, 162, 247) OK
wid ...087 focused=True  top    (624,640) pixel=(122, 162, 247) want=(122, 162, 247) OK
```

13/13 samples per capture, both focus states, twice in a row.

Looking at pixels found two long-standing bugs that protocol-level evidence
could never show:

1. `set_clip_box` clipped river's *own* border rects away: river intersects the
   window clip with the border rects, and the borders sit outside the window
   box.  The WM now uses `set_content_clip_box`, which clips the client's buffer
   only.
2. Clipping to the client's last reported size let a client that was still
   mid-resize draw over the right/bottom borders.  The clip is now the layout
   rect.

## Session lock: pass, lock *and* unlock

Locking (as before): `test/tools/lockclient` takes an ext-session-lock lock and
paints every output `#202020`; the WM refuses focus changes, injection and
ordinary bindings.

```
info(lock): session locked                      <- river's own decision
session locked: focus and injection suspended   <- backend
session locked                                  <- frontend
inject ("x" "Return") refused: session locked
key "s-2" ignored: session locked
locked screen: lock-colour 100% of samples, border-colour 0 samples
```

Unlock used to fail twice over, and neither failure was where it looked.

**Failure 1, the client.**  `lockclient` called `unlock_and_destroy()`, flushed
and exited.  Exiting that fast can close the socket before river has read the
request, and then nobody can unlock the session.  The client now waits for a
roundtrip after the flush.

**Failure 2, the WM (the real one).**  Even with the unlock delivered, the
injected key vanished:

```
session unlocked
inject ("u" "Return")     <- frontend sent it, backend injected it
(then nothing reached the app)
```

River clears the seat's keyboard focus when the session locks (`LockManager`
`seat.focus(.none)`) and again on unlock.  The WM kept its own record of the
applied focus, so after the unlock `reconcile-focus` saw "already focused" and
sent no `focus_window` at all: river's seat focused nothing, and every injected
key went to the void.  Fix: forget the applied focus when the lock engages, and
ask for a manage sequence when it releases.

```
info(lock): session locked
info(lock): session unlocked
session unlocked
session unlocked
focus -> window 4278190086                      <- 1 ms later, re-asserted
injected u as keycode 22 (shift=nil, mods=0)
injected Return as keycode 28 (shift=nil, mods=0)
app received: u \n
locked screen:   lock-colour 100% of samples, border-colour 0
unlocked screen: lock-colour 0%, border-colour 782 samples  (the scene is back)
```

`test/run-emacs-only-lock-test.sh` now ends in seven explicit verdicts instead
of a dump, so a half-working lock cannot look like a pass.

**Third finding, from the drive to make the lock test repeatable.**  One run in
seven never got `locked` from river at all, and the client died with
`Protocol error 1 ...: the locked event was never sent`.  That is the protocol
telling the truth: `unlock_and_destroy` is only legal *after* `locked`, so a
compositor that never presented a lock surface or blank frame (a nested host
that stops presenting for a moment can do this) must be released with plain
`destroy`.  The client now tracks whether `locked` arrived and chooses the right
request; that run would now end with "compositor never sent locked, destroying
the lock" and visible MISMATCH verdicts rather than a confusing failure.

Six consecutive lock runs after these fixes: `session locked`, `session
unlocked`, `u` delivered, 7/7 verdicts OK.

## Test tooling fixes found on the way

- The visual suite silently reported a missing capture as a border failure when
  `screencopy` timed out; it now retries once and the driver waits for the
  retry.  Two consecutive runs: 14/14 samples OK.
- `run-emacs-only-lock-test.sh` asks river for the `lock` and `output` scopes,
  so river's own `session locked`/`session unlocked` lines are in the evidence
  instead of being filtered out by `-log-scopes wm`.

## All suites, after these changes

| suite | result |
|---|---|
| `run-emacs-only-test.sh` | 31/31 sequences, `j` delivered, 0 panics |
| `run-emacs-only-multi-test.sh` | 34/34, `o`, desktops independent, 0 panics |
| `run-emacs-only-keys-test.sh` | real keys: `Super+2`, `Super+f`, typed `a b`, 0 panics |
| `run-emacs-only-hotplug-test.sh` | `h` on the surviving output, 0 panics |
| `run-emacs-only-ops-test.sh` | op lifecycle + `op-done`, `m`, 0 panics |
| `run-emacs-only-pointer-test.sh` | move +200/+120, resize +100/+80, 0 panics |
| `run-emacs-only-visual-test.sh` | 14/14 border pixels, both focus states, 0 panics |
| `run-emacs-only-wedge-test.sh` | SIGSTOP -> detect -> respawn -> `c`, 0 panics |
| `run-emacs-only-features-test.sh` | 42/42, `^A h i`, resync, `r`, 0 panics |
| `run-emacs-only-lock-test.sh` | locked, refusals, unlocked, `u`, 7/7 verdicts |
| `run-be-tests.sh` | 27/27 ERT |
| leftovers after every run | `(none)` |

# 2026-11-15 (fifth session): configuration file and login-session entry

Policy moved out of the code into one Elisp file, and the WM got a real
session entry point.  Two questions drove the design: *can a config file bind a
key to a command that does not exist?* and *does the session path a greeter uses
actually bring the WM up?*  Both are now answered by tests.

## Configuration: one file, one binding list

Before this session a key had to be written in three places to work: the
`emacs-wm-command-map` defvar, `emacs-wm--command-keys`, and
`emacs-wm-intercepted-prefixes` (whose desktop entries were also generated
again by `emacs-wm--desktop-key-names`).  Miss one and the key either never
reached Emacs or never reached river.

Now `lisp/emacs-wm-config.el` is the built-in default and
`$XDG_CONFIG_HOME/emacs-wm/config.el` overrides it; the code keeps only
mechanism.  Registration is derived from `emacs-wm-key-bindings`, so a bound key
is an intercepted key:

```
registered "s-1" as bid 1  ... registered "s-<f12>" as bid 19
registered "s-<f9>" as bid 20            <- added by the user configuration
registered "C-x" as bid 21 ... registered "M-x" as bid 23
registered "s-t" as bid 24 ... registered "s-<next>" as bid 29   <- :simulate
```

and the backend asked river for exactly those keysyms:

```
binding 2 = s-2 (keysym 0x32 mods 0x40)
binding 9 = s-f (keysym 0x66 mods 0x40)
binding 20 = s-<f9> (keysym 0xffc6 mods 0x40)
binding 24 = s-t (keysym 0x74 mods 0x40)
```

A name that does not resolve is an error when bindings are applied, not a key
that arrives and does nothing:

```
emacs-wm: no command "no-such-command" in `emacs-wm-commands'
```

`M-x emacs-wm-reload-config` re-loads, rebuilds the keymap, re-defines the
global keys, unbinds the previously registered bids and registers the new ones,
so a key removed from the file stops being intercepted instead of swallowing
presses.

## Firefox `:simulate` samples, and why they can be Emacs keys

`:simulate` exists to map an **Emacs binding** to the key an application
expects, so the first version of the samples -- which used Super keys -- was
wrong about the feature's purpose.  The shipped rules are now:

```
C-v -> <next>    M-v -> <prior>   C-s -> C-f   C-l -> C-l
C-w -> C-w       C-t -> C-t       C-a -> C-a   M-x -> C-l
```

Making that safe needed one new rule in `emacs-wm--handle-key`.  C-v, C-a, C-t
and friends are keys *every* application uses; if the WM intercepts them to
translate them for Firefox, a terminal would stop receiving Ctrl+V.  A press is
now handled in this order:

1. a `:simulate` rule for the focused window -> translate and inject;
2. a WM binding -> run its command;
3. a key that some rule translates but this window has no rule for -> inject
   the key unchanged (pass-through);
4. everything else (`C-x`, `M-x`, ...) -> an Emacs event, as before.

Step 3 is what lets the same key mean "page down" in Firefox and "paste" in a
terminal.  Measured with two terminals (one matched by a rule, one not) and
real key presses through river's binding matching:

```
focusing "mapped" -> 4278190086
--- pressing C-t
simulate ("C-a" "m" "Return") as [(:name "a" :mods 4) (:name "m" :mods 0) (:name "Return" :mods 0)]
focusing "plain" -> 4278190087
--- pressing C-g
no "C-g" rule for this window: passing the key through
simulate ("C-g") as [(:name "g" :mods 4)]

mapped window received: 001 m \n     (the translation)
plain window received:  \a \n       (C-g itself: 0x07)
```

`C-g` is the pass-through probe because a terminal does not treat it specially;
`C-t` would have been swallowed by Linux's VSTATUS, and the first attempt at
this test failed for exactly that reason (an app that writes only complete
lines also needs a Return after a bare control character).

Two more details found while making the rules real:

- `(kbd "F5")` is the two characters `F` `5`, not the function key, so
  `emacs-wm--key->binding` returns nil for it and the binding silently never
  registers.  Function keys must be written `"<f5>"`.  The same trap applies to
  any `"s-F5"` a user might write; the configuration tests now check that every
  bound key and every `:simulate` key is expressible.
- `M-x` is both an intercepted prefix and a Firefox simulation.  The rule wins
  while Firefox is focused (the address bar is the closest thing to a command
  prompt), and every other app still gets `M-x` in Emacs.  Five ERT tests pin
  the precedence: rule, WM binding, pass-through, prefix.

## Session entry point

`contrib/emacs-wm.desktop` -> `contrib/emacs-wm-session` -> (`river` runs it
back with `--wm`) -> `emacs -l emacs-wm-session`, which loads the user
configuration, enables the WM and runs the autostart list.  The script sets
`XDG_CURRENT_DESKTOP=emacs-wm`, puts session/frontend/backend logs in
`$XDG_STATE_HOME/emacs-wm/`, and keeps the orphan watchdog: if the compositor
socket disappears or is replaced, Emacs is taken down with it.

`test/run-session-test.sh` drives that path in a nested session with a
temporary `XDG_CONFIG_HOME`/`XDG_STATE_HOME` and a temporary configuration:

```
OK       session script ran and logged
OK       frontend loaded the user configuration
OK       WM connected to river as the window manager
OK       shipped binding became an intercepted key
OK       the configuration's extra binding became an intercepted key
OK       the firefox :simulate keys are intercepted too
OK       layout applied
OK       autostart suppressed by the configuration
```

Autostart is deliberately `("noctalia")` in the shipped configuration and nil
in that temporary one: a nested test session must not spawn the user's live bar,
and "the list came from the config file" is exactly what the last verdict
proves.

Logout is a new `exit-session` message (frontend) -> `river_window_manager_v1.exit_session`
(backend), bound to `s-<f12>`.  It is legal outside a manage sequence, so it
needs no queueing.

## Coverage added

`test/run-config-test.sh`: 22 ERT tests, no compositor.  They check that every
command entry is well formed, every binding resolves to a command, keys are
unique and expressible, the firefox rules translate (and do not leak to other
apps), unknown names error, `(FUNCTION . ARGS)` bindings arrive with their
arguments, the user file overrides the defaults, a missing file is not an error,
a reload replaces rather than appends, and -- driving `emacs-wm--handle-key`
with a stubbed backend -- that the four-way key precedence holds (rule, WM
binding, pass-through, Emacs event).

## All suites, after these changes

| suite | result |
|---|---|
| `run-config-test.sh` | 22/22 ERT (configuration, incl. key precedence) |
| `run-be-tests.sh` | 27/27 ERT (backend) |
| `run-emacs-only-test.sh` | 31/31 sequences, `j`, 0 panics |
| `run-emacs-only-multi-test.sh` | 34/34, `o`, desktops independent |
| `run-emacs-only-keys-test.sh` | `Super+2` -> desktop 2, `Super+f` -> toggle-float, `a b`/`c` |
| `run-emacs-only-hotplug-test.sh` | `h` on the surviving output |
| `run-emacs-only-ops-test.sh` | op lifecycle, `m` |
| `run-emacs-only-pointer-test.sh` | move +200/+120, resize +100/+80 |
| `run-emacs-only-visual-test.sh` | 14/14 border pixels |
| `run-emacs-only-wedge-test.sh` | SIGSTOP -> respawn -> `c` |
| `run-emacs-only-features-test.sh` | 42/42, `^A h i`, resync, `r` |
| `run-emacs-only-lock-test.sh` | 7/7 verdicts |
| `run-session-test.sh` | 8/8 verdicts |
| `run-emacs-only-simulate-test.sh` | 4/4 verdicts (translation and pass-through) |
| leftovers after every run | `(none)` |

# 2026-11-15 (sixth session): relocatable drivers, no paths into one home

The drivers had the development machine baked in (`~/src/emacs-wm`,
`~/src/river/zig-out/bin/river`, `/run/user/<uid>`).  A checkout now
derives everything from its own location:

```
test/lib.sh        REPO, LISP, TOOLS, RUNTIME_DIR, RIVER (EMACS_WM_RIVER, then
                   ../river/zig-out/bin/river, then $PATH), need_tool NAME
```

- Drivers `. "$(dirname "$0")/lib.sh"`, `cd "$REPO"`, `require_river`, and use
  `"$RIVER"`, `"$SESSION_SCRIPT"`, `clear_sockets`, `state_file`.  Scenarios get
  the helper directory from `EMACS_WM_TEST_TOOLS`, with a `load-file-name`
  fallback so one can be loaded by hand.
- `test/run-emacs-only.sh` resolves `EMACS_WM_TEST_EL` as a bare name against
  `test/`, so drivers no longer pass absolute paths.
- `test/cleanup-ours.sh` uses the same derivation: it kills only processes whose
  arguments mention *this* checkout's `lisp/` or `test/` directory, matched by
  literal substring on the executable's own name (`emacs*` or `river`).  Two
  consequences: a session running from another checkout survives a test run, and
  `pkill -x river` (which would kill a live session) is gone from the live
  drivers.  The retired wm-poc-era drivers keep theirs and now say so in a
  comment.
- `contrib/emacs-wm.desktop` runs `Exec=emacs-wm-session` (looked up on `$PATH`,
  like river's own session file), and `contrib/emacs-wm-session` resolves
  symlinks so `~/.local/bin/emacs-wm-session` finds its checkout.

Verified by exporting the tree to a directory that has nothing to do with the
original and running a full nested suite there, with river found through a
sibling symlink and `keyinject` built on demand:

```
copy at /tmp/reloc-test-parent/emacs-wm
REPO=/tmp/reloc-test-parent/emacs-wm
RIVER=/tmp/reloc-test-parent/emacs-wm/../river/zig-out/bin/river
OK       the rule translated C-t in the mapped window
OK       the mapped app received the translation (^A m)
OK       the unbound window got the key passed through
OK       the plain app received C-g itself (^G, 0x07)
leftovers: (none)
```

## The lock test's timing assumption, removed

A battery run hit the environment flake again: river logged `waiting for lock
surfaces timed out`, and the lock client's 8 s hold expired before the
compositor confirmed the lock, so it released with `destroy` (correct) and the
suite failed with five MISMATCHes.  Nothing was wrong with the WM -- the nested
host had simply been slow to present a frame.

Both sides now avoid the race:

- `lockclient` waits up to 6 s for `locked` *before* starting its hold, and says
  `no locked event within 6s` if it never comes;
- `test/elisp-lock.el` watches `emacs-wm--locked` with a 0.25 s timer and runs
  the refusal checks when the lock actually engages, and the post-unlock
  injection when it actually releases, instead of at absolute 11 s/19 s marks.

Four consecutive runs of `run-emacs-only-lock-test.sh`: 8/8 verdicts each, and
the extra verdict `lock client confirmed the lock` makes a client that never got
`locked` a visible failure rather than a mysterious one.
