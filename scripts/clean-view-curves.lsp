(vl-load-com)

;; This file expects zomo-common.lsp to be loaded first.

(defun zomo:curve-length (entity / end-param value)
  (setq end-param
    (vl-catch-all-apply 'vlax-curve-getEndParam (list entity)))
  (if (vl-catch-all-error-p end-param)
    nil
    (progn
      (setq value
        (vl-catch-all-apply 'vlax-curve-getDistAtParam
          (list entity end-param)))
      (if (vl-catch-all-error-p value) nil value))))

(defun zomo:point-segment-distance (point start end / vector offset length2 factor closest)
  (setq vector (mapcar '- end start)
        offset (mapcar '- point start)
        length2 (apply '+ (mapcar '* vector vector)))
  (if (<= length2 1e-18)
    (distance point start)
    (progn
      (setq factor (/ (apply '+ (mapcar '* offset vector)) length2)
            factor (max 0.0 (min 1.0 factor))
            closest (mapcar '+ start (mapcar '(lambda (item) (* factor item)) vector)))
      (distance point closest))))

(defun zomo:sample-segment (entity p0 p1 point0 point1 tolerance depth /
                            p25 pm p75 point25 pointm point75 left right)
  (setq p25 (+ p0 (* 0.25 (- p1 p0)))
        pm (/ (+ p0 p1) 2.0)
        p75 (+ p0 (* 0.75 (- p1 p0)))
        point25 (vlax-curve-getPointAtParam entity p25)
        pointm (vlax-curve-getPointAtParam entity pm)
        point75 (vlax-curve-getPointAtParam entity p75))
  (cond
    ((or (null point25) (null pointm) (null point75)) nil)
    ((and
       (<= (zomo:point-segment-distance point25 point0 point1) tolerance)
       (<= (zomo:point-segment-distance pointm point0 point1) tolerance)
       (<= (zomo:point-segment-distance point75 point0 point1) tolerance))
      (list point0 point1))
    ((>= depth 14) nil)
    (t
      (setq left (zomo:sample-segment entity p0 pm point0 pointm tolerance (1+ depth))
            right (zomo:sample-segment entity pm p1 pointm point1 tolerance (1+ depth)))
      (if (and left right)
        (append left (cdr right))
        nil))))

(defun zomo:spline-points (entity tolerance / start-param end-param start-point end-point)
  (setq start-param (vlax-curve-getStartParam entity)
        end-param (vlax-curve-getEndParam entity)
        start-point (vlax-curve-getPointAtParam entity start-param)
        end-point (vlax-curve-getPointAtParam entity end-param))
  (if (and start-point end-point (> end-param start-param))
    (zomo:sample-segment entity start-param end-param start-point end-point tolerance 0)
    nil))

(defun zomo:double-array-3d (points / values data point)
  (setq values nil)
  (foreach point points
    (setq values
      (append values
        (list (float (car point)) (float (cadr point))
          (float (if (caddr point) (caddr point) 0.0))))))
  (setq data (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length values)))))
  (vlax-safearray-fill data values)
  data)

(defun zomo:owner-object (document object / value)
  (setq value
    (vl-catch-all-apply 'vla-ObjectIDToObject
      (list document (vla-get-OwnerID object))))
  (if (vl-catch-all-error-p value) nil value))

