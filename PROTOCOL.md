# emacs-wm — daemon ↔ elisp protocol, v0

Design notes for an Emacs window manager on river 0.6 (`river-window-management-v1` v6).
The backend Emacs is the Wayland client; the frontend Emacs is the
layout/policy engine.

Status: implemented twice.  Originally by `wm-poc` (Rust); since 2026-11-15 the
WM client is a second Emacs (`lisp/emacs-wm-be.el` + `lisp/emacs-wm-wl.el`) and
the transport between the two Emacsen is one printed sexp per line instead of
NDJSON.  Message semantics below are unchanged; see `EMACS-ONLY.md` for why a
pure-Elisp client is possible and what it costs.  Verified against river main @ 85b0088
(`river_window_manager_v1` v6, `river_xkb_bindings_v1` v3,
`river_virtual_keyboard_manager_v1` v1, `zwp_virtual_keyboard_manager_v1` v1).

---

## 1. Goals and non-goals

Goals

- Emacs is never in the input or frame hot path. River must be able to answer
  every manage/render sequence from the daemon's cached state, even while Emacs
  is garbage collecting or blocked in `call-process`.
- Either process can die and restart without taking the other with it. That is
  the whole selling point of the river split; throwing it away by putting Emacs
  in the WM slot as a hard dependency would be a waste.
- Simulation keys ("replay this key sequence into the focused client") work
  atomically with focus changes, using `river_virtual_keyboard_manager_v1`.

Non-goals

- Synchronous RPC from Emacs into the daemon. There is exactly one request/response
  pair (`hello`), plus `ping`. Everything else is one-way.
