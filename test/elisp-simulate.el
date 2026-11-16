;;; elisp-simulate.el --- :simulate translation and pass-through  -*- lexical-binding: t; -*-

;; Two terminal windows, one with a `:simulate' rule for C-t and one without.
;; Pressing C-t must be translated in the first and passed through unchanged in
;; the second: that is the property that lets Emacs keys (C-v, C-a, M-x) be used
;; as simulation keys without breaking the same keys in every other app.

(require 'emacs-wm)

(defconst wl-dir
  (or (getenv "EMACS_WM_TEST_TOOLS")
      (expand-file-name "tools/target/debug"
                        (file-name-directory (or load-file-name
                                                 buffer-file-name))))
  "Directory of the native helpers (test/tools/target/debug), for spawning them.")

(emacs-wm--log "--- simulate test starting, socket %s" (emacs-wm-socket-path))

;; The "mapped" terminal turns C-t into C-a, "m", Return, and C-g into Escape.
;; The catch-all kitty rule (float nil) matches the other window and has no
;; :simulate, so both keys fall through to it untouched.
;;
;; C-g is the pass-through key because it is *not* a terminal special character:
;; an app must be able to receive it (^G, 0x07) when no rule applies.  C-t is
;; only used for the translation side (the receiving terminal would swallow
;; ^T, which is Linux's VSTATUS).
(setq emacs-wm-window-rules
      '(((:app-id "kitty" :title "mapped")
         (:simulate (("C-t" . ("C-a" "m" "Return"))
                     ("C-g" . ("Escape")))))
        ((:app-id "kitty") (:float nil))))

(emacs-wm-enable)

(defun sim-arg (tag)
  "Spawn a terminal tagged TAG that appends every input line to a file."
  (emacs-wm-spawn
   (concat "kitty -1 --title " tag " -o remember_window_size=no sh -c "
           "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/sim-" tag ".txt; done'")))

(defun sim-focus (title)
  "Focus the app window whose title contains TITLE."
  (let (target)
    (maphash (lambda (wid meta)
               (when (and (not target)
                          (string-match-p (regexp-quote title)
                                          (downcase (or (plist-get meta :title) ""))))
                 (setq target wid)))
             emacs-wm--meta-by-wid)
    (emacs-wm--log "focusing %S -> %S" title target)
    (when target (emacs-wm--focus-app-wid target))))

(defun sim-press (key)
  "Type KEY as a real keyboard would: through river's binding matching."
  (emacs-wm--log "--- pressing C-%s" key)
  (emacs-wm-spawn (concat wl-dir "/keyinject -m ctrl " key " 2>>/tmp/keyinject.log")))

(run-with-timer 4 nil (lambda () (sim-arg "mapped")))
(run-with-timer 6 nil (lambda () (sim-arg "plain")))
(run-with-timer 9 nil (lambda () (sim-focus "mapped")))
(run-with-timer 11 nil (lambda () (sim-press "t")))
(run-with-timer 14 nil (lambda () (sim-focus "plain")))
(run-with-timer 16 nil (lambda () (sim-press "g")))
;; The plain terminal's `read' only writes completed lines, so give the ^G a
;; line terminator.  A bare Return is not a WM binding, so it reaches the app
;; directly, exactly like C-g did.
(run-with-timer 17 nil
                (lambda ()
                  (emacs-wm--log "--- pressing Return (to complete the line)")
                  (emacs-wm-spawn (concat wl-dir "/keyinject Return 2>>/tmp/keyinject.log"))))
(run-with-timer 20 nil
                (lambda ()
                  (emacs-wm--log "20s: focused=%S"
                                 (emacs-wm--focused-wid))
                  (emacs-wm--log "buffers: %S" (hash-table-keys emacs-wm--buffer-by-wid))))
