;;; elisp-test.el --- scripted exercise of the emacs-wm client  -*- lexical-binding: t; -*-

;; Loaded by test/run-elisp.sh inside a nested river session. Becomes the WM's
;; brain, spawns an app the way Emacs normally would, then types into it through
;; the injection path.

(require 'emacs-wm)

(emacs-wm--log "--- elisp-test starting, socket %s" (emacs-wm-socket-path))

;; Rule test: float anything called "kitty", the same shape as the blueman rule.
(setq emacs-wm-window-rules
      '(((:app-id "kitty") (:float t))))

(emacs-wm-enable)

;; 8s: an app window, spawned by Emacs (so it inherits this session's env --
;; this is also the fix for dbus-activated apps landing outside the session).
(run-with-timer
 8 nil
 (lambda ()
   (emacs-wm--log "spawning the test app")
   (emacs-wm-spawn
    (concat "kitty -1 --title elisp-app -o remember_window_size=no sh -c "
            "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/elisp-app-input.txt; done'"))))

;; 14s: report what Emacs thinks the layout is.
(run-with-timer
 14 nil
 (lambda ()
   (condition-case err
       (progn
   (emacs-wm--log "selected buffer: %S" (buffer-name (window-buffer (selected-window))))
   (emacs-wm--log "app buffers: %S"
                  (let (acc)
                    (maphash (lambda (wid buf)
                               (push (list wid (buffer-name buf)
                                           (and (get-buffer-window buf) t))
                                     acc))
                             emacs-wm--buffer-by-wid)
                    acc))
   (emacs-wm--log "rules=%S -> actions %S"
                  emacs-wm-window-rules (emacs-wm--rule-actions 4278190084))
   (emacs-wm--log "fid map: %S"
                  (let (acc)
                    (maphash (lambda (name fid) (push (cons name fid) acc))
                             emacs-wm--fid-by-name)
                    acc)))
     (error (emacs-wm--log "14s timer error: %S" err)))))

;; 18s: switch desktop from elisp (the WM key "s-2" calls the same function).
(run-with-timer
 18 nil
 (lambda ()
   (emacs-wm--log "switching to desktop 2 via elisp")
   (emacs-wm-desktop-2)))

;; 16s: select the app window, then type into it via the WM.
(run-with-timer
 16 nil
 (lambda ()
   (let* ((wid (car (hash-table-keys emacs-wm--buffer-by-wid)))
          (buf (gethash wid emacs-wm--buffer-by-wid))
          (win (and buf (get-buffer-window buf))))
     (emacs-wm--log "injecting into wid %S (window %S)" wid win)
     (when win (select-window win))
     (emacs-wm--schedule-layout)
     (run-with-timer 1 nil (lambda () (emacs-wm-inject "j" "Return"))))))

;; 20s: exercise the daily-driving commands the way the WM keys do.
(run-with-timer
 20 nil
 (lambda ()
   (let* ((wid (car (hash-table-keys emacs-wm--buffer-by-wid)))
          (buf (gethash wid emacs-wm--buffer-by-wid)))
     (emacs-wm--log "--- daily driving checks (wid %S) ---" wid)
     ;; click-to-focus: what the daemon sends on pointer_enter
     (emacs-wm--handle (list :t "pointer-enter" :wid wid))
     (emacs-wm--log "selected after pointer-enter: %S"
                    (buffer-name (window-buffer (selected-window))))
     ;; fullscreen
     (emacs-wm-toggle-fullscreen)
     (emacs-wm--log "requested fullscreen"))))

;; 21s: border-only change -- widen the borders without touching any geometry,
;; focus or visibility. This is the case the daemon's "identical snapshot"
;; guard used to swallow.
(run-with-timer
 21 nil
 (lambda ()
   (emacs-wm--log "--- border-only change: width 2 -> 3 ---")
   (setq emacs-wm-border-width 3)
   (emacs-wm--schedule-layout)))

(run-with-timer
 22 nil
 (lambda ()
   (emacs-wm--log "--- border-only change: width 3 -> 2 ---")
   (setq emacs-wm-border-width 2)
   (emacs-wm--schedule-layout)))

;; 24s: minimise, then leave fullscreen
(run-with-timer
 24 nil
 (lambda ()
   (emacs-wm-toggle-fullscreen)
   (emacs-wm--log "left fullscreen")
   (emacs-wm-minimize-window)
   (emacs-wm--log "minimised")))

;; 26s: close the focused window (s-q)
(run-with-timer
 26 nil
 (lambda ()
   (emacs-wm--log "closing focused window")
   (emacs-wm-close-window)))
