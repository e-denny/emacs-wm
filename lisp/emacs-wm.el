;;; emacs-wm.el --- Emacs as a river window manager  -*- lexical-binding: t; -*-

;; Minimal client for the wm-poc control socket. This is the experiment that
;; decides whether "Emacs is the window manager" feels right: river and the
;; daemon stay policy-free, everything in this file is the WM's brain.
;;
;; The daemon owns the Wayland connection and answers river's manage sequences
;; from the last layout pushed here. This file therefore never talks to river
;; directly and never blocks: it reacts to events, recomputes a layout snapshot
;; from Emacs' own window tree, and pushes it.
;;
;; See ../../PROTOCOL.md for the message set.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defgroup emacs-wm nil
  "Emacs as a window manager for river."
  :group 'environment
  :prefix "emacs-wm-")

(defcustom emacs-wm-log-file (or (getenv "EMACS_WM_LOG_FILE") "/tmp/emacs-wm-elisp.log")
  "File to append diagnostics to, or nil.
The session script points this at the state directory through
`EMACS_WM_LOG_FILE'; the /tmp default keeps tests and one-off runs
self-contained."
  :type '(choice (const nil) file))

(defcustom emacs-wm-commands nil
  "Named commands a key binding may refer to.
A list of (NAME FUNCTION DOCSTRING).  The name is what a binding in
`emacs-wm-key-bindings' and a `:simulate' rule use; FUNCTION is the
interactive command.  The shipped `emacs-wm-config.el' fills this in and
lists every command the window manager has."
  :type '(repeat (list string symbol string)))

(defcustom emacs-wm-key-bindings nil
  "Key bindings of the window manager.
A list of (KEY . COMMAND).  KEY is anything `kbd' accepts, e.g. \"s-f\";
COMMAND is a name from `emacs-wm-commands', a function symbol, or a
(FUNCTION . ARGS) form for a command that takes arguments.

Every key listed here is registered with the compositor, so a bound key is
also a key the WM receives -- there is no second list to keep in sync.  Only
single-key combinations can be registered (river matches modifier state plus
one keysym); anything longer is left to Emacs.

Bound keys are also put on `global-map', because a key press reaches Emacs as
an ordinary event after the compositor forwards it."
  :type '(alist :key-type string :value-type sexp))

(defcustom emacs-wm-intercepted-prefixes '("C-x" "C-c" "M-x")
  "Extra key sequences the compositor forwards to Emacs.
Keys bound in `emacs-wm-key-bindings' are registered automatically; this list
is for the prefixes that have no WM binding of their own but must still land
in Emacs rather than in the focused app (edit keys, `M-x', ...).
Single-key sequences only: river matches one keysym plus modifiers."
  :type '(repeat key-sequence))

(defcustom emacs-wm-config-file
  (expand-file-name "emacs-wm/config.el"
                    (or (getenv "XDG_CONFIG_HOME")
                        (expand-file-name "~/.config")))
  "File loaded by `emacs-wm-load-config' as the user configuration.
The shipped `emacs-wm-config.el' is the built-in default; this file, when it
exists, is loaded after it and overrides whatever it sets."
  :type 'file)

(defcustom emacs-wm-startup-commands nil
  "Shell commands started after the window manager is up.
Run by `emacs-wm-run-startup-commands', which the session entry point calls;
`emacs-wm-enable' does not, so embedding the WM in an existing session does
not start anything unexpected."
  :type '(repeat string))

(defcustom emacs-wm-popup-command nil
  "Command spawned by `emacs-wm-spawn-popup'.
Set in the configuration file; nil means the command refuses to run."
  :type '(choice (const nil) string))

(defcustom emacs-wm-window-rules nil
  "Window rules: alist of (MATCH . ACTIONS).
MATCH is a plist matched against a window's metadata, ACTIONS is a plist with
`:float', `:desktop', `:border-width', `:border-color', `:border-edges' and
`:simulate'. Matching is case-insensitive substring for `:app-id', `:title'
and `:class'.

`:simulate' translates a WM key into keys typed into *that app*:

  ((:app-id \"firefox\")
   (:simulate ((\"s-w\" . (\"C-w\")) (\"s-t\" . (\"C-t\")))))

meaning: while a Firefox window has focus, s-w stands for the key sequence
C-w, and s-t for C-t.  Keys are written the way `kbd' accepts them.  The
backend does the injection in a single manage sequence, so the sequence
lands in the focused app.  Only the first matching rule applies, so repeat
anything you need in the same rule."
  :type 'alist)

(defcustom emacs-wm-submaps nil
  "Chorded key maps: alist of (NAME . ((KEY . COMMAND) ...)).
KEY is anything `kbd' understands, e.g. f or C-w. Enter one with
`emacs-wm-enter-submap'; it consumes exactly one key. If that key hits a key
in the submap its COMMAND runs, otherwise river eats the press and the submap
is left (that is what `ensure_next_key_eaten' is for)."
  :type 'alist)

(defcustom emacs-wm-enable-hook nil
  "Hook run after `emacs-wm-enable'."
  :type 'hook)

(defcustom emacs-wm-border-width 2
  "Border width in pixels drawn by the compositor around app windows.
Zero or nil disables borders. Per-rule override: `:border-width'."
  :type 'integer)

(defcustom emacs-wm-border-color-focused "#7aa2f7"
  "Border colour of the focused app window.
Per-rule override: `:border-color'."
  :type 'string)

(defcustom emacs-wm-border-color-unfocused "#3b4261"
  "Border colour of every other app window."
  :type 'string)

(defcustom emacs-wm-border-edges 15
  "Which edges get a border, as a bitmask: top=1, bottom=2, left=4, right=8.
The default, 15, draws all four edges."
  :type 'integer)

;; ---------------------------------------------------------------- logging

(defun emacs-wm--log (fmt &rest args)
  (when emacs-wm-log-file
    (ignore-errors
      (append-to-file (apply #'format (concat fmt "\n") args)
                      nil emacs-wm-log-file))))

;; ---------------------------------------------------------------- state

(defvar emacs-wm--proc nil)
(defvar emacs-wm--rx-buffer "" "Unparsed bytes from the daemon.")
(defvar emacs-wm--queue nil "Events waiting to be handled.")
(defvar emacs-wm--busy nil "Reentrancy guard for the drain loop.")
(defvar emacs-wm--epoch nil)
(defvar emacs-wm--backend-process nil
  "Process object of the backend Emacs, when we started it ourselves.")
(defvar emacs-wm--pointer-bid-to-action (make-hash-table :test 'eql)
  "Pointer binding id -> action name (\"move\" or \"resize\").")
(defvar emacs-wm--gen 0)
(defvar emacs-wm--layout-dirty nil)
(defvar emacs-wm--layout-timer nil)

(defvar emacs-wm--fid-by-name (make-hash-table :test 'equal)
  "Frame name (as reported by the daemon) -> fid.")
(defvar emacs-wm--name-by-fid (make-hash-table)
  "fid -> frame name.")
(defvar emacs-wm--frame-name-by-wid (make-hash-table)
  "river window id -> desktop frame name, so clicks on a frame can focus it.")
(defvar emacs-wm--buffer-by-wid (make-hash-table)
  "daemon window id -> buffer.")
(defvar emacs-wm--meta-by-wid (make-hash-table :test 'equal)
  "daemon window id -> plist of metadata (title, app-id, size, ...).")
(defvar emacs-wm--buffer-by-identifier (make-hash-table :test 'equal)
  "river_window_v1 identifier -> buffer, so a restart reuses the buffer.")
(defvar emacs-wm-command-map nil
  "WM keys, looked up after the compositor forwards them to Emacs.
Built from `emacs-wm-key-bindings' by `emacs-wm-apply-bindings'; there are no
bindings in the code, so this and the configuration cannot disagree.")

(defvar emacs-wm--bid-to-key (make-hash-table :test 'eql)
  "binding id -> Emacs event sequence to replay.")
(defvar emacs-wm--key-to-bid (make-hash-table :test 'equal))
(defvar emacs-wm--outputs (make-hash-table :test 'eql)
  "river_output_v1 oid -> plist with :x :y :w :h and :usable.")
(defvar emacs-wm--desktop-by-oid (make-hash-table :test 'eql)
  "oid -> desktop number currently shown on that output.")
(defvar emacs-wm--rect-override (make-hash-table :test 'eql)
  "Window id -> (X Y W H) chosen by dragging/resizing, overriding the rule.")
(defvar emacs-wm--float-override (make-hash-table :test 'eql)
  "Window id -> t/nil chosen by `emacs-wm-toggle-float', overriding the rule.")

(defvar emacs-wm--raise-order nil
  "Window ids bottom->top, the stacking order the backend applies.
New windows are appended; clicking or raising moves one to the end.")

(defvar emacs-wm--pointer-oid nil
  "Output the pointer is over, as last reported by the daemon.")
(defcustom emacs-wm-resize-edges 10
  "Edges a keyboard- or pointer-started resize moves.
Bitmask: top 1, bottom 2, left 4, right 8.  The default 10 is the bottom-right
corner, which is what a drag from the corner means."
  :type 'integer)

(defcustom emacs-wm-pointer-bindings
  '((272 . "move")      ; BTN_LEFT with `emacs-wm-pointer-modifiers'
    (273 . "resize"))   ; BTN_RIGHT
  "Mouse buttons that move or resize the window under the pointer.
Button numbers are from linux/input-event-codes.h."
  :type '(alist :key-type integer :value-type string))

(defcustom emacs-wm-pointer-modifiers 64
  "Modifier bitmask held for `emacs-wm-pointer-bindings' (64 = Super)."
  :type 'integer)

(defcustom emacs-wm-desktops-per-output 4
  "How many desktops (Emacs frames) to create on each output.
Each desktop is a real Emacs frame, so this is also the number of hidden
frames per output; raising it costs redisplay work, not daemon work."
  :type 'integer)

(defvar emacs-wm--desktops-per-output emacs-wm-desktops-per-output
  "Effective desktop count per output, from `emacs-wm-desktops-per-output'.")

(defconst emacs-wm--max-desktop-key 9
  "Highest desktop number that gets a default key binding.")

;; ---------------------------------------------------------------- transport

(defun emacs-wm-socket-path ()
  (format "%s/emacs-wm.%s.sock"
          (or (getenv "XDG_RUNTIME_DIR") "/tmp")
          (or (getenv "WAYLAND_DISPLAY") "unknown")))

(defun emacs-wm--send (msg)
  "Send MSG (a plist with :t) to the backend.
Both sides are Emacs, so the wire format is one printed sexp per line: no
syntax to get wrong, no numbers to round, and `nil' means false everywhere."
  (when (process-live-p emacs-wm--proc)
    (let ((print-escape-newlines t)
          (print-escape-nonascii t)
          (print-length nil)
          (print-level nil)
          (print-circle nil))
      (condition-case err
          (process-send-string emacs-wm--proc (concat (prin1-to-string msg) "\n"))
        (error (emacs-wm--log "send failed: %S" err))))))

(defun emacs-wm--filter (_proc chunk)
  "Accumulate CHUNK, parse complete lines, defer handling."
  (setq emacs-wm--rx-buffer (concat emacs-wm--rx-buffer chunk))
  (let (line)
    (while (string-match "\n" emacs-wm--rx-buffer)
      (setq line (substring emacs-wm--rx-buffer 0 (match-beginning 0))
            emacs-wm--rx-buffer (substring emacs-wm--rx-buffer (match-end 0)))
      (unless (string-empty-p (string-trim line))
        (condition-case err
            (push (car (read-from-string line)) emacs-wm--queue)
          (error (emacs-wm--log "bad message: %S (%s)" err line))))))
  (run-at-time 0 nil #'emacs-wm--drain))

(defcustom emacs-wm-allow-when-locked nil
  "Keys that still work while the session is locked.
Names as in `emacs-wm-intercepted-prefixes' (\"s-2\", \"XF86AudioMute\", ...).
Everything else is ignored while an ext-session-lock lock is held: the lock
surface belongs to the lock client, not to this window manager."
  :type '(repeat string))

(defvar emacs-wm--locked nil
  "Non-nil while the session is locked.")

(defcustom emacs-wm-ping-interval 5.0
  "Seconds between liveness probes to the backend.
The backend answers every `ping' from state it already holds, so a missing
answer means the backend is wedged -- not busy -- and the frontend stops
treating it as trustworthy."
  :type 'number)

(defcustom emacs-wm-ping-timeout 3.0
  "Seconds to wait for a `pong' before declaring the backend wedged."
  :type 'number)

(defcustom emacs-wm-max-respawns 5
  "How many backend restarts in a row to attempt before giving up.
Restarts are only counted while no `pong' has been received, so an orderly
sequence of restarts over a long session does not use up the budget."
  :type 'integer)

(defvar emacs-wm--pings nil
  "Outstanding liveness probes: alist of (SEQUENCE . SENT-AT).")
(defvar emacs-wm--ping-seq 0
  "Sequence number of the last `ping' sent.")
(defvar emacs-wm--pong-seen 0
  "How many `pong's have arrived since the last resync.")
(defvar emacs-wm--respawn-count 0
  "Backend restarts since the last `pong'.")
(defvar emacs-wm--ping-timer nil
  "Timer running `emacs-wm--ping'.")

(defun emacs-wm--ping ()
  "Send a liveness probe, and restart the backend if it stopped answering."
  (when (process-live-p emacs-wm--proc)
    (let* ((now (float-time))
           (deadline (and emacs-wm--pings
                          (cdr (car (last emacs-wm--pings)))))
           (stale (and deadline (> (- now deadline) emacs-wm-ping-timeout))))
      (cond
       (stale
        (emacs-wm--log "WEDGED: no pong for %.1fs (%d outstanding); restarting backend"
                       (- now deadline) (length emacs-wm--pings))
        (emacs-wm--restart-wedged-backend))
       (t
        (setq emacs-wm--ping-seq (1+ emacs-wm--ping-seq))
        (push (cons emacs-wm--ping-seq now) emacs-wm--pings)
        ;; Keep the list bounded even if pongs are lost but the process lives.
        (when (> (length emacs-wm--pings) 32)
          (setq emacs-wm--pings (last emacs-wm--pings 32)))
        (emacs-wm--send (list :t "ping" :n emacs-wm--ping-seq)))))))

(defun emacs-wm--restart-wedged-backend ()
  "Kill a backend that stopped answering and start a fresh one."
  (if (>= emacs-wm--respawn-count emacs-wm-max-respawns)
      (progn
        (emacs-wm--log "ERROR: backend wedged %d times in a row; giving up. Emacs is no longer the window manager."
                       emacs-wm--respawn-count)
        ;; Stop probing: there is nothing left to recover, and a message every
        ;; few seconds forever is worse than silence.
        (emacs-wm--stop-ping-timer)
        (message "emacs-wm: window manager backend is dead (restarted %d times); giving up"
                 emacs-wm--respawn-count))
    (setq emacs-wm--respawn-count (1+ emacs-wm--respawn-count))
    (emacs-wm--log "restarting backend (attempt %d of %d)"
                   emacs-wm--respawn-count emacs-wm-max-respawns)
    (unless (process-live-p emacs-wm--backend-process)
      (emacs-wm--log "WARN: we did not start this backend, so it cannot be killed from here"))
    ;; Kill the process, not just the socket: it is alive enough to accept a
    ;; new connection, which would land us back in the same wedged process.
    (emacs-wm-stop-backend)
    (when (process-live-p emacs-wm--proc)
      (delete-process emacs-wm--proc))))

(defcustom emacs-wm-auto-reconnect t
  "Reconnect to the daemon when the connection drops.
The daemon can be restarted without losing anything: app buffers stay,
and each window is re-attached by its `identifier'."
  :type 'boolean)

(defun emacs-wm--sentinel (proc event)
  (emacs-wm--log "process %s: %s" (process-name proc) (string-trim event))
  (when (memq (process-status proc) '(closed failed exit))
    (setq emacs-wm--proc nil)
    (message "emacs-wm: disconnected from the WM daemon")
    (when emacs-wm-auto-reconnect
      (run-at-time 1.5 nil #'emacs-wm--reconnect))))

(defun emacs-wm--reconnect ()
  "Re-establish the socket and let `hello' resynchronise state.
If the backend process died, start a new one: river re-sends every window to
a rebinding WM client and each is reattached by its `identifier'."
  (unless (process-live-p emacs-wm--proc)
    (if (not (file-exists-p (emacs-wm--wayland-socket)))
        (emacs-wm--log "compositor socket is gone, not reconnecting")
      (emacs-wm--log "reconnecting to %s" (emacs-wm-socket-path))
      (condition-case err
          (emacs-wm-connect)
        (error
         (emacs-wm--log "reconnect failed: %S, retrying" err)
         (run-at-time 2 nil #'emacs-wm--reconnect))))))

(defun emacs-wm--resync ()
  "Forget everything tied to the old daemon generation.
Buffers survive: they are the user's state. Windows come back with new ids
and are matched again by `identifier'."
  (emacs-wm--log "--- resync: keeping %d buffers, dropping window ids ---"
                 (hash-table-count emacs-wm--buffer-by-wid))
  (maphash (lambda (wid buf)
             (let ((ident (plist-get (gethash wid emacs-wm--meta-by-wid) :identifier)))
               (when (and ident (buffer-live-p buf))
                 (puthash ident buf emacs-wm--buffer-by-identifier))))
           emacs-wm--buffer-by-wid)
  (clrhash emacs-wm--buffer-by-wid)
  (clrhash emacs-wm--meta-by-wid)
  (clrhash emacs-wm--fid-by-name)
  (clrhash emacs-wm--name-by-fid)
  (clrhash emacs-wm--frame-name-by-wid)
  (clrhash emacs-wm--bid-to-key)
  (clrhash emacs-wm--key-to-bid)
  (setq emacs-wm--submap nil)
  (setq emacs-wm--gen 0)
  (setq emacs-wm--pings nil)
  (emacs-wm--schedule-layout))

(defun emacs-wm--drain ()
  "Handle queued events, then push a layout if anything changed."
  (when (and (not emacs-wm--busy) emacs-wm--queue)
    (setq emacs-wm--busy t)
    (unwind-protect
        (while emacs-wm--queue
          (let ((msg (pop emacs-wm--queue)))
            (condition-case err
                (emacs-wm--handle msg)
              (error (emacs-wm--log "handler error on %S: %S" (plist-get msg :t) err)))))
      (setq emacs-wm--busy nil))
    (when emacs-wm--layout-dirty
      (emacs-wm--push-layout))))

;; ---------------------------------------------------------------- events

(defun emacs-wm--handle (msg)
  (pcase (plist-get msg :t)
    ("hello"
     (let ((epoch (plist-get msg :epoch))
           (old emacs-wm--epoch))
       (setq emacs-wm--epoch epoch)
       (emacs-wm--log "hello epoch %s (was %s) caps %S" epoch old (plist-get msg :caps))
       (when (and old (not (equal old epoch)))
         (emacs-wm--resync))
       (emacs-wm--send (list :t "hello-ack" :v 0 :epoch emacs-wm--epoch))
       (emacs-wm--register-bindings)
       (emacs-wm--register-pointer-bindings)))
    ("output"
     (let ((oid (plist-get msg :oid)))
       (puthash oid msg emacs-wm--outputs)
       (emacs-wm--log "output %s: %sx%s at %s,%s usable %S" oid
                      (plist-get msg :w) (plist-get msg :h)
                      (plist-get msg :x) (plist-get msg :y)
                      (plist-get msg :usable))
       (emacs-wm--ensure-output-frames oid)
       (emacs-wm--schedule-layout)))
    ("output-removed"
     (let ((oid (plist-get msg :oid)))
       (remhash oid emacs-wm--outputs)
       (remhash oid emacs-wm--desktop-by-oid)
       (when (eql emacs-wm--pointer-oid oid)
         (setq emacs-wm--pointer-oid nil))
       (emacs-wm--log "output %s removed, deleting its desktop frames" oid)
       (dolist (f (emacs-wm--desktop-frames oid))
         (when (> (length (frame-list)) 1)
           (delete-frame f)))
       (emacs-wm--schedule-layout)))
    ("pointer"
     (let ((oid (plist-get msg :oid)))
       (unless (eql oid emacs-wm--pointer-oid)
         (setq emacs-wm--pointer-oid oid)
         (emacs-wm--log "pointer on output %s" oid)
         (emacs-wm--schedule-layout))))
    ("frame"
     (let ((fid (plist-get msg :fid))
           (name (plist-get msg :name)))
       (puthash name fid emacs-wm--fid-by-name)
       (puthash fid name emacs-wm--name-by-fid)
       (when-let ((wid (plist-get msg :wid)))
         (puthash wid name emacs-wm--frame-name-by-wid))
       (emacs-wm--log "frame fid=%s name=%S" fid name)
       (emacs-wm--schedule-layout)))
    ("frame-gone"
     (let ((name (gethash (plist-get msg :fid) emacs-wm--name-by-fid)))
       (when name (remhash name emacs-wm--fid-by-name))
       (remhash (plist-get msg :fid) emacs-wm--name-by-fid)
       (emacs-wm--log "frame gone fid=%s" (plist-get msg :fid))))
    ("window"
     (let* ((wid (plist-get msg :wid))
            (meta (plist-put (gethash wid emacs-wm--meta-by-wid)
                             :output (plist-get msg :output))))
       (puthash wid meta emacs-wm--meta-by-wid)
       (emacs-wm--create-buffer wid)))
    ("gone"
     (setq emacs-wm--raise-order (delq (plist-get msg :wid) emacs-wm--raise-order))
     (remhash (plist-get msg :wid) emacs-wm--rect-override)
     (remhash (plist-get msg :wid) emacs-wm--float-override)
     (let ((buf (gethash (plist-get msg :wid) emacs-wm--buffer-by-wid)))
       (emacs-wm--log "window %s gone" (plist-get msg :wid))
       (when buf (kill-buffer buf))
       (remhash (plist-get msg :wid) emacs-wm--buffer-by-wid)
       (remhash (plist-get msg :wid) emacs-wm--meta-by-wid)
       (emacs-wm--schedule-layout)))
    ("title" (emacs-wm--update-meta msg :title))
    ("app-id" (emacs-wm--update-meta msg :app-id))
    ("size" (emacs-wm--update-meta msg :size))
    ("identifier" (emacs-wm--update-meta msg :identifier))
    ("parent" (emacs-wm--update-meta msg :parent))
    ("key" (emacs-wm--handle-key msg))
    ("key-unbound" (emacs-wm--handle-key-unbound))
    ("pong"
     (setq emacs-wm--pings (assoc-delete-all (plist-get msg :n) emacs-wm--pings)
           emacs-wm--pong-seen (1+ emacs-wm--pong-seen)
           emacs-wm--respawn-count 0))
    ("op-done"
     (let ((wid (plist-get msg :wid)))
       (puthash wid (list (plist-get msg :x) (plist-get msg :y)
                          (plist-get msg :w) (plist-get msg :h))
                emacs-wm--rect-override)
       ;; A window the user dragged is theirs to place from now on.
       (puthash wid t emacs-wm--float-override)
       (emacs-wm--log "op-done: wid %s now at %S"
                      wid (gethash wid emacs-wm--rect-override))
       (emacs-wm--schedule-layout)))
    ("decor"
     (let* ((wid (plist-get msg :wid))
            (meta (gethash wid emacs-wm--meta-by-wid)))
       (puthash wid (plist-put meta :decor (plist-get msg :hint))
                emacs-wm--meta-by-wid)
       (emacs-wm--log "window %s wants %s decorations" wid (plist-get msg :hint))))
    ("pointer-bind"
     (let ((wid (plist-get msg :wid))
           (bid (plist-get msg :bid)))
       ;; Buttons act on the window under the pointer, not on the focused one.
       (when wid
         (emacs-wm--focus-app-wid wid))
       (let ((action (gethash bid emacs-wm--pointer-bid-to-action)))
         (emacs-wm--log "pointer binding %s -> %S on wid %S" bid action wid)
         (when (equal action "move") (emacs-wm--start-op "move"))
         (when (equal action "resize")
           (emacs-wm--start-op "resize" emacs-wm-resize-edges)))))
    ("pointer-enter"
     (let ((wid (plist-get msg :wid)))
       ;; Clicking a window raises it, the way every other WM behaves.
       (when (and wid (gethash wid emacs-wm--buffer-by-wid))
         (emacs-wm--raise wid))
       (emacs-wm--focus-wid wid)))
    ("locked"
     (setq emacs-wm--locked (and (plist-get msg :on) t))
     (emacs-wm--log "session %s" (if emacs-wm--locked "locked" "unlocked"))
     (when emacs-wm--locked
       ;; Do not keep pointing the selected frame at a window the user can no
       ;; longer see or interact with.
       (emacs-wm-exit-submap t)))
    ("pointer-leave" nil)
    ("layer-focus" nil)
    ("modifiers" nil)
    ("request"
     (emacs-wm--log "window %s requested %s" (plist-get msg :wid) (plist-get msg :kind)))
    ("bye" (emacs-wm--log "daemon said bye: %S" (plist-get msg :reason)))
    (_ (emacs-wm--log "unhandled event %S" msg))))

(defun emacs-wm--update-meta (msg key)
  (let* ((wid (plist-get msg :wid))
         (meta (gethash wid emacs-wm--meta-by-wid))
         (value (pcase key
                  (:title (plist-get msg :title))
                  (:app-id (plist-get msg :app_id))
                  (:identifier (plist-get msg :identifier))
                  (:parent (plist-get msg :has_parent))
                  (:size (list (plist-get msg :w) (plist-get msg :h))))))
    (setq meta (plist-put meta key value))
    (puthash wid meta emacs-wm--meta-by-wid)
    (when (memq key '(:title :app-id))
      (let ((buf (gethash wid emacs-wm--buffer-by-wid)))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (rename-buffer (emacs-wm--buffer-name meta) t)))))
    (when (eq key :identifier)
      (let* ((wid (plist-get msg :wid))
             (ident (plist-get msg :identifier))
             (orphan (and ident (gethash ident emacs-wm--buffer-by-identifier)))
             (fresh (gethash wid emacs-wm--buffer-by-wid)))
        (cond
         ;; a restart: the app window is the same, reuse its old buffer
         ((and orphan (buffer-live-p orphan) (not (eq orphan fresh)))
          (when (buffer-live-p fresh) (kill-buffer fresh))
          (puthash wid orphan emacs-wm--buffer-by-wid)
          (with-current-buffer orphan (setq emacs-wm-wid wid))
          (emacs-wm--log "re-attached %S to wid %s via identifier %S"
                         (buffer-name orphan) wid ident))
         ;; remember this identity for the next restart
         ((and ident (buffer-live-p fresh))
          (puthash ident fresh emacs-wm--buffer-by-identifier)))))
    (when (and (eq key :title)
               (string-prefix-p "wm-frame:" (or (plist-get msg :title) "")))
      ;; a frame reported as a plain window first: never mirror it
      (when-let ((buf (gethash wid emacs-wm--buffer-by-wid)))
        (remhash wid emacs-wm--buffer-by-wid)
        (when (buffer-live-p buf) (kill-buffer buf)))
      (emacs-wm--log "window %s is one of our frames, not mirroring it" wid))
    ;; a rule may match only once the title/app-id is known
    (when (memq key '(:title :app-id))
      (emacs-wm--schedule-layout))))

;; ---------------------------------------------------------------- buffers

(defvar-local emacs-wm-wid nil
  "Daemon window id for this buffer, if it mirrors an app window.")

(defun emacs-wm--buffer-name (meta)
  (let ((title (or (plist-get meta :title) "untitled"))
        (app (plist-get meta :app-id)))
    (if (and app (not (string-empty-p app)))
        (format "%s [%s]" title app)
      title)))

(define-derived-mode emacs-wm-mode special-mode "WM"
  "Major mode for buffers mirroring a Wayland app window."
  :group 'emacs-wm
  (setq-local buffer-read-only t)
  (setq-local cursor-type nil))

(defun emacs-wm--create-buffer (wid)
  (unless (or (gethash wid emacs-wm--buffer-by-wid)
              ;; our own frames are containers, not clients to be mirrored
              (gethash wid emacs-wm--frame-name-by-wid)
              (string-prefix-p
               "wm-frame:"
               (or (plist-get (gethash wid emacs-wm--meta-by-wid) :title) "")))
    (let* ((meta (gethash wid emacs-wm--meta-by-wid))
           (buf (generate-new-buffer (emacs-wm--buffer-name meta))))
      (with-current-buffer buf
        (emacs-wm-mode)
        (setq emacs-wm-wid wid))
      (puthash wid buf emacs-wm--buffer-by-wid)
      (emacs-wm--log "buffer %S for window %s" (buffer-name buf) wid)
      (unless (get-buffer-window buf)
        ;; Mirror it on the output the window opened on, not wherever the
        ;; selected frame happens to be.
        (let ((frame (emacs-wm--desktop-frame
                      (or (plist-get meta :output) (emacs-wm--current-oid)))))
          (when frame (select-frame-set-input-focus frame))
          (pop-to-buffer buf)))
      (emacs-wm--schedule-layout))))

;; ---------------------------------------------------------------- key handling

(defun emacs-wm--key->binding (keys)
  "Turn KEYS (a key sequence like \"C-x\") into (EVENT . MODS) for the daemon.
Returns nil when the key cannot be expressed as modifier + key."
  (let* ((seq (kbd keys))
         (ev (aref seq 0))
         (basic (or (event-basic-type ev)
                    ;; Emacs returns nil for e.g. `s-f11`; strip the modifier
                    ;; prefixes off the symbol instead.
                    (and (symbolp ev)
                         (intern (replace-regexp-in-string
                                  "\\`\\(?:[sSCHAM]-\\)+" ""
                                  (symbol-name ev))))))
         (mods (event-modifiers ev))
         (bits 0))
    (when (seq-empty-p (seq-drop seq 1))
      (dolist (m mods)
        (setq bits (logior bits (pcase m
                                  ('shift 1)
                                  ('control 4)
                                  ('meta 8)
                                  ('super 64)
                                  ('hyper 128)
                                  (_ 0)))))
      (cons (if (characterp basic) basic (symbol-name basic)) bits))))

(defun emacs-wm--register-pointer-bindings ()
  "Register `emacs-wm-pointer-bindings' with the backend."
  (let ((bid 500))
    (dolist (entry emacs-wm-pointer-bindings)
      (setq bid (1+ bid))
      (puthash bid (cdr entry) emacs-wm--pointer-bid-to-action)
      (emacs-wm--send (list :t "bind-pointer" :bid bid
                            :button (car entry)
                            :mods emacs-wm-pointer-modifiers))
      (emacs-wm--log "registered pointer binding %s: button %s -> %s"
                     bid (car entry) (cdr entry)))))

(defun emacs-wm--binding-key-names ()
  "Key names bound in `emacs-wm-key-bindings', in config order."
  (delete-dups (mapcar #'car emacs-wm-key-bindings)))

(defun emacs-wm--named-command (name)
  "Command FUNCTION for NAME from `emacs-wm-commands', or nil."
  (nth 1 (assoc name emacs-wm-commands)))

(defun emacs-wm--binding-command (spec)
  "Turn a binding's SPEC into an interactive command.
SPEC is a name from `emacs-wm-commands', a function symbol, or
(FUNCTION . ARGS).  Unknown names are an error, not a silent no-op: a config
typo should say so at load time rather than swallow the key."
  (cond
   ((stringp spec)
    (or (emacs-wm--named-command spec)
        (error "emacs-wm: no command %S in `emacs-wm-commands'" spec)))
   ((and (consp spec) (symbolp (car spec)))
    (let ((fn (car spec))
          (args (cdr spec)))
      (lambda () (interactive) (apply fn args))))
   ((functionp spec) spec)
   ((symbolp spec)
    (or (fboundp spec)
        (error "emacs-wm: %S is not a function" spec))
    spec)
   (t (error "emacs-wm: cannot use %S as a key binding" spec))))

(defun emacs-wm-apply-bindings ()
  "Rebuild `emacs-wm-command-map' from `emacs-wm-key-bindings'.
Run by `emacs-wm-enable', and by hand after editing the configuration in a
running session.  The map is rebuilt from scratch, so removing a binding from
the configuration really removes it."
  (let ((map (make-sparse-keymap)))
    (dolist (binding emacs-wm-key-bindings)
      (let ((key (car binding)))
        (unless (stringp key)
          (error "emacs-wm: key %S is not a string" key))
        (define-key map (kbd key) (emacs-wm--binding-command (cdr binding)))))
    (setq emacs-wm-command-map map))
  emacs-wm-command-map)

(defun emacs-wm--define-global-bindings ()
  "Put the interceptable bindings on `global-map'.
The compositor forwards a bound key as an ordinary event, so Emacs has to
find it in a normal keymap.  Keys river cannot match (multi-key sequences)
are skipped: binding them globally would only shadow Emacs' own keys."
  (dolist (binding emacs-wm-key-bindings)
    (let* ((name (car binding))
           (key (kbd name)))
      (when (emacs-wm--key->binding name)
        (define-key global-map key (lookup-key emacs-wm-command-map key))))))

(defun emacs-wm--register-bindings ()
  "Register every key the compositor should forward, with the daemon.
That is: the keys bound in `emacs-wm-key-bindings', the extra prefixes in
`emacs-wm-intercepted-prefixes', and the keys only a `:simulate' rule uses."
  (cl-loop for keys in (delete-dups
                        (append (emacs-wm--binding-key-names)
                                emacs-wm-intercepted-prefixes
                                ;; keys only used by per-app `:simulate' rules
                                (emacs-wm--simulate-key-names)))
           for bid from 1
           when (emacs-wm--key->binding keys)
           do (emacs-wm--register-key keys bid)))

(defvar emacs-wm--bid-to-name (make-hash-table :test 'eql)
  "binding id -> key name as written in the config, e.g. s-w.")
(defvar emacs-wm--submap nil
  "Name of the active one-shot submap, or nil.")
(defvar emacs-wm--submap-keys (make-hash-table :test 'equal)
  "Key name -> command for the active submap.")
(defvar emacs-wm--submap-bids nil
  "Binding ids registered for the active submap, unbound on exit.")
(defvar emacs-wm--submap-bid-counter 1000
  "Binding ids for submap keys, well clear of the static ones.")

(defun emacs-wm--register-key (keys bid)
  "Register KEYS (a key sequence string) with the daemon as BID."
  (let ((binding (emacs-wm--key->binding keys)))
    (when binding
      (puthash bid (aref (kbd keys) 0) emacs-wm--bid-to-key)
      (puthash keys bid emacs-wm--key-to-bid)
      (puthash bid keys emacs-wm--bid-to-name)
      (emacs-wm--send (list :t "bind"
                            :bid bid
                            :name keys
                            :key (car binding)
                            :mods (cdr binding)))
      (emacs-wm--log "registered %S as bid %d" keys bid)
      bid)))

(defun emacs-wm-enter-submap (name)
  "Enter the one-shot submap NAME from `emacs-wm-submaps'.
Its keys are bound only while it is active, so they do not swallow typing
the rest of the time."
  (interactive
   (list (completing-read "Submap: " (mapcar #'car emacs-wm-submaps))))
  (let ((entry (assoc name emacs-wm-submaps)))
    (unless entry (user-error "No submap %S" name))
    (when emacs-wm--submap (emacs-wm-exit-submap t))
    (setq emacs-wm--submap name
          emacs-wm--submap-bids nil)
    (clrhash emacs-wm--submap-keys)
    (dolist (kv (cdr entry))
      (puthash (car kv) (cdr kv) emacs-wm--submap-keys))
    (maphash (lambda (key cmd)
               (setq emacs-wm--submap-bid-counter
                     (1+ emacs-wm--submap-bid-counter))
               (push (cons emacs-wm--submap-bid-counter
                           (emacs-wm--register-key key emacs-wm--submap-bid-counter))
                     emacs-wm--submap-bids)
               cmd)
             emacs-wm--submap-keys)
    ;; river eats the next key press: an unbound one comes back as
    ;; `key-unbound' instead of reaching the app.
    (emacs-wm--send (list :t "eat-next" :on t))
    (emacs-wm--schedule-layout)
    (emacs-wm--log "entered submap %S (%d keys)" name (hash-table-count emacs-wm--submap-keys))))

(defun emacs-wm-exit-submap (&optional cancel)
  "Leave the active submap and unbind its keys."
  (when emacs-wm--submap
    (emacs-wm--log "left submap %S" emacs-wm--submap)
    (dolist (pair emacs-wm--submap-bids)
      (when (cdr pair)
        (emacs-wm--send (list :t "unbind" :bid (car pair)))))
    (clrhash emacs-wm--submap-keys)
    (setq emacs-wm--submap nil
          emacs-wm--submap-bids nil)
    (if cancel
        (emacs-wm--send (list :t "eat-next" :on nil))
      ;; the press itself consumed the eat-next request
      nil)))

(defun emacs-wm--simulate-for (wid name)
  "Key sequence that NAMEd key should stand for in WID's app, or nil."
  (when (and wid name)
    (cdr (assoc name (plist-get (emacs-wm--rule-actions wid) :simulate)))))

(defun emacs-wm--simulate-keys (keys)
  "Type KEYS into the focused app.
Each element is a key description as `kbd' accepts it, e.g. C-x or M-w."
  (let (msgs)
    (dolist (k keys)
      (let ((binding (emacs-wm--key->binding k)))
        (cond
         ;; `emacs-wm--key->binding' yields a character for printable keys;
         ;; the daemon wants a keysym *name*, so "a" not ?a.
         (binding (push (list :name (if (characterp (car binding))
                                        (string (car binding))
                                      (car binding))
                              :mods (cdr binding))
                        msgs))
         ;; Not expressible as an Emacs key event (Return, Tab, space, ...):
         ;; pass it as an xkb keysym name, which is what the daemon resolves.
         (t (push (list :name k :mods 0) msgs)))))
    (when msgs
      (let ((seq (vconcat (nreverse msgs))))
        (emacs-wm--send (list :t "inject" :keys seq))
        (emacs-wm--log "simulate %S as %S" keys seq)))))

(defun emacs-wm--intercepted-for-app-p (name)
  "Non-nil when NAME is forwarded only so a `:simulate' rule can translate it.
Such a key is an *Emacs* binding (C-v, C-a, ...) that an app also uses, so
when no rule matches the focused window it has to reach that app unchanged
instead of being swallowed."
  (and (member name (emacs-wm--simulate-key-names))
       ;; A key the user explicitly wants in Emacs keeps going to Emacs.
       (not (member name emacs-wm-intercepted-prefixes))))

(defun emacs-wm--handle-key (msg)
  "Handle one key press forwarded by the daemon.

Order of precedence:

 1. a `:simulate' rule for the focused window (translate and inject);
 2. a WM binding (`emacs-wm-key-bindings': run its command);
 3. a key that some rule translates but this window has no rule for
    (`emacs-wm--intercepted-for-app-p': give the app its own key back);
 4. everything else (`C-x', `M-x', ...) reaches Emacs as an event.

Step 3 is what makes Emacs keys usable as simulation keys: C-v means page
down in Firefox and stays C-v in a terminal."
  (cl-block emacs-wm--handle-key
    (let* ((bid (plist-get msg :bid))
           (name (gethash bid emacs-wm--bid-to-name))
           (event (gethash bid emacs-wm--bid-to-key))
           (command (and name
                         emacs-wm-command-map
                         (commandp (lookup-key emacs-wm-command-map (kbd name))))))
      (when (and emacs-wm--locked
                 (not (member name emacs-wm-allow-when-locked)))
        (emacs-wm--log "key %S ignored: session locked" name)
        (cl-return-from emacs-wm--handle-key nil))
      (when (equal (plist-get msg :state) "press")
        (when emacs-wm--submap
          (let ((cmd (gethash name emacs-wm--submap-keys)))
            (emacs-wm-exit-submap)
            (if cmd
                (progn
                  (emacs-wm--log "submap key %S -> %S" name cmd)
                  (call-interactively cmd))
              (emacs-wm--log "submap: %S is not in it, running its normal binding" name))))
        (let ((sim (emacs-wm--simulate-for (emacs-wm--focused-wid) name)))
          (cond
           (sim
            (emacs-wm--simulate-keys sim))
           (command
            (when event
              (push (cons t event) unread-command-events)
              (emacs-wm--log "key bid %d -> event %S" bid event)))
           ((emacs-wm--intercepted-for-app-p name)
            (emacs-wm--log "no %S rule for this window: passing the key through" name)
            (emacs-wm--simulate-keys (list name)))
           (event
            (push (cons t event) unread-command-events)
            (emacs-wm--log "key bid %d -> event %S" bid event))))))))

(defun emacs-wm--handle-key-unbound ()
  "River ate a key press that hit no binding: leave the submap."
  (emacs-wm--log "unbound key eaten%s"
                 (if emacs-wm--submap
                     (format " (leaving submap %S)" emacs-wm--submap)
                   ""))
  (emacs-wm-exit-submap))

;; ---------------------------------------------------------------- frames

(defun emacs-wm--frame-name (frame)
  (frame-parameter frame 'name))

(defun emacs-wm--frame-oid-and-desktop (frame)
  "Return (OID . DESKTOP) for FRAME if it is a desktop frame."
  (when-let ((name (emacs-wm--frame-name frame)))
    (when (string-match
           "\\`wm-frame:\\([0-9]+\\):\\([0-9]+\\)\\'" name)
      (cons (string-to-number (match-string 1 name))
            (string-to-number (match-string 2 name))))))

(defun emacs-wm--desktop-name (oid n)
  "Frame name of desktop N on output OID.
The daemon parses this as `wm-frame:<oid>:<desktop>`, which is how a frame
carries the output it belongs to."
  (format "wm-frame:%s:%s" oid n))

(defun emacs-wm--desktop-frames (&optional oid)
  "All desktop frames, or only those belonging to output OID."
  (let ((prefix (and oid (format "wm-frame:%s:" oid))))
    (seq-filter (lambda (f)
                  (let ((name (or (emacs-wm--frame-name f) "")))
                    (and (string-prefix-p "wm-frame:" name)
                         (or (null prefix) (string-prefix-p prefix name)))))
                (frame-list))))

(defun emacs-wm--output-oids ()
  "Known output ids, in a stable order."
  (sort (hash-table-keys emacs-wm--outputs) #'<))

(defun emacs-wm--current-oid ()
  "Output the pointer is over, else the first output the daemon reported."
  (or emacs-wm--pointer-oid (car (emacs-wm--output-oids))))

(defun emacs-wm--desktop (oid)
  "Desktop number currently shown on output OID."
  (or (and oid (gethash oid emacs-wm--desktop-by-oid)) 1))

(defun emacs-wm--desktop-frame (oid &optional n)
  "The Emacs frame showing desktop N (default: the current one) on OID."
  (let ((name (emacs-wm--desktop-name oid (or n (emacs-wm--desktop oid)))))
    (seq-find (lambda (f) (equal (emacs-wm--frame-name f) name))
              (emacs-wm--desktop-frames oid))))

(defun emacs-wm--adopt-frame (name)
  "Rename an existing non-desktop frame to NAME and return it, else nil.
Any frame that is not already a desktop frame is a liability: it reaches us
as an ordinary \"app\" window, gets mirrored into one of our own desktop
frames, and the mirror's title feeds back into the frame title until the
frame has resized itself to nothing. So every frame Emacs already has is
turned into a desktop before any new frame is created."
  (let ((cands (seq-filter (lambda (f) (null (emacs-wm--frame-oid-and-desktop f)))
                           (frame-list))))
    (let ((frame (or (and (memq (selected-frame) cands) (selected-frame))
                     (car cands))))
      (when frame
        (set-frame-name name)
        (emacs-wm--log "adopted existing frame as %S" name)
        frame))))

(defun emacs-wm--ensure-output-frames (oid)
  "Ensure one frame exists per desktop on output OID."
  (dotimes (i emacs-wm--desktops-per-output)
    (let* ((name (emacs-wm--desktop-name oid (1+ i)))
           (frame (or (seq-find (lambda (f) (equal (emacs-wm--frame-name f) name))
                                (frame-list))
                      (emacs-wm--adopt-frame name))))
      (unless frame
        (make-frame `((name . ,name) (undecorated . t)))
        (emacs-wm--log "created desktop frame %S (output %s)" name oid))))
  (unless (gethash oid emacs-wm--desktop-by-oid)
    (puthash oid 1 emacs-wm--desktop-by-oid))
  (emacs-wm--log "desktop frames: %S" (mapcar #'emacs-wm--frame-name (frame-list))))

;; ---------------------------------------------------------------- layout

(defun emacs-wm--hex-to-32 (color)
  "Convert a #rrggbb COLOR to a list of three 32-bit components.
River takes RGBA as 0..0xffffffff, i.e. 100% = #xffffffff, so each 8-bit
component is scaled by #x01010101."
  (when (and (stringp color)
             (string-match
              "\\`#\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\([0-9a-fA-F]\\{2\\}\\)\\'"
              color))
    (list (* (string-to-number (match-string 1 color) 16) #x01010101)
          (* (string-to-number (match-string 2 color) 16) #x01010101)
          (* (string-to-number (match-string 3 color) 16) #x01010101))))

(defun emacs-wm--border-for (focused actions)
  "Border plist for a window with ACTIONS, or nil for no border.
Width, edges and colours come from the rule's `:border-width',
`:border-edges' and `:border-color' when present, else from the
`emacs-wm-border-*' options. The compositor draws the border itself, so
nothing here affects the window's geometry."
  (let* ((width (or (plist-get actions :border-width)
                    emacs-wm-border-width))
         (edges (or (plist-get actions :border-edges)
                    emacs-wm-border-edges))
         (color (or (plist-get actions :border-color)
                    (if focused
                        emacs-wm-border-color-focused
                      emacs-wm-border-color-unfocused)))
         (rgb (emacs-wm--hex-to-32 color)))
    (when (and (integerp width) (> width 0) rgb)
      (list :w width :edges (or edges 15)
            :r (nth 0 rgb) :g (nth 1 rgb) :b (nth 2 rgb)
            :a #xffffffff))))

(defun emacs-wm--schedule-layout ()
  (setq emacs-wm--layout-dirty t)
  (unless emacs-wm--layout-timer
    (setq emacs-wm--layout-timer
          (run-at-time 0.01 nil #'emacs-wm--flush-layout))))

(defun emacs-wm--flush-layout ()
  (setq emacs-wm--layout-timer nil)
  (when emacs-wm--layout-dirty
    (emacs-wm--push-layout)))

(defun emacs-wm--match-matches-p (match wid)
  "Non-nil when MATCH (a plist) applies to WID's window metadata."
  (let* ((meta (gethash wid emacs-wm--meta-by-wid))
         (app (downcase (or (plist-get meta :app-id) "")))
         (title (downcase (or (plist-get meta :title) ""))))
    (cl-every
     (lambda (pair)
       (pcase (car pair)
         (:app-id (and (stringp (cdr pair))
                       (string-match-p (regexp-quote (downcase (cdr pair))) app)))
         (:title (and (stringp (cdr pair))
                      (string-match-p (regexp-quote (downcase (cdr pair))) title)))
         (_ nil)))
     (cl-loop for (k v) on match by #'cddr collect (cons k v)))))

(defun emacs-wm--rule-actions (wid)
  "Return the action plist for WID's window according to `emacs-wm-window-rules'.
Each rule is (MATCH . ACTIONS) where MATCH is a plist such as (:app-id \"firefox\")
and ACTIONS a plist such as (:float t)."
  (let ((rule (seq-find (lambda (r) (emacs-wm--match-matches-p (car r) wid))
                        emacs-wm-window-rules)))
    (cadr rule)))

(defun emacs-wm--raise (wid)
  "Move WID to the top of the stacking order."
  (setq emacs-wm--raise-order
        (append (delq wid (copy-sequence emacs-wm--raise-order)) (list wid)))
  (emacs-wm--schedule-layout))

(defun emacs-wm--lower (wid)
  "Move WID to the bottom of the stacking order."
  (setq emacs-wm--raise-order
        (cons wid (delq wid (copy-sequence emacs-wm--raise-order))))
  (emacs-wm--schedule-layout))

(defun emacs-wm-raise-window ()
  "Raise the focused app window above the others on its desktop."
  (interactive)
  (let ((wid (emacs-wm--focused-wid)))
    (when wid
      (emacs-wm--raise wid)
      (emacs-wm--log "raised %s" wid))))

(defun emacs-wm-lower-window ()
  "Lower the focused app window below the others on its desktop."
  (interactive)
  (let ((wid (emacs-wm--focused-wid)))
    (when wid
      (emacs-wm--lower wid)
      (emacs-wm--log "lowered %s" wid))))

(defun emacs-wm--order-for (wids)
  "WIDS sorted bottom->top, appending any that are new."
  (let ((known (seq-filter (lambda (w) (memq w wids)) emacs-wm--raise-order))
        (fresh (seq-filter (lambda (w) (not (memq w emacs-wm--raise-order))) wids)))
    (append known fresh)))

(defun emacs-wm--effective-float (wid)
  "Whether WID floats, honouring a manual toggle over the rule."
  (let ((override (gethash wid emacs-wm--float-override 'unset)))
    (if (eq override 'unset)
        (and (plist-get (emacs-wm--rule-actions wid) :float) t)
      override)))

(defun emacs-wm--window-rect (win float &optional wid)
  "Pixel rect of WIN inside its frame, or a centred rect when FLOAT.
WID's dragged rect wins, so a window the user moved stays where they put it."
  (or (and wid (gethash wid emacs-wm--rect-override))
      (if float
      (let* ((frame (window-frame win))
             (fw (frame-pixel-width frame))
             (fh (frame-pixel-height frame))
             (w (/ (* fw 6) 10))
             (h (/ (* fh 6) 10)))
        (when (and (> w 0) (> h 0))
          (list (/ (- fw w) 2) (/ (- fh h) 2) w h)))
      (let ((edges (window-inside-pixel-edges win)))
        (list (nth 0 edges) (nth 1 edges)
              (- (nth 2 edges) (nth 0 edges))
              (- (nth 3 edges) (nth 1 edges)))))))

(defun emacs-wm--push-layout ()
  "Compute a full layout snapshot from Emacs' window tree and push it.
Every output has its own set of desktop frames, and each output only shows
the frame of the desktop it is currently on."
  (setq emacs-wm--layout-dirty nil)
  (setq emacs-wm--gen (1+ emacs-wm--gen))
  (let* ((oids (emacs-wm--output-oids))
         (focus-wid (buffer-local-value 'emacs-wm-wid
                                        (window-buffer (selected-window))))
         (frame-msgs nil)
         (window-msgs nil)
         (seen nil)
         (focus nil))
    ;; frames: every frame of every output, only the current desktop visible
    (dolist (oid oids)
      (let ((visible (emacs-wm--desktop-frame oid)))
        (dolist (f (emacs-wm--desktop-frames oid))
          (let ((fid (gethash (emacs-wm--frame-name f) emacs-wm--fid-by-name)))
            (when fid
              (push (list :fid fid
                          :oid oid
                          :visible (if (eq f visible) t nil))
                    frame-msgs)
              ;; windows of the visible desktop get real rects
              (when (eq f visible)
                (dolist (win (window-list f 'nomini))
                  (let* ((buf (window-buffer win))
                         (wid (buffer-local-value 'emacs-wm-wid buf)))
                    (when wid
                      (let* ((actions (emacs-wm--rule-actions wid))
                             (float (emacs-wm--effective-float wid))
                             (border (emacs-wm--border-for
                                      (and focus-wid (eql wid focus-wid))
                                      actions))
                             (rect (emacs-wm--window-rect win float wid)))
                        (push wid seen)
                        (emacs-wm--log
                         "window %s on output %s: float=%S rect=%S border=%S focused=%S"
                         wid oid float rect border
                         (and focus-wid (eql wid focus-wid)))
                        (when rect
                          (push (append
                                 (list :wid wid
                                       :x (nth 0 rect) :y (nth 1 rect)
                                       :w (nth 2 rect) :h (nth 3 rect)
                                       :visible t
                                       :frame fid
                                       :float (if float t nil))
                                 (when border (list :border border))
                                 (when-let* ((decor (plist-get actions :decor)))
                                   (list :decor decor)))
                                window-msgs))))))))))))
    ;; every remaining window is hidden: mirror it in the desktop frame of the
    ;; output it belongs to, so switching back shows it in the right place
    (maphash
     (lambda (wid buf)
       (when (and (buffer-live-p buf) (not (memq wid seen)))
         (let* ((actions (emacs-wm--rule-actions wid))
                (float (emacs-wm--effective-float wid))
                (border (emacs-wm--border-for nil actions))
                (oid (or (plist-get (gethash wid emacs-wm--meta-by-wid) :output)
                         (emacs-wm--current-oid)))
                (frame (emacs-wm--desktop-frame oid))
                (fid (and frame (gethash (emacs-wm--frame-name frame)
                                        emacs-wm--fid-by-name))))
           (push (append
                  (list :wid wid :x 0 :y 0 :w 0 :h 0
                        :visible nil
                        :float (if float t nil))
                  (when fid (list :frame fid))
                  (when border (list :border border)))
                 window-msgs))))
     emacs-wm--buffer-by-wid)
    ;; focus: the frame holding the selected window, and the app buffer in it
    (let* ((fname (emacs-wm--frame-name (selected-frame)))
           (fid (and fname (gethash fname emacs-wm--fid-by-name))))
      (setq focus (if focus-wid
                      (list :frame fid :window focus-wid)
                    (list :frame fid))))
    (let ((n-frames (length frame-msgs))
          (n-windows (length window-msgs)))
      (emacs-wm--send (list :t "layout"
                            :epoch emacs-wm--epoch
                            :gen emacs-wm--gen
                            :frames (vconcat (nreverse frame-msgs))
                            :windows (vconcat (nreverse window-msgs))
                            ;; bottom->top, so the backend can stack explicitly
                            :order (vconcat (emacs-wm--order-for (nreverse seen)))
                            :focus focus))
      (emacs-wm--log "layout gen %d: %d output(s), %d frame(s), %d window(s), focus %S"
                     emacs-wm--gen (length oids) n-frames n-windows focus))))

;; ---------------------------------------------------------------- public

(defun emacs-wm-spawn (command)
  "Start COMMAND inside this session."
  (interactive "sCommand: ")
  (start-process-shell-command command nil command)
  (emacs-wm--log "spawned %S" command))

(defun emacs-wm-inject (&rest keysyms)
  "Inject KEYSYMS (names like \"j\" or \"Return\") into the focused window."
  (if emacs-wm--locked
      (emacs-wm--log "inject %S refused: session locked" keysyms)
    (emacs-wm--send (list :t "inject"
                          :keys (vconcat (mapcar (lambda (k) (list :name k)) keysyms))))
    (emacs-wm--log "inject %S" keysyms)))

(defun emacs-wm--focused-wid ()
  "Window id of the app buffer in the selected window, or nil."
  (buffer-local-value 'emacs-wm-wid (window-buffer (selected-window))))

(defun emacs-wm-desktop (n)
  "Switch to desktop N on the output under the pointer."
  (interactive "nDesktop number: ")
  (emacs-wm-switch-desktop n))

(defun emacs-wm-move-to-desktop-n (n)
  "Move the focused window to desktop N on its own output."
  (interactive "nDesktop number: ")
  (emacs-wm-move-to-desktop n))

;; Numbered commands, so a config can bind a desktop by name ("desktop-2",
;; "move-to-desktop-2") without writing a lambda.  `emacs-wm-desktop-1' and
;; friends are the ones the shipped configuration uses.
(dotimes (i emacs-wm--max-desktop-key)
  (let ((n (1+ i)))
    (defalias (intern (format "emacs-wm-desktop-%d" n))
      (lambda ()
        (interactive)
        (emacs-wm-switch-desktop n))
      (format "Switch this output to desktop %d." n))
    (defalias (intern (format "emacs-wm-move-to-desktop-%d" n))
      (lambda ()
        (interactive)
        (emacs-wm-move-to-desktop n))
      (format "Move the focused window to desktop %d on its own output." n))))

(defun emacs-wm--simulate-key-names ()
  "Every key that any `:simulate' rule translates."
  (let (names)
    (dolist (rule emacs-wm-window-rules)
      ;; a rule is (MATCH ACTIONS-PLIST), see `emacs-wm--rule-actions'
      (dolist (pair (plist-get (cadr rule) :simulate))
        (push (car pair) names)))
    (nreverse names)))

(defun emacs-wm-spawn-popup ()
  "Spawn `emacs-wm-popup-command'; rules decide whether it floats."
  (interactive)
  (unless emacs-wm-popup-command
    (user-error "emacs-wm: `emacs-wm-popup-command' is not set"))
  (emacs-wm-spawn emacs-wm-popup-command))

(defun emacs-wm-toggle-float ()
  "Toggle floating for the focused app window.
The decision is remembered here as well as in the backend: the layout is
recomputed from the rules on every change, so an unrecorded toggle would be
overwritten by the next snapshot."
  (interactive)
  (let* ((wid (emacs-wm--focused-wid))
         (now (and wid (emacs-wm--effective-float wid))))
    (when wid
      (puthash wid (not now) emacs-wm--float-override)
      (emacs-wm--send (list :t "window-cmd" :wid wid :cmd "toggle-float"))
      (emacs-wm--log "toggle-float for %s -> %s" wid (not now))
      (emacs-wm--schedule-layout))))

(defun emacs-wm--start-op (kind &optional edges)
  "Ask the backend to start an interactive KIND (move/resize) for the focused window."
  (let ((wid (emacs-wm--focused-wid)))
    (if emacs-wm--locked
        (emacs-wm--log "op %s refused: session locked" kind)
     (if (not wid)
        (emacs-wm--log "no focused app window for %s" kind)
      (emacs-wm--log "op %s for %s (edges %S)" kind wid edges)
      (emacs-wm--send (list :t "op-start" :wid wid :kind kind :edges edges))))))

(defun emacs-wm-move-window ()
  "Move the focused app window with the pointer.
Starts a river pointer op: move the mouse and click to finish."
  (interactive)
  (emacs-wm--start-op "move"))

(defun emacs-wm-resize-window ()
  "Resize the focused app window with the pointer, from `emacs-wm-resize-edges'."
  (interactive)
  (emacs-wm--start-op "resize" emacs-wm-resize-edges))

(defun emacs-wm-close-window ()
  "Close the focused app window."
  (interactive)
  (let ((wid (emacs-wm--focused-wid)))
    (when wid (emacs-wm--send (list :t "window-cmd" :wid wid :cmd "close")))))

(defun emacs-wm-minimize-window ()
  "Minimise the focused app window (daemon hides it, buffer is buried)."
  (interactive)
  (let ((wid (emacs-wm--focused-wid)))
    (when wid
      (emacs-wm--send (list :t "window-cmd" :wid wid :cmd "minimize"))
      (bury-buffer))))

(defun emacs-wm-toggle-fullscreen ()
  "Toggle fullscreen for the focused app window."
  (interactive)
  (let ((wid (emacs-wm--focused-wid)))
    (when wid
      (emacs-wm--send (list :t "window-cmd" :wid wid :cmd "toggle-fullscreen"))
      (emacs-wm--log "toggle-fullscreen for %s" wid))))

(defun emacs-wm--focus-wid (wid)
  "Focus WID: an app window's buffer, or the desktop frame it belongs to."
  (if-let ((frame-name (gethash wid emacs-wm--frame-name-by-wid)))
      ;; Clicked a frame's own surface: focus Emacs on that desktop -- but only
      ;; if that frame is the one currently shown on its output.  Before the
      ;; first layout every desktop frame is mapped and stacked, so the pointer
      ;; "enters" whichever happens to be on top and would silently switch the
      ;; output to a random desktop at startup.
      (let ((frame (seq-find (lambda (f) (equal (emacs-wm--frame-name f) frame-name))
                             (emacs-wm--desktop-frames))))
        (when (and frame
                   (string-match
                    "\\`wm-frame:\\([0-9]+\\):\\([0-9]+\\)\\'" frame-name))
          (let* ((oid (string-to-number (match-string 1 frame-name)))
                 (desktop (string-to-number (match-string 2 frame-name)))
                 (shown (emacs-wm--desktop-frame oid)))
            (if (not (equal (emacs-wm--frame-name shown) frame-name))
                (emacs-wm--log
                 "pointer entered %s but output %s shows %s: ignored"
                 frame-name oid (emacs-wm--frame-name shown))
              (puthash oid desktop emacs-wm--desktop-by-oid)
              (select-frame-set-input-focus frame)
              (emacs-wm--log "pointer focus -> frame %s" frame-name)
              (emacs-wm--schedule-layout)))))
    (emacs-wm--focus-app-wid wid)))

(defun emacs-wm--focus-app-wid (wid)
  "Select the buffer mirroring WID, restoring it if it was hidden."
  (let ((buf (gethash wid emacs-wm--buffer-by-wid)))
    (when (buffer-live-p buf)
      (let ((win (get-buffer-window buf)))
        (cond
         (win (select-window win))
         (t
          ;; Not mirrored right now: show it on its own output.
          (let ((frame (emacs-wm--desktop-frame
                        (or (plist-get (gethash wid emacs-wm--meta-by-wid) :output)
                            (emacs-wm--current-oid)))))
            (when frame (select-frame-set-input-focus frame))
            (pop-to-buffer buf))))
        (emacs-wm--log "pointer focus -> %s (%S)" wid (buffer-name buf))
        (emacs-wm--schedule-layout)))))

(defun emacs-wm--wid-output (wid)
  "Output OID the app window WID belongs to."
  (or (plist-get (gethash wid emacs-wm--meta-by-wid) :output)
      (emacs-wm--current-oid)))

(defun emacs-wm-move-to-desktop (n &optional oid)
  "Move the focused app window to desktop N on its own output (or OID)."
  (interactive "nDesktop number: ")
  (let* ((wid (emacs-wm--focused-wid))
         (buf (and wid (gethash wid emacs-wm--buffer-by-wid)))
         (target-oid (or oid (and wid (emacs-wm--wid-output wid))
                         (emacs-wm--current-oid)))
         (target (emacs-wm--desktop-frame target-oid n)))
    (when (and (buffer-live-p buf) target)
      (let ((win (get-buffer-window buf)))
        (when win (delete-window win)))
      (select-frame-set-input-focus target)
      (pop-to-buffer buf)
      (puthash target-oid n emacs-wm--desktop-by-oid)
      (emacs-wm--log "moved %s to desktop %s on output %s" wid n target-oid)
      (emacs-wm--schedule-layout))))

(defun emacs-wm-restore-window ()
  "Show the focused app window again if it was minimised."
  (interactive)
  (let* ((wid (emacs-wm--focused-wid))
         (buf (and wid (gethash wid emacs-wm--buffer-by-wid))))
    (when (buffer-live-p buf)
      (pop-to-buffer buf)
      (emacs-wm--send (list :t "window-cmd" :wid wid :cmd "focus"))
      (emacs-wm--schedule-layout))))

(defun emacs-wm-switch-desktop (n &optional oid)
  "Show desktop N on output OID, default the output under the pointer."
  (interactive "nDesktop number: ")
  (let* ((target-oid (or oid (emacs-wm--current-oid)))
         (frame (emacs-wm--desktop-frame target-oid n)))
    (if (null frame)
        (emacs-wm--log "no desktop %s on output %s" n target-oid)
      (puthash target-oid n emacs-wm--desktop-by-oid)
      (select-frame-set-input-focus frame)
      (raise-frame frame)
      (emacs-wm--log "output %s -> desktop %s (%S)"
                     target-oid n (emacs-wm--frame-name frame))
      (emacs-wm--schedule-layout))))

;;; ------------------------------------------------------------- backend

(defcustom emacs-wm-backend-program nil
  "Emacs binary used for the backend, or nil for `invocation-name'."
  :type '(choice (const :tag "Same Emacs" nil) string))

(defcustom emacs-wm-backend-lisp-directory nil
  "Directory holding emacs-wm-be.el, or nil to find it on `load-path'."
  :type '(choice (const :tag "From load-path" nil) directory))

(defun emacs-wm--wayland-socket ()
  "Path of the Wayland socket the backend should connect to."
  (let ((display (or (getenv "WAYLAND_DISPLAY") "wayland-0")))
    (if (file-name-absolute-p display)
        display
      (concat (or (getenv "XDG_RUNTIME_DIR") "/tmp") "/" display))))

(defun emacs-wm--backend-lisp-dir ()
  (or emacs-wm-backend-lisp-directory
      (file-name-directory (or (locate-library "emacs-wm-be")
                               (error "emacs-wm: emacs-wm-be.el is not on `load-path'")))))

(defun emacs-wm--backend-socket-live-p ()
  "Non-nil when something accepts connections on the backend socket.
A socket *file* proves nothing: a backend killed with SIGKILL leaves one
behind, and connecting to it would hand the frontend a process whose Wayland
connection is already gone."
  (let ((socket (emacs-wm-socket-path)))
    (and (file-exists-p socket)
         (condition-case nil
             (let ((probe (make-network-process :name "emacs-wm-probe"
                                                :family 'local
                                                :service socket
                                                :coding 'utf-8-emacs-unix
                                                :noquery t)))
               (delete-process probe)
               t)
           (error nil)))))

(defun emacs-wm-start-backend ()
  "Start the backend Emacs and wait for its socket.
The backend is a second, minimal Emacs: it is the Wayland client, so the
user's Emacs never sits in river's manage sequence.  Returns non-nil when
the socket exists afterwards."
  (let* ((socket (emacs-wm-socket-path))
         (display (or (getenv "WAYLAND_DISPLAY") "unknown"))
         (server-name (format "emacs-wm-be-%s" display)))
    (unless (emacs-wm--backend-socket-live-p)
      ;; A stale socket file would make the bind below fail or, worse, connect
      ;; us to a corpse.  Remove it before starting a fresh backend.
      (when (file-exists-p socket)
        (emacs-wm--log "removing stale backend socket %s" socket)
        (ignore-errors (delete-file socket)))
      (emacs-wm--log "starting backend Emacs")
      (setq emacs-wm--backend-process
            (make-process
             :name "emacs-wm-backend"
             :buffer " *emacs-wm-backend*"
             :stderr (getenv "EMACS_WM_BE_STDERR")
             :command (list (or emacs-wm-backend-program invocation-name)
                            "-Q"
                            (format "--fg-daemon=%s" server-name)
                            "-L" (emacs-wm--backend-lisp-dir)
                            "-l" "emacs-wm-be"
                            "--eval" "(emacs-wm-be-main)")
             :noquery t
             :filter (lambda (_proc _chunk) nil))
            )
      (emacs-wm--log "backend pid %S" (process-id emacs-wm--backend-process)))
    ;; The backend creates the socket before it binds the WM object, so a
    ;; connect that succeeds is also a connect that will be answered.
    (let ((waited 0))
      (while (and (not (emacs-wm--backend-socket-live-p)) (< waited 100))
        (sleep-for 0.05)
        (setq waited (1+ waited)))
      (emacs-wm--backend-socket-live-p))))

(defun emacs-wm-stop-backend ()
  "Stop a backend Emacs we started ourselves."
  (when (process-live-p emacs-wm--backend-process)
    (delete-process emacs-wm--backend-process))
  (setq emacs-wm--backend-process nil))

(defun emacs-wm--start-ping-timer ()
  "Start the liveness timer once."
  (unless (timerp emacs-wm--ping-timer)
    (setq emacs-wm--ping-timer
          (run-with-timer emacs-wm-ping-interval emacs-wm-ping-interval
                          #'emacs-wm--ping))))

(defun emacs-wm--stop-ping-timer ()
  "Stop the liveness timer."
  (when (timerp emacs-wm--ping-timer)
    (cancel-timer emacs-wm--ping-timer))
  (setq emacs-wm--ping-timer nil))

(defun emacs-wm-connect ()
  "Connect to the backend, starting it if necessary."
  (unless (emacs-wm-start-backend)
    (error "emacs-wm: backend socket %s never appeared" (emacs-wm-socket-path)))
  (emacs-wm--log "connecting to %s" (emacs-wm-socket-path))
  (setq emacs-wm--proc
        (make-network-process :name "emacs-wm"
                              :family 'local
                              :service (emacs-wm-socket-path)
                              :coding 'utf-8-emacs-unix
                              :filter #'emacs-wm--filter
                              :sentinel #'emacs-wm--sentinel
                              :noquery t))
  (setq emacs-wm--pings nil)
  (emacs-wm--start-ping-timer))

(defun emacs-wm-enable (&optional desktops)
  "Connect to the WM daemon and become the window manager's brain.
Key bindings come from `emacs-wm-key-bindings' (see `emacs-wm-config.el').
The user configuration is *not* loaded here: `emacs-wm-load-config' does that,
and the session entry point calls it.  That keeps a driver or a library user
from picking up somebody's personal configuration by accident."
  (interactive)
  (setq emacs-wm--queue nil
        emacs-wm--rx-buffer ""
        emacs-wm--gen 0
        emacs-wm--epoch nil)
  ;; Desktop frames are created per output as the daemon reports them, so a
  ;; single-output session and a two-output session need no configuration.
  (setq emacs-wm--desktops-per-output
        (or (and desktops (length desktops))
            emacs-wm-desktops-per-output))
  (clrhash emacs-wm--desktop-by-oid)
  (modify-all-frames-parameters '((undecorated . t)))
  ;; Bindings first: `hello' registers them with the compositor, and `hello'
  ;; arrives as soon as the connection is up.
  (emacs-wm-apply-bindings)
  (emacs-wm--define-global-bindings)
  (emacs-wm-connect)
  (emacs-wm--log "connected to %s" (emacs-wm-socket-path))
  (add-hook 'window-configuration-change-hook #'emacs-wm--schedule-layout)
  (add-hook 'window-selection-change-functions (lambda (&rest _) (emacs-wm--schedule-layout)))
  (add-hook 'window-buffer-change-functions (lambda (&rest _) (emacs-wm--schedule-layout)))
  (add-hook 'post-command-hook #'emacs-wm--schedule-layout)
  (message "emacs-wm: connected, %d output(s), %d desktop frames, %d key binding(s)"
           (length (emacs-wm--output-oids)) (length (emacs-wm--desktop-frames))
           (length emacs-wm-key-bindings))
  (run-hooks 'emacs-wm-enable-hook))

(defvar emacs-wm--config-loaded nil
  "Non-nil once `emacs-wm-load-config' has loaded the user configuration.")

(defun emacs-wm-load-config (&optional file)
  "Load the user configuration FILE, default `emacs-wm-config-file'.
A missing file is not an error: the shipped `emacs-wm-config.el' already
supplied the defaults.  Call this before `emacs-wm-enable' (or call
`emacs-wm-apply-bindings' afterwards) so new bindings take effect."
  (let ((path (or file emacs-wm-config-file)))
    (cond
     ((and path (file-readable-p path))
      (emacs-wm--log "loading configuration %s" path)
      (load path nil 'nomessage)
      (setq emacs-wm--config-loaded path)
      (message "emacs-wm: configuration %s loaded" path))
     (t
      (emacs-wm--log "no user configuration at %s" path)
      (setq emacs-wm--config-loaded nil)))
    emacs-wm--config-loaded))

(defun emacs-wm--unregister-bindings ()
  "Tell the backend to forget every binding we registered.
Used before re-registering a reloaded configuration, so a key that was
removed from the configuration stops being intercepted instead of becoming a
key that swallows presses and does nothing."
  (maphash (lambda (_key bid) (emacs-wm--send (list :t "unbind" :bid bid)))
           emacs-wm--key-to-bid)
  (clrhash emacs-wm--key-to-bid)
  (clrhash emacs-wm--bid-to-key)
  (clrhash emacs-wm--bid-to-name))

(defun emacs-wm-reload-config (&optional file)
  "Reload the user configuration from FILE and apply it to this session.
Loads the file (`emacs-wm-load-config'), rebuilds the keymap, puts the new
bindings on `global-map', and re-registers them with the backend, so a key
added to the configuration works without restarting the session."
  (interactive)
  (emacs-wm-load-config file)
  (emacs-wm-apply-bindings)
  (emacs-wm--define-global-bindings)
  (when (process-live-p emacs-wm--proc)
    (emacs-wm--unregister-bindings)
    (emacs-wm--register-bindings))
  (emacs-wm--schedule-layout)
  ;; Rules, borders and the desktop count are read from the variables when the
  ;; next layout is computed, so re-sending it is enough for them too.
  (message "emacs-wm: configuration reloaded (%d bindings)" (length emacs-wm-key-bindings)))

(defun emacs-wm-run-startup-commands ()
  "Start every command in `emacs-wm-startup-commands'."
  (dolist (command emacs-wm-startup-commands)
    (emacs-wm--log "autostart %S" command)
    (emacs-wm-spawn command)))

(defun emacs-wm-exit-session ()
  "Ask the compositor to end the session (log out).
River terminates, which takes this Emacs and every app it started with it.
`emacs-wm-close-window' and the other window commands do nothing here."
  (interactive)
  (when (yes-or-no-p "End the emacs-wm session? ")
    (emacs-wm--log "exit-session requested")
    (emacs-wm--send (list :t "exit-session"))))

;; The built-in configuration is loaded last: everything above must exist
;; before it can be referenced, and it is policy, not mechanism.
(require 'emacs-wm-config)

(provide 'emacs-wm)
;;; emacs-wm.el ends here
