;;; elisp-lock.el --- what the WM does while the session is locked  -*- lexical-binding: t; -*-

;; test/tools/lockclient takes an ext-session-lock lock and paints every output
;; solid, exactly as a real locker would.  While it holds the lock the WM must
;; keep out of the way: no focus changes, no injected keys, no ordinary
;; bindings.  Afterwards everything must work again.

(require 'emacs-wm)

(defconst wl-dir "~/src/emacs-wm/test/tools/target/debug")

(emacs-wm--log "--- lock test starting, socket %s" (emacs-wm-socket-path))
(setq emacs-wm-window-rules '(((:app-id "kitty") (:float t))))
(emacs-wm-enable)

(defun wl-report (tag)
  (emacs-wm--log "%s: locked=%S focused=%S buffers=%S"
                 tag emacs-wm--locked (emacs-wm--focused-wid)
                 (hash-table-count emacs-wm--buffer-by-wid)))

(run-with-timer 4 nil
                (lambda ()
                  (emacs-wm-spawn
                   (concat "kitty -1 --title lock-app -o remember_window_size=no sh -c "
                           "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/lock-app-input.txt; done'"))))

(run-with-timer 8 nil (lambda () (wl-report "8s (before the lock)")))

;; 9s: take the lock for 8 seconds.
(run-with-timer
 9 nil
 (lambda ()
   (emacs-wm--log "--- taking the session lock for 8s")
   (emacs-wm-spawn (concat wl-dir "/lockclient 8 202020 2>>/tmp/lockclient.log"))))

;; 11s: the lock should be in force.  Try everything that must not work.
(run-with-timer
 11 nil
 (lambda ()
   (wl-report "11s (locked)")
   (emacs-wm--log "--- injecting while locked (must be refused)")
   (emacs-wm-inject "x" "Return")
   (emacs-wm--log "--- pressing Super+2 while locked (must be ignored)")
   (emacs-wm-spawn (concat wl-dir "/keyinject -m super 2 2>>/tmp/keyinject.log"))
   (run-with-timer
    1 nil
    (lambda ()
      (emacs-wm--log "--- screenshot of the locked session")
      (emacs-wm-spawn (concat wl-dir "/screenshot /tmp/visual-locked.ppm 5"
                              " 2>>/tmp/screenshot.log"))))))

(run-with-timer 13 nil (lambda () (wl-report "13s (still locked)")))

;; 19s: the lock client has exited; everything must work again.
(run-with-timer
 19 nil
 (lambda ()
   (wl-report "19s (after unlock)")
   (emacs-wm--log "--- injecting after unlock (must arrive)")
   (emacs-wm-inject "u" "Return")))

;; 20s: the lock is gone; the ordinary scene (and its borders) must be back.
(run-with-timer
 20 nil
 (lambda ()
   (emacs-wm--log "--- screenshot after unlock")
   (emacs-wm-spawn (concat wl-dir "/screenshot /tmp/visual-unlocked.ppm 5"
                           " 2>>/tmp/screenshot.log"))))

(run-with-timer 22 nil (lambda () (wl-report "22s (final)")))
