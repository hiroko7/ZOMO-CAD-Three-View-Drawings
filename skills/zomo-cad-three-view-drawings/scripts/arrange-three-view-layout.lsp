(vl-load-com)

;; This file expects zomo-common.lsp to be loaded first.

(defun zomo:alist-value (key values / pair)
  (if (setq pair (assoc key values)) (cdr pair) nil))

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
    (= 3 (length view-specs))
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
    (= 4 (length rect))
    (vl-every 'numberp rect)
    (> (zomo:rect-width rect) 0.0)
    (> (zomo:rect-height rect) 0.0)))

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

(defun zomo:configure-viewport (viewport rect model-center custom-scale / result)
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
        (if (and (caddr model-center) (vlax-property-available-p viewport 'ViewTarget t))
          (vla-put-ViewTarget viewport (zomo:pt3 model-center)))
        (vla-put-CustomScale viewport custom-scale)
        viewport)
      nil))
  (if (vl-catch-all-error-p result) nil result))

(defun zomo:arrange-three-view (view-specs paper-rect custom-scale / document layouts
                                layout layout-block spec role rect model-center
                                handle viewport created result handles configured)
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
      (setq configured t handles nil created nil)
      ;; Resolve and validate every paper rectangle before modifying a viewport.
      (foreach spec view-specs
        (setq role (zomo:role-name (zomo:alist-value 'role spec))
              rect
                (vl-catch-all-apply 'zomo:view-paper-rect
                  (list spec role paper-rect))
              model-center (zomo:alist-value 'model-center spec))
        (if (or (vl-catch-all-error-p rect)
                (not (zomo:valid-rect-p rect))
                (not (listp model-center))
                (< (length model-center) 2))
          (setq configured nil)))
      (if (not configured)
        (list (cons 'status "ERROR") (cons 'message "INVALID_VIEW_GEOMETRY"))
        (progn
          (setq document (vla-get-ActiveDocument (vlax-get-acad-object))
                layouts (vla-get-Layouts document)
                layout (vla-Item layouts (getvar "CTAB"))
                layout-block (vla-get-Block layout)
                configured nil)
          (foreach spec view-specs
            (setq role (zomo:role-name (zomo:alist-value 'role spec))
                  rect (zomo:view-paper-rect spec role paper-rect)
                  model-center (zomo:alist-value 'model-center spec)
                  handle (zomo:alist-value 'viewport-handle spec)
                  viewport (zomo:viewport-from-handle document handle))
            (if (null viewport)
              (progn
                (setq viewport
                  (vl-catch-all-apply 'vla-AddPViewport
                    (list layout-block
                      (zomo:pt3 (zomo:rect-center rect))
                      (zomo:rect-width rect)
                      (zomo:rect-height rect))))
                (if (not (vl-catch-all-error-p viewport))
                  (setq created (cons viewport created)))))
            (if (or (vl-catch-all-error-p viewport) (null viewport))
              (setq configured nil)
              (progn
                (setq result
                  (zomo:configure-viewport viewport rect model-center custom-scale))
                (if result
                  (progn
                    (setq configured (cons viewport configured)
                          handles (cons (cons role (vla-get-Handle viewport)) handles)))
                  (setq configured nil)))))
          (if (or (null configured) (/= 3 (length configured)))
            (progn
              (foreach viewport created
                (vl-catch-all-apply 'vla-Delete (list viewport)))
              (list (cons 'status "ERROR") (cons 'message "VIEWPORT_CONFIGURATION_FAILED")))
            (progn
              ;; Lock only after all three roles share the requested feasible scale.
              (foreach viewport configured
                (vla-put-CustomScale viewport custom-scale)
                (vla-put-DisplayLocked viewport :vlax-true))
              (list
                (cons 'status "PASS")
                (cons 'layout (vla-get-Name layout))
                (cons 'custom-scale custom-scale)
                (cons 'viewports (reverse handles))))))))))

(princ)
