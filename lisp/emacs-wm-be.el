;;; emacs-wm-be.el --- the Wayland side of emacs-wm, in Emacs Lisp  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-wm contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The backend half of emacs-wm: a second, minimal Emacs that is the
;; `river_window_manager_v1' client.  It holds no policy at all.  It answers
;; river's manage and render sequences from the last layout the frontend
;; pushed, routes river's events to the frontend, and applies the frontend's
;; decisions (geometry, borders, focus, bindings, injected keys).
;;
;; Why a second Emacs rather than the user's Emacs: river stops processing
;; *input* while a manage sequence is open (river/Seat.zig: events are queued
;; until `server.wm.state == .idle'), so whatever sits in the WM slot is a hard
;; latency dependency for the whole session.  This process therefore loads
;; nothing but this file and emacs-wm-wl, keeps a tiny heap, raises
;; `gc-cons-threshold', and never calls into the frontend synchronously.  If
;; the frontend is busy -- GC, a debugger, `call-process' -- river keeps
;; getting answers built from the last layout.
;;
;; The frontend supervises this process: if it dies, `emacs-wm--reconnect'
;; starts it again, river re-sends every window, and windows are reattached by
;; `identifier'.  Nothing here writes to the frontend except newline-delimited
;; printed sexps over a Unix socket.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'emacs-wm-wl)

