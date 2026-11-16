;;; config-tests.el --- tests for the configuration layer  -*- lexical-binding: t; -*-

;; The configuration is data, so it can be checked without a compositor: every
;; command name must resolve, every key must be one the compositor can hand
;; over, the shipped firefox `:simulate' rules must translate, and the user's
;; file must be able to override the shipped one.
;;
;; Nothing here starts a process or loads the user's real configuration; the
;; loader tests use a temporary file.

;;; Code:

(require 'ert)
(require 'seq)
(require 'emacs-wm)

;;; The command table

(ert-deftest config-commands-are-well-formed ()
  "Every entry is (NAME FUNCTION DOCSTRING) and FUNCTION is a command."
  (should emacs-wm-commands)
  (dolist (entry emacs-wm-commands)
    (should (stringp (nth 0 entry)))
    (should (symbolp (nth 1 entry)))
    (should (commandp (nth 1 entry)))
    (should (stringp (nth 2 entry))))
  (should (= (length emacs-wm-commands)
             (length (delete-dups (mapcar #'car emacs-wm-commands))))))

(ert-deftest config-desktop-commands-exist-for-every-number ()
  "s-9 has a command even though only four desktops are created by default."
  (dotimes (i emacs-wm--max-desktop-key)
    (let ((n (1+ i)))
      (should (commandp (intern (format "emacs-wm-desktop-%d" n))))
      (should (commandp (intern (format "emacs-wm-move-to-desktop-%d" n)))))))

;;; The bindings

(ert-deftest config-bindings-resolve-to-commands ()
  "Each bound COMMAND names an existing command, whichever form it uses."
  (should emacs-wm-key-bindings)
  (dolist (binding emacs-wm-key-bindings)
    (should (stringp (car binding)))
    (should (commandp (emacs-wm--binding-command (cdr binding))))))

(ert-deftest config-binding-keys-are-unique ()
  (let ((keys (mapcar #'car emacs-wm-key-bindings)))
    (should (equal keys (delete-dups (copy-sequence keys))))))

(ert-deftest config-binding-keys-are-interceptable ()
  "A key the compositor cannot match would be a binding that never fires."
  (dolist (binding emacs-wm-key-bindings)
    (should (emacs-wm--key->binding (car binding)))))

(ert-deftest config-simulate-keys-are-interceptable ()
  "The keys only a `:simulate' rule uses must be registered too."
  (let ((names (emacs-wm--simulate-key-names)))
    (should (member "C-v" names))
    (should (member "M-x" names))
    (dolist (name names)
      (should (emacs-wm--key->binding name)))))

