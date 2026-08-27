(vl-load-com)

;; This file expects zomo-common.lsp to be loaded first.
;; Static contract only: Task 9 must exercise these COM paths in an isolated DWG.

(defun zomo:alist-value (key values / pair)
  (if (and (zomo:alist-p values) (setq pair (assoc key values))) (cdr pair) nil))

(defun zomo:proper-list-p (value)
  (cond
    ((null value) t)
    ((atom value) nil)
    (t (zomo:proper-list-p (cdr value)))))

(defun zomo:alist-p (value)
  (and
    (zomo:proper-list-p value)
    (vl-every
      '(lambda (pair)
        (and pair
             (not (atom pair))
             (or (= (type (car pair)) 'SYM) (= (type (car pair)) 'STR))))
      value)))

(defun zomo:role-name (value)
  (strcase
    (cond
      ((= (type value) 'STR) value)
      ((= (type value) 'SYM) (vl-symbol-name value))
      (t ""))))

(defun zomo:role-count (role specs / count spec)
  (setq count 0)
  (foreach spec specs
    (if (= role (zomo:role-name (zomo:alist-value 'role spec)))
      (setq count (1+ count))))
  count)

(defun zomo:valid-three-view-specs-p (view-specs)
  (and
    (zomo:proper-list-p view-specs)
    (= 3 (length view-specs))
    (vl-every 'zomo:alist-p view-specs)
    (= 1 (zomo:role-count "FRONT" view-specs))
    (= 1 (zomo:role-count "SIDE" view-specs))
    (= 1 (zomo:role-count "PLAN" view-specs))))

(defun zomo:rect-center (rect)
  (list (/ (+ (nth 0 rect) (nth 2 rect)) 2.0)
        (/ (+ (nth 1 rect) (nth 3 rect)) 2.0)
        0.0))

(defun zomo:rect-width (rect) (- (nth 2 rect) (nth 0 rect)))
(defun zomo:rect-height (rect) (- (nth 3 rect) (nth 1 rect)))

(defun zomo:default-role-rect (role paper-rect / left bottom right top split-x split-y)
  (setq left (nth 0 paper-rect)
        bottom (nth 1 paper-rect)
        right (nth 2 paper-rect)
        top (nth 3 paper-rect)
        split-x (+ left (* 0.8 (- right left)))
        split-y (+ bottom (* 0.42 (- top bottom))))
  (cond
    ((= role "FRONT") (list left split-y split-x top))
    ((= role "SIDE") (list split-x split-y right top))
    ((= role "PLAN") (list left bottom right split-y))
    (t nil)))

(defun zomo:view-paper-rect (spec role paper-rect / explicit mapped)
  (setq explicit (zomo:alist-value 'paper-rect spec))
  (cond
    (explicit explicit)
    ((and (listp paper-rect) (listp (car paper-rect)))
      (setq mapped
        (or (assoc role paper-rect)
            (assoc (strcase role t) paper-rect)))
      (if mapped (cdr mapped) nil))
    (t (zomo:default-role-rect role paper-rect))))

(defun zomo:valid-rect-p (rect)
  (and
    (zomo:proper-list-p rect)
    (= 4 (length rect))
    (vl-every 'numberp rect)
    (> (zomo:rect-width rect) 0.0)
    (> (zomo:rect-height rect) 0.0)))

(defun zomo:valid-model-center-p (value)
  (and
    (zomo:proper-list-p value)
    (>= (length value) 2)
    (numberp (car value))
    (numberp (cadr value))
    (or (null (caddr value)) (numberp (caddr value)))))

(defun zomo:valid-direction-p (value)
  (and
    (zomo:proper-list-p value)
    (= 3 (length value))
    (vl-every 'numberp value)
    (> (apply '+ (mapcar 'abs value)) 1e-12)))

(defun zomo:view-geometry-error (rect model-center view-direction / result)
  ;; Keep the complete validator boundary inside catch so dotted values return
  ;; the documented error alist instead of escaping as an unhandled LISP error.
  (setq result
    (vl-catch-all-apply
      '(lambda ()
        (cond
          ((or (not (zomo:valid-rect-p rect))
               (not (zomo:valid-model-center-p model-center)))
            "INVALID_VIEW_GEOMETRY")
          ((not (zomo:valid-direction-p view-direction))
            "VIEW_DIRECTION_REQUIRED")
          (t nil)))
      nil))
  (if (vl-catch-all-error-p result) "INVALID_VIEW_GEOMETRY" result))

(defun zomo:viewport-from-handle (document handle / value)
  (if (and handle (= (type handle) 'STR))
    (progn
      (setq value
        (vl-catch-all-apply 'vla-HandleToObject (list document handle)))
      (if (and
            (not (vl-catch-all-error-p value))
            (= "AcDbViewport" (vla-get-ObjectName value)))
        value
        nil))
    nil))

(defun zomo:viewport-state (viewport / result)
  ;; Capture every property changed by this script before touching an existing viewport.
  (setq result
    (vl-catch-all-apply
      '(lambda ()
        (list
          (cons 'Center (vla-get-Center viewport))
          (cons 'Width (vla-get-Width viewport))
          (cons 'Height (vla-get-Height viewport))
          (cons 'ViewCenter (vla-get-ViewCenter viewport))
          (cons 'ViewTarget (vla-get-ViewTarget viewport))
          (cons 'CustomScale (vla-get-CustomScale viewport))
          (cons 'DisplayLocked (vla-get-DisplayLocked viewport))
          (cons 'ViewportOn (vla-get-ViewportOn viewport))
          (cons 'Direction (vla-get-Direction viewport))))
      nil))
  (if (vl-catch-all-error-p result) nil result))

(defun zomo:restore-viewport-state (viewport state / result)
  (setq result
    (vl-catch-all-apply
      '(lambda ()
        (vla-put-DisplayLocked viewport :vlax-false)
        (vla-put-Center viewport (zomo:alist-value 'Center state))
        (vla-put-Width viewport (zomo:alist-value 'Width state))
        (vla-put-Height viewport (zomo:alist-value 'Height state))
        (vla-put-ViewCenter viewport (zomo:alist-value 'ViewCenter state))
        (vla-put-ViewTarget viewport (zomo:alist-value 'ViewTarget state))
        (vla-put-Direction viewport (zomo:alist-value 'Direction state))
        (vla-put-CustomScale viewport (zomo:alist-value 'CustomScale state))
        (vla-put-ViewportOn viewport (zomo:alist-value 'ViewportOn state))
        (vla-put-DisplayLocked viewport (zomo:alist-value 'DisplayLocked state))
        t)
      nil))
  (and (not (vl-catch-all-error-p result)) result))

(defun zomo:delete-created-viewport (viewport / result)
  (setq result (vl-catch-all-apply 'vla-Delete (list viewport)))
  (not (vl-catch-all-error-p result)))

(defun zomo:rollback-viewports (snapshots created / ok pair viewport)
  (setq ok t)
  (foreach pair snapshots
    (if (not (zomo:restore-viewport-state (car pair) (cdr pair)))
      (setq ok nil)))
  (while (and created ok)
    (setq viewport (car created) created (cdr created))
    (if (not (zomo:delete-created-viewport viewport))
      (setq ok nil)))
  ok)

(defun zomo:configure-viewport (viewport rect model-center view-direction custom-scale / result)
  (setq result
    (vl-catch-all-apply
      '(lambda ()
        (vla-put-DisplayLocked viewport :vlax-false)
        (vla-put-ViewportOn viewport :vlax-true)
        (vla-put-Center viewport (zomo:pt3 (zomo:rect-center rect)))
        (vla-put-Width viewport (zomo:rect-width rect))
        (vla-put-Height viewport (zomo:rect-height rect))
        (vla-put-ViewCenter viewport
          (vlax-2d-point (list (float (car model-center)) (float (cadr model-center)))))
        (vla-put-ViewTarget viewport
          (zomo:pt3
            (list (float (car model-center))
                  (float (cadr model-center))
                  (float (if (caddr model-center) (caddr model-center) 0.0)))))
        (vla-put-Direction viewport (zomo:pt3 view-direction))
        (vla-put-CustomScale viewport custom-scale)
        viewport)
      nil))
  (if (vl-catch-all-error-p result) nil result))

(defun zomo:verify-view-isolation (verifier viewport spec / result)
  ;; The caller-supplied verifier must confirm role-specific layer/scene isolation.
  ;; Missing, undefined, errored, or false verifiers can never produce PASS.
  (if (/= (type verifier) 'SYM)
    nil
    (progn
      (setq result (vl-catch-all-apply verifier (list viewport spec)))
      (and (not (vl-catch-all-error-p result)) result))))

(defun zomo:lock-viewports (viewports / result viewport)
  (setq result
    (vl-catch-all-apply
      '(lambda ()
        (foreach viewport viewports
          (vla-put-DisplayLocked viewport :vlax-true))
        t)
      nil))
  (and (not (vl-catch-all-error-p result)) result))

(defun zomo:arrange-three-view (view-specs paper-rect custom-scale / document layouts
                                layout layout-block spec role rect model-center
                                view-direction verifier handle viewport state plans plan
                                snapshots created configured handles result geometry-error
                                ok message rollback-ok)
  (cond
    ((not (zomo:valid-three-view-specs-p view-specs))
      (list (cons 'status "ERROR") (cons 'message "VIEW_ROLES_MUST_BE_FRONT_SIDE_PLAN")))
    ((or (not (numberp custom-scale)) (<= custom-scale 0.0))
      (list (cons 'status "ERROR") (cons 'message "CUSTOM_SCALE_MUST_BE_POSITIVE")))
    ((= :vlax-true
        (vla-get-ModelType
          (vla-Item
            (vla-get-Layouts
              (vla-get-ActiveDocument (vlax-get-acad-object)))
            (getvar "CTAB"))))
      (list (cons 'status "ERROR") (cons 'message "PAPER_LAYOUT_REQUIRED")))
    (t
      (setq document (vla-get-ActiveDocument (vlax-get-acad-object))
            layouts (vla-get-Layouts document)
            layout (vla-Item layouts (getvar "CTAB"))
            layout-block (vla-get-Block layout)
            plans nil snapshots nil ok t message nil)
      ;; Preflight all caller input and snapshot every existing viewport before mutation.
      (foreach spec view-specs
        (if ok
          (progn
            (setq role (zomo:role-name (zomo:alist-value 'role spec))
                  rect
                    (vl-catch-all-apply 'zomo:view-paper-rect
                      (list spec role paper-rect))
                  model-center (zomo:alist-value 'model-center spec)
                  view-direction (zomo:alist-value 'view-direction spec)
                  verifier (zomo:alist-value 'isolation-verifier spec)
                  handle (zomo:alist-value 'viewport-handle spec)
                  viewport (zomo:viewport-from-handle document handle)
                  geometry-error
                    (if (vl-catch-all-error-p rect)
                      "INVALID_VIEW_GEOMETRY"
                      (zomo:view-geometry-error rect model-center view-direction)))
            (cond
              (geometry-error
                (setq ok nil message geometry-error))
              ((/= (type verifier) 'SYM)
                (setq ok nil message "VIEW_ISOLATION_REQUIRED"))
              (t
                (setq state (if viewport (zomo:viewport-state viewport) nil))
                (if (and viewport (null state))
                  (setq ok nil message "VIEWPORT_SNAPSHOT_FAILED")
                  (progn
                    (if viewport
                      (setq snapshots (cons (cons viewport state) snapshots)))
                    (setq plans
                      (cons
                        (list
                          (cons 'spec spec)
                          (cons 'role role)
                          (cons 'rect rect)
                          (cons 'model-center model-center)
                          (cons 'view-direction view-direction)
                          (cons 'isolation-verifier verifier)
                          (cons 'viewport viewport))
                        plans)))))))))
      (if (not ok)
        (list (cons 'status "ERROR") (cons 'message message))
        (progn
          (setq created nil configured nil handles nil ok t message nil)
          (foreach plan (reverse plans)
            (if ok
              (progn
                (setq spec (zomo:alist-value 'spec plan)
                      role (zomo:alist-value 'role plan)
                      rect (zomo:alist-value 'rect plan)
                      model-center (zomo:alist-value 'model-center plan)
                      view-direction (zomo:alist-value 'view-direction plan)
                      verifier (zomo:alist-value 'isolation-verifier plan)
                      viewport (zomo:alist-value 'viewport plan))
                (if (null viewport)
                  (progn
                    (setq result
                      (vl-catch-all-apply 'vla-AddPViewport
                        (list layout-block
                          (zomo:pt3 (zomo:rect-center rect))
                          (zomo:rect-width rect)
                          (zomo:rect-height rect))))
                    (if (vl-catch-all-error-p result)
                      (setq ok nil message "VIEWPORT_CREATE_FAILED")
                      (setq viewport result created (cons viewport created)))))
                (if ok
                  (if (null
                        (zomo:configure-viewport
                          viewport rect model-center view-direction custom-scale))
                    (setq ok nil message "VIEWPORT_CONFIGURATION_FAILED")
                    (if (not (zomo:verify-view-isolation verifier viewport spec))
                      (setq ok nil message "VIEW_ISOLATION_FAILED")
                      (setq configured (cons viewport configured)
                            handles
                              (cons (cons role (vla-get-Handle viewport)) handles))))))))
          (if (and ok (= 3 (length configured)))
            (if (not (zomo:lock-viewports configured))
              (setq ok nil message "VIEWPORT_LOCK_FAILED"))
            (if (null message) (setq ok nil message "VIEWPORT_CONFIGURATION_FAILED")))
          (if ok
            (list
              (cons 'status "PASS")
              (cons 'layout (vla-get-Name layout))
              (cons 'custom-scale custom-scale)
              (cons 'viewports (reverse handles)))
            (progn
              (setq rollback-ok (zomo:rollback-viewports snapshots created))
              (if rollback-ok
                (list (cons 'status "ERROR") (cons 'message message))
                (list
                  (cons 'status "REVIEW")
                  (cons 'message "VIEWPORT_ROLLBACK_UNCONFIRMED")
                  (cons 'cause message))))))))))

(princ)
