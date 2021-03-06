;;;; libfann
(in-package :fann)

(defclass neural-network ()
  ((raw-pointer :initform nil
		:initarg :raw-pointer)
   (num-inputs :initarg :num-inputs)
   (num-outputs :initarg :num-outputs)))

(defmethod print-object ((object neural-network) stream)
  (with-slots (num-inputs num-outputs) object
    (print-unreadable-object (object stream :type t :identity t)
      (format stream "~A,~A" num-inputs num-outputs)))
  object)

(defun %make-neural-network (pointer)
  "Create a neural network from a raw pointer"
  (let* ((nn (make-instance 'neural-network 
			    :raw-pointer pointer
			    :num-inputs (fann-get-num-input pointer)
			    :num-outputs (fann-get-num-output pointer))))
    (tg:finalize nn
		 #'(lambda () (fannint:fann-destroy pointer)))
    nn))

(defun sequence->foreign-array (seq type)
  "Convert a sequence or an single element to a foreign array"
  (if (or (vectorp seq) (listp seq))
      (cffi:foreign-alloc type :initial-contents seq)
      (cffi:foreign-alloc type :initial-element seq)))

(defmacro with-sequence-as-foreign-array ((&rest var-sequence-type-triples) &body body)
  `(let ,(%map-nth-list #'(lambda (vst-rest)
			    (let ((var (first vst-rest))
				  (sequence (second vst-rest))
				  (type (third vst-rest)))
			      `(,var (sequence->foreign-array ,sequence ,type))))
			3 var-sequence-type-triples)
     (unwind-protect 
	  (progn ,@body)
       ,@(%map-nth-list #'(lambda (v-rest) `(cffi:foreign-free ,(first v-rest)))
			3 var-sequence-type-triples))))

(define-condition neural-network-error (error)
  ((message :initarg :message)))

(defun create-neural-network (layer-sizes &key (connection-rate 0.1) (type :standard))
  "Create a neural network. :TYPE must be one of :STANDARD, :SPARSE, or :SHORTCUT. 
:CONNECTION-RATE rate is used only for :SPARSE matrices."
  (with-sequence-as-foreign-array (layers layer-sizes :int)
    (let ((num-layers (length layer-sizes)))
      (%make-neural-network
       (ecase type
	 (:standard
	  (fann-create-standard-array num-layers layers))
	 (:sparse
	  (fann-create-sparse-array connection-rate num-layers layers))
	 (:shortcut
	  (fann-create-shortcut-array num-layers layers)))))))

(defun run (nn input)
  "Run the neural network NN on a sequence INPUT."
  (with-sequence-as-foreign-array (input-array input 'fann-internal:fann-type)
    (let ((output (fann-internal:fann-run (slot-value nn 'raw-pointer) input-array)))
      (loop for i from 0 to (1- (slot-value nn 'num-outputs))
	 collecting (cffi:mem-aref output 'fann-internal:fann-type i)))))


(defmacro define-nn-accessor (name)
  `(progn
     (define-nn-get-accessor ,name)
     (define-nn-set-accessor ,name)))

(defmacro define-nn-accessors (&rest names)
  `(progn
     (define-nn-get-accessors ,@names)
     (define-nn-set-accessors ,@names)))

(defmacro define-nn-get-accessor (name)
  "Define the function for accessing a specific parameter of the neural network"
  (let ((internal-get (intern (format nil "FANN-GET-~A" name))))
    (with-gensyms (nn-var rest)
      `(defun ,name (,nn-var &rest ,rest)
	 (apply (function ,internal-get) (%pointer ,nn-var) ,rest)))))

(defmacro define-nn-get-accessors (&rest names)
  `(progn 
     ,@(mapcar #'(lambda (name) `(define-nn-get-accessor ,name))
	       names)))

(defmacro define-nn-set-accessor (name)
  "Define a setf macro for setting values for parameters of the neural network"
  (let ((internal-set (intern (format nil "FANN-SET-~S" name)))
	(generated-set (intern (format nil "%~A" name))))
    (with-gensyms (nn-var rest value)
      `(progn 
	 (defun ,generated-set (,nn-var ,value &rest ,rest)
	   (apply (function ,internal-set) (%pointer ,nn-var) (append ,rest (list ,value)))
	   ,value)
	 (defsetf ,name ,generated-set)))))

(defmacro define-nn-set-accessors (&rest names)
  `(progn ,@(mapcar #'(lambda (name)
			`(define-nn-set-accessor ,name))
		    names)))

;;; write-only accessors
(define-nn-set-accessors activation-function-hidden activation-function-output
  activation-steepness-hidden activation-steepness-output
  activation-function-layer activation-steepness-layer)

;;; read-only accessors
(define-nn-get-accessors num-input num-output total-neurons total-connections)

;;; read/write accessors
(define-nn-accessors training-algorithm learning-rate learning-momentum 
  train-error-function train-stop-function 
  bit-fail-limit 
  quickprop-decay quickprop-mu 
  rprop-increase-factor rprop-decrease-factor rprop-delta-min rprop-delta-max)

(defun %pointer (nn)
  (slot-value nn 'raw-pointer))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; I/O
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun load-ann-from-file (pathname)
  "Load a neural network previously saved at PATHNAME"
  (cffi:with-foreign-string (config-filename (namestring pathname))
    (%make-neural-network
     (fann-create-from-file config-filename))))

(defun save-ann-to-file (nn pathname &optional fixed-point)
  "Save the neural network NN to a file specified by PATHNAME."
  (cffi:with-foreign-string (config-filename (namestring pathname))
    (if fixed-point
	(let ((rv (fann-save-to-fixed (%pointer nn) config-filename)))
	  (when (< rv 0)
	    (error 'neural-network-error 
		   :message "Could not save as fixed point"))
	  rv)
	(fann-save (%pointer nn) config-filename))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;; Training
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(defun randomize-weights (nn min-weight max-weight)
  "Randomize the weights of NN before training"
  (fann-randomize-weights (%pointer nn) min-weight max-weight))
