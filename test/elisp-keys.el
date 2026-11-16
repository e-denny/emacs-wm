;;; elisp-keys.el --- real key presses through river's binding path  -*- lexical-binding: t; -*-

;; Every other test drives `emacs-wm--handle-key' from a timer.  This one types
;; into the session with test/keyinject, which creates a virtual keyboard the
;; way any client would (with a keymap fd).  River attaches it as an ordinary
;; input device, so the keys go through river's own binding matching:
;;
;;   keyinject -> wl_seat -> river KeyboardGroup -> river_xkb_binding_v1.pressed
;;            -> emacs-wm-be -> emacs-wm -> command

(require 'emacs-wm)

(defconst wk-dir "~/src/emacs-wm/test/tools/target/debug/keyinject")

(emacs-wm--log "--- real-key test starting, socket %s" (emacs-wm-socket-path))
(setq emacs-wm-window-rules '(((:app-id "kitty") (:float t))))
(emacs-wm-enable)

;; Every command the command loop actually runs, so we can tell whether a
;; pushed key event became a command at all.
(add-hook 'pre-command-hook
          (lambda ()
            (emacs-wm--log "CMD %S (binding s-2: %S, unread after: %d)"
                           this-command
                           (key-binding (kbd "s-2"))
                           (length unread-command-events))))

(defun wk-type (&rest args)
  (emacs-wm--log "--- keyinject %S" args)
  ;; Keep each helper's own output: a failed keymap upload or an unmappable
  ;; keysym is otherwise invisible.
  (emacs-wm-spawn
   (concat (mapconcat #'identity (cons wk-dir args) " ")
           " 2>>/tmp/keyinject.log")))

(defun wk-report (tag)
  (emacs-wm--log "%s: oid=%S desktop=%S focused=%S float=%S pongs=%d"
                 tag (emacs-wm--current-oid)
                 (emacs-wm--desktop (emacs-wm--current-oid))
                 (emacs-wm--focused-wid)
                 (let ((wid (emacs-wm--focused-wid)))
                   (and wid (plist-get (emacs-wm--rule-actions wid) :float)))
                 emacs-wm--pong-seen))

(run-with-timer 4 nil
                (lambda ()
                  (emacs-wm--log "spawning the app")
                  (emacs-wm-spawn
                   (concat "kitty -1 --title keys-app -o remember_window_size=no sh -c "
                           "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/keys-app-input.txt; done'"))))

(run-with-timer 8 nil (lambda () (wk-report "8s (before keys)")))

;; 10s: Super+f toggles floating (the rule floats kitty, so this turns it off).
(run-with-timer 10 nil (lambda () (wk-type "-m" "super" "f")))

;; 13s: type into the app with a real keyboard while it is visible.
(run-with-timer 13 nil (lambda () (wk-report "13s (app visible)")))
(run-with-timer
 14 nil
 (lambda ()
   (emacs-wm--log "typing into wid %S with a real keyboard" (emacs-wm--focused-wid))
   (wk-type "a" "b" "Return")))

;; 17s: Super+2 switches the desktop; the app must go away with desktop 1.
(run-with-timer 17 nil (lambda () (wk-type "-m" "super" "2")))
(run-with-timer 20 nil (lambda () (wk-report "20s (on desktop 2)")))

;; 22s: Super+1 brings it back, and typing works again.
(run-with-timer 22 nil (lambda () (wk-type "-m" "super" "1")))
(run-with-timer
 24 nil
 (lambda ()
   (wk-report "24s (back on desktop 1)")
   (wk-type "c" "Return")))

(run-with-timer 27 nil (lambda () (wk-report "27s (after typing)")))