- Exposing input/output configuration (libinput, kanshi's job) or layer shell
  *management* to elisp in v0. Layer surfaces are consumed as hints only (§6.4).
- Emacs-side rendering of borders/decorations. v0 uses no decorations; client-side
  decorations are refused (`use_csd`) unless elisp asks otherwise later.

## 2. Process model

```
river (compositor, owns input routing, rendering, frame deadlines)
  └─ wm-daemon          (the active `river_window_manager_v1` client)
       └─ /run/user/1000/emacs-wm.wayland-0.sock
  └─ emacs              (connects to the socket; owns layout + keymap policy)
       └─ frames/windows (one frame per desktop, app buffers inside)
  └─ noctalia (Quickshell)  ← zwlr_layer_shell_v1, never managed by the WM §6.4
```

- Started as `river -c wm-daemon`. The daemon must **create the socket before**
  binding `river_window_manager_v1`, so an already-running Emacs attaches before
  the first manage sequence.
- Socket path: `$XDG_RUNTIME_DIR/emacs-wm.$WAYLAND_DISPLAY.sock`
  (per-session, so nested test sessions do not collide).
- One client at a time. A new connection replaces the old one (restart semantics
  in §8).

Lifetimes

| killed | consequence |
|---|---|
| daemon | river keeps serving; windows stay at their last state because river keeps client state and only the WM object goes away. Emacs sees EOF. On rebind, river **re-sends every window** (`Window.manageStart`, `window.object == null` → `sendWindow`, with an explicit "if the window manager is restarted" comment). |
| Emacs | daemon keeps the last layout and keeps answering sequences. Windows do not move. `ping` timeouts get logged, nothing else. |
| river | daemon sees `bye`/EOF, exits; elisp deletes its frames. |

## 3. Transport and framing

Unix stream socket, UTF-8, **newline-delimited JSON**: one object per line, no
embedded raw newlines (JSON escapes them). Rationale: `json-parse-string` /
`json-serialize` are C-speed in Emacs 30+, and NDJSON needs ~10 lines of framing
code on each side instead of a length prefixer.

- Max line: 1 MiB. Receiver treats overflow as fatal for the connection.
- Integers only for geometry (river's logical coordinate space, int32).
- Elisp side parses into plists (`:object-type 'plist`) for speed.
- Unknown keys must be ignored; unknown `t` values must be ignored with a log
  line, so either side can add messages without a handshake bump.
- `v` (protocol version) is checked only in `hello`.

## 4. Messages

Common envelope: `{"v":0,"t":"<type>", ...}`. Events and commands share the
namespace; direction is implied by the type.

### 4.1 Daemon → Emacs

| `t` | payload | notes |
|---|---|---|
| `hello` | `epoch`, `daemon`, `caps[]` | first message on every connection; `epoch` = daemon process instance counter |
| `window` | `wid`, `identifier`, `app_id?`, `title?`, `pid?`, `parent?`, `hint{min_w,min_h,max_w,max_h}`, `csd` | new window; `identifier` is the stable key (see §8) |
| `gone` | `wid` | window destroyed |
| `title` | `wid`, `title` | coalescable |
| `app-id` | `wid`, `app_id` | coalescable |
| `size` | `wid`, `w`, `h` | actual content size, used for clipping; coalescable |
| `request` | `wid`, `kind` | `minimize｜maximize｜unmaximize｜fullscreen｜exit-fullscreen｜show-menu｜move｜resize` |
| `decor` | `wid`, `hint` | `none｜client｜server` |
| `output` | `oid`, `name?`, `x`, `y`, `w`, `h`, `usable{x,y,w,h}`, `scale`, `transform` | output geometry changed/added; `usable` is `river_layer_shell_output_v1.non_exclusive_area` (global coords, after bar exclusive zones) |
| `output-gone` | `oid` | |
| `frame` | `fid`, `name`, `oid`, `wid` | one of **our own** Emacs frames (title prefix match, §6.1); `name` is the correlation key Emacs assigned, `wid` is the frame's own window id so clicks on a frame can focus it |
| `frame-gone` | `fid` | frame surface destroyed |
| `layer-focus` | `kind` | `exclusive｜non-exclusive｜none` — a bar/layer surface took, borrowed, or released keyboard focus (§6.4) |
| `pointer-enter` | `wid` | click-to-focus input; river has no focus event (focus is WM state) |
| `pointer-leave` | `wid` | |
| `pointer-bind` | `bid`, `wid` | a `river_pointer_binding_v1` fired; `wid` is the window under the pointer, `bid` echoes the id Emacs registered |
| `op-done` | `wid`, `x`, `y`, `w`, `h` | a move/resize op finished; the rect is final and the window is floated |
| `locked` | `on` | `river_window_manager_v1.session_locked`/`session_unlocked`; while on, focus, injection and ops are refused. River clears the seat's keyboard focus on both transitions, so the backend forgets its applied focus when the lock engages and re-asserts it after `on` false |
| `key` | `bid`, `state` | `press｜release`; `bid` echoes the id Emacs registered |
| `key-unbound` | – | `ate_unbound_key`: the eaten key matched no binding; exit submaps |
| `modifiers` | `old`, `new` | bitmask as in `river_seat_v1.modifiers` |
| `focus-done` | `wid?` | confirmation of the focus the daemon actually applied |
| `ping` | `n` | liveness/backpressure probe |
| `log` | `level`, `msg` | daemon diagnostics, mirrored into `*emacs-wm-log*` |
| `bye` | `reason` | `river-exit｜session-locked｜superseded｜shutdown` |

### 4.2 Emacs → daemon

| `t` | payload | notes |
|---|---|---|
| `hello-ack` | `v`, `epoch` | refusal of a mismatched `v` is a connection close |
| `layout` | `epoch`, `gen`, `focus`, `frames[]`, `windows[]`, `order[]` | **full snapshot**; see §4.3 for the shape |
| `bind` | `bid`, `key{code｜name,sym?}`, `event`, `override?` | `event` is an opaque Emacs event descriptor echoed back in `key` |
| `unbind` | `bid` | |
| `inject` | `keys[]{code,state}`, `mods{depressed,latched,locked}` | queued, flushed at the next `manage_finish` |
| `window-cmd` | `wid`, `cmd` | `close｜minimize｜fullscreen｜toggle-fullscreen｜focus｜toggle-float` |
| `pong` | `n` | |
| `quit` | – | ask the daemon to exit (development aid) |
| `exit-session` | – | forward river's `river_window_manager_v1.exit_session`: the compositor terminates and the session ends. Legal outside a manage sequence |

### 4.2b `output` / `output-removed` / `pointer`

| message | fields | meaning |
|---|---|---|
| `output` | `oid`, `x`, `y`, `w`, `h`, `usable{x,y,w,h}` | an output the WM may place frames on; `usable` is `river_layer_shell_output_v1.non_exclusive_area` in **global** coordinates |
| `output-removed` | `oid` | the output is gone; Emacs deletes that output's desktop frames and its windows are re-homed |
| `pointer` | `x`, `y`, `oid` | sent only when the pointer moves to a *different* output, not on every motion; it decides which output `s-1`/`s-2` act on and where new windows open |

### 4.3 `layout` snapshot

```json
{"t":"layout","epoch":1,"gen":7,
 "focus":{"frame":41,"window":12},
 "frames":[{"fid":0,"oid":1,"visible":true,"x":0,"y":0,"w":1920,"h":1032},
           {"fid":1,"oid":1,"visible":false,"x":0,"y":0,"w":1920,"h":1032}],
 "windows":[{"wid":12,"frame":0,"x":0,"y":0,"w":960,"h":1032,"visible":true,
             "border":{"w":2,"edges":15,"r":2054847098,"g":2728567458,"b":4160223223,"a":4294967295}},
            {"wid":13,"frame":1,"x":0,"y":0,"w":1920,"h":1032,"visible":false},
            {"wid":14,"anchor":"output","oid":1,"x":1180,"y":120,"w":640,"h":480,
             "visible":true,"float":true}],
 "order":[0,12,14]}
```

- `frames[].fid` — container ids owned by Emacs (stable for the life of the
  connection). `{x,y,w,h}` are output-relative; `w,h` should normally be the
  output's `usable` rect, so a noctalia bar at the top just works. When `rect` is
  omitted the daemon uses the usable area of the frame's own output.
- `frames[].oid` — the `river_output_v1` id this frame lives on (§6.6). Emacs
  takes it from the `output` messages, so it never has to reason about output
  origins: the daemon adds the output origin for each frame.
- `windows[].border` — compositor-drawn border, passed through verbatim to
  `river_window_v1.set_borders`. All policy (width, edges, focused vs unfocused
  colour, per-rule overrides) is in Emacs; the daemon only dedupes and applies,
  and river hides borders by itself while a window is fullscreen. `edges` is a
  bitmask (top 1, bottom 2, left 4, right 8); RGBA components are 0..0xffffffff,
  i.e. 100% = `0xffffffff`.
- `windows[].frame` — frame-relative rect of an app window that is mirrored into
  an Emacs window (§6.2).
- `windows[].anchor:"output"` — an **unmirrored / floating** window: positioned
  output-relative, never clipped to an Emacs window, tiled flag cleared, stacked
  per `order[]` (§6.3).
- `windows[].float` — request floating behaviour for a framed window too (still
  mirrored, just not tiled: no dimension proposals conditioned on grid math).
- `order[]` — bottom→top, may mix frame ids and window ids.
- `focus` — `{"frame":fid}` to focus Emacs itself on that desktop, or
  `{"frame":fid,"window":wid}` to focus an app window. Omitting `window` is how
  "desktop has no windows" is expressed.
- `visible:false` hides a surface without unmapping it (see §6.1 for why that
  distinction matters).
- Borders take part in the "identical snapshot" check: a *focus-only* change alters
  nothing but the border colour, and dropping it as a no-op would leave stale
  borders. Applying borders must also happen before the fullscreen early-return, so
  a change sent while a window is fullscreen is not lost.

Notes

- The daemon converts frame-relative → output-relative → global by adding the
  frame origin and then the output origin. Emacs never needs output origins.
- `order[]` is bottom→top, used for `place_top`/stacking. For tiled-only layouts
  it is still required because windows can overlap for a moment during a sequence.
- `bid` is allocated by Emacs (0..N, reused per registration). On reconnect the
  daemon forgets all bindings; `hello` triggers a full re-registration (§8).
- `inject` keys are **evdev keycodes** (`linux/input-event-codes.h`), not keysyms
  and not xkb keycodes — `zwp_virtual_keyboard_v1.key` wants the evdev value, while
  xkbcommon keycodes are offset by 8. Verified the hard way in the PoC: sending the
  xkb keycode for `j` (44) types `z`; 36 is `j`.
- Shifted keysyms need an explicit `modifiers` request around the injected key;
  the daemon resolves keysym → (keycode, needs_shift) by searching xkb shift level
  0 and then level 1. Do **not** resolve keysym names case-insensitively — it folds
  `J` onto `j` and silently lowercases injected text.
- Injected keys deliberately bypass river's binding matching (the synced keyboard
  calls `keyboardNotifyKey` directly), so injection can never re-trigger a WM
  binding. That is the correct semantic for simulation keys, and it means a WM
  cannot use injection to test its own bindings.

## 5. Sequencing and atomicity

The rules that make the design work. Both sides must implement them literally.

1. **`layout` is state, not a command.** The daemon never applies it immediately;
   it stores it as *pending* and applies it inside the next manage sequence.
2. **`gen` is monotonic per `epoch`.** Older snapshots are ignored. A snapshot
   received mid-sequence is applied at the following sequence, and the daemon
   then issues `manage_dirty` once (never per snapshot) at `manage_finish`.
3. **`inject` is an ordered intent.** Injected keys are queued in arrival order
   and flushed at the end of the next manage sequence, after focus changes from
   the same batch. That yields "focus W and type `C-s` into W", atomically,
   which is the whole reason `river_virtual_keyboard_v1` exists.
4. **The daemon never waits for Emacs.** `manage_start` is answered from the last
   applied state plus pending state already in hand. `render_start` likewise.
   There is no timeout, no blocking read, and no way for Emacs to stall a frame.
5. **Emacs pushes, never requests.** Any daemon→Emacs data Emacs needs (window
   lists, geometry) is pushed as events and cached in elisp; elisp never asks.
6. **Coalescing is the daemon's job for display, Emacs's job for layout.**
   Emacs coalesces layout pushes to one per command-loop iteration (see §9);
   the daemon coalesces repeated `title`/`app-id`/`size` into the latest value per
   `wid` when it has to drop due to backpressure.

Sequence sketch (interception + injection):

```
river            wm-daemon                        emacs
 | manage_start     |                                |
 |<-----------------|                                |
 |                  | last layout + pending layout   |
 |  propose/w reflect|                               |
 |----------------->|                                |
 |                  | key{bid:7,state:press}         |
 |                  |------------------------------->|   unread-command-events
 |                  |                                |   C-x prefix -> C-s
 |                  |<-------------------------------|   inject [C-s], focus W
 | manage_finish    |                                |
 |<-----------------|  focus_window(W) + vkb.key(31) |
 |  routes key to W |                                |
```

## 6. Geometry contract

### 6.1 Frames are desktops

- Each virtual desktop is **one Emacs frame** ("desktop frame"), undecorated,
  created by elisp with `make-frame` — not by the daemon. Several desktops may
  share an output; at most one is visible per output at a time.
- Switching desktop is *only* flipping `visible` in `layout`. No layout
  recomputation, no buffer churn: each desktop frame keeps its own window tree,
  `tab-bar` state and `buffer-predicate` alive.
- Frame rect comes from the output's `usable` area (§6.4), so a noctalia bar at
  the top or bottom simply shrinks the tiling area.
- **Frame identity.** The daemon has to tell which `river_window_v1`s are its own
  Emacs frames. pgtk never calls `xdg_toplevel.set_identifier`, and river's
  `identifier` is compositor-generated policy, so it cannot carry our name —
  title matching remains for frames only: elisp titles each desktop frame
  `wm-frame:<n>`, the daemon emits `frame {fid,name}` and elisp stores `name` in
  a frame parameter. No guessing on either side, and app windows keep using the
  proper `identifier`.
- **Hide, never unmap.** `hide()` changes rendering state only: the surface stays
  mapped, the `river_window_v1` survives, and Emacs keeps the frame's window
  tree. `make-frame-invisible` is the opposite: unmapping makes river `makeInert()`
  the window, destroy the WM's object and mint a *new* `identifier` when it is
  mapped again (`Window.manageStart`, `closing` branch). That is exactly why
  reka grows `request-frame`/`discard-frame` for outputs appearing and
  disappearing, and why desktop switching must not use it.
- Risk to measure, not assume: a hidden frame still runs Emacs redisplay, and
  pgtk may stall waiting for `wl_surface.frame` callbacks a hidden surface never
  receives. If switching feels stale or Emacs CPU grows with desktop count, the
  fallback needs no protocol change: one frame per output, desktops as saved
  window configurations (`window-state-get`) inside it.

### 6.2 Mirrored windows

- Each app window is mirrored as an ordinary Emacs window showing a `wm-mode`
  buffer (EXWM's shape, but the compositor does the drawing — Emacs is a layout
  calculator, not a frame host).
- Rect = `window-inside-absolute-pixel-edges` of that Emacs window, frame-relative.
  The daemon adds frame origin, then output origin, and applies
  `set_clip_box(0,0,actual_w,actual_h)` from the `size` event to trim shadow/gaps.
- A buffer not displayed in any window, or in a desktop that is not visible, is
  sent as `visible:false` → `hide()`; on return `show()` + `place_top()`.

### 6.3 Unmirrored / floating windows

- `windows[].anchor:"output"` entries are never shown in an Emacs window: no
  clip box, `set_tiled` cleared, output-relative position from elisp, stacking
  from `order[]`. Focus works identically.
- Sensible elisp defaults: windows with `parent` set (dialogs, file pickers,
  popups) float; app_id/title rules can force floating; a floating window can be
  adopted into the layout later by simply sending it as a framed window in the
  next snapshot — no protocol change.
- This is the escape hatch for anything Emacs's window tree models badly, e.g. a
  splash screen or a transient toolbar-ish window.

### 6.4 Bars and layer surfaces (noctalia)

Noctalia is a Quickshell client and uses `zwlr_layer_shell_v1` (river advertises
v4 — verified). Layer surfaces are **not** `river_window_v1`s: they never appear
in `window` events and the WM must never try to manage or position them. They
compose above/below the WM's windows by layer, independent of `order[]`.

What the WM does have to consume, from `river-layer-shell-v1` (v1, verified):

| trigger | meaning | what we do |
|---|---|---|
| `river_layer_shell_output_v1.non_exclusive_area` | "area of the output remaining after subtracting the exclusive zones of layer surfaces", global coords, explicitly a hint | publish as `output.usable`; elisp sizes desktop frames to it |
| `river_layer_shell_seat_v1.focus_exclusive` | a layer surface grabbed the keyboard (noctalia launcher); river **ignores all WM focus requests** until `focus_none` | stop pushing `focus`, remember `last-window`, daemon drops focus intents instead of erroring |
| `focus_non_exclusive` | layer surface gets focus, WM keeps control | remember `last-window`, don't fight it unless the user acted |
| `focus_none` | layer surface released focus | restore `last-window`, else focus the current frame |
| `river_layer_shell_output_v1.set_default` | default output for new layer surfaces | daemon sets it for the focused output, once per manage sequence |

The daemon must never try to reserve space itself: exclusive-zone math is the
compositor's, we only consume the hint. A bar that resizes (font change, new
widget) arrives as a new `output` event with a new `usable`, and elisp resizes
frames in response.