(defun zomo:copy-graphic-properties (source target / property value)
  (foreach property '(Layer Linetype LinetypeScale Color Lineweight)
    (if (and
          (vlax-property-available-p source property)
          (vlax-property-available-p target property t))
      (progn
        (setq value (vl-catch-all-apply 'vlax-get-property (list source property)))
        (if (not (vl-catch-all-error-p value))
          (vl-catch-all-apply 'vlax-put-property (list target property value))))))
  target)

(defun zomo:convert-spline (document object tolerance / entity points owner candidate delete-status)
  (setq entity (vlax-vla-object->ename object)
        points (vl-catch-all-apply 'zomo:spline-points (list entity tolerance)))
  (if (or (vl-catch-all-error-p points) (null points))
    nil
    (progn
      ;; The candidate is created only after every adaptive segment passed tolerance.
      (setq owner (zomo:owner-object document object))
      (if (null owner)
        nil
        (progn
          (setq candidate
            (vl-catch-all-apply 'vla-Add3DPoly
              (list owner (zomo:double-array-3d points))))
          (if (vl-catch-all-error-p candidate)
            nil
            (progn
              (zomo:copy-graphic-properties object candidate)
              (setq delete-status (zomo:delete-object-status object))
              (cond
                ((= delete-status "DELETED") candidate)
                ((= delete-status "FAILED")
                  (zomo:delete-object-status candidate)
                  'REVIEW)
                (t 'REVIEW)))))))))

(defun zomo:type-count-add (counts object-name / pair)
  (if (setq pair (assoc object-name counts))
    (subst (cons object-name (1+ (cdr pair))) pair counts)
    (cons (cons object-name 1) counts)))

(defun zomo:same-point-p (a b tolerance)
  (<= (distance a b) tolerance))

(defun zomo:line-data (object / entity start end)
  (if (= "AcDbLine" (vla-get-ObjectName object))
    (progn
      (setq entity (vlax-vla-object->ename object)
            start (vlax-curve-getStartPoint entity)
            end (vlax-curve-getEndPoint entity))
      (list start end))
    nil))

(defun zomo:duplicate-line-p (first second tolerance / a b c d)
  (setq a (car first) b (cadr first) c (car second) d (cadr second))
  (or
    (and (zomo:same-point-p a c tolerance) (zomo:same-point-p b d tolerance))
    (and (zomo:same-point-p a d tolerance) (zomo:same-point-p b c tolerance))))

(defun zomo:live-object-p (object / value)
  (setq value (vl-catch-all-apply 'vla-get-ObjectName (list object)))
  (not (vl-catch-all-error-p value)))

(defun zomo:delete-object-status (object / result erased)
  ;; UNKNOWN means COM raised and liveness cannot be proven; stop destructive work.
  (setq result (vl-catch-all-apply 'vla-Delete (list object)))
  (if (not (vl-catch-all-error-p result))
    "DELETED"
    (progn
      (setq erased (vl-catch-all-apply 'vlax-erased-p (list object)))
      (cond
        ((vl-catch-all-error-p erased) "UNKNOWN")
        (erased "DELETED")
        ((zomo:live-object-p object) "FAILED")
        (t "UNKNOWN")))))

(defun zomo:remove-line-duplicates (objects tolerance / outer inner first second removed
                                    destructive-ok delete-status)
  (setq removed 0 outer objects destructive-ok t)
  (while (and outer destructive-ok)
    (setq first (car outer) inner (cdr outer))
    (if (and first (zomo:live-object-p first))
      (while (and inner destructive-ok)
        (setq second (car inner))
        (if (and second
                 (zomo:live-object-p second)
                 (zomo:duplicate-line-p
                   (zomo:line-data first) (zomo:line-data second) tolerance))
          (progn
            (setq delete-status (zomo:delete-object-status second))
            (if (= delete-status "DELETED")
              (setq removed (1+ removed))
              (setq destructive-ok nil))))
        (setq inner (cdr inner))))
    (setq outer (cdr outer)))
  (list removed destructive-ok))

(defun zomo:shared-line-points (first second tolerance / a b c d)
  (setq a (car first) b (cadr first) c (car second) d (cadr second))
  (cond
    ((zomo:same-point-p a c tolerance) (list b a d))
    ((zomo:same-point-p a d tolerance) (list b a c))
    ((zomo:same-point-p b c tolerance) (list a b d))
    ((zomo:same-point-p b d tolerance) (list a b c))
    (t nil)))

(defun zomo:same-line-style-p (first second)
  (and
    (= (vla-get-OwnerID first) (vla-get-OwnerID second))
    (= (vla-get-Layer first) (vla-get-Layer second))
    (= (vla-get-Linetype first) (vla-get-Linetype second))
    (= (vla-get-Color first) (vla-get-Color second))))

(defun zomo:merge-collinear-lines (document objects tolerance / outer inner first second
                                    shared owner candidate merged destructive-ok
                                    first-delete second-delete)
  (setq merged 0 outer objects destructive-ok t)
  (while (and outer destructive-ok)
    (setq first (car outer) inner (cdr outer))
    (if (and first (zomo:live-object-p first))
      (while (and inner destructive-ok)
        (setq second (car inner))
        (if (and
              second
              (zomo:live-object-p second)
              (zomo:same-line-style-p first second)
              (setq shared
                (zomo:shared-line-points
                  (zomo:line-data first) (zomo:line-data second) tolerance))
              (<=
                (zomo:point-segment-distance (cadr shared) (car shared) (caddr shared))
                tolerance))
          (progn
            (setq owner (zomo:owner-object document first)
                  candidate
                    (vl-catch-all-apply 'vla-AddLine
                      (list owner (zomo:pt3 (car shared)) (zomo:pt3 (caddr shared)))))
            (if (vl-catch-all-error-p candidate)
              (setq destructive-ok nil)
              (progn
                (zomo:copy-graphic-properties first candidate)
                (setq second-delete (zomo:delete-object-status second))
                (cond
                  ((= second-delete "DELETED")
                    (setq first-delete (zomo:delete-object-status first))
                    (if (= first-delete "DELETED")
                      (setq first candidate merged (1+ merged))
                      (setq destructive-ok nil)))
                  ((= second-delete "FAILED")
                    (zomo:delete-object-status candidate)
                    (setq destructive-ok nil))
                  (t (setq destructive-ok nil)))))))
        (setq inner (cdr inner))))
    (setq outer (cdr outer)))
  (list merged destructive-ok))

(defun zomo:clean-selection (selection tolerance / document count index entity object
                              object-name type-counts input-count spline-before
                              spline-after zero-removed duplicate-removed status
                              curve-length line-objects candidate destructive-ok
                              delete-status operation-result)
  (if (or (null selection) (not (numberp tolerance)) (<= tolerance 0.0))
    (list
      (cons 'input-count 0)
      (cons 'spline-count-before 0)
      (cons 'spline-count-after 0)
      (cons 'zero-length-removed 0)
      (cons 'duplicate-removed 0)
      (cons 'object-types nil)
      (cons 'status "REVIEW"))
    (progn
      (setq document (vla-get-ActiveDocument (vlax-get-acad-object))
            input-count (sslength selection)
            index 0 spline-before 0 spline-after 0 zero-removed 0
            duplicate-removed 0 type-counts nil line-objects nil status "PASS")
      (setq destructive-ok t)
      ;; Every object visited below comes from the caller's selection set.
      (while (< index input-count)
        (setq entity (ssname selection index)
              object (vlax-ename->vla-object entity)
              object-name (vla-get-ObjectName object)
              type-counts (zomo:type-count-add type-counts object-name)
              curve-length (zomo:curve-length entity))
        (if (= object-name "AcDbSpline")
          (setq spline-before (1+ spline-before)))
        (cond
          ((and destructive-ok curve-length (<= curve-length tolerance))
            (setq delete-status (zomo:delete-object-status object))
            (if (= delete-status "DELETED")
              (setq zero-removed (1+ zero-removed))
              (progn
                (setq status "REVIEW" destructive-ok nil)
                (if (= object-name "AcDbSpline")
                  (setq spline-after (1+ spline-after))))))
          ((and destructive-ok (= object-name "AcDbSpline"))
            (setq candidate (zomo:convert-spline document object tolerance))
            (cond
              ((= candidate 'REVIEW)
                (setq spline-after (1+ spline-after)
                      status "REVIEW" destructive-ok nil))
              ((null candidate)
              (progn
                (setq spline-after (1+ spline-after)
                      status "REVIEW")))))
          ((= object-name "AcDbLine")
            (setq line-objects (cons object line-objects))))
        (setq index (1+ index)))
      ;; Duplicate removal is deliberately limited to selected line objects.
      (if destructive-ok
        (progn
          (setq operation-result
            (zomo:remove-line-duplicates line-objects tolerance)
                duplicate-removed (car operation-result)
                destructive-ok (cadr operation-result))
          (if destructive-ok
            (progn
              (setq operation-result
                (zomo:merge-collinear-lines document line-objects tolerance)
                    destructive-ok (cadr operation-result))))))
      (if (not destructive-ok) (setq status "REVIEW"))
      (list
        (cons 'input-count input-count)
        (cons 'spline-count-before spline-before)
        (cons 'spline-count-after spline-after)
        (cons 'zero-length-removed zero-removed)
        (cons 'duplicate-removed duplicate-removed)
        (cons 'object-types (reverse type-counts))
        (cons 'status status)))))

(princ)
