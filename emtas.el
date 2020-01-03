;;; emtas.el --- Absurdly fast Emacs startup time -*- lexical-binding: t -*-

;; Copyright (C) 2019 Radon Rosborough

;; Author: Radon Rosborough <radon.neon@gmail.com>
;; Created: 2 Jan 2020
;; Homepage: https://github.com/raxod502/emtas
;; Keywords: convenience
;; Package-Requires: ((emacs "25.1") (heap "0.5"))
;; Version: 0

;;; Commentary:

;; Please see https://github.com/raxod502/emtas for more information.

;;; Code:

;; To see the outline of this file, run M-x outline-minor-mode and
;; then press C-c @ C-t. To also show the top-level functions and
;; variable declarations in each section, run M-x occur with the
;; following query: ^;;;;* \|^(

(require 'cl-lib)

;; Yucky hack because `heap' loads `cl' which it really really
;; shouldn't, and Emacs rightfully prints an annoying message about
;; the deprecation of `cl' which happened like a decade ago, but we
;; don't want to bother *our* users. In case you're wondering why the
;; heck we're binding `run-with-idle-timer', see
;; `do-after-load-evaluation' which is what generates the deprecation
;; message (using an idle timer, no less).
(cl-letf* ((run-with-idle-timer (symbol-function #'run-with-idle-timer))
           ((symbol-function #'run-with-idle-timer)
            (lambda (secs repeat function &rest args)
              (unless (and (= (length args) 1)
                           (stringp (car args))
                           (string-match-p "^Package .+ is deprecated$"
                                           (car args)))
                (apply run-with-idle-timer secs repeat function args)))))
  (require 'heap))

(defgroup emtas nil
  "Like a tool-assisted speedrun, but for Emacs startup time."
  :group 'convenience
  :prefix "emtas-"
  :link '(url-link "https://github.com/raxod502/emtas"))

(defcustom emtas-idle-queue-delay 0.1
  "Number of seconds to wait between each idle action."
  :type 'number)

(defcustom emtas-idle-action-max-duration 0.01
  "How long EMTAS will do idle work before returning control, in seconds.
This should be significantly less than the maximum delay you can
deal with. Research suggests that humans start to notice software
latency somewhere in the ballpark of 100ms."
  :type 'number)

(defcustom emtas-cache-file
  (expand-file-name "var/emtas-cache.el" user-emacs-directory)
  "File in which to cache feature dependency tree.
See `emtas-idle-require'."
  :type 'file)

(defvar emtas--cache-loaded nil
  "Non-nil means `emtas-cache-file' has been loaded.")

(defvar emtas--cache-dirty nil
  "Non-nil means cache was modified since `emtas-cache-file' was written.")

(defvar emtas--cache nil
  "The EMTAS cache, loaded from `emtas-cache-file'.
Currently this is just an alist mapping idle-required features to
their transitive dependencies in reverse order.")

(defvar emtas--idle-queue (make-heap (lambda (a b) (> (car a) (car b))))
  "Priority queue of actions to perform. They have an arbitrary format.

Invariant: this variable is non-nil if and only if there's an
idle timer scheduled to pop something off the queue.")

(defvar emtas--inhibit-scheduling nil
  "Non-nil means `emtas--schedule-action' never sets an idle timer.")

(defun emtas--low-order (order)
  "Return an order value lower than any the user is allowed to provide."
  (- order 1e7))

(defun emtas--pop-action-and-reschedule ()
  "Execute an action from the idle queue, and schedule another pop."
  (let ((emtas--inhibit-scheduling t)
        (start-time (current-time)))
    (while (and (or emtas--idle-queue emtas--cache-dirty)
                (< (float-time (time-subtract (current-time) start-time))
                   emtas-idle-action-max-duration))
      (pcase (queue-dequeue emtas--idle-queue)
        (`nil
         (unless emtas--idle-queue
           ;; Looks like we popped everything off the queue, so the
           ;; cache must be dirty (otherwise we'd not be in the loop).
           ;; Better write it to disk. Then we'll be done.
           (cl-assert emtas--cache-loaded)
           (cl-assert emtas--cache-dirty)
           (make-directory (file-name-directory emtas-cache-file) 'parents)
           (with-temp-file emtas-cache-file
             (let ((print-level nil)
                   (print-length nil))
               (print emtas--cache (current-buffer))))
           (setq emtas--cache-dirty nil)))
        (`(,order . load-cache)
         (unless emtas--cache-loaded
           (with-temp-buffer
             (ignore-errors
               (insert-file-contents-literally
                emtas-cache-file)
               (setq emtas--cache (read (current-buffer)))))
           (setq emtas--cache-loaded t)
           (setq emtas--cache-dirty nil)))
        (`(,order . (idle-require ,feature))
         (if-let ((deps (alist-get feature emtas--cache)))
             (let ((idx 0))
               (dolist (dep deps)
                 (emtas--schedule-action
                  `(dependency-require ,feature)
                  ;; This acts as a lexicographic sort assuming no
                  ;; instance of Emacs has more than a billion
                  ;; features available.
                  (+ order (* idx 1e-9)))
                 (queue-enqueue
                  emtas--idle-queue `(dependency-require ,feature))
                 (cl-incf idx)))
           (emtas--schedule-action
            `(require ,feature)
            (emtas--low-order 1))))))
    (when (or emtas--idle-queue emtas--cache-dirty)
      (run-with-idle-timer
       emtas-idle-queue-delay
       nil #'emtas--pop-action-and-reschedule))))

(defun emtas--schedule-action (action order)
  "Schedule an ACTION on the idle queue."
  (unless (and emtas--idle-queue (not emtas--inhibit-scheduling))
    (run-with-idle-timer
     emtas-idle-queue-delay
     nil #'emtas--pop-action-and-reschedule))
  (queue-enqueue emtas--idle-queue (cons order action)))

(defun emtas-idle-require (feature &optional order)
  "Require FEATURE when idle, amortizing load time of dependencies.
The first time you call `emtas-idle-require', it will act the
same as `require', but it will record data about the feature
dependency graph and store it in `emtas-cache-file'. The next
time, it will load the features in reverse dependency order,
which means the editor UI will never be blocked waiting for a
whole bunch of features to load at the same time. If the
dependency graph changes, this will be detected automatically
within one restart of Emacs.

Idle requires with a smaller ORDER (defaults to 0) will happen
first. ORDER must be an integer between -1e6 and +1e6, as other
values are for internal use."
  (setq order (or order 0))
  (unless (and (integerp order)
               (>= order -1e6)
               (<= order +1e6))
    (error "EMTAS: illegal idle-require order: %S" order))
  (emtas--schedule-action 'load-cache (emtas--low-order 0))
  (emtas--schedule-action `(idle-require ,feature) (or order 0)))

(provide 'emtas)

;; Local Variables:
;; indent-tabs-mode: nil
;; outline-regexp: ";;;;* "
;; End:

;;; selectrum.el ends here