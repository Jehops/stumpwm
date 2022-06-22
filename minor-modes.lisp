;;;; MINOR MODES

;; This file is part of stumpwm.
;;
;; stumpwm is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; stumpwm is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this software; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 59 Temple Place, Suite 330,
;; Boston, MA 02111-1307 USA

;;; Commentary:

;; This file implements minor modes for StumpWM. Minor modes are implemented as
;; mixins which get added to a scope object to allow overriding methods which
;; are called upon that object. Minor modes are defined with the macro
;; DEFINE-MINOR-MODE, and new scopes can be defined by
;; DEFINE-MINOR-MODE-SCOPE. All scope objects must be instances of classes, as
;; the MOP is used to implement minor modes and add them to scope objects.

;;; Code:

(in-package :stumpwm)

(export '(minor-mode
          define-minor-mode

          add-minor-mode-scope
          define-minor-mode-scope
          define-descended-minor-mode-scope

          sync-all-minor-modes

          validate-superscope
          validate-scope

          *minor-mode*
          *minor-mode-enable-hook*
          *minor-mode-disable-hook*
          *unscoped-minor-modes*

          minor-mode-scope
          minor-mode-global-p
          enable-minor-mode
          disable-minor-mode
          minor-mode-keymap
          minor-mode-lighter

          list-modes
          list-minor-modes
          list-current-mode-objects
          list-mode-objects
          enabled-minor-modes
          current-minor-modes
          minor-mode-enabled-p
          find-minor-mode

          generate-keymap))

(defvar *minor-mode*)

