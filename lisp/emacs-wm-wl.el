;;; emacs-wm-wl.el --- a Wayland client in Emacs Lisp  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  emacs-wm contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The smallest Wayland client that can act as a river window manager.
;;
;; Wayland is not a request/response protocol with acknowledgements: a client
;; writes length-prefixed binary messages to the compositor socket and reads
;; events from it.  That is all this file implements -- framing, the argument
;; types the river protocols actually use, an object table and dispatch.  It
;; deliberately does NOT implement `fd' arguments: passing a file descriptor
;; needs SCM_RIGHTS ancillary data, which a `make-network-process' connection
;; cannot carry.  Every river window-management protocol is fd-free; the only
;; fd in the whole set is `zwp_virtual_keyboard_v1.keymap', and river now
;; borrows the seat's keymap for a virtual keyboard that never sets one, so a
;; client of this kind can still inject keys.  See emacs-wm-be.el.
;;
;; Reference: https://wayland.freedesktop.org/docs/html/ (wire format).

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defgroup emacs-wm-wl nil
  "Minimal Wayland client for emacs-wm."
  :group 'emacs-wm)

;;; ---------------------------------------------------------------- protocol

(cl-defstruct (emacs-wm-wl-interface (:constructor emacs-wm-wl--make-interface))
  "One Wayland interface as read from a protocol XML file."
  name version requests events)

(cl-defstruct (emacs-wm-wl-message (:constructor emacs-wm-wl--make-message))
  "One request or event of an interface."
  name since args opcode)

(cl-defstruct (emacs-wm-wl-arg (:constructor emacs-wm-wl--make-arg))
  name type interface)

(cl-defstruct (emacs-wm-wl-object (:constructor emacs-wm-wl--make-object))
  "A client-side Wayland object."
  id interface version data)

(cl-defstruct (emacs-wm-wl-connection (:constructor emacs-wm-wl--make-connection))
  "One Wayland connection."
  socket process rx objects next-id interfaces handler
  (dangling-names nil)
  (closed nil))

(defvar emacs-wm-wl--registry-queue nil
  "Globals seen in the current registry round-trip are handled immediately.")

(defun emacs-wm-wl--xml-child (node tag)
  "Return the children of NODE whose car is TAG."
  (seq-filter (lambda (child) (and (consp child) (eq (car child) tag)))
              (cddr node)))

(defun emacs-wm-wl--xml-attr (node name)
  "Value of attribute NAME (a symbol) in NODE, as a string."
  (let ((pair (assq name (cadr node))))
    (and pair (cdr pair))))

(defun emacs-wm-wl--parse-args (node)
  "Parse the `arg' children of NODE into a vector of `emacs-wm-wl-arg'."
  (vconcat
   (mapcar (lambda (a)
             (emacs-wm-wl--make-arg
              :name (emacs-wm-wl--xml-attr a 'name)
              :type (emacs-wm-wl--xml-attr a 'type)
              :interface (emacs-wm-wl--xml-attr a 'interface)))
           (emacs-wm-wl--xml-child node 'arg))))

(defun emacs-wm-wl-read-protocols (files)
  "Read protocol XML FILES and return a hash of interface name -> interface.
The hash is keyed by the interface name as a string, e.g. \"wl_registry\"."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (file files)
      (unless (file-readable-p file)
        (error "emacs-wm-wl: protocol file not readable: %s" file))
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (let ((root (libxml-parse-xml-region (point-min) (point-max))))
          ;; A leading comment makes libxml return a `top' wrapper holding the
          ;; comment and the real root; find the protocol element either way.
          (when (eq (car root) 'top)
            (setq root (seq-find (lambda (node)
                                   (and (consp node) (eq (car node) 'protocol)))
                                 root)))
          (unless (eq (car root) 'protocol)
            (error "emacs-wm-wl: %s is not a protocol file" file))
          (dolist (iface (emacs-wm-wl--xml-child root 'interface))
            (let* ((name (emacs-wm-wl--xml-attr iface 'name))
                   (version (string-to-number
                             (or (emacs-wm-wl--xml-attr iface 'version) "1")))
                   (requests (make-hash-table :test 'equal))
                   (events (make-hash-table :test 'equal))
                   (req-index 0)
                   (evt-index 0))
              (dolist (child (cddr iface))
                (when (consp child)
                  (pcase (car child)
                    ('request
                     (let ((msg (emacs-wm-wl--make-message
                                 :name (emacs-wm-wl--xml-attr child 'name)
                                 :since (string-to-number
                                         (or (emacs-wm-wl--xml-attr child 'since) "1"))
                                 :args (emacs-wm-wl--parse-args child)
                                 :opcode req-index)))
                       (puthash (emacs-wm-wl-message-name msg) msg requests))
                     (setq req-index (1+ req-index)))
                    ('event
                     (let ((msg (emacs-wm-wl--make-message
                                 :name (emacs-wm-wl--xml-attr child 'name)
                                 :since (string-to-number
                                         (or (emacs-wm-wl--xml-attr child 'since) "1"))
                                 :args (emacs-wm-wl--parse-args child)
                                 :opcode evt-index)))
                       (puthash (emacs-wm-wl-message-name msg) msg events))
                     (setq evt-index (1+ evt-index))))))
              (puthash name
                       (emacs-wm-wl--make-interface
                        :name name :version version
                        :requests requests :events events)
                       table))))))
    table))

(defun emacs-wm-wl--message-by-opcode (opcode table)
  "Return the message of OPCODE in TABLE (an events or requests hash)."
  (let (found)
    (maphash (lambda (_name msg)
               (when (= (emacs-wm-wl-message-opcode msg) opcode)
                 (setq found msg)))
             table)
    found))

;;; ------------------------------------------------------------------- bytes
;;
;; Wayland arguments are 4-byte aligned little-endian words.  Emacs strings are
;; byte vectors when unibyte, so we can read and write them directly.

(defsubst emacs-wm-wl--u32 (n)
  "Encode integer N as 4 little-endian bytes."
  (let ((n (logand n #xffffffff)))
    (unibyte-string (logand n #xff)
                    (logand (ash n -8) #xff)
                    (logand (ash n -16) #xff)
                    (logand (ash n -24) #xff))))

(defsubst emacs-wm-wl--get-u32 (s offset)
  "Read an unsigned 32-bit integer from unibyte string S at OFFSET."
  (logior (aref s offset)
          (ash (aref s (1+ offset)) 8)
          (ash (aref s (+ offset 2)) 16)
          (ash (aref s (+ offset 3)) 24)))

(defun emacs-wm-wl--get-i32 (s offset)
  "Read a signed 32-bit integer from unibyte string S at OFFSET."
  (let ((n (emacs-wm-wl--get-u32 s offset)))
    (if (>= n #x80000000) (- n #x100000000) n)))

(defun emacs-wm-wl--pad (n)
  "Number of padding bytes needed to align N to a 4-byte boundary."
  (let ((r (logand n 3)))
    (if (zerop r) 0 (- 4 r))))

(defun emacs-wm-wl--pad-string ()
  "A string of NULs long enough for any needed padding."
  "\0\0\0")

(defun emacs-wm-wl--encode-string (s)
  "Encode STRING S (a UTF-8 string or nil) as a Wayland string."
  (let* ((bytes (if s (encode-coding-string s 'utf-8-unix) ""))
         (len (1+ (length bytes))))
    (concat (emacs-wm-wl--u32 len)
            bytes
            "\0"
            (substring (emacs-wm-wl--pad-string) 0 (emacs-wm-wl--pad len)))))

(defun emacs-wm-wl--decode-string (s offset)
  "Decode the Wayland string at OFFSET in S.
Return (STRING . NEXT-OFFSET).  A zero length means nil (null string)."
  (let* ((len (emacs-wm-wl--get-u32 s offset))
         (start (+ offset 4)))
    (if (zerop len)
        (cons nil (+ start 0))
      (let ((raw (substring s start (+ start (1- len))))
            (next (+ start len (emacs-wm-wl--pad len))))
        (cons (decode-coding-string raw 'utf-8-unix) next)))))

;;; --------------------------------------------------------------- encoding

(defun emacs-wm-wl--encode-arg (type value)
  "Encode VALUE of Wayland TYPE."
  (pcase type
    ("int" (emacs-wm-wl--u32 value))
    ("fixed" (emacs-wm-wl--u32 (round (* value 256))))
    ((or "uint" "object" "new_id")
     (emacs-wm-wl--u32 (or value 0)))
    ("string"
     (emacs-wm-wl--encode-string value))
    ("array"
     (let* ((data (if value (string-to-unibyte value) ""))
            (len (length data)))
       (concat (emacs-wm-wl--u32 len)
               data
               (substring (emacs-wm-wl--pad-string) 0 (emacs-wm-wl--pad len)))))
    ("fd"
     (error "emacs-wm-wl: cannot send an fd argument (SCM_RIGHTS is not available)"))
    (_ (error "emacs-wm-wl: unknown argument type %S" type)))
  )

(defun emacs-wm-wl--object-id (object-or-id)
  (if (emacs-wm-wl-object-p object-or-id)
      (emacs-wm-wl-object-id object-or-id)
    object-or-id))

;;; -------------------------------------------------------------- connection

(defun emacs-wm-wl-new-id (connection interface)
  "Allocate an id on CONNECTION for an object of INTERFACE (a string)."
  (let ((id (emacs-wm-wl-connection-next-id connection)))
    (setf (emacs-wm-wl-connection-next-id connection) (1+ id))
    (emacs-wm-wl-object-add connection interface id)))

(defun emacs-wm-wl-object-add (connection interface id &optional version)
  "Track a new object of INTERFACE with ID on CONNECTION."
  (let* ((iface (gethash interface (emacs-wm-wl-connection-interfaces connection)))
         (object (emacs-wm-wl--make-object
                  :id id :interface interface
                  :version (or version (and iface (emacs-wm-wl-interface-version iface)))
                  :data nil)))
    (puthash id object (emacs-wm-wl-connection-objects connection))
    object))

(defun emacs-wm-wl-object (connection id)
  "Return the object with ID on CONNECTION, or nil."
  (gethash id (emacs-wm-wl-connection-objects connection)))

(defun emacs-wm-wl-object-remove (connection id)
  "Forget the object with ID on CONNECTION."
  (remhash id (emacs-wm-wl-connection-objects connection)))

(defun emacs-wm-wl-request (connection object-or-id request &optional values)
  "Send REQUEST on OBJECT-OR-ID.
VALUES is a plist mapping each argument name (a string in the XML) to its
value, e.g. (:x 10 :y 20).  A `new_id' argument is allocated here unless the
caller passed an integer: pass :NAME-interface to choose the interface when
the XML does not declare one.  Returns the allocated object, if any."
  (let* ((objects (emacs-wm-wl-connection-objects connection))
         (id (emacs-wm-wl--object-id object-or-id))
         (object (gethash id objects))
         (iface (and object
                     (gethash (emacs-wm-wl-object-interface object)
                              (emacs-wm-wl-connection-interfaces connection))))
         (message (and iface (gethash request (emacs-wm-wl-interface-requests iface)))))
    (unless object
      (error "emacs-wm-wl: request %S on unknown object %S" request id))
    (unless message
      (error "emacs-wm-wl: %s has no request %S"
             (emacs-wm-wl-object-interface object) request))
    (let ((args (emacs-wm-wl-message-args message))
          (new-id nil)
          (payload ""))
      (dotimes (i (length args))
        (let* ((arg (aref args i))
               (name (emacs-wm-wl-arg-name arg))
               (type (emacs-wm-wl-arg-type arg))
               (value (plist-get values (intern (concat ":" name)))))
          (when (equal type "new_id")
            (let* ((declared (emacs-wm-wl-arg-interface arg))
                   (chosen (or (plist-get values (intern (concat ":" name "-interface")))
                               declared
                               (error "emacs-wm-wl: %s.%s needs :%s-interface"
                                      (emacs-wm-wl-object-interface object)
                                      request name))))
              (if (integerp value)
                  ;; The caller allocated the id and tracks the object itself.
                  (unless (emacs-wm-wl-object connection value)
                    (emacs-wm-wl-object-add connection chosen value))
                (setq new-id (emacs-wm-wl-new-id connection chosen)
                      value (emacs-wm-wl-object-id new-id)))))
          (setq payload (concat payload (emacs-wm-wl--encode-arg type value)))))
      (let* ((size (+ 8 (length payload)))
             (header (concat (emacs-wm-wl--u32 id)
                             (emacs-wm-wl--u32
                              (logior (ash size 16)
                                      (emacs-wm-wl-message-opcode message))))))
        (emacs-wm-wl--write connection (concat header payload)))
      new-id)))

(defun emacs-wm-wl--write (connection string)
  "Write STRING to CONNECTION's socket."
  (let ((proc (emacs-wm-wl-connection-process connection)))
    (unless (process-live-p proc)
      (error "emacs-wm-wl: connection is not live"))
    (process-send-string proc string)))

;;; ---------------------------------------------------------------- decoding

(defun emacs-wm-wl--decode-args (string offset args)
  "Decode ARGS from STRING starting at OFFSET, returning a plist."
  (let ((acc nil)
        (i 0))
    (while (< i (length args))
      (let* ((arg (aref args i))
             (name (emacs-wm-wl-arg-name arg))
             (type (emacs-wm-wl-arg-type arg))
             (key (intern (concat ":" name))))
        (pcase type
          ("int"
           (push key acc) (push (emacs-wm-wl--get-i32 string offset) acc)
           (setq offset (+ offset 4)))
          ("uint"
           (push key acc) (push (emacs-wm-wl--get-u32 string offset) acc)
           (setq offset (+ offset 4)))
          ("fixed"
           (push key acc)
           (push (/ (emacs-wm-wl--get-i32 string offset) 256.0) acc)
           (setq offset (+ offset 4)))
          ((or "object" "new_id")
           (push key acc) (push (emacs-wm-wl--get-u32 string offset) acc)
           (setq offset (+ offset 4)))
          ("string"
           (let ((pair (emacs-wm-wl--decode-string string offset)))
             (push key acc) (push (car pair) acc)
             (setq offset (cdr pair))))
          ("array"
           (let* ((len (emacs-wm-wl--get-u32 string offset))
                  (start (+ offset 4))
                  (data (substring string start (+ start len))))
             (push key acc) (push data acc)
             (setq offset (+ start len (emacs-wm-wl--pad len)))))
          ("fd"
           (error "emacs-wm-wl: cannot receive an fd argument")))
        (setq i (1+ i))))
    (nreverse acc)))

(defun emacs-wm-wl--dispatch (connection string)
  "Decode one complete message in STRING and dispatch it."
  (let* ((id (emacs-wm-wl--get-u32 string 0))
         (word (emacs-wm-wl--get-u32 string 4))
         (opcode (logand word #xffff))
         (object (emacs-wm-wl-object connection id)))
    (cond
     ((null object)
      ;; Events for an object we destroyed arrive for a while; that is normal.
      nil)
     (t
      (let* ((iface (gethash (emacs-wm-wl-object-interface object)
                             (emacs-wm-wl-connection-interfaces connection)))
             (message (and iface
                           (emacs-wm-wl--message-by-opcode
                            opcode (emacs-wm-wl-interface-events iface)))))
        (cond
         ((null message)
          (emacs-wm-wl--log connection "unknown event opcode %d on %s"
                            opcode (emacs-wm-wl-object-interface object)))
         (t
          (let ((args (emacs-wm-wl--decode-args
                       string 8 (emacs-wm-wl-message-args message)))
                (handler (emacs-wm-wl-connection-handler connection)))
            (when handler
              (funcall handler connection object
                       (emacs-wm-wl-message-name message) args)))))))
     )))

(defun emacs-wm-wl--filter (connection)
  "Return the process filter for CONNECTION."
  (lambda (_proc chunk)
    (setq chunk (string-to-unibyte chunk))
    (setf (emacs-wm-wl-connection-rx connection)
          (concat (emacs-wm-wl-connection-rx connection) chunk))
    (let ((progress t))
      (while progress
        (let ((buf (emacs-wm-wl-connection-rx connection)))
          (if (< (length buf) 8)
              (setq progress nil)
            (let* ((word (emacs-wm-wl--get-u32 buf 4))
                   (len (ash word -16)))
              (cond
               ((< len 8)
                (emacs-wm-wl--log connection
                                  "invalid message length %d; dropping buffer" len)
                (setf (emacs-wm-wl-connection-rx connection) "")
                (setq progress nil))
               ((< (length buf) len)
                (setq progress nil))
               (t
                (let ((msg (substring buf 0 len)))
                  (setf (emacs-wm-wl-connection-rx connection)
                        (substring buf len))
                  (condition-case err
                      (emacs-wm-wl--dispatch connection msg)
                    (error
                     (emacs-wm-wl--log connection "dispatch error: %S" err)))))))))))))

(defun emacs-wm-wl--sentinel (connection)
  "Return the process sentinel for CONNECTION."
  (lambda (_proc event)
    (unless (memq (process-status (emacs-wm-wl-connection-process connection))
                  '(run open listen connect stop))
      (setf (emacs-wm-wl-connection-closed connection) t)
      (emacs-wm-wl--log connection "connection closed: %s" (string-trim event))
      (when-let* ((handler (emacs-wm-wl-connection-handler connection)))
        (funcall handler connection nil "closed" nil)))))

(defun emacs-wm-wl-connect (socket handler &optional protocol-dir)
  "Connect to the Wayland SOCKET and call HANDLER for every event.
HANDLER is called as (CONNECTION OBJECT EVENT ARGS); OBJECT is nil for the
synthetic \"closed\" event.  Returns the connection."
  (let* ((connection (emacs-wm-wl--make-connection
                      :socket socket
                      :next-id 1
                      :objects (make-hash-table :test 'eql)
                      :interfaces (emacs-wm-wl-read-protocols
                                   (emacs-wm-wl--protocol-files protocol-dir))
                      :handler handler))
         (proc (make-network-process
                :name "emacs-wm-wayland"
                :family 'local
                :service socket
                :coding 'binary
                :noquery t
                :filter (emacs-wm-wl--filter connection)
                :sentinel (emacs-wm-wl--sentinel connection))))
    (setf (emacs-wm-wl-connection-process connection) proc)
    ;; Start at 2: id 1 is wl_display, allocated by the protocol itself.
    (emacs-wm-wl-object-add connection "wl_display" 1)
    (setf (emacs-wm-wl-connection-next-id connection) 2)
    connection))

(defun emacs-wm-wl-disconnect (connection)
  "Close CONNECTION."
  (when-let* ((proc (emacs-wm-wl-connection-process connection)))
    (when (process-live-p proc)
      (delete-process proc)))
  (setf (emacs-wm-wl-connection-closed connection) t))

;;; ----------------------------------------------------------------- logging

(defvar emacs-wm-wl-log-function nil
  "Function called with (FORMAT ARGS) for protocol-level diagnostics.")

(defun emacs-wm-wl--log (connection fmt &rest args)
  "Log FMT/ARGS, prefixed with the connection state."
  (ignore connection)
  (when emacs-wm-wl-log-function
    (condition-case nil
        (funcall emacs-wm-wl-log-function fmt args)
      (error nil))))

(defconst emacs-wm-wl--protocol-directory
  (file-name-directory
   (or (locate-library "emacs-wm-wl")
       load-file-name
       (error "emacs-wm-wl: cannot locate its own source to find the protocol XML")))
  "Directory holding the protocol XML this client loads.")

(defun emacs-wm-wl--protocol-files (dir)
  "List the protocol XML files to load from DIR.
DIR defaults to `emacs-wm-wl--protocol-directory'/protocol."
  (let ((dir (or dir (expand-file-name "protocol" emacs-wm-wl--protocol-directory))))
    (mapcar (lambda (name) (expand-file-name name dir))
            '("wayland-core.xml"
              "river-window-management-v1.xml"
              "river-xkb-bindings-v1.xml"
              "river-layer-shell-v1.xml"
              "river-virtual-keyboard-v1.xml"
              "virtual-keyboard-unstable-v1.xml"))))

(provide 'emacs-wm-wl)
;;; emacs-wm-wl.el ends here
