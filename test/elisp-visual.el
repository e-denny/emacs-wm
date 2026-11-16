;;; elisp-visual.el --- borders and positions, looked at  -*- lexical-binding: t; -*-

;; Two tiled app windows, a screenshot of each focus state.  The driver turns
;; the PPM into a PNG and samples the border pixels against the expected
;; colours, so "the border is drawn" stops being a protocol-level inference.

(require 'emacs-wm)

(emacs-wm--log "--- visual test starting, socket %s" (emacs-wm-socket-path))
(setq emacs-wm-window-rules nil)        ; tile everything, no floats
(setq emacs-wm-border-width 2)
(emacs-wm-enable)

(defconst wv-shot
  (expand-file-name
   "screenshot"
   (or (getenv "EMACS_WM_TEST_TOOLS")
       (expand-file-name "tools/target/debug"
                         (file-name-directory (or load-file-name
                                                  buffer-file-name))))))

(defun wv-screenshot (name)
  "Capture NAME, retrying while the nested host refuses to present a frame.
Screencopy needs the compositor to render the output; a nested session whose
host window is occluded for a moment answers no frame at all.  Each attempt
gets a short deadline so several fit inside one scenario."
  (emacs-wm--log "--- screenshot %s" name)
  (cl-labels
      ((attempt
        (n)
        (unless (file-exists-p (format "/tmp/visual-%s.ppm" name))
          (emacs-wm--log "--- screenshot %s attempt %d" name n)
          ;; The PPM is what the driver samples; the PNG is for humans.
          (emacs-wm-spawn (format "%s /tmp/visual-%s.ppm 3 2>>/tmp/visual-tool.log"
                                  wv-shot name))
          ;; The tool gives up after its deadline (3s); try again a little
          ;; later, up to four attempts.
          (when (< n 4)
            (run-with-timer 5 nil (lambda () (attempt (1+ n))))))))
    (attempt 1)))

;; 4s: first window (kitty, titled so the layout log is readable).
(run-with-timer 4 nil
                (lambda ()
                  (emacs-wm-spawn "kitty -1 --title vis-a -o remember_window_size=no sleep 600")))

;; 6s: second window from a different app (wev just sits there).
(run-with-timer 6 nil (lambda () (emacs-wm-spawn "wev")))

;; 9s: both tiled, one of them focused.
(run-with-timer 9 nil (lambda () (wv-screenshot "focused-a")))

;; 12s: focus the other one and capture again.
(run-with-timer
 12 nil
 (lambda ()
   (let ((wids (hash-table-keys emacs-wm--buffer-by-wid)))
     (emacs-wm--log "buffers: %S" wids)
     ;; The one that is not focused now.
     (let ((other (seq-find (lambda (w) (not (eql w (emacs-wm--focused-wid)))) wids)))
       (emacs-wm--log "focusing %S" other)
       (when other (emacs-wm--focus-app-wid other))))))

(run-with-timer 14 nil (lambda () (wv-screenshot "focused-b")))