**Workspaces in the bar.** River main does *not* implement
`ext_workspace_manager_v1` (checked the advertised globals), so noctalia cannot
list Emacs desktops natively. `zwlr_foreign_toplevel_manager_v1` v3 and
`ext_foreign_toplevel_list_v1` do exist for a task list. Recommendation: the
daemon writes `$XDG_RUNTIME_DIR/emacs-wm.state.json` (outputs, desktops, focused
desktop, per-desktop window counts, focused title) on every applied layout, and a
Quickshell script widget polls it. Deliberately outside the WM protocol so the
bar never becomes a WM dependency; if that proves insufficient, the right move is
`ext-workspace` support in river, not a bar-specific dialect.

### 6.4a Simulation keys, chords and the bar file

- **Simulation keys.** `inject` entries take an optional `mods` mask (ctrl 4, alt 8,
  shift 1, super 64) held down around the key. Combined with a focus push in the same
  manage sequence, this expresses "in *this* app, `s-w` means `C-w q`" without Emacs
  ever seeing the translated keys. Keysyms that `kbd` cannot express (`Return`, `Tab`)
  are passed as xkb keysym names, which is what the resolution path already wants.
- **Chords.** `river_xkb_bindings_seat_v1.ensure_next_key_eaten` is exposed as
  `eat-next {on}` (queued, applied in the manage sequence); `ate_unbound_key` is
  forwarded as `key-unbound`. A submap should bind its keys *only while active* and
  unbind them on exit: a globally bound plain `f` would otherwise be intercepted
  everywhere and replayed through Emacs, which is the "bind every keysym and inject"
  trap this design avoids.
