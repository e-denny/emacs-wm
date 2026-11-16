;;; elisp-wedge.el --- does the frontend notice a wedged backend?  -*- lexical-binding: t; -*-

;; The backend is stopped with SIGSTOP: alive, still listening, but not
;; answering.  The ping watchdog must notice, kill it, start a fresh one, and
;; resync -- without losing the app buffer.

(require 'emacs-wm)

(emacs-wm--log "--- wedge test starting, socket %s" (emacs-wm-socket-path))

;; Short timeouts so the test finishes quickly.
(setq emacs-wm-ping-interval 3.0
      emacs-wm-ping-timeout 2.0)

(emacs-wm-enable)

(defun wt-report (tag)
  (emacs-wm--log "%s: epoch=%S connected=%S pongs=%d respawns=%d buffers=%S"
                 tag emacs-wm--epoch (and (process-live-p emacs-wm--proc) t)
                 emacs-wm--pong-seen emacs-wm--respawn-count
                 (let (acc) (maphash (lambda (w b) (push (cons w (buffer-name b)) acc))
                                     emacs-wm--buffer-by-wid) acc)))

(run-with-timer 6 nil
                (lambda ()
                  (emacs-wm--log "spawning the app")
                  (emacs-wm-spawn
                   (concat "kitty -1 --title wedge-app -o remember_window_size=no sh -c "
                           "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/wedge-app-input.txt; done'"))))

(run-with-timer 10 nil (lambda () (wt-report "10s (healthy)")))

;; 12s: wedge the backend.
(run-with-timer
 12 nil
 (lambda ()
   (emacs-wm--log "--- stopping the backend with SIGSTOP (wedged, not dead) ---")
   (call-process "pkill" nil nil nil "-STOP" "-f" "emacs-wm-be")))

(run-with-timer 20 nil (lambda () (wt-report "20s (should have restarted)")))

;; 24s: does the recovered backend still receive state and inject?
(run-with-timer
 24 nil
 (lambda ()
   (let* ((wid (car (hash-table-keys emacs-wm--buffer-by-wid)))
          (buf (gethash wid emacs-wm--buffer-by-wid)))
     (emacs-wm--log "after recovery: wid=%S buffer=%S" wid (and buf (buffer-name buf)))
     (when buf
       (pop-to-buffer buf)
       (emacs-wm--schedule-layout)
       (run-with-timer 1 nil (lambda () (emacs-wm-inject "c" "Return")))))))

(run-with-timer 30 nil (lambda () (wt-report "30s (after inject)")))