(setf (documentation '*minor-mode* 'variable)
"A dynamic variable bound to the minor mode object when executing a minor mode
command.")


;;;;;;;;;;;;;;;;;;;;;
;;; General Hooks ;;;
;;;;;;;;;;;;;;;;;;;;;

(defvar *minor-mode-enable-hook* ()
  "A hook run whenever a minor mode is enabled. Functions are called with the
minor mode symbol and the object they have been added to. This is run when a
minor mode is explicitly enabled via enable-minor-mode.")

(defvar *minor-mode-disable-hook* ()
  "A hook run whenever a minor mode is disabled. Functions are called with the
minor mode symbol and the scope object. This is run when a minor mode is
explicitly disabled via disable-minor-mode.")


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Classes and Global Modes ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defclass unscoped-modes () ())

(defclass minor-mode () ()
  (:documentation "The root minor mode class. All minor modes are subclasses of
this class."))

(defvar *unscoped-minor-modes* (make-instance 'unscoped-modes)
  "A dynamic variable holding all unscoped minor modes as mixed into the same
object.")

(defvar *active-global-minor-modes* ()
  "A list of all currently active global minor modes.")


;;;;;;;;;;;;;;;;;
;;; Sync Keys ;;;
;;;;;;;;;;;;;;;;;

(defun minor-mode-sync-keys-hook-function (&rest rest)
  (declare (ignore rest))
  (sync-keys))

(add-hook *focus-frame-hook* 'minor-mode-sync-keys-hook-function)
(add-hook *focus-window-hook* 'minor-mode-sync-keys-hook-function)
(add-hook *focus-group-hook* 'minor-mode-sync-keys-hook-function)


;;;;;;;;;;;;;;;;;;
;;; Conditions ;;;
;;;;;;;;;;;;;;;;;;

(define-condition minor-mode-error (error) ())

(define-condition minor-mode-enable-error (minor-mode-error)
  ((mode :initarg :mode :reader minor-mode-enable-error-mode)
   (object :initarg :object :reader minor-mode-enable-error-object)
   (reason :initarg :reason :reader minor-mode-enable-error-reason))
  (:report
   (lambda (c s)
     (format s "Unable to enable minor mode ~A in object ~A.~%Reason: ~A"
             (minor-mode-enable-error-mode c)
             (minor-mode-enable-error-object c)
             (minor-mode-enable-error-reason c)))))

(define-condition minor-mode-disable-error (minor-mode-error)
  ((mode :initarg :mode :reader minor-mode-disable-error-mode)
   (object :initarg :object :reader minor-mode-disable-error-object)
   (reason :initarg :reason :reader minor-mode-disable-error-reason))
  (:report
   (lambda (c s)
     (format s "Unable to disable minor mode ~A in object ~A.~%Reason: ~A"
             (minor-mode-disable-error-mode c)
             (minor-mode-disable-error-object c)
             (minor-mode-disable-error-reason c)))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Minor Mode Protocol ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defgeneric minor-mode-global-p (minor-mode-symbol)
  (:documentation "Return T when MINOR-MODE-SYMBOL denotes a global minor mode")
  (:method (mode) (declare (ignore mode)) nil))

(defgeneric minor-mode-scope (minor-mode-symbol)
  (:documentation "Return as a keyword the scope of the minor mode"))

(defgeneric minor-mode-keymap (minor-mode)
  (:method (minor-mode) nil)
  (:documentation "Return the top map for the minor mode"))

(defgeneric minor-mode-lighter (mode)
  (:method (minor-mode) nil)
  (:method :around (mode)
    (format nil "~{~A~^ ~}"
            (call-next-method)))
  (:documentation "Return a string of minor mode lighters."))

(defgeneric minor-mode-enable-hook (minor-mode-symbol)
  (:documentation
   "Returns the minor mode enable hook for a given minor mode symbol. This hook is
run whenever the minor mode is enabled via autoenable."))

(defmethod no-applicable-method ((f (eql #'minor-mode-enable-hook)) &rest rest)
  (declare (ignore f rest))
  nil)

(defgeneric minor-mode-disable-hook (minor-mode-symbol)
  (:documentation
   "Returns the minor mode disable hook for a given minor mode symbol.  This hook
is run whenever the minor mode is disabled via autodisable."))

(defmethod no-applicable-method ((f (eql #'minor-mode-disable-hook)) &rest rest)
  (declare (ignore f rest))
  nil)

(defgeneric minor-mode-hook (minor-mode-symbol)
  (:documentation
   "Returns the minor mode hook for a given minor mode symbol. This hook is run
whenever the minor mode is explicitly enabled."))

(defmethod no-applicable-method ((f (eql #'minor-mode-hook)) &rest rest)
  (declare (ignore f rest))
  nil)

(defgeneric minor-mode-destroy-hook (minor-mode-symbol)
  (:documentation
   "Returns the minor mode hook for a given minor mode symbol. This hook is run
whenever the minor mode is explicitly disabled."))

(defmethod no-applicable-method ((f (eql #'minor-mode-destroy-hook)) &rest rest)
  (declare (ignore f rest))
  nil)

(defun run-hook-for-minor-mode (hook minor-mode object &optional invert-order)
  "Run a specific minor mode hook for the minor mode and all of its superclasses
which have such a hook defined. HOOK must be a function which takes a symbol and
returns a list of functions. MINOR-MODE is a symbol to be passed to HOOK. OBJECT
is the minor mode object to pass to the hook functions. When INVERT-ORDER is T
the superclass hooks are run first."
  (labels ((run (mode)
             (let ((name (class-name mode))
                   (supers (sb-mop:class-direct-superclasses mode)))
               (when invert-order
                 (run-hook-with-args (funcall hook name) name object))
               (when supers
                 (mapc #'run supers))
               (unless invert-order
                 (run-hook-with-args (funcall hook name) name object)))))
    (run (find-class minor-mode))))

(defgeneric autoenable-minor-mode (mode object)
  (:documentation
   "The core of enabling minor modes within an object. Mixes the minor mode in to
the object"))

(defmethod no-applicable-method ((f (eql #'autoenable-minor-mode)) &rest rest)
  (declare (ignore f rest))
  nil)

(defgeneric autodisable-minor-mode (mode object)
  (:documentation
   "The core of disabling minor modes within an object. Calls the minor modes
on-disable function."))

(defmethod no-applicable-method ((f (eql #'autodisable-minor-mode)) &rest rest)
  (declare (ignore f rest))
  nil)

(defgeneric enable-when (mode object)
  (:documentation
   "Define methods for this generic function to control when the minor mode should
be enabled."))

(defmethod no-applicable-method ((f (eql #'enable-when)) &rest rest)
  (declare (ignore f rest))
  nil)

(defun disable-minor-mode (minor-mode &optional scope-object)
  "Disable MINOR-MODE in the relevant objects."
  (when (minor-mode-global-p minor-mode)
    (setf *active-global-minor-modes*
          (remove minor-mode *active-global-minor-modes*)))
  (let ((run-hook nil))
    (flet ((disable (object)
             (unless run-hook
               (run-hook-with-args *minor-mode-disable-hook* minor-mode object)
               (run-hook-for-minor-mode #'minor-mode-destroy-hook
                                        minor-mode
                                        object
                                        t))
             (when (and (autodisable-minor-mode minor-mode object)
                        (not run-hook))
               (setf run-hook object))))
      (mapc #'disable 
            (cond ((minor-mode-global-p minor-mode)
                   (append (funcall (scope-all-objects-function
                                     (minor-mode-scope minor-mode)))
                           (when scope-object
                             (list scope-object))))
                  (t (list (or scope-object
                               (funcall (scope-current-object-function
                                         (minor-mode-scope minor-mode))))))))))
  (minor-mode-sync-keys-hook-function))

(defun enable-minor-mode (minor-mode &optional scope-object)
  "Enable MINOR-MODE. If MINOR-MODE is global, then enable it in all relevant
objects. Otherwise enable it in the current object. If SCOPE-OBJECT is provided,
use SCOPE-OBJECT instead of the current object, or include it in the list of
current objects if MINOR-MODE is global"
  (when (minor-mode-global-p minor-mode)
    (pushnew minor-mode *active-global-minor-modes*))
  (let ((run-hook nil))
    (flet ((enable (object)
             (cond ((typep object minor-mode)
                    (restart-case 
                        (error 'minor-mode-enable-error :mode minor-mode
                                                        :object object
                                                        :reason 'already-enabled)
                      (continue () nil)))
                   ((autoenable-minor-mode minor-mode object)
                    (unless run-hook
                      (setf run-hook object))))))
      (mapc #'enable
            (cond ((minor-mode-global-p minor-mode)
                   (append (funcall (scope-all-objects-function
                                     (minor-mode-scope minor-mode)))
                           (when scope-object
                             (list scope-object))))
                  (t (list (or scope-object
                               (funcall (scope-current-object-function
                                         (minor-mode-scope minor-mode))))))))
      (when run-hook
        (run-hook-for-minor-mode #'minor-mode-hook minor-mode run-hook)
        (run-hook-with-args *minor-mode-enable-hook* minor-mode run-hook))))
  (minor-mode-sync-keys-hook-function))


;;;;;;;;;;;;;;;;;;;;;;;;
;;; Find Minor Modes ;;;
;;;;;;;;;;;;;;;;;;;;;;;;

(defun sync-minor-modes (object)
  "Sync the globally active minor modes in the object"
  (loop for class in *active-global-minor-modes*
        when (typep object (scope-type (minor-mode-scope class)))
          do (autoenable-minor-mode class object)))

(defun sync-all-minor-modes ()
  "Loop through all recently created objects and ensure that the appropriate minor
modes are enabled in them, then nullify the list of objects."
  ;; This functions is needed because calling autoenable-minor-mode from within
  ;; a method that accesses slots is implied to be undefined behavior, so we
  ;; cant do this from within initialize-instance.
  (let ((objects (prog1 (swm-class-new-objects (current-screen))
                   (setf (swm-class-new-objects (current-screen)) nil))))
    (when (and objects *active-global-minor-modes*)
      (loop for object in objects
            do (sync-minor-modes object)))))

(defun replace-class-and-sync (object new-class &rest initargs)
  "Replaces the main class in OBJECT with the new class, and then syncs all minor
modes."
  (apply #'dynamic-mixins:replace-class object new-class initargs)
  (sync-minor-modes object))

;; (defmethod change-class :after ((object swm-class) new-class &rest rest)
;;   (declare (ignore new-class rest))
;;   (sync-minor-modes object))

;; (defparameter *my-tracker* nil)

;; (defmethod change-class :after (object (new-class standard-class) &rest rest)
;;   (declare (ignore rest))
;;   (labels ((class-search (subclass)
;;              (loop for class in (sb-mop:class-direct-superclasses subclass)
;;                    when (or (eql (class-name class) 'swm-class)
;;                             (class-search class))
;;                      do (setf *my-tracker* object)
;;                         (sync-minor-modes object)
;;                         (return-from class-search nil))))
;;     (class-search new-class)))

;; (defmethod change-class :after (object (new-class swm-class) &rest rest)
;;   (declare (ignore rest))
;;   (setf *my-tracker* (class-of object))
;;   (sync-minor-modes object))

(defun list-modes (object)
  "List all minor modes followed by the major mode for OBJECT."
  (sync-all-minor-modes)
  (when (typep object 'dynamic-mixins:mixin-object)
    (mapcar #'class-name (dynamic-mixins:mixin-classes (class-of object)))))

(defun list-minor-modes (object)
  "List all minor modes active in OBJECT"
  (butlast (list-modes object)))

(defun list-mode-objects (&optional (sync t))
  (when sync
    (sync-all-minor-modes))
  (let* ((screens (sort-screens))
         (groups (loop for screen in screens
                       append (screen-groups screen)))
         (heads (loop for screen in screens
                      append (screen-heads screen)))
         (frames (loop for group in groups
                       when (typep group 'tile-group)
                         append (flatten (tile-group-frame-tree group))))
         (windows (loop for group in groups
                        append (group-windows group))))
    (append windows frames heads groups screens (list *unscoped-minor-modes*))))

(defun list-current-mode-objects (&key (screen (current-screen)))
  (sync-all-minor-modes)
  (let* ((group (current-group screen))
         (head (current-head group))
         (frame (when (typep group 'tile-group)
                  (tile-group-current-frame group)))
         (window (group-current-window group)))
    (if frame
        (list window frame head group screen *unscoped-minor-modes*)
        (list window head group screen *unscoped-minor-modes*))))

(defcommand current-minor-modes (&optional (screen (current-screen))) ()
  "Return all currently active minor modes."
  (let ((modes (mapcan #'list-minor-modes
                       (list-current-mode-objects :screen screen))))
    (prog1 modes 
      (when %interactivep%
        (message "~{~A~^~%~}" (or modes '("No active minor modes")))))))

(defcommand enabled-minor-modes () ()
  "Return all enabled minor modes, with duplicates removed."
  (let ((modes (remove-duplicates (mapcan #'list-minor-modes
                                          (list-mode-objects)))))
    (prog1 modes
      (when %interactivep%
        (message "~{~A~^~%~}" (or modes '("No active minor modes")))))))

(defun minor-mode-enabled-p (minor-mode &optional (screen (current-screen)))
  "Return T if MINOR-MODE is active"
  (check-type minor-mode symbol)
  (if (minor-mode-global-p minor-mode)
      (member minor-mode *active-global-minor-modes*)
      (member minor-mode (append (current-minor-modes screen)))))

(defun find-minor-mode (minor-mode &optional (screen (current-screen)))
  "Return the minor mode object associated with MINOR-MODE."
  (check-type minor-mode symbol)
  (flet ((ct (o)
           (and (typep o minor-mode) o)))
    (let ((group (current-group screen)))
      (or (ct *unscoped-minor-modes*)
          (ct screen)
          (ct group)
          (ct (current-head group))
          (ct (when (typep group 'tile-group)
                (tile-group-current-frame group)))
          (ct (group-current-window group))))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Activep and Top Maps ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun minor-mode-command-active-p (group command)
  (find-minor-mode (command-class command) (group-screen group)))

(push #'minor-mode-command-active-p *custom-command-filters*)

(defun minor-mode-top-maps (group)
  "Return a list of all minor mode top maps."
  (apply #'append
         (mapcar #'minor-mode-keymap
                 (list-current-mode-objects :screen (group-screen group)))))

;;;;;;;;;;;;;;;;;;;;;;;;
;;; Helper Functions ;;;
;;;;;;;;;;;;;;;;;;;;;;;;

(defun generate-keymap (keymap-spec &optional
                                      (top-map (stumpwm:make-sparse-keymap))
                                      (filter-bindings #'identity))
  "Generate a (potentially nested) keymap based on KEYMAP. KEYMAP is a list of
keymap specs, where each spec is a cons cell containing an input sequence and
something to bind it to. The input sequence is a string representing an
arbitrary sequence of keys, eg \"C-x C-s\". The thing to bind it to is an
arbitrary thing which will be passed to FILTER-BINDINGS, which defaults to
#'identity. TOP-MAP is the keymap to bind everything in, and defaults to an
empty keymap."
  (let* ((topmap top-map)
         (curmap topmap)
         (keymap keymap-spec))
    (flet
        ((create-keymap-binding (keys)
           (let ((in-seq (car keys))
                 (bind-to (cdr keys)))
             (labels
                 ((bind-it (key &optional to)
                    (cond (to (stumpwm:define-key curmap (stumpwm:kbd key) to))
                          (t (stumpwm:define-key curmap (stumpwm:kbd key)
                               (funcall filter-bindings bind-to)))))
                  (attempt-binding (key rest bind seq)
                    (cond
                      ((and bind (stumpwm::kmap-p bind))
                       (if (null rest)
                           (restart-case
                               (error "~A in ~A is already bound to a keymap"
                                      (stumpwm::print-key (stumpwm:kbd key)) seq)
                             (keep-binding ()
                               :report "Keep the current binding"
                               nil)
                             (replace-binding ()
                               :report (lambda (s)
                                         (format s "Replace with binding ~A"
                                                 bind-to))
                               (bind-it key)))
                           (setf curmap bind)))
                      (bind
                       (restart-case (error "~S in ~S is already bound to ~A"
                                            (stumpwm::print-key (stumpwm:kbd key))
                                            seq
                                            bind)
                         (replace-binding ()
                           :report
                           (lambda (s)
                             (format s "Replace with binding ~A"
                                     (if (null rest)
                                         bind-to
                                         (format nil "the keymap ~{~A~^ ~}"
                                                 rest))))
                           (bind-it key))))
                      ((null rest)
                       (bind-it key))
                      (t (let ((m (stumpwm:make-sparse-keymap)))
                           (bind-it key m)
                           (setf curmap m)))))
                  (traverse-and-bind (seq)
                    (loop for (key . rest) on (cl-ppcre:split " " seq)
                          do (let ((bind (stumpwm:lookup-key curmap
                                                             (stumpwm:kbd key))))
                               (attempt-binding key rest bind seq)))))
               (if (not (or (symbolp bind-to)
                            (stringp bind-to)
                            (functionp bind-to)))
                   (restart-case (error "Invalid binding ~A" bind-to)
                     (bind-anyway ()
                       :report "Bind the key binding regardless"
                       (traverse-and-bind in-seq))
                     (skip-binding ()
                       :report "skip this binding"
                       nil))
                   (traverse-and-bind in-seq))))))
      (cond ((null keymap)
             topmap)
            ((or (symbolp keymap)
                 (stumpwm::kmap-p keymap))
             keymap)
            ((listp keymap)
             (restart-case (mapc (lambda (keys)
                                   (create-keymap-binding keys)
                                   (setf curmap topmap))
                                 keymap)
               (abort-bindings ()
                 :report "Return the keymap without binding further keys"
                 topmap)
               (abort-bindings* ()
                 :report "Return an empty keymap"
                 (stumpwm:make-sparse-keymap)))
             topmap)
            (t (restart-case
                   (error "Function MAKE-MINOR-MODE-KEYMAP cant understand ~A"
                          keymap)
                 (use-empty-keymap ()
                   :report "Use an empty keymap"
                   (stumpwm:make-sparse-keymap))))))))

(defun make-minor-mode-keymap (spec)
  (generate-keymap spec))

(defun make-minor-mode-top-map (top-map-spec root-map-spec)
  "Create a top map for a minor mode based upon its TOP-MAP-SPEC and
ROOT-MAP-SPEC."
  (let ((top-map nil)
        (root-map (if root-map-spec
                      (make-minor-mode-keymap root-map-spec)
                      (make-sparse-keymap))))
    (fill-keymap top-map *escape-key* root-map)
    (generate-keymap top-map-spec top-map)))


(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun make-special-variable-name (mode name)
    (intern (format nil "*~A-~A*" mode name)))
  
  (defun parse-minor-mode-options (options)
    (let ((valid-options
            '((:interactive            1)
              (:scope                  1)
              (:global                 1)
              (:lighter-make-clickable 1)
              (:lighter                1)
              (:expose-keymaps         1)
              (:root-map               1)
              (:top-map                1)
              (:enable-when            t)
              (:make-hooks             1)
              (:default-initargs       t)
              (:define-command-definer 1)))
          (all-vals '())
          (other-opts '()))
      (flet ((collect-values (option)
               (let ((argcount (cadr (assoc (car option) valid-options))))
                 (if argcount
                     (progn (if (and (numberp argcount)
                                     (= argcount 1))
                                (push (cadr option) all-vals)
                                (push (cdr option) all-vals))
                            (push (car option) all-vals))
                     (push option other-opts)))))
        (mapc #'collect-values options)
        (values all-vals other-opts))))

  (defun define-command-macro (mode)
    `(defmacro ,(intern (string-upcase (format nil "define-~A-command" mode)))
         (name (&rest args) (&rest interactive-args) &body body)
       (multiple-value-bind (bod decls docstring)
           (parse-body body :documentation t)
         `(defcommand (,name ,',mode) ,args ,interactive-args
            ,@(when docstring
                `(,docstring))
            ,@decls 
            (let ((*minor-mode* (find-minor-mode ',',mode (current-screen))))
              ,@bod)))))
  
  (defun define-enable-methods (mode scope hooks-defined globalp)
    (declare (ignorable mode scope hooks-defined globalp))
    (let ((optarg (get-scope scope)))
      `((defmethod autoenable-minor-mode ((mode (eql ',mode)) (obj ,mode))
          (signal 'minor-mode-enable-error :mode ',mode
                                           :object obj
                                           :reason 'already-enabled))
        (defmethod autoenable-minor-mode ((mode (eql ',mode)) (obj ,(car optarg)))
          (when (and ,@(unless (eql (third optarg) (first optarg))
                         ;; Check if the filter type is the same as the class
                         ;; type, and if not then explicitly check if the object
                         ;; conforms to that type.
                         `((typep obj ',(third optarg))))
                     (enable-when mode obj))
            (prog1 (dynamic-mixins:ensure-mix obj ',mode)
              (run-hook-for-minor-mode #'minor-mode-enable-hook
                                       ',mode
                                       obj))))
        (defmethod autodisable-minor-mode ((mode (eql ',mode)) (obj ,mode))
          (run-hook-for-minor-mode #'minor-mode-disable-hook ',mode obj t)
          (dynamic-mixins:delete-from-mix obj ',mode)))))

  (defun genlighter (mode lighter)
    (cond ((null lighter)
           (flet ((nullgen (s l)
                    (mapcar (lambda (e)
                              (if (or (string-equal e "mode") (< (length e) l))
                                  e
                                  (subseq e 0 l)))
                            s)))
             `(lambda (mode)
                (declare (ignore mode))
                ,(let ((split (remove-if (lambda (s) (string= s ""))
                                         (cl-ppcre:split "-" (symbol-name mode)))))
                   (format nil "~{~A~^-~}" (case (length split)
                                             ((1) split)
                                             ((2) (nullgen split 3))
                                             ((3) (nullgen split 2))
                                             (otherwise (nullgen split 1))))))))
          ((stringp lighter)
           `(lambda (mode)
              (declare (ignore mode))
              ,lighter))
          (t
           (when (or (symbolp lighter)
                     (and (listp lighter)
                          (not (or (eql (car lighter) 'lambda)
                                   (eql (car lighter) 'function)))))
             (warn "Assuming ~A is funcallable" lighter))
           lighter)))

  (defun define-hooks (mode)
    `((defvar ,(make-special-variable-name mode 'enable-hook) nil
        ,(format nil
"A hook run when enabling ~A, called with the mode symbol and the scope object."
                 mode))
      (defvar ,(make-special-variable-name mode 'disable-hook) nil
        ,(format nil
"A hook run when disabling ~A, called with the mode symbol and the scope
object. This hook is run when ~A is disabled in an object, however if an object
goes out of scope before a minor mode is disabled then this hook will not be run
for that object."
                 mode mode))
      (defvar ,(make-special-variable-name mode 'hook) nil
        ,(format nil
"A hook run when explicitly enabling ~A, called with the mode symbol and the
scope object."
                 mode))
      (defvar ,(make-special-variable-name mode 'destroy-hook) nil
        ,(format nil
"A hook run when explicitly disabling ~A, called with the mode symbol and the
scope object."
                 mode))
      (defmethod minor-mode-enable-hook ((mode (eql ',mode)))
        (declare (ignore mode))
        ,(make-special-variable-name mode 'enable-hook))
      (defmethod (setf minor-mode-enable-hook) (new (mode (eql ',mode)))
        (declare (ignore mode))
        (setf ,(make-special-variable-name mode 'enable-hook) new))
      (defmethod minor-mode-disable-hook ((mode (eql ',mode)))
        (declare (ignore mode))
        ,(make-special-variable-name mode 'disable-hook))
      (defmethod (setf minor-mode-disable-hook) (new (mode (eql ',mode)))
        (declare (ignore mode))
        (setf ,(make-special-variable-name mode 'disable-hook) new))
      (defmethod minor-mode-hook ((mode (eql ',mode)))
        (declare (ignore mode))
        ,(make-special-variable-name mode 'hook))
      (defmethod (setf minor-mode-hook) (new (mode (eql ',mode)))
        (declare (ignore mode))
        (setf ,(make-special-variable-name mode 'hook) new))
      (defmethod minor-mode-destroy-hook ((mode (eql ',mode)))
        (declare (ignore mode))
        ,(make-special-variable-name mode 'destroy-hook))
      (defmethod (setf minor-mode-destroy-hook) (new (mode (eql ',mode)))
        (declare (ignore mode))
        (setf ,(make-special-variable-name mode 'destroy-hook) new)))))


;;;;;;;;;;;;;;;;;;;;;;;;;
;;; Minor Mode Scopes ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *minor-mode-scopes* (make-hash-table)
    "Store the scope supertypes and object retrieval functions for a scope")
  (defun add-minor-mode-scope
      (designator type current-object-thunk &optional filter-type)
    "Add a list of the TYPE, CURRENT-OBJECT-THUNK, and ALL-OBJECTS-THUNK, under
DESIGNATOR in the minor mode scope hash table."
    (setf (gethash designator *minor-mode-scopes*)
          (list type current-object-thunk (or filter-type type))))
  (defun get-scope (designator)
    (multiple-value-bind (value foundp)
        (gethash designator *minor-mode-scopes*)
      (if foundp
          value
          (error "Invalid scope designator ~A" designator))))
  (defun scope-type (designator)
    (first (get-scope designator)))
  (defun scope-filter-type (designator)
    (third (get-scope designator)))
  (defun scope-current-object-function (designator)
    (cadr (get-scope designator)))
  (defun scope-all-objects-function (designator)
    (let ((type (first (get-scope designator))))
      (lambda ()
        (loop for object in (list-mode-objects nil)
              when (typep object type)
                collect object))))
  (defun find-active-global-minor-modes-for-scope (scope)
    (loop for mode in *active-global-minor-modes*
          when (eql scope (minor-mode-scope mode))
            collect mode)))

(defgeneric validate-superscope (scope superscope)
  (:documentation
   "A generic function for explicitly allowing a scope to descend from an
otherwise invalid superscope."))

(defmethod no-applicable-method ((f (eql #'validate-superscope)) &rest r)
  (declare (ignore f r))
  (values nil nil))

(defun superclassp (class superclass)
  (check-type class symbol)
  (check-type superclass symbol)
  (let ((s (find-class superclass))
        (superclasses (sb-mop:class-direct-superclasses (find-class class))))
    (loop for super in superclasses
          when (or (eq super s)
                   (superclassp (class-name super) superclass))
            do (return-from superclassp t))))

(defun validate-scope (scope superclasses &key (errorp t))
  "Validate a scope for a set of superclasses. SCOPE must be a designator as
defined with define-minor-mode-scope, and superclasses should be the list of
superclasses for a minor mode being defined with a scope of SCOPE. When ERRORP
is T then an error is signalled when an invalid superscope is encountered. If it
is NIL the NIL is returned instead. Upon success a list of conses is returned
where the car is the scope designator and the cdr is the class with that scope."
  (flet ((doerror (scope superscope type)
           (if errorp
               (error "~S is not a valid subscope of ~S from class ~A"
                      scope superscope type)
               (return-from validate-scope nil))))
    (let ((scopetype (scope-type scope))
          (superscopes (mapcar (lambda (el)
                                 (cons 
                                  (ignore-errors (minor-mode-scope el))
                                  el))
                               superclasses)))
      (mapc (lambda (superscope)
              (when (car superscope)
                (multiple-value-bind (valid invalid)
                    (validate-superscope scope (car superscope))
                  (or (and invalid
                           (doerror scope (car superscope) (cdr superscope)))
                      valid
                      (eql scopetype (scope-type (car superscope)))
                      (superclassp scopetype (scope-type (car superscope)))
                      (doerror scope (car superscope) (cdr superscope))))))
            superscopes))))

(defun validate-minor-mode-superclasses (superclasses)
  (flet ((validate (class)
           (when (or (eq class 'swm-class)
                     (superclassp class 'swm-class))
             (error "The class ~A is not a valid superclass for minor modes~%as it descends from SWM-CLASS"
                    class))))
    (mapc #'validate superclasses)))


(defmacro define-minor-mode-scope
    ((designator class &optional filter-type) &body retrieve-current-object)
  "Define a minor mode scope for use with DEFINE-MINOR-MODE.  This generates a
call to ADD-MINOR-MODE-SCOPE which is evaluated when compiled, loaded, or
executed. DESIGNATOR should be a keyword and TYPE should denote a class, while
FILTER-TYPE should denote a general type. RETRIEVE-CURRENT-OBJECT should be a
thunk body which returns the current object for this scope."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (add-minor-mode-scope ,designator
                           ',class
                           (lambda () ,@retrieve-current-object)
                           ,@(when filter-type
                               `(',filter-type)))))

(defmacro define-descended-minor-mode-scope (designator parent
                                             &key class filter-type
                                               retrieve-current-object)
  "Define a descended scope which inherits the parents type and functions unless
provided."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (add-minor-mode-scope ,designator
                           ,@(if class
                                 `(',class)
                                 `((scope-type ,parent)))
                           ,(if retrieve-current-object
                                `(lambda ()
                                   ,retrieve-current-object)
                                `(scope-current-object-function ,parent))
                           ,@(when filter-type
                               `(',filter-type)))))

(define-minor-mode-scope (:unscoped unscoped-modes)
  *unscoped-minor-modes*)

(define-minor-mode-scope (:screen screen)
  (current-screen))

(define-minor-mode-scope (:group group)
  (current-group))

(define-minor-mode-scope (:tile-group tile-group)
  (current-group))

(define-minor-mode-scope (:float-group float-group)
  (current-group))

(define-minor-mode-scope (:dynamic-group dynamic-group)
  (current-group))

(defun %manual-tiling-group-p (g)
  (and (typep g 'tile-group)
       (not (typep g 'dynamic-group))))

(define-minor-mode-scope (:manual-tiling-group tile-group
                                               (satisfies %manual-tiling-group-p))
  (current-group))

(define-minor-mode-scope (:frame frame)
  (let ((g (current-group)))
    (when (typep g 'tile-group)
      (tile-group-current-frame g))))

(define-minor-mode-scope (:head head)
  (current-head))

(defun %frame-but-not-head (o)
  (and (typep o 'frame)
       (not (typep o 'head))))

(define-descended-minor-mode-scope :frame-excluding-head :frame
  :filter-type (satisfies %frame-but-not-head))

(define-minor-mode-scope (:window window)
  (current-window))

(define-minor-mode-scope (:tile-window tile-window)
  (current-window))

(define-minor-mode-scope (:float-window float-window)
  (current-window))


(defmacro define-minor-mode (mode superclasses slots &rest options)
  "Define a minor mode as a class to be instantiated when the minor mode is
activated. Minor modes are dynamically mixed in to and out of the appropriate
object when they are enabled or disabled.

If @var{SUPERCLASSES} is not provided a default superclass of MINOR-MODE will be
provided. @var{OPTIONS} may include all normal options when defining a class,
with the addition of the following options:

@itemize
@item
(:SCOPE SCOPE-DESIGNATOR)@*
The :SCOPE option determines what object(s) the minor mode can be mixed in
with. New scopes can be defined with the macro DEFINE-MINOR-MODE-SCOPE.

@item
(:GLOBAL (OR T NIL))@*
When true the :GLOBAL option changes the way enable methods are defined to track
the minor mode and autoenable it in all existing scope objects, as well as
autoenabled when new scope objects are instantiated.

@item
(:TOP-MAP spec)@*
The minor modes top map is created based upon the provided spec, which must be a
list of cons cells whose car is a key sequence and whose cdr is a binding. For
example: @code{(list (cons \"C-m x\" \"echo\"))}. This would bind the key
sequence @kbd{C-m x} to the echo command. A reference to this keymap is stored
as a slot in the minor mode object and can be accessed via the reader
@code{MODE-KEYMAP} where @code{MODE} is the minor mode name.

@item
(:ROOT-MAP spec)@*
The minor modes root map is created based upon the provided spec. The spec is as
described in the :TOP-MAP option.

@item
(:EXPOSE-KEYMAPS (OR T NIL))@*
This value is used at macroexpansion time to determine whether or not to
generate keymap variables or store the keymap within the object. When T the
variables *MODE-TOP-MAP* and *MODE-ROOT-MAP* will be generated. 

@item
(:LIGHTER T)@*
The :LIGHTER option will be used to generate a function returning a string to
display in the mode line. When :LIGHTER is NULL a string is generated based upon
the mode name. When it is a string that string is used as is. Otherwise :LIGHTER
will assumed to be funcallable and used as is. When it is a symbol or a list
that doesn't begin with LAMBDA or FUNCTION a warning is issued that
DEFINE-MINOR-MODE is assuming it is funcallable. When assumed to be funcallable,
it is called with the mode object as its only argument.

@item
(:LIGHTER-MAKE-CLICKABLE (OR T NIL))@*
When :LIGHTER-MAKE-CLICKABLE is T then the :LIGHTER is wrapped in a call to
FORMAT-WITH-ON-CLICK-ID, called with the id :ML-ON-CLICK-MINOR-MODE and the mode
as a quoted symbol. 

@item
(:INTERACTIVE (OR SYMBOL T NIL))@*
The :INTERACTIVE option determines whether a command to toggle the minor mode on
and off is generated. If it is T then a command with the same name as the minor
mode is generated. If it is a symbol then that symbol will be used when defining
the command.

@item
(:ENABLE-WHEN (MODE OBJECT) &BODY BODY)@*
When provided, the :ENABLE-WHEN option generates a method for the enable-when
generic function. MODE is bound to the mode symbol, and OBJECT is bound to the
scope object. If this is not provided, a method is generated which returns T for
the minor mode and its scope. If it is provided and is nil, then no method is
generated and a method for ENABLE-WHEN which dispatches upon the mode as a
symbol and the scope type for the minor mode must be manually defined.

@item
(:MAKE-HOOKS (OR T NIL))@*
When :MAKE-HOOKS is T a set of hook variables are generated. These variables are
fourfold: *MODE-HOOK* is run after explicitly enabling the minor
mode. *MODE-ENABLE-HOOK* is run when the minor mode is
autoenabled. *MODE-DISABLE-HOOK* is run when the minor mode is
autodisabled. Finally *MODE-DESTROY-HOOK* is run when the minor mode is
explicitly disabled. 

@item
(:DEFINE-COMMAND-DEFINER (OR T NIL))@*
When :DEFINE-COMMAND-DEFINER is T a macro is defined for defining commands that
are active only when the minor mode is active. Commands defined with this macro
have the special variable *MINOR-MODE* bound to the minor mode object in their
body. The generated macro is called DEFINE-MODE-COMMAND. This option defaults to
T. 
@end itemize

Example:
@verbatim
(define-minor-mode evil-mode () ()
  (:scope :screen)
  (:top-map '((\"j\" . \"move-focus down\")
              (\"k\" . \"move-focus up\")
              (\"h\" . \"move-focus left\")
              (\"l\" . \"move-focus right\")
              (\"x\" . *exchange-window-map*)
              (\"C-m b\" . \"evil-echo\")))
  (:lighter \"EVIL\")
  (:lighter-make-clickable nil))

(define-evil-mode-command evil-echo () ()
  (run-commands \"echo\"))
@end verbatim
"
  (when (null superclasses)
    (setq superclasses '(minor-mode)))
  (multiple-value-bind (mm-opts other-opts)
      (parse-minor-mode-options options)
    (destructuring-bind (&key top-map root-map (expose-keymaps t)
                           lighter lighter-make-clickable
                           (scope :unscoped) interactive global
                           (enable-when nil ewpp)
                           (make-hooks t) (define-command-definer t)
                           default-initargs)
        mm-opts
      (with-gensyms (gmode gkeymap)
        `(progn
           ;; Ensure that the superclasses are valid for a minor mode. 
           (validate-minor-mode-superclasses ',superclasses)

           ;; Ensure that SCOPE is a valid scope for the superclass list.
           (validate-scope ,scope ',superclasses)

           ,@(when expose-keymaps 
               `((defvar ,(make-special-variable-name mode 'root-map)
                     (make-minor-mode-keymap ,root-map)
                   ,(format nil "The root map for ~A" mode))
                 (defvar ,(make-special-variable-name mode 'top-map)
                     (make-minor-mode-top-map
                      ,top-map
                      ',(make-special-variable-name mode 'root-map))
                     ,(format nil "The top map for ~A" mode))))

           (defclass ,mode ,superclasses
             ((,gkeymap
               :initform ,@(if expose-keymaps
                               `(',(make-special-variable-name mode 'top-map))
                               `((make-minor-mode-top-map
                                  ',top-map
                                  (make-minor-mode-keymap ',root-map))))
               :reader ,(intern (format nil "~A-KEYMAP" mode))
               :allocation :class)
              ,@slots)
             (:default-initargs ,@default-initargs)
             ,@other-opts)

           ,@(when global 
               `((defmethod minor-mode-global-p ((mode (eql ',mode))) t)))

           (defmethod minor-mode-lighter ((,gmode ,mode))
             (cons
              ,(if lighter-make-clickable
                   `(format-with-on-click-id (funcall ,(genlighter mode lighter)
                                                      ,gmode)
                                             :ml-on-click-minor-mode
                                             ',mode)
                   `(funcall ,(genlighter mode lighter) ,gmode))
              (call-next-method)))

           (defmethod minor-mode-scope ((,gmode (eql ',mode)))
             (declare (ignore ,gmode))
             ,scope)

           ,@(when make-hooks
               (define-hooks mode))

           (defmethod minor-mode-keymap ((,gmode ,mode))
             (cons (slot-value ,gmode ',gkeymap) (call-next-method)))

           ,@(cond (enable-when
                    (let ((args (car enable-when))
                          (body (cdr enable-when)))
                      `((defmethod enable-when ((,(car args) (eql ',mode))
                                                (,(cadr args) ,(scope-type scope)))
                          ,@body))))
                   (ewpp nil)
                   (t `((defmethod enable-when ((mode (eql ',mode))
                                                (obj ,(scope-type scope)))
                          t))))

           ,@(define-enable-methods mode scope make-hooks global)

           ,@(when interactive
               `((defcommand ,(cond ((eq interactive t) mode)
                                    (t interactive))
                     (&optional (yn nil ynpp)) ((:y-or-n))
                   (flet ((enable () (enable-minor-mode ',mode))
                          (disable () (disable-minor-mode ',mode)))
                     (cond (yn (enable))
                           (ynpp (disable))
                           ((minor-mode-enabled-p ',mode) (disable))
                           (t (enable)))))))

           ,@(when define-command-definer
               (list (define-command-macro mode))))))))

(defun dynamic-mixins::dformat (&rest r)
  (apply #'dformat r))
