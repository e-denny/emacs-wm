;;; elisp-features.el --- exercise simulation keys, submaps, resync, desktops  -*- lexical-binding: t; -*-

;; Run inside a nested river whose child script restarts the daemon part way
;; through, so reconnection and re-attachment are exercised for real.

(require 'emacs-wm)

(emacs-wm--log "--- features test starting, socket %s" (emacs-wm-socket-path))

;; app-id rule with a simulation key: s-w means C-a h i Return in that app
(setq emacs-wm-window-rules
      '(((:app-id "kitty")
         (:float t :simulate (("s-w" . ("C-a" "h" "i" "Return")))))))

;; a one-shot submap, entered from elisp in the test
(setq emacs-wm-submaps
      '(("test" . (("f" . emacs-wm-toggle-float)
                   ("q" . emacs-wm-close-window)))))

(emacs-wm-enable)

;; timer errors otherwise vanish into *Messages*; the harness needs them
(advice-add 'timer-event-handler :around
            (lambda (fn &rest args)
              (condition-case err (apply fn args)
                (error (emacs-wm--log "TIMER ERROR: %S" err)))))

(defun ft-report (tag)
  (let ((oids (emacs-wm--output-oids)))
    (emacs-wm--log "%s: oids=%S desktops=%S desktop-frames=%d epoch=%S connected=%S"
                   tag oids
                   (let (acc) (dolist (o oids) (push (cons o (emacs-wm--desktop o)) acc)) acc)
                   (length (emacs-wm--desktop-frames))
                   emacs-wm--epoch (and emacs-wm--proc t))))

(run-with-timer 5 nil (lambda () (ft-report "5s")))

;; 7s: dynamic desktops -- 3 and 4 must exist, not just 1 and 2
(run-with-timer
 7 nil
 (lambda ()
   (emacs-wm--log "switching through desktops 3 and 4")
   (emacs-wm-switch-desktop 3)
   (run-with-timer 1 nil (lambda () (emacs-wm-switch-desktop 4)))
   (run-with-timer 2 nil (lambda () (emacs-wm-switch-desktop 1)))))

;; 9s: the bar state file must show the desktop we just switched to
(run-with-timer
 9 nil
 (lambda ()
   (let ((file (expand-file-name "emacs-wm.state.json"
                                 (or (getenv "XDG_RUNTIME_DIR") "/tmp"))))
     (when (file-exists-p file)
       (emacs-wm--log "state file now: %s"
                      (with-temp-buffer
                        (insert-file-contents file)
                        (buffer-string)))))))

;; 10s: the app window
(run-with-timer
 10 nil
 (lambda ()
   (emacs-wm--log "spawning the test app")
   (emacs-wm-spawn
    (concat "kitty -1 --title feat-app -o remember_window_size=no sh -c "
            "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/feat-app-input.txt; done'"))))

;; 15s: per-app simulation key -- press the bound key the way river would
(run-with-timer
 15 nil
 (lambda ()
   (let* ((wid (car (hash-table-keys emacs-wm--buffer-by-wid)))
          (buf (gethash wid emacs-wm--buffer-by-wid))
          (win (and buf (get-buffer-window buf))))
     (when win (select-window win))
     (emacs-wm--schedule-layout)
     (run-with-timer
      1 nil
      (lambda ()
        (let ((bid (gethash "s-w" emacs-wm--key-to-bid)))
          (emacs-wm--log "simulating a press of s-w (bid %S) in wid %S" bid wid)
          (emacs-wm--handle-key (list :bid bid :state "press"))))))))

;; 18s: submap -- enter it, then press its key
(run-with-timer
 18 nil
 (lambda ()
   (emacs-wm--log "--- submap test ---")
   (emacs-wm-enter-submap "test")
   (run-with-timer
    1 nil
    (lambda ()
      (let ((bid (gethash "f" emacs-wm--key-to-bid)))
        (emacs-wm--log "pressing submap key f (bid %S), submap=%S" bid emacs-wm--submap)
        (emacs-wm--handle-key (list :bid bid :state "press"))
        (emacs-wm--log "after submap key: submap=%S" emacs-wm--submap))))))

;; 22s: submap left by an unbound (eaten) key
(run-with-timer
 22 nil
 (lambda ()
   (emacs-wm--log "--- submap exit by unbound key ---")
   (emacs-wm-enter-submap "test")
   (run-with-timer 1 nil
                   (lambda ()
                     (emacs-wm--handle-key-unbound)
                     (emacs-wm--log "after unbound key: submap=%S" emacs-wm--submap)))))

;; 30s: the daemon is restarted by the child script around 26s; report state
(run-with-timer 30 nil (lambda () (ft-report "30s (after restart)")))

(run-with-timer
 33 nil
 (lambda ()
   (let ((wid (car (hash-table-keys emacs-wm--buffer-by-wid))))
     (emacs-wm--log "buffers after restart: %S"
                    (let (acc)
                      (maphash (lambda (w b) (push (list w (buffer-name b)) acc))
                               emacs-wm--buffer-by-wid)
                      acc))
     (emacs-wm--log "focused wid after restart: %S" wid)
     (when wid (emacs-wm-inject "r" "Return")))))

(run-with-timer 36 nil (lambda () (ft-report "36s")))
