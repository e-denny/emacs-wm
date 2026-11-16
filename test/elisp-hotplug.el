;;; elisp-hotplug.el --- output removal, as far as it can be driven here  -*- lexical-binding: t; -*-

;; river 0.6 has no output-management protocol and a nested output is a window
;; of the *host* compositor, so a real output cannot be unplugged from inside
;; this session.  What *can* be tested honestly is our side of it: the
;; frontend's `output-removed' handling (delete that output's desktop frames,
;; forget it, keep working on the survivors) and the backend's `output' path.
;; The backend's river_output_v1.removed handler is the only part that stays
;; unexercised; it is three statements that mirror the ones tested here.

(require 'emacs-wm)

(emacs-wm--log "--- hotplug test starting, socket %s" (emacs-wm-socket-path))
(setq emacs-wm-window-rules '(((:app-id "kitty") (:float t))))
(emacs-wm-enable)

(defun ht-report (tag)
  (emacs-wm--log "%s: oids=%S frames=%S desktop-by-oid=%S"
                 tag (emacs-wm--output-oids)
                 (mapcar #'emacs-wm--frame-name (emacs-wm--desktop-frames))
                 (let (acc) (maphash (lambda (o d) (push (cons o d) acc))
                                     emacs-wm--desktop-by-oid) acc)))

(run-with-timer 5 nil (lambda () (ht-report "5s (two outputs)")))

;; 8s: remove the second output exactly as the backend would report it.
(run-with-timer
 8 nil
 (lambda ()
   (let ((victim (cadr (emacs-wm--output-oids))))
     (if (null victim)
         (emacs-wm--log "only one output; nothing to remove")
       (emacs-wm--log "removing output %s (synthetic output-removed)" victim)
       (emacs-wm--handle (list :t "output-removed" :oid victim))
       (run-with-timer 1 nil (lambda () (ht-report "9s (after removal)")))))))

;; 12s: the surviving output must still create a desktop and mirror a window.
(run-with-timer
 12 nil
 (lambda ()
   (emacs-wm--log "spawning the app on the surviving output")
   (emacs-wm-spawn
    (concat "kitty -1 --title hotplug-app -o remember_window_size=no sh -c "
            "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/hotplug-app-input.txt; done'"))))

(run-with-timer
 16 nil
 (lambda ()
   (let ((wid (emacs-wm--focused-wid)))
     (emacs-wm--log "focused wid after removal: %S (output %S)" wid
                    (and wid (emacs-wm--wid-output wid)))
     (when wid (emacs-wm-inject "h" "Return")))))

(run-with-timer 19 nil (lambda () (ht-report "19s (final)")))
