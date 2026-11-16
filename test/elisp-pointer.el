;;; elisp-pointer.el --- real pointer drag moves a window  -*- lexical-binding: t; -*-

;; The op plumbing was verified with a real key press but zero deltas; this
;; drives it with actual pointer motion: Super+left-button drag on a tiled
;; window, using test/tools/pointerinject (a virtual pointer, which river
;; attaches as an ordinary pointer device).

(require 'emacs-wm)

(defconst wp-dir "~/src/emacs-wm/test/tools/target/debug")

(emacs-wm--log "--- pointer test starting, socket %s" (emacs-wm-socket-path))
(setq emacs-wm-window-rules nil)        ; start tiled
(emacs-wm-enable)

(defun wp-rect (wid)
  (and wid (gethash wid emacs-wm--rect-override)))

(defun wp-report (tag)
  (let ((wid (emacs-wm--focused-wid)))
    (emacs-wm--log "%s: focused=%S override=%S float-override=%S"
                   tag wid (wp-rect wid)
                   (and wid (gethash wid emacs-wm--float-override)))))

(run-with-timer 4 nil
                (lambda ()
                  (emacs-wm-spawn "kitty -1 --title ptr-app -o remember_window_size=no sleep 600")))

(run-with-timer 8 nil (lambda () (wp-report "8s (before the drag)")))

;; 10s: Super + left button, dragged by (200, 120).
(run-with-timer
 10 nil
 (lambda ()
   (emacs-wm--log "--- pointer drag Super+BTN_LEFT by 200,120")
   (emacs-wm-spawn (concat wp-dir "/pointerinject drag 200 120 -m super -b 272"
                           " 2>>/tmp/pointerinject.log"))))

(run-with-timer 14 nil (lambda () (wp-report "14s (after the drag)")))

;; 16s: Super + right button resizes from the bottom-right corner.
(run-with-timer
 16 nil
 (lambda ()
   (emacs-wm--log "--- pointer resize Super+BTN_RIGHT by 100,80")
   (emacs-wm-spawn (concat wp-dir "/pointerinject drag 100 80 -m super -b 273"
                           " 2>>/tmp/pointerinject.log"))))

(run-with-timer 20 nil (lambda () (wp-report "20s (after the resize)")))

;; 21s: a screenshot of the moved+resized window.
(run-with-timer
 21 nil
 (lambda ()
   (emacs-wm--log "--- screenshot after drag and resize")
   (emacs-wm-spawn (concat wp-dir "/screenshot /tmp/visual-dragged.ppm 5"
                           " 2>>/tmp/pointerinject.log"))))

(run-with-timer 24 nil (lambda () (wp-report "24s (final)")))
