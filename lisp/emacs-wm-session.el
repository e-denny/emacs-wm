;;; emacs-wm-session.el --- start emacs-wm as a login session  -*- lexical-binding: t; -*-

;; The entry point a session (greeter, TTY, or `river -c ...') runs.  It is
;; deliberately tiny: all policy is in the configuration file, all mechanism is
;; in emacs-wm.el, and this file only decides the order.
;;
;;   emacs -Q -L .../lisp -l emacs-wm-session
;;
;; Order matters:
;;
;;   1. load the user configuration ($XDG_CONFIG_HOME/emacs-wm/config.el),
;;      after the built-in defaults, so it can override them;
;;   2. become the window manager -- this starts the backend Emacs;
;;   3. run the autostart commands from the configuration.
;;
;; Nothing here is needed to *use* emacs-wm from an existing session, which is
;; why the test drivers load their own scenario file instead.

;;; Code:

(require 'emacs-wm)

(emacs-wm-load-config)

(emacs-wm-enable)

(emacs-wm-run-startup-commands)

(provide 'emacs-wm-session)
;;; emacs-wm-session.el ends here