(defgroup emacs-wm-be nil
  "Wayland backend for emacs-wm."
  :group 'emacs-wm)

(defcustom emacs-wm-be-log-file "/tmp/emacs-wm-be.log"
  "File the backend appends its log to, or nil for no logging."
  :type '(choice (const :tag "No logging" nil) file))

(defcustom emacs-wm-be-log-level 'info
  "Minimum level to log: `debug', `info', `warn' or `error'."
  :type '(choice (const debug) (const info) (const warn) (const error)))

(defcustom emacs-wm-be-gc-cons-threshold (* 32 1024 1024)
  "`gc-cons-threshold' for the backend.
The backend's heap is tiny, so a large threshold makes collections rare; the
point is to keep manage sequences free of GC pauses."
  :type 'integer)

(defcustom emacs-wm-be-gc-cons-percentage 0.2
  "`gc-cons-percentage' for the backend."
  :type 'number)

(defcustom emacs-wm-be-state-file nil
  "Where to write the bar state file.
nil means $XDG_RUNTIME_DIR/emacs-wm.state.json."
  :type '(choice (const :tag "Default" nil) file))

(defcustom emacs-wm-be-socket-path nil
  "Unix socket the frontend connects to.
nil means $XDG_RUNTIME_DIR/emacs-wm.$WAYLAND_DISPLAY.sock."
  :type '(choice (const :tag "Default" nil) string))

(defcustom emacs-wm-be-hide-inactive t
  "Hide frames of desktops that are not current.
Only used when no frontend layout has arrived yet."
  :type 'boolean)

;;; ---------------------------------------------------------------- logging

(defconst emacs-wm-be--levels '((debug . 0) (info . 1) (warn . 2) (error . 3)))

(defun emacs-wm-be-log (level fmt &rest args)
  "Log FMT/ARGS at LEVEL."
  (when (and emacs-wm-be-log-file
             (>= (alist-get level emacs-wm-be--levels 1)
                 (alist-get emacs-wm-be-log-level emacs-wm-be--levels 1)))
    (condition-case nil
        (let ((coding-system-for-write 'utf-8-unix)
              (line (concat (format-time-string "%H:%M:%S.") 
                            (format "%03d " (mod (truncate (* 1000 (float-time))) 1000))
                            (upcase (symbol-name level)) " "
                            (apply #'format fmt args) "\n")))
          (write-region line nil emacs-wm-be-log-file 'append))
      (error nil))))

(defmacro emacs-wm-be--debug (fmt &rest args)
  `(emacs-wm-be-log 'debug ,fmt ,@args))

;;; ------------------------------------------------------------------ state

(cl-defstruct (emacs-wm-be-window (:constructor emacs-wm-be--window-make))
  "One `river_window_v1' known to the backend."
  id node
  ;; 'frame (one of our own Emacs frames), 'app, or nil until the title says.
  role
  desktop output                 ; frames: desktop number and output oid
  frame-desktop frame-output     ; apps: desktop/frame they are mirrored in
  title app-id identifier
  hint-min hint-max size
  has-parent floating fullscreen minimized
  rect last-proposed
  border border-applied
  fid                            ; frames: id handed to the frontend
  tiled                          ; last set_tiled value, to dedupe
  decor-applied                  ; "csd"/"ssd" last sent, to dedupe
  maximized                      ; frames: inform_maximized sent?
  ;; Rendering state actually applied, so a render sequence only sends deltas.
  render-x render-y render-visible render-clip)

(cl-defstruct (emacs-wm-be-output (:constructor emacs-wm-be--output-make))
  "One `river_output_v1'."
  id x y w h usable ls-output name)

(cl-defstruct (emacs-wm-be-binding (:constructor emacs-wm-be--binding-make))
  "One `river_xkb_binding_v1' created for the frontend."
  id keysym mods name)

(cl-defstruct (emacs-wm-be-state (:constructor emacs-wm-be--state-make))
  conn
  wm xkb-bindings xkb-bindings-seat river-vkb-mgr zwp-vkb-mgr vkb
  seat wl-seat layer-shell ls-seat
  layer-focus                   ; 'none, 'non-exclusive or 'exclusive
  bindings                      ; bid -> emacs-wm-be-binding
  pointer-bindings              ; bid -> river_pointer_binding_v1 object id
  pending-pointer-binds
  outputs windows
  pointer-x pointer-y pointer-oid
  ;; Window under the pointer, needed to attribute a pointer binding press.
  pointer-window
  desktop
  focus                         ; wid of the focused window, or nil
  pending-inject pending-binds pending-unbinds pending-window-ops pending-eat-next
  layout applied-layout gen
  render-dirty
  manage-count
  next-fid
  epoch
  server client client-rx
  quitting
  ;; Active pointer operation (move/resize): a plist, see `--op-start'.
  op
  ;; river's session lock state (ext-session-lock).  While locked the WM must
  ;; keep its hands off focus and input.
  session-locked
  ;; Set while a manage sequence is in progress: only then may window
  ;; management state (focus, tiling, bindings, fullscreen) be modified;
  ;; river kills the connection otherwise.
  in-manage)

(defvar emacs-wm-be--state nil
  "The one backend state.")

(defsubst emacs-wm-be--win (wid)
  (gethash wid (emacs-wm-be-state-windows emacs-wm-be--state)))

(defsubst emacs-wm-be--out (oid)
  (gethash oid (emacs-wm-be-state-outputs emacs-wm-be--state)))

(defun emacs-wm-be--now-ms ()
  "Milliseconds since the epoch, as an unsigned 32-bit number."
  (logand (truncate (* 1000 (float-time))) #xffffffff))

(defun emacs-wm-be--req (object request &optional values)
  "Send REQUEST on OBJECT with VALUES."
  (emacs-wm-wl-request (emacs-wm-be-state-conn emacs-wm-be--state)
                       object request values))

(defun emacs-wm-be--dirty ()
  "Ask river for a manage sequence.  Legal outside a sequence."
  (when (emacs-wm-be-state-wm emacs-wm-be--state)
    (emacs-wm-be--debug "manage_dirty")
    (emacs-wm-be--req (emacs-wm-be-state-wm emacs-wm-be--state) "manage_dirty")))

;;; ----------------------------------------------------------- keysym tables
;;
;; Two directions are needed and neither is available in Emacs:
;;
;;   binding:  keysym name/number  ->  XKB keysym  (river_xkb_binding_v1 wants
;;             a keysym, not an Emacs key event)
;;   inject:   XKB keysym          ->  evdev keycode (+ shift), because
;;             zwp_virtual_keyboard_v1.key speaks linux/input-event-codes.h
;;
;; The keycode table is the US layout.  River now gives a keymap-less virtual
;; keyboard the seat's keymap, so keycodes are interpreted exactly like
;; physical ones; on a non-US layout the printable punctuation may differ.

(defconst emacs-wm-be--named-keysyms
  '(("return" . #xff0d) ("escape" . #xff1b) ("backspace" . #xff08)
    ("tab" . #xff09) ("space" . #x0020) ("delete" . #xffff)
    ("insert" . #xff63) ("home" . #xff50) ("end" . #xff57)
    ("prior" . #xff55) ("pageup" . #xff55) ("next" . #xff56)
    ("pagedown" . #xff56) ("left" . #xff51) ("up" . #xff52)
    ("right" . #xff53) ("down" . #xff54) ("menu" . #xff67)
    ("print" . #xff61) ("pause" . #xff13) ("scroll" . #xff14)
    ("iso-lefttab" . #xfe20)
    ("f1" . #xffbe) ("f2" . #xffbf) ("f3" . #xffc0) ("f4" . #xffc1)
    ("f5" . #xffc2) ("f6" . #xffc3) ("f7" . #xffc4) ("f8" . #xffc5)
    ("f9" . #xffc6) ("f10" . #xffc7) ("f11" . #xffc8) ("f12" . #xffc9)
    ("xf86audioraisevolume" . #x1008ff13)
    ("xf86audiolowervolume" . #x1008ff11)
    ("xf86audiomute" . #x1008ff12)
    ("xf86audioplay" . #x1008ff14)
    ("xf86audionext" . #x1008ff17)
    ("xf86audioprev" . #x1008ff16)
    ("xf86monbrightnessup" . #x1008ff02)
    ("xf86monbrightnessdown" . #x1008ff03))
  "Keysym names the WM keys and `:simulate' rules may use.")

(defun emacs-wm-be--utf32->keysym (cp)
  "Turn codepoint CP into an XKB keysym."
  (cond ((not (integerp cp)) 0)
        ((and (>= cp #x20) (<= cp #x7e)) cp)
        ((and (>= cp #xa0) (<= cp #xff)) cp)
        ((> cp 0) (+ #x01000000 cp))
        (t 0)))

(defun emacs-wm-be--resolve-keysym (key)
  "Resolve KEY (a character, integer or name string) to an XKB keysym."
  (cond
   ((integerp key) (emacs-wm-be--utf32->keysym key))
   ((and (stringp key) (= 1 (length key)))
    (emacs-wm-be--utf32->keysym (aref key 0)))
   ((symbolp key) (emacs-wm-be--resolve-keysym (symbol-name key)))
   ((stringp key)
    (or (cdr (assoc (downcase key) emacs-wm-be--named-keysyms))
        (when (string-match "\\`U\\+\\([0-9a-fA-F]+\\)\\'" key)
          (emacs-wm-be--utf32->keysym (string-to-number (match-string 1 key) 16)))
        (emacs-wm-be--debug "unknown keysym name %S" key)
        nil))
   (t nil)))

(defun emacs-wm-be--us-keycode-table ()
  "Build the US keysym -> (KEYCODE . SHIFT) table used for injection.
Rows are given with their evdev keycodes explicitly: ` and \\ are not
contiguous with the rows around them in linux/input-event-codes.h."
  (let ((table (make-hash-table :test 'eql)))
    (emacs-wm-be--fill-row table "`" "~" '(41))
    (emacs-wm-be--fill-row table "1234567890-=" "!@#$%^&*()_+"
                           '(2 3 4 5 6 7 8 9 10 11 12 13))
    (emacs-wm-be--fill-row table "qwertyuiop[]" "QWERTYUIOP{}"
                           '(16 17 18 19 20 21 22 23 24 25 26 27))
    (emacs-wm-be--fill-row table "asdfghjkl;'" "ASDFGHJKL:\""
                           '(30 31 32 33 34 35 36 37 38 39 40))
    (emacs-wm-be--fill-row table "\\" "|" '(43))
    (emacs-wm-be--fill-row table "zxcvbnm,./" "ZXCVBNM<>?"
                           '(44 45 46 47 48 49 50 51 52 53))
    (puthash #x20 (cons 57 nil) table)  ; space
    (puthash #x0a (cons 28 nil) table)  ; C-j / newline
    table))

(defun emacs-wm-be--fill-row (table plain &optional shifted codes)
  "Put PLAIN and SHIFTED characters into TABLE at the given CODES.
When SHIFTED is a list instead of a string it is taken as CODES."
  (when (listp shifted)
    (setq codes shifted
          shifted nil))
  (dotimes (i (length plain))
    (puthash (aref plain i) (cons (nth i codes) nil) table)
    (when (and shifted (< i (length shifted)))
      (puthash (aref shifted i) (cons (nth i codes) t) table))))

(defconst emacs-wm-be--named-keycodes
  '(("return" . 28) ("escape" . 1) ("backspace" . 14) ("tab" . 15)
    ("space" . 57) ("delete" . 111) ("insert" . 110) ("home" . 102)
    ("end" . 107) ("prior" . 104) ("pageup" . 104) ("next" . 109)
    ("pagedown" . 109) ("left" . 105) ("up" . 103) ("right" . 106)
    ("down" . 108) ("menu" . 139)
    ("f1" . 59) ("f2" . 60) ("f3" . 61) ("f4" . 62) ("f5" . 63)
    ("f6" . 64) ("f7" . 65) ("f8" . 66) ("f9" . 67) ("f10" . 68)
    ("f11" . 87) ("f12" . 88))
  "Named keys that are not printable, as evdev keycodes.")

(defvar emacs-wm-be--keysym-keycodes nil
  "Lazily built hash of keysym -> (keycode . shift).")

(defun emacs-wm-be--keysym->keycode (keysym)
  "Return (KEYCODE . SHIFT) for KEYSYM, or nil."
  (or emacs-wm-be--keysym-keycodes
      (setq emacs-wm-be--keysym-keycodes (emacs-wm-be--us-keycode-table)))
  (or (gethash keysym emacs-wm-be--keysym-keycodes)
      ;; Named keys: find the name whose keysym matches.
      (let (found)
        (dolist (pair emacs-wm-be--named-keysyms)
          (when (and (not found) (= (cdr pair) keysym))
            (setq found (cons (cdr (assoc (car pair) emacs-wm-be--named-keycodes))
                              nil))))
        found)))

;;; -------------------------------------------------------------- registry

(defconst emacs-wm-be--required-globals
  '("river_window_manager_v1" "river_xkb_bindings_v1" "river_layer_shell_v1"
    "river_virtual_keyboard_manager_v1" "zwp_virtual_keyboard_manager_v1"
    "wl_seat"))

(defun emacs-wm-be--bind-global (name interface version)
  "Bind global NAME of INTERFACE at VERSION, returning the new object."
  (let* ((conn (emacs-wm-be-state-conn emacs-wm-be--state))
         (object (emacs-wm-wl-new-id conn interface)))
    (emacs-wm-be--debug "bind %s v%d -> object %d (global %s)"
                        interface version (emacs-wm-wl-object-id object) name)
    (emacs-wm-wl-request conn (emacs-wm-wl-object conn 2) "bind"
                         (list :name name
                               :interface interface
                               :version version
                               :id (emacs-wm-wl-object-id object)
                               :id-interface interface))
    object))

(defun emacs-wm-be--on-global (args)
  "Handle wl_registry.global."
  (let* ((name (plist-get args :name))
         (interface (plist-get args :interface))
         (version (plist-get args :version))
         (state emacs-wm-be--state))
    (emacs-wm-be--debug "global %s v%d (name %d)" interface version name)
    (pcase interface
      ("wl_registry" nil)
      ("river_window_manager_v1"
       (let ((object (emacs-wm-be--bind-global name interface (min version 6))))
         (setf (emacs-wm-be-state-wm state) (emacs-wm-wl-object-id object))))
      ("river_xkb_bindings_v1"
       (let ((object (emacs-wm-be--bind-global name interface (min version 3))))
         (setf (emacs-wm-be-state-xkb-bindings state)
               (emacs-wm-wl-object-id object))
         (emacs-wm-be--maybe-create-bindings-seat)))
      ("river_layer_shell_v1"
       (let ((object (emacs-wm-be--bind-global name interface 1)))
         (setf (emacs-wm-be-state-layer-shell state)
               (emacs-wm-wl-object-id object))))
      ("river_virtual_keyboard_manager_v1"
       (let ((object (emacs-wm-be--bind-global name interface 1)))
         (setf (emacs-wm-be-state-river-vkb-mgr state)
               (emacs-wm-wl-object-id object))
         (emacs-wm-be--maybe-create-vkb)))
      ("zwp_virtual_keyboard_manager_v1"
       (let ((object (emacs-wm-be--bind-global name interface 1)))
         (setf (emacs-wm-be-state-zwp-vkb-mgr state)
               (emacs-wm-wl-object-id object))
         (emacs-wm-be--maybe-create-vkb)))
      ("wl_seat"
       (let ((object (emacs-wm-be--bind-global name interface 1)))
         (setf (emacs-wm-be-state-wl-seat state)
               (emacs-wm-wl-object-id object))
         (emacs-wm-be--maybe-create-vkb)))
      (_ nil))))

;;; --------------------------------------------------------------- outputs

(defun emacs-wm-be--usable (output)
  "Usable (X Y W H) of OUTPUT, in global coordinates."
  (or (emacs-wm-be-output-usable output)
      (list (emacs-wm-be-output-x output) (emacs-wm-be-output-y output)
            (emacs-wm-be-output-w output) (emacs-wm-be-output-h output))))

(defun emacs-wm-be--origin (oid)
  "Global origin (X Y) of output OID."
  (let ((output (emacs-wm-be--out oid)))
    (if output
        (list (emacs-wm-be-output-x output) (emacs-wm-be-output-y output))
      (list 0 0))))

(defun emacs-wm-be--primary-output ()
  "The output that is not the pointer's, for fallbacks."
  (let (best)
    (maphash (lambda (_oid output)
               (when (or (null best)
                         (< (emacs-wm-be-output-id output)
                            (emacs-wm-be-output-id best)))
                 (setq best output)))
             (emacs-wm-be-state-outputs emacs-wm-be--state))
    best))

(defun emacs-wm-be--output-at (x y)
  "Output whose rectangle contains global (X, Y), or nil."
  (let (found)
    (maphash
     (lambda (_oid output)
       (when (and (not found)
                  (>= x (emacs-wm-be-output-x output))
                  (< x (+ (emacs-wm-be-output-x output)
                          (max 1 (emacs-wm-be-output-w output))))
                  (>= y (emacs-wm-be-output-y output))
                  (< y (+ (emacs-wm-be-output-y output)
                          (max 1 (emacs-wm-be-output-h output)))))
         (setq found (emacs-wm-be-output-id output))))
     (emacs-wm-be-state-outputs emacs-wm-be--state))
    found))

(defun emacs-wm-be--current-output-oid ()
  "Output a new window should open on: under the pointer, else the first."
  (or (emacs-wm-be--output-at (emacs-wm-be-state-pointer-x emacs-wm-be--state)
                              (emacs-wm-be-state-pointer-y emacs-wm-be--state))
      (emacs-wm-be-state-pointer-oid emacs-wm-be--state)
      (let ((output (emacs-wm-be--primary-output)))
        (and output (emacs-wm-be-output-id output)))))

(defun emacs-wm-be--emit-output (output)
  "Tell the frontend about OUTPUT."
  (emacs-wm-be--emit
   (list :t "output"
         :oid (emacs-wm-be-output-id output)
         :name (emacs-wm-be-output-name output)
         :x (emacs-wm-be-output-x output)
         :y (emacs-wm-be-output-y output)
         :w (emacs-wm-be-output-w output)
         :h (emacs-wm-be-output-h output)
         :usable (pcase-let ((`(,x ,y ,w ,h) (emacs-wm-be--usable output)))
                   (list :x x :y y :w w :h h))
         :scale 1 :transform 0)))

;;; -------------------------------------------------------------- the frontend

(defun emacs-wm-be--socket-path ()
  (or emacs-wm-be-socket-path
      (format "%s/emacs-wm.%s.sock"
              (or (getenv "XDG_RUNTIME_DIR") "/tmp")
              (or (getenv "WAYLAND_DISPLAY") "unknown"))))

(defun emacs-wm-be-state-file-path ()
  (or emacs-wm-be-state-file
      (format "%s/emacs-wm.state.json"
              (or (getenv "XDG_RUNTIME_DIR") "/tmp"))))

(defun emacs-wm-be--emit (msg)
  "Send MSG (a plist with :t) to the frontend."
  (let ((client (emacs-wm-be-state-client emacs-wm-be--state)))
    (when (and client (process-live-p client))
      (condition-case err
          (let ((print-escape-newlines t)
                (print-escape-nonascii t)
                (coding-system-for-write 'utf-8-unix))
            (process-send-string client (concat (prin1-to-string msg) "\n")))
        (error (emacs-wm-be-log 'warn "send to frontend failed: %S" err))))))

(defun emacs-wm-be--on-client (server client message)
  "Handle a connection or disconnect on SERVER for CLIENT."
  (let ((state emacs-wm-be--state))
    (cond
     ((string-prefix-p "accept" message)
      (emacs-wm-be-log 'info "frontend connected: %s" (string-trim message))
      (set-process-coding-system client 'utf-8-emacs-unix 'utf-8-emacs-unix)
      (set-process-filter client #'emacs-wm-be--client-filter)
      (setf (emacs-wm-be-state-client state) client
            (emacs-wm-be-state-client-rx state) "")
      (emacs-wm-be--emit (list :t "hello"
                               :epoch (emacs-wm-be-state-epoch state)
                               :daemon "emacs-wm-be"
                               :caps (vector "layout" "bind" "inject"
                                             "window-cmd" "eat-next"))))
     (t
      (emacs-wm-be-log 'info "frontend disconnected: %s" (string-trim message))
      (when (eq client (emacs-wm-be-state-client state))
        (setf (emacs-wm-be-state-client state) nil)))))
  (ignore server))

(defun emacs-wm-be--client-filter (proc chunk)
  "Read complete sexps from CHUNK and handle them."
  (let* ((state emacs-wm-be--state)
         (buffer (concat (emacs-wm-be-state-client-rx state) chunk)))
    (setf (emacs-wm-be-state-client-rx state) "")
    (let (line)
      (while (string-match "\n" buffer)
        (setq line (substring buffer 0 (match-beginning 0))
              buffer (substring buffer (match-end 0)))
        (unless (string-empty-p (string-trim line))
          (condition-case err
              (let ((msg (car (read-from-string line))))
                (if (listp msg)
                    (emacs-wm-be--handle-client msg)
                  (emacs-wm-be-log 'warn "client sent a non-list: %S" msg)))
            (error (emacs-wm-be-log 'warn "bad client message: %S (%s)" err line)))))
      (setf (emacs-wm-be-state-client-rx state) buffer)))
  (ignore proc))

(defun emacs-wm-be--handle-client (msg)
  "Handle one message MSG from the frontend."
  (let ((state emacs-wm-be--state))
    (emacs-wm-be--debug "client msg %S" (plist-get msg :t))
    (pcase (plist-get msg :t)
      ("hello-ack"
       (emacs-wm-be-log 'info "handshake complete, protocol v%s" (plist-get msg :v))
       ;; A new frontend knows nothing about the world: send it everything.
       (emacs-wm-be--replay-state)
       (emacs-wm-be--dirty))
      ("layout"
       (let ((epoch (plist-get msg :epoch))
             (gen (plist-get msg :gen)))
         (cond
          ((and epoch (emacs-wm-be-state-epoch state)
                (/= epoch (emacs-wm-be-state-epoch state)))
           (emacs-wm-be-log 'warn "layout for stale epoch %s (mine %s)"
                            epoch (emacs-wm-be-state-epoch state)))
          ((and gen (<= gen (or (emacs-wm-be-state-gen state) 0)))
           (emacs-wm-be--debug "layout gen %s is not newer than %s"
                               gen (emacs-wm-be-state-gen state)))
          ((and (emacs-wm-be-state-applied-layout state)
                (equal (plist-get msg :frames)
                       (plist-get (emacs-wm-be-state-applied-layout state) :frames))
                (equal (plist-get msg :windows)
                       (plist-get (emacs-wm-be-state-applied-layout state) :windows))
                (equal (plist-get msg :focus)
                       (plist-get (emacs-wm-be-state-applied-layout state) :focus))
                (not (emacs-wm-be-state-render-dirty state)))
           (emacs-wm-be--debug "layout gen %s is identical to the applied one" gen)
           (setf (emacs-wm-be-state-gen state) gen))
          (t
           (emacs-wm-be-log 'info "layout gen %s: %d frame(s), %d window(s), focus %S"
                            gen (length (plist-get msg :frames))
                            (length (plist-get msg :windows))
                            (plist-get msg :focus))
           (setf (emacs-wm-be-state-layout state) msg
                 (emacs-wm-be-state-gen state) gen
                 (emacs-wm-be-state-render-dirty state) t)
           (emacs-wm-be--dirty)))))
      ("bind"
       (push (list (plist-get msg :bid)
                   (plist-get msg :key)
                   (or (plist-get msg :mods) 0)
                   (plist-get msg :name))
             (emacs-wm-be-state-pending-binds state))
       (emacs-wm-be--dirty))
      ("bind-pointer"
       (push (list (plist-get msg :bid)
                   (plist-get msg :button)
                   (or (plist-get msg :mods) 0))
             (emacs-wm-be-state-pending-pointer-binds state))
       (emacs-wm-be--dirty))
      ("unbind"
       (push (plist-get msg :bid) (emacs-wm-be-state-pending-unbinds state))
       (emacs-wm-be--dirty))
      ("inject"
       (dolist (key (append (plist-get msg :keys) nil))
         (push (list (plist-get key :name) (or (plist-get key :mods) 0))
               (emacs-wm-be-state-pending-inject state)))
       (emacs-wm-be--dirty))
      ("eat-next"
       (push (if (plist-get msg :on) t nil)
             (emacs-wm-be-state-pending-eat-next state))
       (emacs-wm-be--dirty))
      ("window-cmd" (emacs-wm-be--window-command msg))
      ("op-start" (emacs-wm-be--op-start msg))
      ("op-end"
       (when (emacs-wm-be-state-op state)
         (push (cons (plist-get (emacs-wm-be-state-op state) :wid) 'op-end)
               (emacs-wm-be-state-pending-window-ops state))
         (emacs-wm-be--dirty)))
      ("ping" (emacs-wm-be--emit (list :t "pong" :n (plist-get msg :n))))
      ("pong" nil)
      ("quit" (emacs-wm-be--quit "frontend asked"))
      ("exit-session"
       ;; Legal at any time (not window-management state): river terminates
       ;; and the connection closes, which is how this process learns to go.
       (emacs-wm-be-log 'info "frontend asked river to end the session")
       (when (emacs-wm-be-state-wm state)
         (emacs-wm-be--req (emacs-wm-be-state-wm state) "exit_session")))
      (_ (emacs-wm-be-log 'debug "unknown client message %S" (plist-get msg :t))))))

;;; ------------------------------------------------------------- injections

(defun emacs-wm-be--flush-inject ()
  "Write queued injected keys, inside the current manage sequence."
  (let* ((state emacs-wm-be--state)
         (keys (nreverse (emacs-wm-be-state-pending-inject state))))
    (setf (emacs-wm-be-state-pending-inject state) nil)
    (when (and keys (emacs-wm-be-state-session-locked state))
      (emacs-wm-be-log 'warn "session locked: dropped %d injected key(s)" (length keys))
      (setq keys nil))
    (when keys
      (let ((vkb (emacs-wm-be-state-vkb state)))
        (if (not vkb)
            (emacs-wm-be-log 'warn "inject requested but no virtual keyboard")
          (dolist (entry keys)
            (pcase-let ((`(,name ,mods) entry))
              (let* ((keysym (emacs-wm-be--resolve-keysym name))
                     (resolved (and keysym (emacs-wm-be--keysym->keycode keysym))))
                (if (not resolved)
                    (emacs-wm-be-log 'warn "cannot map %S to a keycode" name)
                  (let* ((code (car resolved))
                         (shift (cdr resolved))
                         (mask (logior mods (if shift 1 0)))
                         (t0 (emacs-wm-be--now-ms)))
                    (emacs-wm-be--req vkb "modifiers"
                                      (list :mods_depressed mask :mods_latched 0
                                            :mods_locked 0 :group 0))
                    (emacs-wm-be--req vkb "key"
                                      (list :time t0 :key code :state 1))
                    (emacs-wm-be--req vkb "key"
                                      (list :time (logand (1+ t0) #xffffffff)
                                            :key code :state 0))
                    (emacs-wm-be--req vkb "modifiers"
                                      (list :mods_depressed 0 :mods_latched 0
                                            :mods_locked 0 :group 0))
                    (emacs-wm-be-log 'info
                                     "injected %s as keycode %d (shift=%s, mods=%#x)"
                                     name code shift mods)))))))))))

;;; -------------------------------------------------------- virtual keyboard

(defun emacs-wm-be--maybe-create-vkb ()
  "Create and sync a virtual keyboard once the seats and managers exist."
  (let ((state emacs-wm-be--state))
    (when (and (not (emacs-wm-be-state-vkb state))
               (emacs-wm-be-state-seat state)
               (emacs-wm-be-state-wl-seat state)
               (emacs-wm-be-state-zwp-vkb-mgr state)
               (emacs-wm-be-state-river-vkb-mgr state))
      (let* ((conn (emacs-wm-be-state-conn state))
             (vkb (emacs-wm-wl-new-id conn "zwp_virtual_keyboard_v1")))
        (emacs-wm-wl-request conn (emacs-wm-be-state-zwp-vkb-mgr state)
                             "create_virtual_keyboard"
                             (list :seat (emacs-wm-be-state-wl-seat state)
                                   :id (emacs-wm-wl-object-id vkb)))
        ;; Synced *before* any keymap request; we never send one, and river
        ;; borrows the seat's keymap for that case.
        (emacs-wm-wl-request conn (emacs-wm-be-state-river-vkb-mgr state)
                             "sync_keyboard"
                             (list :virtual_keyboard (emacs-wm-wl-object-id vkb)))
        (setf (emacs-wm-be-state-vkb state) (emacs-wm-wl-object-id vkb))
        (emacs-wm-be-log 'info "virtual keyboard synced with the manage sequence")
        (emacs-wm-be--dirty)))))

;;; ---------------------------------------------------------------- bindings

(defun emacs-wm-be--maybe-create-bindings-seat ()
  "Create river_xkb_bindings_seat_v1 so chords can eat the next key."
  (let ((state emacs-wm-be--state))
    (when (and (not (emacs-wm-be-state-xkb-bindings-seat state))
               (emacs-wm-be-state-xkb-bindings state)
               (emacs-wm-be-state-seat state))
      (let* ((conn (emacs-wm-be-state-conn state))
             (object (emacs-wm-wl-new-id conn "river_xkb_bindings_seat_v1")))
        (emacs-wm-wl-request conn (emacs-wm-be-state-xkb-bindings state)
                             "get_seat"
                             (list :id (emacs-wm-wl-object-id object)
                                   :seat (emacs-wm-be-state-seat state)))
        (setf (emacs-wm-be-state-xkb-bindings-seat state)
              (emacs-wm-wl-object-id object))
        (emacs-wm-be-log 'info "river_xkb_bindings_seat_v1 created (chords)")))))

(defun emacs-wm-be--apply-pending-bindings ()
  "Create, enable and destroy bindings.  Manage sequence only."
  (let* ((state emacs-wm-be--state)
         (unbinds (nreverse (emacs-wm-be-state-pending-unbinds state)))
         (binds (nreverse (emacs-wm-be-state-pending-binds state))))
    (setf (emacs-wm-be-state-pending-unbinds state) nil
          (emacs-wm-be-state-pending-binds state) nil)
    (dolist (bid unbinds)
      (when-let* ((binding (gethash bid (emacs-wm-be-state-bindings state))))
        (emacs-wm-be--req (emacs-wm-be-binding-id binding) "destroy")
        (remhash bid (emacs-wm-be-state-bindings state))
        (emacs-wm-be--debug "destroyed binding %s" bid)))
    (when (and binds
               (emacs-wm-be-state-xkb-bindings state)
               (emacs-wm-be-state-seat state))
      (dolist (entry binds)
        (pcase-let ((`(,bid ,key ,mods ,name) entry))
          (when-let* ((old (gethash bid (emacs-wm-be-state-bindings state))))
            (emacs-wm-be--req (emacs-wm-be-binding-id old) "destroy"))
          (let ((keysym (emacs-wm-be--resolve-keysym key)))
            (if (not keysym)
                (emacs-wm-be-log 'warn "cannot resolve binding key %S (%s)" key name)
              (let* ((conn (emacs-wm-be-state-conn state))
                     (object (emacs-wm-wl-new-id conn "river_xkb_binding_v1")))
                (emacs-wm-wl-request conn (emacs-wm-be-state-xkb-bindings state)
                                     "get_xkb_binding"
                                     (list :seat (emacs-wm-be-state-seat state)
                                           :id (emacs-wm-wl-object-id object)
                                           :keysym keysym
                                           :modifiers mods))
                (emacs-wm-be--req (emacs-wm-wl-object-id object) "enable")
                (puthash bid (emacs-wm-be--binding-make
                              :id (emacs-wm-wl-object-id object)
                              :keysym keysym :mods mods :name name)
                         (emacs-wm-be-state-bindings state))
                (emacs-wm-be-log 'info "binding %s = %s (keysym %#x mods %#x)"
                                 bid name keysym mods)))))))))

(defun emacs-wm-be--apply-pending-pointer-bindings ()
  "Create and enable queued pointer bindings.  Manage sequence only."
  (let* ((state emacs-wm-be--state)
         (queue (nreverse (emacs-wm-be-state-pending-pointer-binds state)))
         (seat (emacs-wm-be-state-seat state)))
    (setf (emacs-wm-be-state-pending-pointer-binds state) nil)
    (when (and queue seat)
      (dolist (entry queue)
        (pcase-let ((`(,bid ,button ,mods) entry))
          (let* ((conn (emacs-wm-be-state-conn state))
                 (object (emacs-wm-wl-new-id conn "river_pointer_binding_v1")))
            (emacs-wm-wl-request conn seat "get_pointer_binding"
                                 (list :id (emacs-wm-wl-object-id object)
                                       :button button
                                       :modifiers mods))
            (emacs-wm-be--req (emacs-wm-wl-object-id object) "enable")
            (puthash bid (emacs-wm-wl-object-id object)
                     (emacs-wm-be-state-pointer-bindings state))
            (emacs-wm-be-log 'info "pointer binding %s: button %s mods %#x"
                             bid button mods)))))))

(defun emacs-wm-be--pointer-binding-bid (object-id)
  "Return the frontend bid for pointer binding OBJECT-ID."
  (let (found)
    (maphash (lambda (bid id) (when (= id object-id) (setq found bid)))
             (emacs-wm-be-state-pointer-bindings emacs-wm-be--state))
    found))

(defun emacs-wm-be--apply-pending-eat-next ()
  "Ensure or cancel eating the next key, for submap escape.  Manage only."
  (let* ((state emacs-wm-be--state)
         (queue (nreverse (emacs-wm-be-state-pending-eat-next state))))
    (setf (emacs-wm-be-state-pending-eat-next state) nil)
    (when (and queue (emacs-wm-be-state-xkb-bindings-seat state))
      (dolist (on queue)
        (emacs-wm-be--req (emacs-wm-be-state-xkb-bindings-seat state)
                          (if on "ensure_next_key_eaten"
                            "cancel_ensure_next_key_eaten"))))))

(defun emacs-wm-be--binding-for-object (object-id)
  "Return the binding whose object id is OBJECT-ID."
  (let (found)
    (maphash (lambda (bid binding)
               (when (= (emacs-wm-be-binding-id binding) object-id)
                 (setq found (cons bid binding))))
             (emacs-wm-be-state-bindings emacs-wm-be--state))
    found))

;;; ----------------------------------------------------------- window ops

(defun emacs-wm-be--queue-window-op (wid op)
  "Queue window management OP (\"close\" or a fullscreen cons) for WID."
  (emacs-wm-be--debug "queue window op %S for %s" op wid)
  (push (cons wid op) (emacs-wm-be-state-pending-window-ops emacs-wm-be--state))
  (emacs-wm-be--dirty))

(defun emacs-wm-be--apply-pending-window-ops ()
  "Apply queued close/fullscreen/op operations.  Manage sequence only."
  (let* ((state emacs-wm-be--state)
         (ops (nreverse (emacs-wm-be-state-pending-window-ops state))))
    (setf (emacs-wm-be-state-pending-window-ops state) nil)
    (dolist (entry ops)
      (let* ((wid (car entry))
             (op (cdr entry))
             (window (and (integerp wid) (emacs-wm-be--win wid))))
        (emacs-wm-be--debug "apply window op %S for %s (window %s)"
                            op wid (and window t))
        (when window
          (pcase op
            ("close"
             (emacs-wm-be--req (emacs-wm-be-window-id window) "close"))
            ('fullscreen
             (emacs-wm-be--req (emacs-wm-be-window-id window) "inform_fullscreen")
             (let ((oid (or (emacs-wm-be-window-output window)
                            (emacs-wm-be--current-output-oid))))
               (emacs-wm-be--req (emacs-wm-be-window-id window) "fullscreen"
                                 (list :output oid)))
             (setf (emacs-wm-be-window-fullscreen window) t))
            ('exit-fullscreen
             (emacs-wm-be--req (emacs-wm-be-window-id window) "inform_not_fullscreen")
             (emacs-wm-be--req (emacs-wm-be-window-id window) "exit_fullscreen")
             (setf (emacs-wm-be-window-fullscreen window) nil))
            ('op-start
             (let ((seat (emacs-wm-be-state-seat state)))
               (when seat
                 ;; River's op acts on the seat's focused window.
                 (emacs-wm-be--req seat "focus_window" (list :window wid))
                 (emacs-wm-be--req seat "op_start_pointer")
                 (emacs-wm-be-log 'info "river op_start_pointer for %s" wid))))
            ('op-end
             (when-let* ((seat (emacs-wm-be-state-seat state)))
               (emacs-wm-be--req seat "op_end")
               (emacs-wm-be--debug "river op_end for %s" wid)
               ;; River's `.end' cancels the op without sending op_release
               ;; (that only comes from a pointer release), so finish here.
               ;; `--op-finish' is idempotent: it clears the op.
               (emacs-wm-be--op-finish)))))))))

(defun emacs-wm-be--window-command (msg)
  "Handle a window-cmd MSG from the frontend."
  (let* ((wid (plist-get msg :wid))
         (cmd (plist-get msg :cmd))
         (window (emacs-wm-be--win wid)))
    (if (not window)
        (emacs-wm-be-log 'debug "window-cmd %s for unknown window %s" cmd wid)
      (pcase cmd
        ("close" (emacs-wm-be--queue-window-op wid "close"))
        ("minimize"
         (setf (emacs-wm-be-window-minimized window) t)
         (emacs-wm-be--dirty))
        ("focus"
         (setf (emacs-wm-be-window-minimized window) nil)
         (setf (emacs-wm-be-state-focus emacs-wm-be--state) wid)
         (emacs-wm-be--dirty))
        ("toggle-float"
         (setf (emacs-wm-be-window-floating window)
               (not (emacs-wm-be-window-floating window)))
         (emacs-wm-be--dirty))
        ((or "fullscreen" "toggle-fullscreen")
         (if (emacs-wm-be-window-fullscreen window)
             (emacs-wm-be--queue-window-op wid 'exit-fullscreen)
           (emacs-wm-be--queue-window-op wid 'fullscreen)))
        (_ (emacs-wm-be-log 'warn "unknown window-cmd %S" cmd))))))

;;; --------------------------------------------------------------- replay

(defun emacs-wm-be--replay-state ()
  "Send the frontend the current outputs, frames and app windows."
  (let ((state emacs-wm-be--state))
    (emacs-wm-be-log 'info "replaying state: %d output(s), %d window(s)"
                     (hash-table-count (emacs-wm-be-state-outputs state))
                     (hash-table-count (emacs-wm-be-state-windows state)))
    (maphash (lambda (_oid output) (emacs-wm-be--emit-output output))
             (emacs-wm-be-state-outputs state))
    ;; Frames first: their fids are what the frontend's layout refers to.
    (maphash (lambda (_wid window)
               (when (emacs-wm-be-window-fid window)
                 (emacs-wm-be--emit
                  (list :t "frame"
                        :fid (emacs-wm-be-window-fid window)
                        :name (or (emacs-wm-be-window-title window) "")
                        :oid (emacs-wm-be-window-output window)
                        :wid (emacs-wm-be-window-id window)))))
             (emacs-wm-be-state-windows state))
    (maphash (lambda (_wid window)
               (unless (emacs-wm-be-window-fid window)
                 (let ((wid (emacs-wm-be-window-id window)))
                   (emacs-wm-be--emit (list :t "window" :wid wid
                                            :output (emacs-wm-be-window-output window)))
                   (when (emacs-wm-be-window-title window)
                     (emacs-wm-be--emit (list :t "title" :wid wid
                                              :title (emacs-wm-be-window-title window))))
                   (when (emacs-wm-be-window-app-id window)
                     (emacs-wm-be--emit (list :t "app-id" :wid wid
                                              :app_id (emacs-wm-be-window-app-id window))))
                   (when (emacs-wm-be-window-identifier window)
                     (emacs-wm-be--emit (list :t "identifier" :wid wid
                                              :identifier (emacs-wm-be-window-identifier window))))
                   (when-let* ((size (emacs-wm-be-window-size window)))
                     (emacs-wm-be--emit (list :t "size" :wid wid
                                              :w (car size) :h (cdr size)))))))
             (emacs-wm-be-state-windows state))))

;;; ---------------------------------------------------- interactive ops
;;
;; Dragging is split three ways: river reports cumulative pointer deltas
;; (`op_delta' is measured from the op's start, not from the last event), the
;; backend turns them into a rect, and the frontend persists the result.  The
;; backend holds no policy: it only moves or resizes the window the frontend
;; asked it to, and tells the frontend where it ended up.

(defun emacs-wm-be--op-after-delta (op dx dy)
  "Return OP updated by the cumulative pointer delta DX, DY.
A move keeps the size; a resize moves the edges in EDGES (bitmask: top 1,
bottom 2, left 4, right 8) and never makes the window smaller than 1x1."
  (let* ((kind (plist-get op :kind))
         (edges (or (plist-get op :edges) 10))
         (sx (plist-get op :start-x))
         (sy (plist-get op :start-y))
         (sw (max 1 (plist-get op :start-w)))
         (sh (max 1 (plist-get op :start-h))))
    (if (equal kind "resize")
        (let* ((left (and (/= 0 (logand edges 4)) dx))
               (right (and (/= 0 (logand edges 8)) dx))
               (top (and (/= 0 (logand edges 1)) dy))
               (bottom (and (/= 0 (logand edges 2)) dy))
               (x (+ sx (or left 0)))
               (y (+ sy (or top 0)))
               (w (max 1 (- (+ sw (or right 0)) (or left 0))))
               (h (max 1 (- (+ sh (or bottom 0)) (or top 0)))))
          (plist-put (plist-put (plist-put (plist-put op :x x) :y y) :w w) :h h))
      (plist-put (plist-put op :x (+ sx dx)) :y (+ sy dy)))))

(defun emacs-wm-be--op-start (msg)
  "Begin a move or resize for the frontend's MSG."
  (let* ((state emacs-wm-be--state)
         (wid (plist-get msg :wid))
         (window (emacs-wm-be--win wid))
         (rect (and window (or (emacs-wm-be-window-rect window) '(0 0 100 100)))))
    (if (emacs-wm-be-state-session-locked state)
        (emacs-wm-be-log 'warn "session locked: ignoring op-start for %S" wid)
     (if (not window)
        (emacs-wm-be-log 'warn "op-start for unknown window %S" wid)
      (setf (emacs-wm-be-state-op state)
            (list :wid wid
                  :kind (or (plist-get msg :kind) "move")
                  :edges (or (plist-get msg :edges) 10)
                  :start-x (nth 0 rect) :start-y (nth 1 rect)
                  :start-w (max 1 (nth 2 rect)) :start-h (max 1 (nth 3 rect))
                  :x (nth 0 rect) :y (nth 1 rect)
                  :w (max 1 (nth 2 rect)) :h (max 1 (nth 3 rect))))
      (emacs-wm-be-log 'info "op %s started for window %s at %S"
                       (plist-get (emacs-wm-be-state-op state) :kind) wid rect)
      ;; `op_start_pointer' is window management state: only legal inside a
      ;; manage sequence, like every other op in this list.
      (push (cons wid 'op-start) (emacs-wm-be-state-pending-window-ops state))
      (emacs-wm-be--dirty)))))

(defun emacs-wm-be--op-delta (args)
  "Apply a cumulative pointer delta from river.
River sends one `op_delta' per manage sequence while an op is live, repeating
the same (cumulative) value when the pointer has not moved, so only a delta
that actually changes the rect may ask for another sequence -- otherwise the
two feed each other in a loop and pin a core."
  (let* ((state emacs-wm-be--state)
         (op (emacs-wm-be-state-op state))
         (new (and op (emacs-wm-be--op-after-delta
                       op (plist-get args :dx) (plist-get args :dy)))))
    (when (and new
               (not (equal (list (plist-get op :x) (plist-get op :y)
                                 (plist-get op :w) (plist-get op :h))
                           (list (plist-get new :x) (plist-get new :y)
                                 (plist-get new :w) (plist-get new :h)))))
      (setf (emacs-wm-be-state-op state) new)
      (emacs-wm-be--dirty))))

(defun emacs-wm-be--op-finish ()
  "Finish the active op and tell the frontend where the window ended up."
  (let* ((state emacs-wm-be--state)
         (op (emacs-wm-be-state-op state)))
    (when op
      (setf (emacs-wm-be-state-op state) nil)
      (emacs-wm-be-log 'info "op %s finished for window %s: %S"
                       (plist-get op :kind) (plist-get op :wid)
                       (list (plist-get op :x) (plist-get op :y)
                             (plist-get op :w) (plist-get op :h)))
      (emacs-wm-be--emit
       (list :t "op-done" :wid (plist-get op :wid)
             :x (plist-get op :x) :y (plist-get op :y)
             :w (plist-get op :w) :h (plist-get op :h)))
      ;; river does NOT clear its own op on pointer release: `op_release' is
      ;; only a notification.  Until the WM sends op_end, `seat.op' stays set,
      ;; which makes the *next* op_start_pointer a no-op and leaves the cursor
      ;; in op mode.  Queue the teardown for the next manage sequence.
      (push (cons (plist-get op :wid) 'op-end)
            (emacs-wm-be-state-pending-window-ops state))
      (emacs-wm-be--debug "queued river op_end after release")
      (emacs-wm-be--dirty))))

;;; --------------------------------------------------------------- layout

(defun emacs-wm-be--frame-for-fid (fid)
  "The window whose fid is FID."
  (let (found)
    (maphash (lambda (_wid window)
               (when (and (not found)
                          (emacs-wm-be-window-fid window)
                          (= (emacs-wm-be-window-fid window) fid))
                 (setq found window)))
             (emacs-wm-be-state-windows emacs-wm-be--state))
    found))

(defun emacs-wm-be--propose-once (window width height)
  "Propose WIDTH x HEIGHT for WINDOW unless already proposed, clamped by hints."
  (let* ((min (emacs-wm-be-window-hint-min window))
         (max (emacs-wm-be-window-hint-max window))
         (width (max 1 width))
         (height (max 1 height))
         (width (if min (max width (car min)) width))
         (height (if min (max height (cdr min)) height))
         (width (if (and max (> (car max) 0)) (min width (car max)) width))
         (height (if (and max (> (cdr max) 0)) (min height (cdr max)) height))
         (proposed (cons width height)))
    (unless (equal proposed (emacs-wm-be-window-last-proposed window))
      (setf (emacs-wm-be-window-last-proposed window) proposed)
      (emacs-wm-be--req (emacs-wm-be-window-id window) "propose_dimensions"
                        (list :width width :height height)))))

(defun emacs-wm-be--apply-tiled (window edges)
  "Send set_tiled EDGES for WINDOW when it changed."
  (unless (equal edges (emacs-wm-be-window-tiled window))
    (setf (emacs-wm-be-window-tiled window) edges)
    (emacs-wm-be--req (emacs-wm-be-window-id window) "set_tiled"
                      (list :edges edges))))

(defun emacs-wm-be--sync-border (window)
  "Apply WINDOW's border if it changed."
  (let ((border (emacs-wm-be-window-border window)))
    (unless (equal border (emacs-wm-be-window-border-applied window))
      (emacs-wm-be--debug "border for window %s: %S"
                          (emacs-wm-be-window-id window) border)
      (setf (emacs-wm-be-window-border-applied window) border)
      (emacs-wm-be--req (emacs-wm-be-window-id window) "set_borders"
                        (if border
                            (list :edges (or (plist-get border :edges) 15)
                                  :width (or (plist-get border :w) 0)
                                  :r (or (plist-get border :r) 0)
                                  :g (or (plist-get border :g) 0)
                                  :b (or (plist-get border :b) 0)
                                  :a (or (plist-get border :a) #xffffffff))
                          (list :edges 0 :width 0 :r 0 :g 0 :b 0 :a 0))))))

(defun emacs-wm-be--reconcile-layout ()
  "Apply the current layout's window-management state.  Manage sequence only."
  (let* ((state emacs-wm-be--state)
         (layout (emacs-wm-be-state-layout state)))
    (when layout
     (dolist (frame-msg (append (plist-get layout :frames) nil))
      (let* ((fid (plist-get frame-msg :fid))
             (oid (plist-get frame-msg :oid))
             (frame (emacs-wm-be--frame-for-fid fid)))
        (when frame
          (let* ((output (or (emacs-wm-be--out oid)
                             (emacs-wm-be--primary-output)))
                 (usable (if output (emacs-wm-be--usable output)
                           '(0 0 1920 1080)))
                 (uw (nth 2 usable))
                 (uh (nth 3 usable)))
            (emacs-wm-be--propose-once frame uw uh)
            (unless (emacs-wm-be-window-maximized frame)
              (setf (emacs-wm-be-window-maximized frame) t)
              (emacs-wm-be--req (emacs-wm-be-window-id frame) "inform_maximized"))
            (emacs-wm-be--apply-tiled frame 15)
            (setf (emacs-wm-be-window-rect frame) (list 0 0 uw uh))))))
    (dolist (win-msg (append (plist-get layout :windows) nil))
      (let* ((wid (plist-get win-msg :wid))
             (window (emacs-wm-be--win wid)))
        (when window
          (setf (emacs-wm-be-window-border window) (plist-get win-msg :border))
          ;; Borders are independent of geometry: apply before the fullscreen
          ;; early return so a colour change is not lost while fullscreen.
          (emacs-wm-be--sync-border window)
          (cond
           ((and (emacs-wm-be-state-op state)
                 (eql wid (plist-get (emacs-wm-be-state-op state) :wid)))
            ;; Being dragged: the op owns its geometry until it finishes.
            (let ((op (emacs-wm-be-state-op state)))
              (when (equal (plist-get op :kind) "resize")
                (emacs-wm-be--propose-once window
                                           (plist-get op :w) (plist-get op :h)))
              (setf (emacs-wm-be-window-rect window)
                    (list (plist-get op :x) (plist-get op :y)
                          (plist-get op :w) (plist-get op :h)))))
           ((not (plist-get win-msg :visible))
            ;; Hidden (or on another desktop): leave its geometry alone.  It is
            ;; hidden anyway, and proposing 1x1 to a terminal makes clients
            ;; resize themselves into oblivion (one of them exits).
            nil)
           ((emacs-wm-be-window-fullscreen window)
            (let* ((oid (or (emacs-wm-be-window-output window) 0))
                   (output (emacs-wm-be--out oid))
                   (width (if output (emacs-wm-be-output-w output) 1920))
                   (height (if output (emacs-wm-be-output-h output) 1080)))
              (emacs-wm-be--propose-once window width height)))
           (t
            (let ((float (plist-get win-msg :float))
                  (rect (list (plist-get win-msg :x) (plist-get win-msg :y)
                              (plist-get win-msg :w) (plist-get win-msg :h))))
              (emacs-wm-be--apply-tiled window (if float 0 15))
              (let ((decor (plist-get win-msg :decor)))
                (when (and decor (not (equal decor (emacs-wm-be-window-decor-applied window))))
                  (setf (emacs-wm-be-window-decor-applied window) decor)
                  (emacs-wm-be--req (emacs-wm-be-window-id window)
                                    (if (equal decor "csd") "use_csd" "use_ssd"))
                  (emacs-wm-be-log 'info "window %s decoration: %s" wid decor)))
              (emacs-wm-be--propose-once window (nth 2 rect) (nth 3 rect))
              (setf (emacs-wm-be-window-rect window) rect
                    (emacs-wm-be-window-floating window) (and float t))
              (setf (emacs-wm-be-window-frame-desktop window)
                    (plist-get win-msg :frame))))))))
    ;; Ask river to treat us as the default layer-shell manager for each output
    ;; so its non_exclusive_area (after bar exclusive zones) is authoritative.
    (maphash (lambda (_oid output)
               (when-let* ((ls-output (emacs-wm-be-output-ls-output output)))
                 (emacs-wm-be--req ls-output "set_default")))
             (emacs-wm-be-state-outputs state)))
    (emacs-wm-be--write-state-file)))

(defun emacs-wm-be--reconcile-focus ()
  "Apply the layout's focus.  Manage sequence only."
  (let* ((state emacs-wm-be--state)
         (layout (emacs-wm-be-state-layout state))
         (seat (emacs-wm-be-state-seat state)))
    (when (and seat
               (not (emacs-wm-be-state-session-locked state))
               (not (eq (emacs-wm-be-state-layer-focus state) 'exclusive)))
      (if (null layout)
          nil
        (let ((wid (plist-get (plist-get layout :focus) :window))
              (fid (plist-get (plist-get layout :focus) :frame))
              (frame (and (plist-get (plist-get layout :focus) :frame)
                          (emacs-wm-be--frame-for-fid
                           (plist-get (plist-get layout :focus) :frame)))))
          (cond
           ((and wid (emacs-wm-be--win wid))
            (let ((window (emacs-wm-be--win wid)))
              (setf (emacs-wm-be-window-minimized window) nil)
              (unless (eql wid (emacs-wm-be-state-focus state))
                (setf (emacs-wm-be-state-focus state) wid)
                (emacs-wm-be-log 'info "focus -> window %d" wid)
                (emacs-wm-be--req seat "focus_window" (list :window wid)))))
           (frame
            (let ((frame-id (emacs-wm-be-window-id frame)))
              (unless (eql frame-id (emacs-wm-be-state-focus state))
                (setf (emacs-wm-be-state-focus state) frame-id)
                (emacs-wm-be-log 'info "focus -> frame window %d" frame-id)
                (emacs-wm-be--req seat "focus_window" (list :window frame-id)))))
           (t
            (when (emacs-wm-be-state-focus state)
              (setf (emacs-wm-be-state-focus state) nil)
              (emacs-wm-be--req seat "clear_focus"))))
          (ignore fid))))))

;;; --------------------------------------------------------------- rendering

(defun emacs-wm-be--render-window (window x y visible clip-w clip-h)
  "Apply rendering state for WINDOW: position, visibility and clipping.
Position and stacking live on `river_node_v1'; visibility and clipping on
`river_window_v1'."
  (let ((object (emacs-wm-be-window-id window))
        (node (emacs-wm-be-window-node window)))
    (unless (equal (emacs-wm-be-window-render-visible window) visible)
      (setf (emacs-wm-be-window-render-visible window) visible)
      (if visible
          (emacs-wm-be--req object "show")
        (emacs-wm-be--req object "hide")))
    (when visible
      (unless (and (eql x (emacs-wm-be-window-render-x window))
                   (eql y (emacs-wm-be-window-render-y window)))
        (setf (emacs-wm-be-window-render-x window) x
              (emacs-wm-be-window-render-y window) y)
        (emacs-wm-be--req node "set_position" (list :x x :y y)))
      (let ((clip (and clip-w (cons clip-w clip-h))))
        (unless (equal clip (emacs-wm-be-window-render-clip window))
          (setf (emacs-wm-be-window-render-clip window) clip)
          (when clip
            ;; NOT set_clip_box: river intersects its own border rects with the
            ;; window clip, and the borders sit *outside* the window box, so a
            ;; window clip of the content size erases every border.  The content
            ;; clip boxes only the surface, which is what we actually want.
            (emacs-wm-be--req object "set_content_clip_box"
                              (list :x 0 :y 0 :width clip-w :height clip-h))))))))

(defun emacs-wm-be--render ()
  "Apply the applied layout's rendering state.  Render sequence only."
  (let* ((state emacs-wm-be--state)
         (layout (emacs-wm-be-state-layout state))
         ;; Restacking is only needed when the layout actually changed; doing
         ;; it every frame would be two protocol requests per window at 60 Hz.
         (restack (emacs-wm-be-state-render-dirty state))
         (order (plist-get layout :order))
         (focused (plist-get (plist-get layout :focus) :window)))
    (when layout
      ;; Frames first: they sit at the bottom of the stack.
      (dolist (frame-msg (append (plist-get layout :frames) nil))
        (let ((frame (emacs-wm-be--frame-for-fid (plist-get frame-msg :fid))))
          (when frame
            (let* ((oid (or (plist-get frame-msg :oid) 0))
                   (output (emacs-wm-be--out oid))
                   (origin (emacs-wm-be--origin oid))
                   (ox (nth 0 origin))
                   (oy (nth 1 origin))
                   (usable (if output (emacs-wm-be--usable output) '(0 0 1920 1080)))
                   (ux (nth 0 usable))
                   (uy (nth 1 usable))
                   (uw (nth 2 usable))
                   (uh (nth 3 usable))
                   (visible (if (plist-get frame-msg :visible) t nil)))
              (ignore ux uy)
              (emacs-wm-be--render-window frame (+ ox ux) (+ oy uy) visible nil nil)
              (when (and restack visible)
                (emacs-wm-be--req (emacs-wm-be-window-node frame) "place_bottom")
                (setf (emacs-wm-be-window-rect frame) (list 0 0 uw uh)))))))
      ;; Then app windows.
      (dolist (win-msg (append (plist-get layout :windows) nil))
        (let* ((wid (plist-get win-msg :wid))
               (window (emacs-wm-be--win wid))
               (oid (or (emacs-wm-be-window-output window) 0))
               (origin (emacs-wm-be--origin oid))
               (ox (nth 0 origin))
               (oy (nth 1 origin))
               (rect (list (plist-get win-msg :x) (plist-get win-msg :y)
                           (plist-get win-msg :w) (plist-get win-msg :h)))
               (visible (if (plist-get win-msg :visible) t nil))
               (float (plist-get win-msg :float))
               ;; The clip is the layout rect, not the client's last reported
               ;; size: a client still mid-resize would draw over the borders.
               (op (let ((op (emacs-wm-be-state-op state)))
                     (and op (eql wid (plist-get op :wid)) op)))
               (rect (if op
                         (list (plist-get op :x) (plist-get op :y)
                               (plist-get op :w) (plist-get op :h))
                       rect)))
          (when window
            (emacs-wm-be--render-window
             window (+ ox (nth 0 rect)) (+ oy (nth 1 rect)) visible
             ;; Clip to the *rect*, not to the client's last reported size: a
             ;; client that has not finished resizing yet would otherwise draw
             ;; over the right/bottom borders, which river places outside the
             ;; window box.
             (unless float (nth 2 rect))
             (unless float (nth 3 rect)))
            (when (and restack visible (null order))
              ;; No explicit order: focused last, hash order otherwise.
              (emacs-wm-be--req (emacs-wm-be-window-node window) "place_top")
              (when (eql wid focused)
                (emacs-wm-be--req (emacs-wm-be-window-node window) "place_top"))))))
      ;; An explicit bottom->top order: each place_top raises the node above
      ;; everything placed before it, so one pass in order is enough.
      (when (and restack order)
        (dolist (wid (append order nil))
          (let ((window (emacs-wm-be--win wid)))
            (when window
              (emacs-wm-be--req (emacs-wm-be-window-node window) "place_top"))))))
    (setf (emacs-wm-be-state-render-dirty state) nil)))

;;; ------------------------------------------------------------ state file

(defcustom emacs-wm-be-desktops-per-output 4
  "Desktop count reported to the bar state file."
  :type 'integer)

(defun emacs-wm-be--write-state-file ()
  "Write the bar state file atomically."
  (let ((path (emacs-wm-be-state-file-path)))
    (when path
      (let* ((layout (emacs-wm-be-state-layout emacs-wm-be--state))
             (focus (plist-get layout :focus))
             (fid (plist-get focus :frame))
             (frame (and fid (emacs-wm-be--frame-for-fid fid)))
             (desktop (or (and frame (emacs-wm-be-window-desktop frame)) 1))
             (counts (make-hash-table :test 'equal)))
        (dolist (win-msg (append (plist-get layout :windows) nil))
          (let ((frame-id (plist-get win-msg :frame)))
            (when (and frame-id (plist-get win-msg :visible))
              (let ((key (format "%s" frame-id)))
                (puthash key (1+ (or (gethash key counts) 0)) counts)))))
        (let ((json (json-serialize
                     (list :desktop desktop
                           :desktops emacs-wm-be-desktops-per-output
                           :generation (or (emacs-wm-be-state-gen emacs-wm-be--state) 0)
                           :windows counts
                           :focus (list :frame fid
                                        :window (plist-get focus :window))))))
          (let ((tmp (concat path ".tmp")))
            (with-temp-file tmp (insert json))
            (rename-file tmp path t)))))))

;;; ------------------------------------------------------------- the engine

(defun emacs-wm-be--manage-finish ()
  "Finish the manage sequence."
  (setf (emacs-wm-be-state-in-manage emacs-wm-be--state) nil)
  (emacs-wm-be--req (emacs-wm-be-state-wm emacs-wm-be--state) "manage_finish")
  (emacs-wm-be--debug "sent manage_finish"))

(defun emacs-wm-be--on-manage-start ()
  "Handle river's manage_start: apply everything from cached state."
  (let ((state emacs-wm-be--state))
    (setf (emacs-wm-be-state-in-manage state) t
          (emacs-wm-be-state-manage-count state)
          (1+ (emacs-wm-be-state-manage-count state)))
    (emacs-wm-be--debug "manage_start #%d" (emacs-wm-be-state-manage-count state))
    ;; Whatever happens below, river must get its manage_finish: a sequence
    ;; left open stops river from ever starting another one, and river stops
    ;; processing input in the meantime.
    (unwind-protect
        (condition-case err
            (progn
              (emacs-wm-be--debug "  phase: bindings")
              (emacs-wm-be--apply-pending-bindings)
              (emacs-wm-be--apply-pending-pointer-bindings)
              (emacs-wm-be--apply-pending-eat-next)
              (emacs-wm-be--apply-pending-window-ops)
              (emacs-wm-be--maybe-create-vkb)
              (emacs-wm-be--debug "  phase: layout")
              (emacs-wm-be--reconcile-layout)
              (emacs-wm-be--debug "  phase: focus")
              (emacs-wm-be--reconcile-focus)
              (emacs-wm-be--debug "  phase: inject")
              (emacs-wm-be--flush-inject)
              (setf (emacs-wm-be-state-applied-layout state)
                    (emacs-wm-be-state-layout state)))
          (error (emacs-wm-be-log 'error "manage sequence error: %S" err)))
      (emacs-wm-be--manage-finish))))

(defun emacs-wm-be--on-render-start ()
  "Handle river's render_start."
  (emacs-wm-be--debug "  render")
  (unwind-protect
      (condition-case err
          (emacs-wm-be--render)
        (error (emacs-wm-be-log 'error "render sequence error: %S" err)))
    (emacs-wm-be--req (emacs-wm-be-state-wm emacs-wm-be--state) "render_finish")
    (emacs-wm-be--debug "sent render_finish")))

;;; -------------------------------------------------------------- events

(defun emacs-wm-be--frame-role (title)
  "Parse TITLE as a desktop frame name.
Returns (DESKTOP . OUTPUT-OID) for \"wm-frame:<oid>:<desktop>\", (DESKTOP . nil)
for the legacy \"wm-frame:<desktop>\", and nil for anything else."
  (when (and (stringp title) (string-prefix-p "wm-frame:" title))
    (let* ((rest (substring title (length "wm-frame:")))
           (parts (split-string rest ":")))
      (cond
       ((and (= 2 (length parts))
             (string-match-p "\\`[0-9]+\\'" (car parts))
             (string-match-p "\\`[0-9]+\\'" (cadr parts)))
        (cons (string-to-number (cadr parts))
              (string-to-number (car parts))))
       ((and (= 1 (length parts))
             (string-match-p "\\`[0-9]+\\'" (car parts)))
        (cons (string-to-number (car parts)) nil))))))

(defun emacs-wm-be--on-window-title (window args)
  "Handle river_window_v1.title on WINDOW."
  (let* ((state emacs-wm-be--state)
         (title (plist-get args :title))
         (wid (emacs-wm-be-window-id window))
         (role (emacs-wm-be--frame-role title)))
    (setf (emacs-wm-be-window-title window) title)
    (emacs-wm-be--emit (list :t "title" :wid wid :title title))
    (if role
        (progn
          (setf (emacs-wm-be-window-role window) 'frame
                (emacs-wm-be-window-desktop window) (car role))
          (when (cdr role)
            (setf (emacs-wm-be-window-output window) (cdr role)))
          (unless (emacs-wm-be-window-fid window)
            (let* ((fid (emacs-wm-be-state-next-fid state))
                   (oid (or (emacs-wm-be-window-output window)
                            (emacs-wm-be--current-output-oid))))
              (setf (emacs-wm-be-state-next-fid state) (1+ fid)
                    (emacs-wm-be-window-fid window) fid
                    (emacs-wm-be-window-output window) oid)
              (emacs-wm-be-log 'info "frame %d is window %d (%s)" fid wid title)
              (emacs-wm-be--emit (list :t "frame" :fid fid :name title
                                       :oid oid :wid wid)))))
      (setf (emacs-wm-be-window-role window) 'app))))

(defun emacs-wm-be--on-window (wid)
  "Handle a new river_window_v1 with id WID."
  (let* ((state emacs-wm-be--state)
         (window (emacs-wm-wl-object-add (emacs-wm-be-state-conn state)
                                         "river_window_v1" wid))
         (open-on (emacs-wm-be--current-output-oid))
         (node (emacs-wm-wl-new-id (emacs-wm-be-state-conn state) "river_node_v1")))
    (emacs-wm-wl-request (emacs-wm-be-state-conn state) window "get_node"
                         (list :id (emacs-wm-wl-object-id node)))
    (puthash wid
             (emacs-wm-be--window-make
              :id wid :node (emacs-wm-wl-object-id node) :output open-on)
             (emacs-wm-be-state-windows state))
    (emacs-wm-be--debug "new window %d on output %s" wid open-on)
    (emacs-wm-be--emit (list :t "window" :wid wid :output open-on))))

(defun emacs-wm-be--on-window-closed (window)
  "Handle river_window_v1.closed on WINDOW."
  (let* ((state emacs-wm-be--state)
         (wid (emacs-wm-be-window-id window))
         (record (emacs-wm-be--win wid)))
    (emacs-wm-be-log 'info "window %d closed" wid)
    (emacs-wm-be--emit (list :t "gone" :wid wid))
    (when (and record (emacs-wm-be-window-fid record))
      (emacs-wm-be--emit (list :t "frame-gone"
                               :fid (emacs-wm-be-window-fid record))))
    (remhash wid (emacs-wm-be-state-windows state))
    (when (eql wid (emacs-wm-be-state-focus state))
      (setf (emacs-wm-be-state-focus state) nil))
    ;; `closed' is sent from Window.makeInert: river has already destroyed both
    ;; the river_window_v1 and the river_node_v1 object belonging to us, so
    ;; sending destroy would be a request on an unknown object.  Just forget
    ;; them locally.
    (when record
      (when-let* ((node (emacs-wm-be-window-node record)))
        (emacs-wm-wl-object-remove (emacs-wm-be-state-conn state) node)))
    (emacs-wm-wl-object-remove (emacs-wm-be-state-conn state) wid)))

(defun emacs-wm-be--on-output (oid)
  "Handle a new river_output_v1 with id OID."
  (let* ((state emacs-wm-be--state)
         (record (emacs-wm-be--output-make :id oid :x 0 :y 0 :w 0 :h 0)))
    ;; Register the server-allocated object so its events dispatch to us.
    (emacs-wm-wl-object-add (emacs-wm-be-state-conn state) "river_output_v1" oid)
    (puthash oid record (emacs-wm-be-state-outputs state))
    (when (emacs-wm-be-state-layer-shell state)
      (let ((ls (emacs-wm-wl-new-id (emacs-wm-be-state-conn state)
                                    "river_layer_shell_output_v1")))
        (emacs-wm-wl-request (emacs-wm-be-state-conn state)
                             (emacs-wm-be-state-layer-shell state)
                             "get_output"
                             (list :id (emacs-wm-wl-object-id ls) :output oid))
        (setf (emacs-wm-be-output-ls-output record) (emacs-wm-wl-object-id ls))))
    (emacs-wm-be--emit-output record)))

(defun emacs-wm-be--on-layer-focus (kind)
  "Track which kind of layer surface holds focus."
  (setf (emacs-wm-be-state-layer-focus emacs-wm-be--state) kind)
  (emacs-wm-be--emit (list :t "layer-focus" :kind (symbol-name kind)))
  (emacs-wm-be--debug "layer focus %S" kind))

(defun emacs-wm-be--on-pointer-position (args)
  "Track the pointer and tell the frontend when it changes output."
  (let* ((state emacs-wm-be--state)
         (x (plist-get args :x))
         (y (plist-get args :y))
         (oid (or (emacs-wm-be--output-at x y)
                  (emacs-wm-be-state-pointer-oid state))))
    (setf (emacs-wm-be-state-pointer-x state) x
          (emacs-wm-be-state-pointer-y state) y)
    (unless (eql oid (emacs-wm-be-state-pointer-oid state))
      (setf (emacs-wm-be-state-pointer-oid state) oid)
      (emacs-wm-be--debug "pointer on output %s" oid)
      (emacs-wm-be--emit (list :t "pointer" :x x :y y :oid oid)
                         ))))

(defun emacs-wm-be--on-key-event (binding-object state-name)
  "Forward a key press/release for BINDING-OBJECT to the frontend."
  (let ((entry (emacs-wm-be--binding-for-object binding-object)))
    (when entry
      (emacs-wm-be--emit (list :t "key" :bid (car entry) :state state-name)))))

;;; -------------------------------------------------------- event dispatch

(defun emacs-wm-be--dispatch (connection object event args)
  "Dispatch one Wayland event."
  (ignore connection)
  (when (null object)
    ;; Synthetic "closed" event from the codec: river went away.
    (when (equal event "closed")
      (emacs-wm-be-log 'warn "Wayland connection closed")
      (emacs-wm-be--quit "river exited")))
  (when object
    (let ((interface (emacs-wm-wl-object-interface object))
          (wid (emacs-wm-wl-object-id object)))
      (emacs-wm-be--debug "event %s.%s id=%s %S" interface event wid args)
      (pcase interface
        ("wl_display"
         (pcase event
           ("error"
            (emacs-wm-be-log 'error "Wayland protocol error %s on object %s: %s"
                             (plist-get args :code)
                             (plist-get args :object_id)
                             (plist-get args :message)))
           ("delete_id" nil)))
        ("wl_registry"
         (pcase event
           ("global" (emacs-wm-be--on-global args))
           ("global_remove" nil)))
        ("river_window_manager_v1"
         (pcase event
           ("manage_start" (emacs-wm-be--on-manage-start))
           ("render_start" (emacs-wm-be--on-render-start))
           ("window" (emacs-wm-be--on-window (plist-get args :id)))
           ("output" (emacs-wm-be--on-output (plist-get args :id)))
           ("seat" (emacs-wm-be--on-seat (plist-get args :id)))
           ("unavailable"
            (emacs-wm-be-log 'error "river says this client is not the active WM")
            (emacs-wm-be--quit "superseded"))
           ("finished"
            (emacs-wm-be-log 'error "river finished the window management protocol")
            (emacs-wm-be--quit "finished"))
           ("session_locked"
            (setf (emacs-wm-be-state-session-locked emacs-wm-be--state) t)
            ;; River drops keyboard focus when the session locks, so our record
            ;; of the applied focus is no longer true.  Forgetting it here is
            ;; what makes the next manage sequence re-assert focus on unlock;
            ;; keeping it would leave the window focused as far as the WM is
            ;; concerned while river's seat focuses nothing, and every injected
            ;; key would be delivered to the void.
            (setf (emacs-wm-be-state-focus emacs-wm-be--state) nil)
            (emacs-wm-be-log 'info "session locked: focus and injection suspended")
            (emacs-wm-be--emit (list :t "locked" :on t)))
           ("session_unlocked"
            (setf (emacs-wm-be-state-session-locked emacs-wm-be--state) nil)
            (emacs-wm-be-log 'info "session unlocked")
            (emacs-wm-be--emit (list :t "locked" :on nil))
            ;; River also clears the seat's focus on unlock.  Ask for a manage
            ;; sequence now so the layout's focus is applied again without
            ;; waiting for the next unrelated event (a keystroke, a window).
            (emacs-wm-be--dirty))))
        ("river_window_v1"
         (let ((window (emacs-wm-be--win wid)))
           (when window
             (pcase event
               ("title" (emacs-wm-be--on-window-title window args))
               ("app_id"
                (setf (emacs-wm-be-window-app-id window) (plist-get args :app_id))
                (emacs-wm-be--emit (list :t "app-id" :wid wid
                                         :app_id (plist-get args :app_id))))
               ("identifier"
                (setf (emacs-wm-be-window-identifier window)
                      (plist-get args :identifier))
                (emacs-wm-be--emit (list :t "identifier" :wid wid
                                         :identifier (plist-get args :identifier))))
               ("dimensions"
                (setf (emacs-wm-be-window-size window)
                      (cons (plist-get args :width) (plist-get args :height)))
                (emacs-wm-be--emit (list :t "size" :wid wid
                                         :w (plist-get args :width)
                                         :h (plist-get args :height))))
               ("dimensions_hint"
                (setf (emacs-wm-be-window-hint-min window)
                      (cons (plist-get args :min_width) (plist-get args :min_height))
                      (emacs-wm-be-window-hint-max window)
                      (cons (plist-get args :max_width) (plist-get args :max_height))
                      (emacs-wm-be-window-last-proposed window) nil)
                (emacs-wm-be--dirty))
               ("parent"
                (let ((has (and (plist-get args :parent) t)))
                  (setf (emacs-wm-be-window-has-parent window) has)
                  (when has
                    (setf (emacs-wm-be-window-floating window) t))
                  (emacs-wm-be--emit (list :t "parent" :wid wid :has_parent has))))
               ("decoration_hint"
                ;; 0 = no preference, 1 = client side, 2 = server side
                (emacs-wm-be--emit
                 (list :t "decor" :wid wid
                       :hint (pcase (plist-get args :hint)
                               (1 "client") (2 "server") (_ "none")))))
               ("unreliable_pid"
                (emacs-wm-be--debug "window %d pid %s" wid (plist-get args :unreliable_pid)))
               ("closed" (emacs-wm-be--on-window-closed window))
               ("fullscreen_requested"
                (emacs-wm-be--emit (list :t "request" :wid wid :kind "fullscreen"))
                (emacs-wm-be--queue-window-op wid 'fullscreen))
               ("exit_fullscreen_requested"
                (emacs-wm-be--emit (list :t "request" :wid wid :kind "exit-fullscreen"))
                (emacs-wm-be--queue-window-op wid 'exit-fullscreen))
               ("minimize_requested"
                (setf (emacs-wm-be-window-minimized window) t)
                (emacs-wm-be--emit (list :t "request" :wid wid :kind "minimize"))
                (emacs-wm-be--dirty))
               ("maximize_requested"
                (emacs-wm-be--emit (list :t "request" :wid wid :kind "maximize")))
               ("unmaximize_requested"
                (emacs-wm-be--emit (list :t "request" :wid wid :kind "unmaximize")))
               ("show_window_menu_requested"
                (emacs-wm-be--emit (list :t "request" :wid wid :kind "show-menu")))
               ("pointer_move_requested"
                (emacs-wm-be--emit (list :t "request" :wid wid :kind "move")))
               ("pointer_resize_requested"
                (emacs-wm-be--emit (list :t "request" :wid wid :kind "resize")))
               (_ nil)))))
        ("river_output_v1"
         (let ((output (emacs-wm-be--out wid)))
           (when output
             (pcase event
               ("position"
                (setf (emacs-wm-be-output-x output) (plist-get args :x)
                      (emacs-wm-be-output-y output) (plist-get args :y))
                (emacs-wm-be--emit-output output)
                (emacs-wm-be--dirty))
               ("dimensions"
                (setf (emacs-wm-be-output-w output) (plist-get args :width)
                      (emacs-wm-be-output-h output) (plist-get args :height))
                (emacs-wm-be--emit-output output)
                (emacs-wm-be--dirty))
               ("wl_output" nil)
               ("removed"
                (emacs-wm-be-log 'info "output %d removed" wid)
                (emacs-wm-be--emit (list :t "output-removed" :oid wid))
                (remhash wid (emacs-wm-be-state-outputs emacs-wm-be--state))
                (when-let* ((ls (emacs-wm-be-output-ls-output output)))
                  (emacs-wm-be--req ls "destroy"))
                (emacs-wm-be--req wid "destroy")
                (emacs-wm-be--dirty))
               ("capture_sessions" nil)))))
        ("river_seat_v1"
         (pcase event
           ("pointer_position" (emacs-wm-be--on-pointer-position args))
           ("pointer_enter"
            (setf (emacs-wm-be-state-pointer-window emacs-wm-be--state)
                  (plist-get args :window))
            (emacs-wm-be--emit (list :t "pointer-enter" :wid (plist-get args :window))))
           ("pointer_leave"
            (setf (emacs-wm-be-state-pointer-window emacs-wm-be--state) nil)
            (emacs-wm-be--emit (list :t "pointer-leave")))
           ("window_interaction"
            (when-let* ((wid (plist-get args :window)))
              (setf (emacs-wm-be-state-focus emacs-wm-be--state) wid)
              (when-let* ((window (emacs-wm-be--win wid)))
                (setf (emacs-wm-be-window-minimized window) nil))
              (emacs-wm-be--dirty)))
           ("removed" (emacs-wm-be-log 'warn "seat removed"))
           ("op_delta" (emacs-wm-be--op-delta args))
           ("op_release" (emacs-wm-be--op-finish))
           ("wl_seat" nil)
           ("op_delta_touch" nil) ("op_release_touch" nil)
           ("op_cancel_touch" nil)
           ("shell_surface_interaction" nil)))
        ("river_xkb_binding_v1"
         (pcase event
           ("pressed" (emacs-wm-be--on-key-event wid "press"))
           ("released" (emacs-wm-be--on-key-event wid "release"))
           ("stop_repeat" nil)))
        ("river_xkb_bindings_seat_v1"
         (pcase event
           ("ate_unbound_key"
            (emacs-wm-be--debug "river ate an unbound key")
            (emacs-wm-be--emit (list :t "key-unbound")))
           ("modifiers_update"
            (emacs-wm-be--emit (list :t "modifiers"
                                     :old (plist-get args :old)
                                     :new (plist-get args :new))))))
        ("river_pointer_binding_v1"
         (pcase event
           ("pressed"
            (when-let* ((bid (emacs-wm-be--pointer-binding-bid wid)))
              (emacs-wm-be-log 'info "pointer binding %s pressed on window %s"
                               bid (emacs-wm-be-state-pointer-window
                                    emacs-wm-be--state))
              (emacs-wm-be--emit
               (list :t "pointer-bind" :bid bid
                     :wid (emacs-wm-be-state-pointer-window emacs-wm-be--state)))))
           ("released" nil)))
        ("river_layer_shell_output_v1"
         (pcase event
           ("non_exclusive_area"
            (let ((output (emacs-wm-be--out
                           (emacs-wm-wl-object-id object))))
              (ignore output))
            (maphash (lambda (_oid output)
                       (when (eql (emacs-wm-be-output-ls-output output) wid)
                         (setf (emacs-wm-be-output-usable output)
                               (list (plist-get args :x) (plist-get args :y)
                                     (plist-get args :width)
                                     (plist-get args :height)))
                         (emacs-wm-be-log 'info
                                          "output %d non-exclusive area %dx%d at %d,%d"
                                          (emacs-wm-be-output-id output)
                                          (plist-get args :width) (plist-get args :height)
                                          (plist-get args :x) (plist-get args :y))
                         (emacs-wm-be--emit-output output)))
                     (emacs-wm-be-state-outputs emacs-wm-be--state))
            (emacs-wm-be--dirty))))
        ("river_layer_shell_seat_v1"
         (pcase event
           ("focus_exclusive" (emacs-wm-be--on-layer-focus 'exclusive))
           ("focus_non_exclusive" (emacs-wm-be--on-layer-focus 'non-exclusive))
           ("focus_none" (emacs-wm-be--on-layer-focus 'none))))
        ("wl_seat" nil)
        (_ nil)))))

;;; ------------------------------------------------------------------- seat

(defun emacs-wm-be--on-seat (seat-id)
  "Handle river's seat event, creating the companion objects."
  (let ((state emacs-wm-be--state))
    (emacs-wm-wl-object-add (emacs-wm-be-state-conn state) "river_seat_v1" seat-id)
    (setf (emacs-wm-be-state-seat state) seat-id)
    (emacs-wm-be-log 'info "got seat %d" seat-id)
    (when (emacs-wm-be-state-layer-shell state)
      (let ((ls (emacs-wm-wl-new-id (emacs-wm-be-state-conn state)
                                    "river_layer_shell_seat_v1")))
        (emacs-wm-wl-request (emacs-wm-be-state-conn state)
                             (emacs-wm-be-state-layer-shell state)
                             "get_seat"
                             (list :id (emacs-wm-wl-object-id ls) :seat seat-id))
        (setf (emacs-wm-be-state-ls-seat state) (emacs-wm-wl-object-id ls))))
    (emacs-wm-be--maybe-create-bindings-seat)
    (emacs-wm-be--maybe-create-vkb)
    (emacs-wm-be--dirty)))

;;; -------------------------------------------------------------- lifetime

(defun emacs-wm-be--quit (reason)
  "Tell the frontend why we are leaving, then exit."
  (let ((state emacs-wm-be--state))
    (unless (emacs-wm-be-state-quitting state)
      (setf (emacs-wm-be-state-quitting state) t)
      (emacs-wm-be-log 'warn "quitting: %s" reason)
      (emacs-wm-be--emit (list :t "bye" :reason reason))
      (when (emacs-wm-be-state-conn state)
        (emacs-wm-wl-disconnect (emacs-wm-be-state-conn state)))
      (when (emacs-wm-be-state-client state)
        (ignore-errors (delete-process (emacs-wm-be-state-client state))))
      (run-at-time 0.2 nil (lambda () (kill-emacs 0))))))

;;; ---------------------------------------------------------------- startup

(defun emacs-wm-be-main ()
  "Start the backend: connect to river and serve the frontend."
  (when (getenv "EMACS_WM_BE_LOG_LEVEL")
    (setq emacs-wm-be-log-level
          (intern (downcase (getenv "EMACS_WM_BE_LOG_LEVEL")))))
  (when (getenv "EMACS_WM_BE_LOG_FILE")
    (setq emacs-wm-be-log-file (getenv "EMACS_WM_BE_LOG_FILE")))
  (setq gc-cons-threshold emacs-wm-be-gc-cons-threshold
        gc-cons-percentage emacs-wm-be-gc-cons-percentage)
  (setq emacs-wm-wl-log-function
        (lambda (fmt args) (apply #'emacs-wm-be-log 'debug fmt args)))
  (let* ((socket (emacs-wm-be--socket-path))
         (wayland (or (getenv "WAYLAND_DISPLAY")
                      (error "emacs-wm-be: WAYLAND_DISPLAY is not set")))
         (display (if (file-name-absolute-p wayland)
                      wayland
                    (concat (or (getenv "XDG_RUNTIME_DIR")
                                (error "emacs-wm-be: XDG_RUNTIME_DIR is not set"))
                            "/" wayland)))
         (epoch (logand (truncate (* 1000 (float-time))) #xffffffff))
         (state (emacs-wm-be--state-make
                 :bindings (make-hash-table :test 'eql)
                 :pointer-bindings (make-hash-table :test 'eql)
                 :outputs (make-hash-table :test 'eql)
                 :windows (make-hash-table :test 'eql)
                 :desktop 1
                 :pending-inject nil :pending-binds nil :pending-unbinds nil
                 :pending-window-ops nil :pending-eat-next nil
                 :gen 0 :manage-count 0 :next-fid 1 :epoch epoch
                 :pointer-x 0 :pointer-y 0 :layer-focus 'none)))
    (setq emacs-wm-be--state state)
    (emacs-wm-be-log 'info "--- backend starting: epoch %s socket %s" epoch socket)
    (when (file-exists-p socket)
      (ignore-errors (delete-file socket)))
    (setf (emacs-wm-be-state-server state)
          (make-network-process
           :name "emacs-wm-be-server"
           :server t
           :family 'local
           :service socket
           :coding 'utf-8-unix
           :noquery t
           :log #'emacs-wm-be--on-client
           :filter (lambda (_proc _chunk) nil)))
    (emacs-wm-be-log 'info "listening on %s" socket)
    (run-with-timer 1 1 (lambda () (emacs-wm-be--debug "heartbeat")))
    (setf (emacs-wm-be-state-conn state)
          (emacs-wm-wl-connect display #'emacs-wm-be--dispatch))
    (emacs-wm-be-log 'info "connected to Wayland display %s" display)
    ;; Bind the registry and ask for the globals.
    (let* ((conn (emacs-wm-be-state-conn state))
           (registry (emacs-wm-wl-new-id conn "wl_registry")))
      (emacs-wm-wl-request conn 1 "get_registry"
                           (list :registry (emacs-wm-wl-object-id registry))))
    (add-hook 'kill-emacs-hook
              (lambda () (ignore-errors (delete-file socket))))
    ;; Stay alive: process filters do the work.  Never busy-wait: with no live
    ;; process `accept-process-output' returns immediately, which would pin a
    ;; core for the life of the process (leftover backends were seen doing
    ;; exactly that).  A closed Wayland connection means the compositor is
    ;; gone, and so are we.
    (while (not (emacs-wm-be-state-quitting state))
      (if (accept-process-output nil 0.2)
          nil
        (let ((wayland (and (emacs-wm-be-state-conn state)
                            (emacs-wm-wl-connection-process
                             (emacs-wm-be-state-conn state)))))
          (if (process-live-p wayland)
              (sleep-for 0.05)
            (emacs-wm-be--quit "Wayland connection gone")))))))

(provide 'emacs-wm-be)
;;; emacs-wm-be.el ends here
