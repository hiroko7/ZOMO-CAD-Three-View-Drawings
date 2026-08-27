(vl-load-com)

(defun zomo:pt3 (p / z)
  (setq z (if (caddr p) (caddr p) 0.0))
  (vlax-3d-point
    (list (float (car p)) (float (cadr p)) (float z))))

(defun zomo:bbox (obj / p1 p2 result)
  (setq result
    (vl-catch-all-apply 'vla-GetBoundingBox (list obj 'p1 'p2)))
  (if (vl-catch-all-error-p result)
    nil
    (list
      (vlax-safearray->list p1)
      (vlax-safearray->list p2))))

(defun zomo:object-array (objects / data)
  (if objects
    (progn
      (setq data
        (vlax-make-safearray
          vlax-vbObject
          (cons 0 (1- (length objects)))))
      (vlax-safearray-fill data objects)
      data)
    nil))

(defun zomo:get-attributes (block / has-attributes value)
  (setq has-attributes
    (vl-catch-all-apply 'vla-get-HasAttributes (list block)))
  (if (and
        (not (vl-catch-all-error-p has-attributes))
        (= :vlax-true has-attributes))
    (progn
      (setq value
        (vl-catch-all-apply 'vla-GetAttributes (list block)))
      (if (vl-catch-all-error-p value)
        nil
        (vlax-safearray->list (vlax-variant-value value))))
    nil))

(princ)