- **Bar side channel.** `$XDG_RUNTIME_DIR/emacs-wm.state.json`, rewritten atomically
  after every applied layout: `epoch`, `gen`, `focus{wid,title,app_id,output,desktop}`,
  and per output `{oid,x,y,w,h,usable,desktop,desktops,windows{desktop:count}}`. Read
  by bars, never read back by the WM.
- **Identity across restarts.** `epoch` is seeded from the clock, not counted from 0,
  so a restarted daemon is a *different* generation. On a new epoch the client keeps
  its buffers, drops window ids, re-registers bindings and re-attaches windows by
  `identifier`; the daemon re-sends outputs and windows to every new client.

### 6.4b Desktops are per output

With more than one output, a desktop is a *pair* (output, index), and the frame that
carries it is named `wm-frame:<oid>:<index>` — that name is the whole protocol: the
daemon parses it into `Frame { desktop, output }`, so a frame's output never needs to
be inferred from geometry. Consequences:

- each output switches independently; switching one output changes only which of
  *its* frames is `visible`,
- a window is mirrored in the desktop frame of *its own* output (§6.2), which is why
  `window` messages carry `output`,
- `move-to-desktop` targets the frame of the window's own output,
- an output added later gets its own set of frames; a removed output's frames are
  deleted and Emacs re-homes their windows,
