;;; emacs-wm-config.el --- configuration of the Emacs window manager  -*- lexical-binding: t; -*-

;; This is the window manager's configuration: the commands you can bind, the
;; Super bindings themselves, window rules, borders, desktops, pointer
;; bindings, autostart.  Nothing in here is mechanism -- emacs-wm.el holds the
;; code, this file holds the policy.
;;
;; It is loaded automatically when emacs-wm is loaded, so it is the built-in
;; default.  To customise, copy it to
;;
;;     ${XDG_CONFIG_HOME:-~/.config}/emacs-wm/config.el
;;
;; and edit that copy: the session loads your file *after* this one, so
;; whatever you `setq' there wins.  You can delete everything you do not want
;; to change -- the rest keeps the values below -- but note that lists are
;; replaced wholesale, not merged, so a `setq' of a list is the whole list.
;;
;; Reload without restarting the session:
;;
;;     M-x emacs-wm-reload-config RET
;;
;; which loads this file again, rebuilds the keymap and re-registers the keys
;; with the compositor.
;;
;; Keys are written the way `kbd' accepts them ("s-f" is Super+f,
;; "s-S-2" Super+Shift+2, "s-<f7>" Super+F7).  Only single-key combinations
;; can be handed to river; anything the WM cannot intercept (e.g. "C-x C-f")
;; is left to Emacs.

;;; Code:

;;; ---------------------------------------------------------------- commands
;;
;; The commands a binding may name, with their descriptions.  A binding may
;; also name any function directly, or a (FUNCTION . ARGS) form for a command
;; that needs arguments -- see `emacs-wm-key-bindings' below.
;;
;; Add your own here and then bind them; `emacs-wm-commands' is only a name
;; table, the functions themselves live in emacs-wm.el and in your config.

(setq emacs-wm-commands
      '(;; Desktops.  Each desktop is one Emacs frame on the output under the
        ;; pointer, so `emacs-wm-desktops-per-output' must cover the numbers
        ;; you bind.
        ("desktop-1" emacs-wm-desktop-1 "Switch to desktop 1")
        ("desktop-2" emacs-wm-desktop-2 "Switch to desktop 2")
        ("desktop-3" emacs-wm-desktop-3 "Switch to desktop 3")
        ("desktop-4" emacs-wm-desktop-4 "Switch to desktop 4")
        ("desktop-5" emacs-wm-desktop-5 "Switch to desktop 5")
        ("desktop-6" emacs-wm-desktop-6 "Switch to desktop 6")
        ("desktop-7" emacs-wm-desktop-7 "Switch to desktop 7")
        ("desktop-8" emacs-wm-desktop-8 "Switch to desktop 8")
        ("desktop-9" emacs-wm-desktop-9 "Switch to desktop 9")
        ("move-to-desktop-1" emacs-wm-move-to-desktop-1 "Move the window to desktop 1")
        ("move-to-desktop-2" emacs-wm-move-to-desktop-2 "Move the window to desktop 2")
        ("move-to-desktop-3" emacs-wm-move-to-desktop-3 "Move the window to desktop 3")
        ("move-to-desktop-4" emacs-wm-move-to-desktop-4 "Move the window to desktop 4")
        ("move-to-desktop-5" emacs-wm-move-to-desktop-5 "Move the window to desktop 5")
        ("move-to-desktop-6" emacs-wm-move-to-desktop-6 "Move the window to desktop 6")
        ("move-to-desktop-7" emacs-wm-move-to-desktop-7 "Move the window to desktop 7")
        ("move-to-desktop-8" emacs-wm-move-to-desktop-8 "Move the window to desktop 8")
        ("move-to-desktop-9" emacs-wm-move-to-desktop-9 "Move the window to desktop 9")
        ;; Windows.
        ("toggle-float" emacs-wm-toggle-float "Float or tile the focused window")
        ("close-window" emacs-wm-close-window "Close the focused window")
        ("minimize-window" emacs-wm-minimize-window "Hide the focused window")
        ("restore-window" emacs-wm-restore-window "Show the focused window again")
        ("toggle-fullscreen" emacs-wm-toggle-fullscreen "Fullscreen the focused window")
        ("raise-window" emacs-wm-raise-window "Raise the focused window")
        ("lower-window" emacs-wm-lower-window "Lower the focused window")
        ("move-window" emacs-wm-move-window "Move the focused window with the pointer")
        ("resize-window" emacs-wm-resize-window "Resize the focused window with the pointer")
        ;; Session.
        ("spawn-popup" emacs-wm-spawn-popup "Run `emacs-wm-popup-command'")
        ("enter-submap" emacs-wm-enter-submap "Enter a one-shot key submap")
        ("exit-session" emacs-wm-exit-session "End the session (log out)")))

