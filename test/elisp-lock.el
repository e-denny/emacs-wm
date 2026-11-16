;;; elisp-lock.el --- what the WM does while the session is locked  -*- lexical-binding: t; -*-

;; test/tools/lockclient takes an ext-session-lock lock and paints every output
;; solid, exactly as a real locker would.  While it holds the lock the WM must
;; keep out of the way: no focus changes, no injected keys, no ordinary
;; bindings.  Afterwards everything must work again.
;;
;; The checks are driven by the WM's own `locked' state, not by absolute timers.
;; How long river takes to confirm a lock depends on the host compositor
;; presenting a frame (a nested session's host can be busy), which a test cannot
;; schedule; watching the state makes a slow compositor slow the test down
;; instead of failing it.

(require 'emacs-wm)

(defconst wl-dir
  (or (getenv "EMACS_WM_TEST_TOOLS")
      (expand-file-name "tools/target/debug"
                        (file-name-directory (or load-file-name
                                                 buffer-file-name))))
  "Directory of the native helpers (test/tools/target/debug), for spawning them.")

(emacs-wm--log "--- lock test starting, socket %s" (emacs-wm-socket-path))
(setq emacs-wm-window-rules '(((:app-id "kitty") (:float t))))
(emacs-wm-enable)

(defun wl-report (tag)
  (emacs-wm--log "%s: locked=%S focused=%S buffers=%S"
                 tag emacs-wm--locked (emacs-wm--focused-wid)
                 (hash-table-count emacs-wm--buffer-by-wid)))

(defvar wl-was-locked nil)
(defvar wl-unlocked nil)

(run-with-timer 4 nil
                (lambda ()
                  (emacs-wm-spawn
                   (concat "kitty -1 --title lock-app -o remember_window_size=no sh -c "
                           "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/lock-app-input.txt; done'"))))

(run-with-timer 8 nil (lambda () (wl-report "before the lock")))

;; 9s: take the lock.  The client waits for the compositor to confirm it and
;; then holds it for 8s.
(run-with-timer
 9 nil
 (lambda ()
   (emacs-wm--log "--- taking the session lock (8s hold)")
   (emacs-wm-spawn (concat wl-dir "/lockclient 8 202020 2>>/tmp/lockclient.log"))))

(defvar wl-watch
  (run-with-timer
   0.25 0.25
   (lambda ()
     (cond
      ;; The lock engaged: everything that must not work, tried for real.
      ((and emacs-wm--locked (not wl-was-locked))
       (setq wl-was-locked t)
       (wl-report "locked (lock engaged)")
       (emacs-wm--log "--- injecting while locked (must be refused)")
       (emacs-wm-inject "x" "Return")
       (emacs-wm--log "--- pressing Super+2 while locked (must be ignored)")
       (emacs-wm-spawn (concat wl-dir "/keyinject -m super 2 2>>/tmp/keyinject.log"))
       (run-with-timer
        1 nil
        (lambda ()
          (emacs-wm--log "--- screenshot of the locked session")
          (emacs-wm-spawn (concat wl-dir "/screenshot /tmp/visual-locked.ppm 5"
                                  " 2>>/tmp/screenshot.log")))))
      ;; The lock was released: everything must work again.
      ((and wl-was-locked (not emacs-wm--locked) (not wl-unlocked))
       (setq wl-unlocked t)
       (wl-report "unlocked (lock released)")
       (emacs-wm--log "--- injecting after unlock (must arrive)")
       (emacs-wm-inject "u" "Return")
       (run-with-timer
        1 nil
        (lambda ()
          (emacs-wm--log "--- screenshot after unlock")
          (emacs-wm-spawn (concat wl-dir "/screenshot /tmp/visual-unlocked.ppm 5"
                                  " 2>>/tmp/screenshot.log")))))))))

;; Safety net: always end the run, and say what state it ended in.
(run-with-timer 26 nil
                (lambda ()
                  (when (timerp wl-watch) (cancel-timer wl-watch))
                  (wl-report "final")))
