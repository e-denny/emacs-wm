;;; elisp-ops.el --- interactive move/resize plumbing  -*- lexical-binding: t; -*-

;; river reports pointer deltas only while an op is live, so this drives the
;; whole path: a real key press starts the op through the WM binding, river
;; acknowledges it and starts sending op_delta, the frontend cancels it, river
;; sends op_release, and the backend reports the final rect back.  What is NOT
;; covered here is moving the pointer itself: this environment has no virtual
;; pointer client, so the deltas are all (0 . 0).  The geometry those deltas
;; feed is unit-tested in test/be-tests.el.

(require 'emacs-wm)

(defconst wo-keyinject
  (expand-file-name
   "keyinject"
   (or (getenv "EMACS_WM_TEST_TOOLS")
       (expand-file-name "tools/target/debug"
                         (file-name-directory (or load-file-name
                                                  buffer-file-name))))))

(emacs-wm--log "--- op test starting, socket %s" (emacs-wm-socket-path))
(setq emacs-wm-window-rules '(((:app-id "kitty") (:float t))))
(emacs-wm-enable)

(defun wo-report (tag)
  (let* ((wid (emacs-wm--focused-wid))
         (rect (and wid (gethash wid emacs-wm--rect-override))))
    (emacs-wm--log "%s: focused=%S rect-override=%S float-override=%S"
                   tag wid rect
                   (and wid (gethash wid emacs-wm--float-override)))))

(run-with-timer 4 nil
                (lambda ()
                  (emacs-wm-spawn
                   (concat "kitty -1 --title ops-app -o remember_window_size=no sh -c "
                           "'while IFS= read -r l; do printf \"%s\\n\" \"$l\" >> /tmp/ops-app-input.txt; done'"))))

(run-with-timer 8 nil (lambda () (wo-report "8s (before the op)")))

;; 10s: Super+F7 is bound to `emacs-wm-move-window'; press it for real.
(run-with-timer
 10 nil
 (lambda ()
   (emacs-wm--log "--- pressing Super+F7 (move) with a real keyboard")
   (emacs-wm-spawn (concat wo-keyinject " -m super F7 2>>/tmp/keyinject.log"))))

(run-with-timer 13 nil (lambda () (wo-report "13s (op should be live)")))

;; 14s: cancel the op from elisp, as Escape would.
(run-with-timer
 14 nil
 (lambda ()
   (let ((wid (emacs-wm--focused-wid)))
     (emacs-wm--log "--- ending the op for wid %S" wid)
     (emacs-wm--send (list :t "op-end" :wid wid)))))

(run-with-timer 17 nil (lambda () (wo-report "17s (op should be finished)")))

;; 19s: the window must still take input afterwards.
(run-with-timer
 19 nil
 (lambda ()
   (let ((wid (emacs-wm--focused-wid)))
     (emacs-wm--log "injecting into wid %S after the op" wid)
     (when wid (emacs-wm-inject "m" "Return")))))

(run-with-timer 21 nil (lambda () (wo-report "21s (final)")))