- the legacy name `wm-frame:<index>` still means "this output" (`output: None`), which
  is what the PoC's built-in mode uses.

### 6.5 Minibuffer and focusing Emacs

The minibuffer gets no surface: it is drawn inside the focused frame. Focusing
Emacs itself is `focus:{"frame":fid}` on that frame's `river_window_v1` — which
is how `C-x C-f` typed on a desktop whose selected window is an app buffer still
reaches Emacs when a prefix intercepts.

## 7. Key handling contract

- Emacs decides *policy*: what is a prefix, what is forwarded, how sequences
  resolve. It registers bindings with `bind`, giving each a `bid` and the Emacs
  event it wants back.
- The daemon converts the Emacs event to a keysym **once, at registration**
  (`xkb_keysym_from_name` / `xkb_utf32_to_keysym`), creates a
  `river_xkb_binding_v1`, and enables it during the next manage sequence.
- When river reports `pressed`, the daemon sends `key{bid,state}`. Elisp looks up
  `bid` → event and pushes it onto `unread-command-events`. No runtime
  keysym→event table is needed; this is reka's cleverest trick and it survives
  the process boundary.
- Chords/submaps: elisp calls `ensure_next_key_eaten` semantics via a daemon
  command (to be added: `eat-next {on|off}`), and handles `key-unbound` to leave
  the submap. Note river *waits* for the manage sequence before processing the
  next key, so submap transitions are inherently synchronous with input.