;;; ---------------------------------------------------------------- bindings
;;
;; (KEY . COMMAND) pairs.  COMMAND is a name from `emacs-wm-commands', a
;; function symbol, or (FUNCTION . ARGS) for a command that takes arguments:
;;
;;     ("s-t" . (emacs-wm-spawn "kitty"))
;;
;; Every key listed here is registered with the compositor automatically, so a
;; key that is bound is also a key the WM receives.  `:simulate' rules below
;; may use keys that are not bound here; those are registered too.
;;
;; Keys the compositor should forward without having a WM binding of their own
;; (prefixes Emacs itself handles) go in `emacs-wm-intercepted-prefixes'.

(setq emacs-wm-key-bindings
      '(;; s-1 .. s-4 switch desktops, s-S-1 .. s-S-4 move windows to them.
        ;; Raise `emacs-wm-desktops-per-output' and add s-5/s-S-5 here if you
        ;; want more.
        ("s-1" . "desktop-1")
        ("s-2" . "desktop-2")
        ("s-3" . "desktop-3")
        ("s-4" . "desktop-4")
        ("s-S-1" . "move-to-desktop-1")
        ("s-S-2" . "move-to-desktop-2")
        ("s-S-3" . "move-to-desktop-3")
        ("s-S-4" . "move-to-desktop-4")
        ;; Windows.
        ("s-f" . "toggle-float")
        ("s-m" . "minimize-window")
        ("s-r" . "restore-window")
        ("s-q" . "close-window")
        ("s-<f11>" . "toggle-fullscreen")
        ("s-<up>" . "raise-window")
        ("s-<down>" . "lower-window")
        ("s-<f7>" . "move-window")
        ("s-<f8>" . "resize-window")
        ;; Session.
        ("s-<return>" . "spawn-popup")
        ("s-<f12>" . "exit-session")))