(ert-deftest config-unknown-command-name-is-an-error ()
  "A typo in the configuration must be loud, not a key that does nothing."
  (let ((emacs-wm-key-bindings '(("s-t" . "no-such-command"))))
    (should-error (emacs-wm-apply-bindings))))

(ert-deftest config-apply-bindings-builds-the-map ()
  (emacs-wm-apply-bindings)
  (dolist (binding emacs-wm-key-bindings)
    (should (commandp (lookup-key emacs-wm-command-map (kbd (car binding))))))
  (should (eq (lookup-key emacs-wm-command-map (kbd "s-f"))
              #'emacs-wm-toggle-float)))

(ert-deftest config-apply-bindings-rebuilds-from-scratch ()
  "Removing a binding from the configuration removes it from the map."
  (let ((emacs-wm-key-bindings '(("s-t" . "toggle-float"))))
    (emacs-wm-apply-bindings)
    (should (commandp (lookup-key emacs-wm-command-map (kbd "s-t"))))
    (should-not (lookup-key emacs-wm-command-map (kbd "s-f")))))

(ert-deftest config-argument-bindings-work ()
  "A (FUNCTION . ARGS) binding becomes a command that calls FUNCTION."
  (let ((emacs-wm-key-bindings '(("s-9" . (emacs-wm-switch-desktop 9)))))
    (emacs-wm-apply-bindings)
    (let ((command (lookup-key emacs-wm-command-map (kbd "s-9"))))
      (should (commandp command))
      ;; `emacs-wm-switch-desktop' logs "no desktop 9" and returns nil; what
      ;; matters is that the argument arrives.
      (let (called)
        (cl-letf (((symbol-function 'emacs-wm-switch-desktop)
                   (lambda (n &optional _oid) (setq called n))))
          (call-interactively command)
          (should (eql called 9)))))))

(ert-deftest config-global-bindings-are-defined ()
  "A forwarded key reaches Emacs through `global-map'."
  (emacs-wm-apply-bindings)
  (emacs-wm--define-global-bindings)
  (should (eq (lookup-key global-map (kbd "s-f")) #'emacs-wm-toggle-float))
  (should (eq (lookup-key global-map (kbd "s-2")) #'emacs-wm-desktop-2)))

;;; Window rules

(defun config-test--window (wid app-id &optional title)
  "Pretend WID is a window of APP-ID, so rules can be evaluated."
  (puthash wid (list :app-id app-id :title (or title app-id))
           emacs-wm--meta-by-wid))

(ert-deftest config-firefox-rule-translates-emacs-keys ()
  "The Firefox samples translate Emacs bindings, not WM keys."
  (unwind-protect
      (progn
        (config-test--window 4242 "firefox" "Mozilla Firefox")
        (should (equal (emacs-wm--simulate-for 4242 "C-v") '("<next>")))
        (should (equal (emacs-wm--simulate-for 4242 "M-v") '("<prior>")))
        (should (equal (emacs-wm--simulate-for 4242 "C-s") '("C-f")))
        (should (equal (emacs-wm--simulate-for 4242 "C-l") '("C-l")))
        (should (equal (emacs-wm--simulate-for 4242 "C-w") '("C-w")))
        (should (equal (emacs-wm--simulate-for 4242 "C-t") '("C-t")))
        (should (equal (emacs-wm--simulate-for 4242 "C-a") '("C-a")))
        (should (equal (emacs-wm--simulate-for 4242 "M-x") '("C-l")))
        ;; A WM key inside Firefox that is not simulated still runs its own
        ;; binding (s-q closes the window).
        (should-not (emacs-wm--simulate-for 4242 "s-q")))
    (remhash 4242 emacs-wm--meta-by-wid)))

(ert-deftest config-rules-do-not-touch-other-apps ()
  (unwind-protect
      (progn
        (config-test--window 4243 "kitty" "kitty")
        (should-not (emacs-wm--simulate-for 4243 "C-v"))
        (should-not (plist-get (emacs-wm--rule-actions 4243) :float)))
    (remhash 4243 emacs-wm--meta-by-wid)))

(ert-deftest config-float-rule-applies ()
  (unwind-protect
      (progn
        (config-test--window 4244 "blueman-manager" "Bluetooth Manager")
        (should (plist-get (emacs-wm--rule-actions 4244) :float)))
    (remhash 4244 emacs-wm--meta-by-wid)))

;;; Simulation: precedence and pass-through
;;
;; The interesting case is the key that means something in Emacs *and* in the
;; app (C-v).  With a rule it is translated; without one it has to reach the
;; app unchanged; and a key the user keeps for Emacs (C-x) must still reach
;; Emacs.  These tests drive `emacs-wm--handle-key' directly, with the send
;; function stubbed out, so no compositor is needed.

(defun config-test--press (key)
  "Handle a press of KEY as if the compositor forwarded it.
Returns a cons of (MESSAGES-SENT . UNREAD-EVENTS-ADDED)."
  (let ((bid (gethash key emacs-wm--key-to-bid))
        (sent nil)
        (unread-before (length unread-command-events)))
    (should bid)
    (cl-letf (((symbol-function 'emacs-wm--send)
               (lambda (msg) (push msg sent))))
      (emacs-wm--handle-key (list :bid bid :state "press")))
    (cons (nreverse sent)
          (seq-take unread-command-events
                    (- (length unread-command-events) unread-before)))))

(defun config-test--focused (wid app-id)
  "Make WID (of APP-ID) the focused window, the way a click would."
  (config-test--window wid app-id)
  (let ((buffer (generate-new-buffer (format " *%s*" app-id))))
    (with-current-buffer buffer
      (setq-local emacs-wm-wid wid))
    (set-window-buffer (selected-window) buffer)
    buffer))

(ert-deftest config-simulate-wins-over-the-wm-binding ()
  "In Firefox, C-v translates; the injected message is the translation."
  (emacs-wm-apply-bindings)
  (emacs-wm--register-bindings)
  (let* ((buffer (config-test--focused 5100 "firefox"))
         (result (config-test--press "C-v"))
         (sent (car result)))
    (unwind-protect
        (progn
          (should (= 1 (length sent)))
          (should (equal (plist-get (car sent) :t) "inject"))
          (should (equal (aref (plist-get (car sent) :keys) 0)
                         '(:name "next" :mods 0)))
          (should-not (cdr result)))
      (kill-buffer buffer)
      (remhash 5100 emacs-wm--meta-by-wid))))

(ert-deftest config-unmatched-simulate-key-is-passed-through ()
  "In an app with no rule, C-v reaches the app unchanged (Ctrl+v)."
  (emacs-wm-apply-bindings)
  (emacs-wm--register-bindings)
  (let* ((buffer (config-test--focused 5101 "kitty"))
         (result (config-test--press "C-v"))
         (sent (car result)))
    (unwind-protect
        (progn
          (should (= 1 (length sent)))
          (should (equal (plist-get (car sent) :t) "inject"))
          (should (equal (aref (plist-get (car sent) :keys) 0)
                         '(:name "v" :mods 4))))
      (kill-buffer buffer)
      (remhash 5101 emacs-wm--meta-by-wid))))

(ert-deftest config-intercepted-prefix-still-reaches-emacs ()
  "C-x is in `emacs-wm-intercepted-prefixes': Emacs gets it, nothing is injected."
  (emacs-wm-apply-bindings)
  (emacs-wm--register-bindings)
  (let* ((buffer (config-test--focused 5102 "kitty"))
         (result (config-test--press "C-x"))
         (sent (car result))
         (unread (cdr result)))
    (unwind-protect
        (progn
          (should-not sent)
          (should (equal unread (list (cons t 24)))))
      (kill-buffer buffer)
      (remhash 5102 emacs-wm--meta-by-wid))))

(ert-deftest config-wm-binding-wins-over-pass-through ()
  "A Super binding is a WM command, in every app."
  (emacs-wm-apply-bindings)
  (emacs-wm--register-bindings)
  (let* ((buffer (config-test--focused 5103 "kitty"))
         (result (config-test--press "s-f")))
    (unwind-protect
        (progn
          (should-not (car result))          ; nothing injected
          (should (cdr result)))             ; the event is queued for Emacs
      (kill-buffer buffer)
      (remhash 5103 emacs-wm--meta-by-wid))))

(ert-deftest config-mx-in-firefox-is-the-browser-prompt ()
  "M-x is both an intercepted prefix and a Firefox simulation: the rule wins."
  (emacs-wm-apply-bindings)
  (emacs-wm--register-bindings)
  (let* ((buffer (config-test--focused 5104 "firefox"))
         (result (config-test--press "M-x"))
         (sent (car result)))
    (unwind-protect
        (progn
          (should (= 1 (length sent)))
          (should (equal (aref (plist-get (car sent) :keys) 0)
                         '(:name "l" :mods 4))))
      (kill-buffer buffer)
      (remhash 5104 emacs-wm--meta-by-wid))))

;;; Loading the user's file

(defun config-test--with-temp-config (contents function)
  "Write CONTENTS to a temporary config file and call FUNCTION with its path."
  (let* ((dir (make-temp-file "emacs-wm-config" t))
         (file (expand-file-name "config.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file file (insert contents))
          (funcall function file))
      (delete-directory dir t))))

(ert-deftest config-user-file-overrides-the-defaults ()
  (config-test--with-temp-config
   ";;; -*- lexical-binding: t; -*-\n(setq emacs-wm-border-width 7)
(setq emacs-wm-popup-command \"my-terminal\")
(setq emacs-wm-key-bindings
      (append emacs-wm-key-bindings '((\"s-x\" . \"toggle-float\"))))
"
   (lambda (file)
     (unwind-protect
         (progn
           (should (emacs-wm-load-config file))
           (should (= emacs-wm-border-width 7))
           (should (equal emacs-wm-popup-command "my-terminal"))
           (should (assoc "s-x" emacs-wm-key-bindings))
           (emacs-wm-apply-bindings)
           (should (eq (lookup-key emacs-wm-command-map (kbd "s-x"))
                       #'emacs-wm-toggle-float)))
       (setq emacs-wm-border-width 2
             emacs-wm-popup-command "blueman-manager"
             emacs-wm-key-bindings (assoc-delete-all "s-x" emacs-wm-key-bindings))
       (emacs-wm-apply-bindings)))))

(ert-deftest config-reload-reapplies-a-changed-file ()
  "Reloading replaces the bindings instead of adding to them."
  (let ((original emacs-wm-key-bindings))
    (config-test--with-temp-config
     ";;; -*- lexical-binding: t; -*-\n(setq emacs-wm-key-bindings '((\"s-y\" . \"toggle-float\")))\n"
     (lambda (file)
       (unwind-protect
           (progn
             (emacs-wm-reload-config file)
             (should (eq (lookup-key emacs-wm-command-map (kbd "s-y"))
                         #'emacs-wm-toggle-float))
             (should (eq (lookup-key global-map (kbd "s-y"))
                         #'emacs-wm-toggle-float))
             ;; s-f was bound before the reload and is not in the new file.
             (should-not (lookup-key emacs-wm-command-map (kbd "s-f"))))
         (setq emacs-wm-key-bindings original)
         (emacs-wm-apply-bindings)
         (emacs-wm--define-global-bindings)
         (define-key global-map (kbd "s-y") nil))))))

(ert-deftest config-missing-user-file-is-not-an-error ()
  "A session with no personal configuration must simply use the defaults."
  (should-not (emacs-wm-load-config "/nonexistent/emacs-wm/config.el")))

(provide 'config-tests)
;;; config-tests.el ends here
