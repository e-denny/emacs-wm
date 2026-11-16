# emacs-wm

Emacs is the window manager. River is the compositor.

`emacs-wm` is a window manager written in Emacs Lisp that speaks Wayland
itself: it is a `river_window_manager_v1` client, so the only non-Elisp code in
the window manager is river. No C daemon, no helper process in the hot path —
two Emacsen, one socket, river.

```
river (compositor: input routing, rendering, frame deadlines)
  ├─ backend Emacs    -Q --fg-daemon   (lisp/emacs-wm-be.el)
  │    the river_window_manager_v1 client; holds no policy
  │    speaks Wayland itself, through emacs-wm-wl.el
  │    └─ $XDG_RUNTIME_DIR/emacs-wm.$WAYLAND_DISPLAY.sock
  └─ frontend Emacs   (lisp/emacs-wm.el)
       your session: desktops, rules, focus, key policy, borders
```

Two Emacsen rather than one because river stops processing input while a
manage sequence is open, so whatever sits in the WM slot is a latency
dependency for the whole session. The backend is a bare `-Q` Emacs that loads
two files; your editing Emacs cannot stall the compositor.

## What works

Layout (tiling, floating, fullscreen, per-output desktops as real Emacs
frames), focus, borders, keyboard and pointer bindings, interactive move and
resize, stacking order, client decorations, key injection and per-app key
translation, ext-session-lock (lock and unlock), a backend watchdog with
restart and resync, output hotplug on the frontend side, and a bar state file.

Every claim above is measured, and `RESULTS.md` is the evidence log: suite
output, sampled border pixels, dropped-key counts, restart transcripts. Where
something is *not* verified, it says so instead.

## Requirements

- Emacs 31+ with pgtk (developed on `32.0.50 --with-pgtk`)
- river 0.6 plus the five patches in [`river-patches/`](river-patches/README.md)
  (stock river 0.5 cannot inject from an fd-less virtual keyboard)
- for the test tools only: a Rust toolchain (`cargo`)

## Run it

```
# 1. build river from river-patches/README.md, then:
river -c test/run-emacs-only.sh          # nested, interactive session
```

The nested session is the safe way to try it: it runs inside your current
compositor as a window. A login session entry point lives in
`contrib/emacs-wm-session` (with `contrib/emacs-wm.desktop`), which starts
river, starts the frontend, keeps the three logs under
`$XDG_STATE_HOME/emacs-wm/`, and never leaves an orphaned Emacs behind.

## Configure it

All policy is in one Elisp file: the command names, the bindings, window
rules, borders, desktop count, pointer buttons, supervision knobs and
autostart. `lisp/emacs-wm-config.el` is the built-in default; copy it to
`$XDG_CONFIG_HOME/emacs-wm/config.el` and edit, and it is loaded after the
built-in one so your `setq`s win.

```elisp
(setq emacs-wm-key-bindings
      '(("s-1" . "desktop-1")
        ("s-f" . "toggle-float")
        ("s-t" . (emacs-wm-spawn "kitty"))))
```

Window rules can translate *Emacs* bindings into what an application expects,
which is what makes the same keys work everywhere:

```elisp
(setq emacs-wm-window-rules
      '(((:app-id "firefox")
         (:simulate (("C-v" . ("<next>"))    ; scroll up a page
                     ("M-v" . ("<prior>"))
                     ("C-s" . ("C-f"))       ; isearch -> find in page
                     ("C-l" . ("C-l")))))))  ; address bar
```

`C-v` means page-down in Firefox and stays `C-v` in a terminal: a key that a
rule translates but that does not match the focused window is passed through
unchanged. `M-x emacs-wm-reload-config` applies an edited file without
restarting the session.

## Tests

Each suite prints its own evidence and ends with a leftovers check, which must
say `(none)` — orphaned frontends re-attaching to a later compositor is a real
failure mode this project hit once.

```
test/run-config-test.sh                  # 22 unit tests: commands, bindings, rules
test/run-be-tests.sh                     # 27 unit tests: geometry, keycode tables
test/run-emacs-only-test.sh              # single output: layout, borders, inject
test/run-emacs-only-keys-test.sh         # real key presses via a virtual keyboard
test/run-emacs-only-multi-test.sh        # two outputs, per-output desktops
test/run-emacs-only-simulate-test.sh     # :simulate translation and pass-through
test/run-emacs-only-pointer-test.sh      # a real pointer drags and resizes
test/run-emacs-only-visual-test.sh       # border pixels, sampled from a capture
test/run-emacs-only-lock-test.sh         # ext-session-lock, lock and unlock
test/run-emacs-only-hotplug-test.sh      # output removal (frontend side)
test/run-emacs-only-ops-test.sh          # move/resize op lifecycle
test/run-emacs-only-wedge-test.sh        # watchdog vs a SIGSTOPped backend
test/run-emacs-only-features-test.sh     # chords, restart/resync
test/run-session-test.sh                 # the login-session entry point
```

The test tools (`test/tools`, Rust) exist because Elisp cannot pass file
descriptors: real key presses, a real pointer, screencopy, and a session-lock
client. The WM itself never needs an fd.

Paths are derived from each script's own location (`test/lib.sh`), so a
checkout works from any directory. The compositor is taken from
`$EMACS_WM_RIVER`, else `../river/zig-out/bin/river` next to the checkout, else
`river` in `$PATH`; `EMACS_WM_REPO` overrides the root and `XDG_RUNTIME_DIR` the
socket directory. `cleanup-ours.sh` only ever kills processes that mention this
checkout's paths, so a session running from another checkout survives a test
run.

## Documentation

| file | what is in it |
|---|---|
| `EMACS-ONLY.md` | design, the river patches, protocol sequencing rules, mitigations, open issues |
| `PROTOCOL.md` | the message schema between the two Emacsen and the ordering rules |
| `RESULTS.md` | the evidence log, including the traps that cost real time |
| `river-patches/` | the five patches river needs, and why |

## Not verified / not done

Touch gestures, multiple or transient seats, and a real TTY/hardware session
(hotplug is verified on the frontend path only). Supporting a second compositor
would mean a second backend; the frontend/protocol split is designed for that
but only river is implemented. The five patches are not filed upstream.

## License

GPL-3.0-or-later; see [`LICENSE`](LICENSE). The Rust test tools under
`test/tools` are already marked `GPL-3.0-or-later` in their headers, and the
river patches are against GPL-3.0-only river code.
