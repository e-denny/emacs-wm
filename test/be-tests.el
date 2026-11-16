;;; be-tests.el --- unit tests for the backend's pure parts  -*- lexical-binding: t; -*-

;; These are deliberately narrow: the parts of lisp/emacs-wm-be.el that are
;; pure functions (pointer-op geometry, keysym/keycode tables, frame-name
;; parsing).  Everything that talks to river is covered by the end-to-end
;; suites instead.

;;; Code:

(require 'ert)
(require 'emacs-wm-be)

;;; Interactive move/resize geometry
;;
;; river sends *cumulative* deltas (measured from the op's start), not
;; incremental ones, so applying a delta twice must not double the movement.

(defconst bt-dir (file-name-directory (or load-file-name buffer-file-name)))

(defun bt-op (kind sx sy sw sh &optional edges)
  (list :wid 1 :kind kind :edges (or edges 10)
        :start-x sx :start-y sy :start-w sw :start-h sh
        :x sx :y sy :w sw :h sh))

(ert-deftest op-move-keeps-size ()
  (let ((op (emacs-wm-be--op-after-delta (bt-op "move" 10 20 100 50) 5 7)))
    (should (equal (plist-get op :x) 15))
    (should (equal (plist-get op :y) 27))
    (should (equal (plist-get op :w) 100))
    (should (equal (plist-get op :h) 50))))

(ert-deftest op-move-is-cumulative ()
  "Applying successive cumulative deltas must not accumulate."
  (let* ((op (bt-op "move" 10 20 100 50))
         (once (emacs-wm-be--op-after-delta op 5 7))
         (twice (emacs-wm-be--op-after-delta once 5 7)))
    (should (equal (list (plist-get twice :x) (plist-get twice :y)) '(15 27)))))

(ert-deftest op-move-negative-delta ()
  (let ((op (emacs-wm-be--op-after-delta (bt-op "move" 100 100 50 50) -40 -30)))
    (should (equal (list (plist-get op :x) (plist-get op :y)) '(60 70)))))

(ert-deftest op-resize-bottom-right ()
  (let ((op (emacs-wm-be--op-after-delta (bt-op "resize" 10 20 100 50 10) 5 7)))
    (should (equal (list (plist-get op :x) (plist-get op :y)) '(10 20)))
    (should (equal (list (plist-get op :w) (plist-get op :h)) '(105 57)))))

(ert-deftest op-resize-top-left ()
  "edges 5 = top (1) + left (4): the origin moves, the far edges stay."
  (let ((op (emacs-wm-be--op-after-delta (bt-op "resize" 10 20 100 50 5) 5 7)))
    (should (equal (list (plist-get op :x) (plist-get op :y)) '(15 27)))
    (should (equal (list (plist-get op :w) (plist-get op :h)) '(95 43)))))

(ert-deftest op-resize-left-only ()
  "Dragging the left edge by 30 must keep the right edge fixed."
  (let ((op (emacs-wm-be--op-after-delta (bt-op "resize" 100 0 200 100 4) 30 0)))
    (should (equal (plist-get op :x) 130))
    (should (equal (plist-get op :w) 170))
    (should (= (+ (plist-get op :x) (plist-get op :w)) 300))))

(ert-deftest op-resize-never-smaller-than-one ()
  (let ((op (emacs-wm-be--op-after-delta (bt-op "resize" 10 10 100 50 10) -500 -500)))
    (should (equal (list (plist-get op :w) (plist-get op :h)) '(1 1)))))

(ert-deftest op-resize-cumulative ()
  (let* ((op (bt-op "resize" 0 0 100 100 10))
         (once (emacs-wm-be--op-after-delta op 10 10))
         (twice (emacs-wm-be--op-after-delta once 10 10)))
    (should (equal (list (plist-get twice :w) (plist-get twice :h)) '(110 110)))))

;;; keysym -> keycode (injection)

(ert-deftest keysym-lowercase-letter ()
  (should (equal (emacs-wm-be--keysym->keycode ?j) '(36 . nil))))

(ert-deftest keysym-uppercase-needs-shift ()
  (should (equal (emacs-wm-be--keysym->keycode ?J) '(36 . t))))

(ert-deftest keysym-digit ()
  (should (equal (emacs-wm-be--keysym->keycode ?1) '(2 . nil)))
  (should (equal (emacs-wm-be--keysym->keycode ?0) '(11 . nil)))
  (should (equal (emacs-wm-be--keysym->keycode ?=) '(13 . nil))))

(ert-deftest keysym-grave-and-backslash ()
  "These two are not contiguous with the rows beside them."
  (should (equal (emacs-wm-be--keysym->keycode ?`) '(41 . nil)))
  (should (equal (emacs-wm-be--keysym->keycode ?~) '(41 . t)))
  (should (equal (emacs-wm-be--keysym->keycode ?\\ ) '(43 . nil)))
  (should (equal (emacs-wm-be--keysym->keycode ?z) '(44 . nil)))
  (should (equal (emacs-wm-be--keysym->keycode ?/) '(53 . nil))))

(ert-deftest keysym-punctuation-shift-level ()
  (should (equal (emacs-wm-be--keysym->keycode ?!) '(2 . t))))

(ert-deftest keysym-space ()
  (should (equal (emacs-wm-be--keysym->keycode #x20) '(57 . nil))))

(ert-deftest keysym-named-return ()
  (should (equal (emacs-wm-be--keysym->keycode #xff0d) '(28 . nil))))

(ert-deftest keysym-unknown-is-nil ()
  (should-not (emacs-wm-be--keysym->keycode #xdeadbeef)))

;;; keysym names used by bindings and :simulate

(ert-deftest resolve-keysym-character ()
  (should (= (emacs-wm-be--resolve-keysym ?j) ?j)))

(ert-deftest resolve-keysym-string-name ()
  (should (= (emacs-wm-be--resolve-keysym "Return") #xff0d))
  (should (= (emacs-wm-be--resolve-keysym "return") #xff0d)))

(ert-deftest resolve-keysym-single-char-string ()
  (should (= (emacs-wm-be--resolve-keysym "j") ?j)))

(ert-deftest resolve-keysym-unknown-name ()
  (should-not (emacs-wm-be--resolve-keysym "NoSuchKeyName")))

;;; frame naming: wm-frame:<oid>:<desktop>

(ert-deftest frame-role-multi-output ()
  (should (equal (emacs-wm-be--frame-role "wm-frame:4278190080:3")
                 '(3 . 4278190080))))

(ert-deftest frame-role-legacy ()
  (should (equal (emacs-wm-be--frame-role "wm-frame:2") '(2 . nil))))

(ert-deftest frame-role-not-a-frame ()
  (should-not (emacs-wm-be--frame-role "some terminal title"))
  (should-not (emacs-wm-be--frame-role "wm-frame:"))
  (should-not (emacs-wm-be--frame-role "wm-frame:x:y"))
  (should-not (emacs-wm-be--frame-role nil)))

;;; Wayland codec primitives

(ert-deftest codec-u32-roundtrip ()
  (dolist (n '(0 1 255 256 65535 4278190080 #xffffffff))
    (should (= (emacs-wm-wl--get-u32 (emacs-wm-wl--u32 n) 0) n))))

(ert-deftest codec-i32-negative ()
  (should (= (emacs-wm-wl--get-i32 (emacs-wm-wl--u32 -1) 0) -1))
  (should (= (emacs-wm-wl--get-i32 (emacs-wm-wl--u32 -1920) 0) -1920)))

(ert-deftest codec-string-roundtrip ()
  (dolist (s '("" "j" "kitty" "ünïcode — ok" "a string with spaces"))
    (let* ((encoded (emacs-wm-wl--encode-string s))
           (decoded (emacs-wm-wl--decode-string encoded 0)))
      (should (equal (car decoded) s))
      (should (zerop (mod (length encoded) 4))))))

(ert-deftest codec-string-padding ()
  "A 3-byte string needs 3 length bytes of padding: 4 + 4 = 8 bytes total."
  (should (= (length (emacs-wm-wl--encode-string "abc")) 8))
  (should (= (length (emacs-wm-wl--encode-string "abcd")) 12)))

(provide 'be-tests)
;;; be-tests.el ends here