;; Single keys bound above are intercepted by the compositor for us.  These are
;; the extra *prefixes* it should forward so Emacs sees them as it always does
;; (edit keys in an app window, M-x, ...).  Add "C-y" etc. here if you want
;; them to reach Emacs instead of the focused app.
(setq emacs-wm-intercepted-prefixes '("C-x" "C-c" "M-x"))

;;; ------------------------------------------------------------- window rules
;;
;; (MATCH . ACTIONS).  MATCH is a plist matched against the window's metadata:
;; `:app-id' and `:title', both case-insensitive substrings.  ACTIONS:
;;
;;   :float t / nil            start floating (or tiled)
;;   :desktop N                open on desktop N
;;   :border-width N           per-window border override (nil = no border)
;;   :border-color "#rrggbb"
;;   :border-edges BITMASK     top 1, bottom 2, left 4, right 8
;;   :decor "csd" / "ssd"      ask the client for client/server decorations
;;   :simulate (("KEY" . ("KEYS" ...)) ...)
;;                             while a window of this app has focus, KEY is
;;                             typed into the app as those keys.  KEY is meant
;;                             to be an *Emacs* binding, so the familiar keys
;;                             keep their familiar meaning per application:
;;                             C-v scrolls a page in Firefox and still pastes
;;                             in a terminal (a key with a rule but no match
;;                             for the focused window is passed through
;;                             unchanged; see `emacs-wm--intercepted-for-app-p')
;;
;; Only the *first* matching rule applies, so put more specific rules first and
;; repeat anything you need in the same rule.
;;
;; The `:simulate' samples below are Firefox: the Emacs binding on the left is
;; typed into the browser as the key on the right, so the muscle memory of
;; Emacs keeps working while no window is faking it.  These keys are intercepted
;; with the compositor because a rule mentions them, which is safe: an app with
;; no rule for a key gets that key back, unchanged (that is how C-a still
;; selects a line in a shell and C-v still pastes in a terminal).

(setq emacs-wm-window-rules
      `(((:app-id "firefox")
         (:simulate (("C-v" . ("<next>"))      ; scroll-up-command -> page down
                     ("M-v" . ("<prior>"))     ; scroll-down-command -> page up
                     ("C-s" . ("C-f"))         ; isearch-forward -> find in page
                     ("C-l" . ("C-l"))         ; recenter -> location bar
                     ("C-w" . ("C-w"))         ; kill-region -> close tab
                     ("C-t" . ("C-t"))         ; transpose-chars -> new tab
                     ("C-a" . ("C-a"))         ; move-beginning-of-line -> select all
                     ("M-x" . ("C-l")))))      ; execute-extended-command -> address bar
        ;; XWayland Firefox reports itself as "Navigator" instead of
        ;; "firefox"; uncomment to get the same keys there.
        ;; ((:app-id "navigator")
        ;;  (:simulate (("C-v" . ("<next>"))
        ;;              ("M-v" . ("<prior>"))
        ;;              ("C-s" . ("C-f")))))
        ((:app-id "blueman") (:float t))
        ((:app-id "pavucontrol") (:float t))))

;; The command `spawn-popup' (bound to s-<return> above) runs this.  Rules
;; decide whether it floats.
(setq emacs-wm-popup-command "blueman-manager")

;;; -------------------------------------------------------------- appearance

(setq emacs-wm-border-width 2
      emacs-wm-border-color-focused "#7aa2f7"
      emacs-wm-border-color-unfocused "#3b4261"
      emacs-wm-border-edges 15)        ; top 1, bottom 2, left 4, right 8

;; One Emacs frame per desktop per output.  The bar's state file reports
;; `emacs-wm-be-desktops-per-output' from the backend (default 4); keep them
;; equal if the bar shows a desktop count.
(setq emacs-wm-desktops-per-output 4)

;;; ---------------------------------------------------------------- pointers
;;
;; Held-modifier + button starts a river pointer op.  272/273 are BTN_LEFT and
;; BTN_RIGHT (linux/input-event-codes.h), 64 is Super.
(setq emacs-wm-pointer-bindings '((272 . "move")
                                  (273 . "resize"))
      emacs-wm-pointer-modifiers 64
      emacs-wm-resize-edges 10)        ; bottom-right corner

;;; ------------------------------------------------------------- supervision
;;
;; The backend is a second Emacs (the actual Wayland client).  It is probed
;; every `emacs-wm-ping-interval' seconds; no answer within
;; `emacs-wm-ping-timeout' means wedged, not busy, and it is restarted up to
;; `emacs-wm-max-respawns' times in a row.

(setq emacs-wm-ping-interval 5.0
      emacs-wm-ping-timeout 3.0
      emacs-wm-max-respawns 5)

;;; ------------------------------------------------------------ while locked
;;
;; With an ext-session-lock lock held, the WM focuses nothing, injects nothing
;; and ignores every binding except the keys listed here.  Empty is the safe
;; default: let the lock client own the screen.
(setq emacs-wm-allow-when-locked nil)

;;; ---------------------------------------------------------------- autostart
;;
;; Shell commands started once the WM is up (`emacs-wm-session.el' runs them,
;; not `emacs-wm-enable', so they belong to the login session).  The bar has to
;; come up after the compositor, which is why it is here and not in your
;; greeter.

(setq emacs-wm-startup-commands
      '("noctalia"))

;;; ------------------------------------------------------------------ submaps
;;
;; A submap is a one-shot keymap: enter it with a binding to "enter-submap"
;; (it prompts for the name) or with `(emacs-wm-enter-submap "NAME")', the next
;; key press is looked up in it, and it is left automatically.  Uncomment to
;; try: while the submap is active, r resizes and m moves with the pointer.

;; (add-to-list 'emacs-wm-submaps
;;              '("window" ("r" . emacs-wm-resize-window)
;;                         ("m" . emacs-wm-move-window)))
;; (setq emacs-wm-key-bindings
;;       (append emacs-wm-key-bindings
;;               '(("s-<f9>" . (emacs-wm-enter-submap "window")))))

;;; --------------------------------------------------------------- your own
;;
;; Ordinary functions work as binding targets, which is how you get behaviour
;; this file does not have a name for:

;; (defun my/emacs-wm ()
;;   "Start my editor as a normal window on this session."
;;   (interactive)
;;   (emacs-wm-spawn "emacs"))
;; (setq emacs-wm-key-bindings
;;       (append emacs-wm-key-bindings '(("s-e" . my/emacs-wm))))

(provide 'emacs-wm-config)
;;; emacs-wm-config.el ends here