- Injection is only for replaying a resolved sequence into the app, never for
  proxying ordinary typing. A `bind` for every keysym plus injection on every
  keystroke would work mechanically and be catastrophically slow.

## 8. Restart, resync, identity

- `epoch` increments per daemon process. On `hello` with a new `epoch`, elisp:
  1. drops stale `wid`s but keeps buffers (they are the user's state),
  2. re-registers all bindings,
  3. pushes a fresh full `layout` (empty until windows arrive),
  4. re-attaches buffers to incoming `window` events by `identifier`, falling
     back to `app_id`+`title` heuristics (reka's approach) and only creating a
     new buffer as a last resort.
- The daemon treats a new connection as a full reset: bindings cleared, pending
  layout cleared, `gen` reset, epoch bumped.
- River re-sends all live windows on WM rebind, so a daemon restart costs one
  manage sequence and leaves window state untouched — as long as the daemon
  rebinds within river's grace behaviour. If river chooses to `unavailable`
  because a stale WM object still exists, the daemon should wait and retry with
  backoff, logging loudly.
- **Desktop frames survive a daemon restart** because they were never unmapped
  (§6.1): they arrive again as ordinary `window` events and are re-matched by
  title (`wm-frame:<n>` → `frame {fid,name}`), which is exact rather than
  heuristic. So the desktop geometry and the frame's Emacs window tree survive;
  only `fid`s are new. App windows have no such luxury (`identifier` is minted per
  `river_window_v1`), which is why app windows re-attach by `identifier` first and
  by `app_id`+`title` only as a fallback.
- The daemon must never assume the elisp state matches its own: after `hello`,
  the first `layout` is authoritative and everything it does not mention is
  hidden.

## 9. Elisp integration

```elisp
;; connection
(setq wm-proc (make-network-process
               :name "emacs-wm"
               :family 'local
               :service (format "%s/emacs-wm.%s.sock"
                                (getenv "XDG_RUNTIME_DIR") (getenv "WAYLAND_DISPLAY"))
               :coding 'utf-8-unix
               :filter #'wm--filter
               :sentinel #'wm--sentinel
               :noquery t))

;; filter: parse, queue, defer. Never do work in a filter.
(defun wm--filter (proc chunk)
  (setq wm--buf (concat wm--buf chunk))
  (while-let ((nl (string-search "\n" wm--buf)))
    (let ((line (substring wm--buf 0 nl)))
      (setq wm--buf (substring wm--buf (1+ nl)))
      (push (json-parse-string line :object-type 'plist) wm--queue)))
  (run-at-time 0 nil #'wm--drain))
```

Rules

- `wm--drain` guards against reentrancy with a flag (reka used a mutex hack here;
  a plain `busy` flag is enough because elisp is single-threaded).
- Handlers are wrapped in `condition-case`; an error must not kill the filter or
  the process. Log to `*emacs-wm-log*` and keep going.
- Layout pushes: hook `window-configuration-change-hook` +
  `window-selection-change-functions`, coalesced by a 0-delay timer that sends at
  most one `layout` per command loop iteration. `gen` increments on send.
- Focus pushes ride in `layout`; do not send them separately (that would need a
  second ordering rule).
- Outbound writes: `process-send-string` with `(concat (json-serialize msg) "\n")`.
  Emacs buffers partial writes; no manual framing needed.
- Liveness: reply to `ping` from the drain loop, not from the filter. If the
  daemon logs `ping` timeouts it must not change behaviour, only complain.

## 10. Daemon implementation notes

- Bind order: `river_window_manager_v1` (v6) first — it is first-come-first-served
  and river sends `unavailable` to late binders — then `river_xkb_bindings_v1`,
  `river_virtual_keyboard_manager_v1`, `zwp_virtual_keyboard_manager_v1`,
  `wl_seat`, then registry roundtrips.
- `sync_keyboard` must be called **before** the first `keymap` request on the
  virtual keyboard (`keymap_already_set` error otherwise), and only has effect
  for the active WM's client. Failures are silent `log.info` lines.
- **River bug as of main @ 85b0088**: after a synced keyboard becomes the seat's
  active keyboard, any focus change panics river (`Seat.keyboardNotifyEnter` casts
  null group data). Reproduced and patched locally; see `RESULTS.md` and
  `~/src/river/fix-vkb-active-keyboard.patch`. Until it is fixed upstream,
  injection and focus changes cannot be combined on stock river — which is exactly
  the atomicity this design depends on.
- Virtual keyboard setup: create keyboard for the seat, `sync_keyboard`, upload
  an XKB keymap obtained from the seat's keyboard (so keycodes match the apps'
  expectations), then inject `key`/`modifiers`, batched at `manage_finish`.
- Event queue to Emacs is bounded (e.g. 4096). On overflow: drop coalescable
  (`title`, `app-id`, `size`) first, then log; never drop `window`, `gone`,
  `output`, `bye`.
- Two dispatch contexts: Wayland `Dispatch` impls (which may only enqueue) and
  the sequence-response path (which reads pending state). Keep them disjoint so
  the "never wait for Emacs" property is visible in the code.
- `manage_dirty` only when pending `gen` > applied `gen`; guard against
  re-entrant dirtying from within the same sequence.
- **Every request that modifies window-management state must be applied inside a
  manage sequence — queue it, never call it from an event handler or a client
  message.** That includes key bindings (`get_xkb_binding`/`enable`), fullscreen
  (`fullscreen`/`exit_fullscreen`), `close`, `propose_dimensions`, and `set_tiled`.
  River rejects them outside a sequence with
  `invalid modification of window management state` and **kills the connection**,
  which looks like the WM crashing. The PoC hit this three separate times
  (bindings, fullscreen, close). Rendering state (`set_position`, `place_top`,
  `set_clip_box`) is allowed during manage *or* render sequences, so it must be
  queued for the render pass instead, not applied at event time.
- Proposing dimensions that have not changed makes clients re-commit; with a
  client that reacts to `size` events this becomes an infinite layout loop.
  Propose only on change, and ignore snapshots identical to the applied one.
- On client attach, re-send all existing windows and frames: a client that
  connects late (or reconnects after a crash) must be able to rebuild state.

## 11. Open questions

1. **Keycode table.** Does the daemon ship the keymap → keycode mapping for elisp
   (needed by `inject`), or does elisp resolve Emacs events to keycodes through a
   static table shipped by the daemon once? v0 should send a `keymap` message with
   `{event-name → keycode}` for the keys elisp actually injects.
2. **Hidden-frame redisplay.** Settled that desktops are frames (§6.1), open is
   whether pgtk handles hidden-frame redisplay cheaply. This must be measured with
   ~8 desktop frames before committing: if frame callbacks stall, switch to one
   frame per output plus `window-state-get` snapshots, which needs no daemon
   change.
3. **Bar/desktop interop.** River has no `ext_workspace_manager_v1`, so the
   `emacs-wm.state.json` side channel (§6.4) is the only way noctalia can show
   desktop names/counts. Open whether a Quickshell script widget polling that file
   is actually pleasant (poll interval, flicker, follow-the-focused-desktop).
4. **Floating-window policy location — decided: elisp.** Rules live in the
   user's Emacs config (see §13); the daemon has no config file. Open sub-question:
   whether a window is ever *held* unrendered until elisp answers (see §13.2), or
   always gets the daemon default first.
5. **Multiple seats / transient seats** (`ext_transient_seat_manager_v1` is
   advertised) — ignored in v0.
6. **`river_touch_gestures_v1`** is new on main; if it stabilises it becomes a
   natural elisp event source. Out of scope until then.
7. **Session lock.** `ext_session_lock_manager_v1` is advertised and
   `river_window_manager_v1` has `session_locked`/`session_unlocked` plus an
   `exit_session` request. v0 only forwards them as `bye`/log; a proper lock
   client story is v1.

## 12. Versioning

`v` bumps for breaking changes; additive messages do not bump. Since river's own
protocol is version-negotiated per global (`min(client_wanted, advertised)`), the
daemon should advertise its own supported river protocol version range in `hello`
so Emacs (and the logs) can tell "your river is too old for injection" apart from
"your daemon is broken".

## 13. Window rules live in elisp

The daemon is policy-free: its only inputs are river and the socket, and it has no
configuration file. Everything that looks like a "window rule" — tile vs float,
geometry, desktop assignment, which prefixes an app gets, whether the window is
mirrored into an Emacs window at all — is elisp in the user's config.

Prior art in the Emacs world is EXWM's `exwm-manage-configurations`: an alist of
predicates over window metadata. The same shape works here, with the predicate as
a plain function:

```elisp
(setq emacs-wm-window-rules
      '(((:app-id . "blueman")   . (:float t :size (0.4 . 0.5) :place center))
        ((:app-id . "pavucontrol") . (:float t :width 0.5))
        ((:class . "Steam")      . (:desktop 3))))
```

Matching metadata comes from the `window` event (`app_id`, `title`, `identifier`,
`pid`, `parent`, `dimensions_hint`, `csd`). The *result* of a rule is not a
command: it is the next `layout` snapshot (`float`, `anchor:"output"`, a rect, a
desktop), which the protocol already carries. No protocol addition was needed for
window rules, and none should be added.

### 13.1 Why not a rule table in the daemon

sway (`for_window`) and Hyprland (`windowrule`) keep rules in compositor config.
Doing that here would mean two configuration files, duplicated policy, and the
window-management brain drifting back out of Emacs — the exact thing this
architecture exists to avoid. The daemon keeps only *defaults*, not rules.

### 13.2 The bootstrap problem

A rule is evaluated after the window exists, but river's manage sequence for a new
window happens immediately. Options:

1. **Daemon default, elisp corrects** — unknown windows are tiled; a window with a
   `parent` is floated (that is a protocol fact, not policy). Elisp's rule
   overrides on the next snapshot, normally before the app has drawn. This is what
   the PoC does.
2. **Hold until decided** — keep the window hidden for the first sequence(s) with a
   hard timeout (~100 ms) then fall back to (1). Correctness for rules that must
   never be violated, at the cost of startup latency proportional to Emacs's
   responsiveness.
3. **Static table in the daemon** — rejected, see §13.1.

The daemon must always have *some* default so that a slow, busy or dead Emacs
never leaves a window unrendered or the desktop unbootable.

### 13.3 Constraints this puts on rules

- **Pure and fast.** The daemon cannot block on Emacs, so a rule that waits on I/O
  or a prompt delays the layout it was meant to produce. Slow work belongs in a
  hook that pushes a later snapshot.
- **No ordering assumptions.** Rules are evaluated per window creation; the same
  metadata can change later (`title`, `app_id`), so a rule that matters must be
  re-evaluated on those events too.
- **Keys are rules as well.** "In this app, translate `C-w` to `C-x`" (simulation
  keys) and "don't intercept `C-c` here" are per-app policy and belong in the same
  table.
