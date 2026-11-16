;;; elisp-multi.el --- multi-output exercise of the emacs-wm client  -*- lexical-binding: t; -*-

;; Run in a nested river started with WLR_WL_OUTPUTS=2. Checks the per-output
;; desktop model: one set of desktop frames per output, switching one output
;; does not disturb the other, and a window can be moved to a desktop on its
;; own output.

(require 'emacs-wm)

(emacs-wm--log "--- multi-output test starting, socket %s" (emacs-wm-socket-path))
(setq emacs-wm-window-rules '(((:app-id "kitty") (:float t))))
(emacs-wm-enable)

(defun mt-report (tag)
  (let ((oids (emacs-wm--output-oids)))
    (emacs-wm--log "%s: outputs=%S desktops=%S frames=%S"
                   tag oids
                   (let (acc) (dolist (o oids) (push (cons o (emacs-wm--desktop o)) acc)) acc)
                   (mapcar #'emacs-wm--frame-name (emacs-wm--desktop-frames)))))

;; 6s: what did the daemon report?
(run-with-timer 6 nil (lambda () (mt-report "6s")))

;; 10s: an app window
(run-with-timer
 10 nil
 (lambda ()
   (emacs-wm--log "spawning the test app")
   (emacs-wm-spawn
    (concat "kitty -1 --title multi-app -o remember_window_size=no sh -c "
            "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/multi-app-input.txt; done'"))))

;; 14s: every output has its own visible desktop frame; report the split
(run-with-timer 14 nil (lambda () (mt-report "14s")))

;; 16s: switch desktop 2 on the FIRST output only -- the second output must
;; keep showing desktop 1.
(run-with-timer
 16 nil
 (lambda ()
   (let ((first (car (emacs-wm--output-oids))))
     (emacs-wm--log "switching output %s to desktop 2 (other output untouched)" first)
     (emacs-wm-switch-desktop 2 first))))

;; 19s: switch the SECOND output to desktop 2 as well
(run-with-timer
 19 nil
 (lambda ()
   (let ((second (cadr (emacs-wm--output-oids))))
     (emacs-wm--log "switching output %s to desktop 2" second)
     (emacs-wm-switch-desktop 2 second))))

;; 22s: back to desktop 1 on the first output -- the app lives there, so
;; switching back must reveal it again.
(run-with-timer
 22 nil
 (lambda ()
   (let ((first (car (emacs-wm--output-oids))))
     (emacs-wm--log "switching output %s back to desktop 1" first)
     (emacs-wm-switch-desktop 1 first)
     (run-with-timer
      1 nil
      (lambda ()
        (emacs-wm--log "after switching back: focused wid=%S (the app)"
                       (emacs-wm--focused-wid)))))))

;; 24s: desktop 2 hides the app: no focused app window, and the buffer stays
;; in the hidden frame's tree.
(run-with-timer
 24 nil
 (lambda ()
   (let ((first (car (emacs-wm--output-oids))))
     (emacs-wm--log "switching output %s to desktop 2 (app must be hidden)" first)
     (emacs-wm-switch-desktop 2 first)
     (run-with-timer
      1 nil
      (lambda ()
        (emacs-wm--log "on desktop 2: focused wid=%S (nil expected)"
                       (emacs-wm--focused-wid)))))))

;; 26s: back to the app's desktop, then type into it through the WM.
(run-with-timer
 26 nil
 (lambda ()
   (let ((first (car (emacs-wm--output-oids))))
     (emacs-wm-switch-desktop 1 first)
     (run-with-timer
      1 nil
      (lambda ()
        (let* ((wid (car (hash-table-keys emacs-wm--buffer-by-wid)))
               (buf (gethash wid emacs-wm--buffer-by-wid))
               (win (and buf (get-buffer-window buf))))
          (emacs-wm--log "injecting into wid %S (window %S)" wid win)
          (when win (select-window win))
          (emacs-wm--schedule-layout)
          (run-with-timer 1 nil (lambda () (emacs-wm-inject "o" "Return")))))))))

;; 31s: move the app to another desktop on its own output, then report
(run-with-timer
 31 nil
 (lambda ()
   (let ((wid (emacs-wm--focused-wid)))
     (if (null wid)
         (emacs-wm--log "move skipped: no focused app window")
       (emacs-wm--log "moving wid %S to desktop 3 on its own output %S"
                      wid (emacs-wm--wid-output wid))
       (emacs-wm-move-to-desktop 3)))))

;; 33s: the app must be focused again, on desktop 3 of its own output
(run-with-timer
 33 nil
 (lambda ()
   (let ((wid (emacs-wm--focused-wid)))
     (emacs-wm--log "after move: focused wid=%S output=%S desktop=%S"
                    wid
                    (and wid (emacs-wm--wid-output wid))
                    (emacs-wm--desktop (or (and wid (emacs-wm--wid-output wid))
                                           (emacs-wm--current-oid)))))))

(run-with-timer 36 nil (lambda () (mt-report "36s")))
