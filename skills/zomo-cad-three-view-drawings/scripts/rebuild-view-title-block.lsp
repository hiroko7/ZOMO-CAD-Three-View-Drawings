(vl-load-com)

;; This file expects zomo-common.lsp to be loaded first.
;; Static contract only: Task 9 must exercise these COM paths in an isolated DWG.

(defun zomo:cleanup-objects (objects / object)
  (foreach object objects
    (if object (vl-catch-all-apply 'vla-Delete (list object))))
  nil)

(defun zomo:title-live-object-p (object / result)
  (setq result (vl-catch-all-apply 'vla-get-ObjectName (list object)))
  (not (vl-catch-all-error-p result)))

(defun zomo:title-delete-status (object / result erased)
  ;; UNKNOWN is distinct: callers return REVIEW and stop further destructive cleanup.
  (setq result (vl-catch-all-apply 'vla-Delete (list object)))
  (if (not (vl-catch-all-error-p result))
    "DELETED"
    (progn
      (setq erased (vl-catch-all-apply 'vlax-erased-p (list object)))
      (cond
        ((vl-catch-all-error-p erased) "UNKNOWN")
        (erased "DELETED")
        ((zomo:title-live-object-p object) "FAILED")
        (t "UNKNOWN")))))

(defun zomo:variant-object-list (value / result)
  (if (or (null value) (vl-catch-all-error-p value))
    nil
    (progn
      (setq result
        (vl-catch-all-apply 'vlax-safearray->list
          (list (vlax-variant-value value))))
      (if (vl-catch-all-error-p result) nil result))))

(defun zomo:title-point-list (value / result)
  (cond
    ((listp value) value)
    ((= (type value) 'VARIANT)
      (setq result
        (vl-catch-all-apply 'vlax-safearray->list
          (list (vlax-variant-value value))))
      (if (vl-catch-all-error-p result) nil result))
    (t nil)))

(defun zomo:title-object (document value / result)
  (cond
    ((= (type value) 'VLA-OBJECT) value)
    ((= (type value) 'STR)
      (setq result
        (vl-catch-all-apply 'vla-HandleToObject (list document value)))
      (if (vl-catch-all-error-p result) nil result))
    (t nil)))

(defun zomo:title-owner-object (document object / result)
  (setq result
    (vl-catch-all-apply 'vla-ObjectIDToObject
      (list document (vla-get-OwnerID object))))
  (if (vl-catch-all-error-p result) nil result))

(defun zomo:title-copy-properties (source target / property value)
  (foreach property '(Layer Linetype LinetypeScale Color Lineweight)
    (if (and
          (vlax-property-available-p source property)
          (vlax-property-available-p target property t))
      (progn
        (setq value (vl-catch-all-apply 'vlax-get-property (list source property)))
        (if (not (vl-catch-all-error-p value))
          (vl-catch-all-apply 'vlax-put-property (list target property value))))))
  target)

(defun zomo:title-attribute-values (block / result attribute)
  (setq result nil)
  (foreach attribute (zomo:get-attributes block)
    (setq result
      (cons
        (cons (strcase (vla-get-TagString attribute))
              (vla-get-TextString attribute))
        result)))
  (reverse result))

(defun zomo:normalize-attribute-values (values / result pair key)
  (setq result nil)
  (foreach pair values
    (setq key
      (cond
        ((= (type (car pair)) 'STR) (strcase (car pair)))
        ((= (type (car pair)) 'SYM) (strcase (vl-symbol-name (car pair))))
        (t nil)))
    (if key (setq result (cons (cons key (cdr pair)) result))))
  result)

(defun zomo:merge-attribute-values (captured overrides / result pair existing)
  (setq result captured)
  (foreach pair (zomo:normalize-attribute-values overrides)
    (if (setq existing (assoc (car pair) result))
      (setq result (subst pair existing result))
      (setq result (cons pair result))))
  result)

(defun zomo:restore-title-attributes (block values / attribute pair result restored)
  (setq restored t)
  (foreach attribute (zomo:get-attributes block)
    (if (setq pair (assoc (strcase (vla-get-TagString attribute)) values))
      (progn
        (setq result
          (vl-catch-all-apply 'vla-put-TextString
            (list attribute (cdr pair))))
        (if (vl-catch-all-error-p result) (setq restored nil)))))
  restored)

(defun zomo:title-width (bbox)
  (- (caadr bbox) (caar bbox)))

(defun zomo:title-frame-object (objects / object object-name bbox width widest result closed)
  (setq widest -1.0 result nil)
  (foreach object objects
    (setq object-name
      (vl-catch-all-apply 'vla-get-ObjectName (list object)))
    (if (and (not (vl-catch-all-error-p object-name))
             (= object-name "AcDbPolyline"))
      (progn
        (setq closed (vl-catch-all-apply 'vla-get-Closed (list object))
              bbox (zomo:bbox object))
        (if (and bbox
                 (not (vl-catch-all-error-p closed))
                 (= closed :vlax-true)
                 (> (setq width (zomo:title-width bbox)) widest))
          (setq widest width result object)))))
  result)

(defun zomo:title-set-frame-edges (frame old-left old-right target-left target-right
                                    tolerance / variant values output x y data midpoint)
  (setq variant (vl-catch-all-apply 'vla-get-Coordinates (list frame)))
  (if (vl-catch-all-error-p variant)
    nil
    (progn
      (setq values (vlax-safearray->list (vlax-variant-value variant))
            output nil midpoint (/ (+ old-left old-right) 2.0))
      (while values
        (setq x (car values) y (cadr values) values (cddr values))
        (cond
          ((<= (abs (- x old-left)) tolerance) (setq x target-left))
          ((<= (abs (- x old-right)) tolerance) (setq x target-right))
          ((< x midpoint) (setq x (+ x (- target-left old-left))))
          (t (setq x (+ x (- target-right old-right)))))
        (setq output (append output (list x y))))
      (setq data
        (vlax-make-safearray vlax-vbDouble (cons 0 (1- (length output)))))
      (vlax-safearray-fill data output)
      (not
        (vl-catch-all-error-p
          (vl-catch-all-apply 'vla-put-Coordinates (list frame data)))))))

(defun zomo:title-shift-content (objects frame old-left old-right target-left target-right
                                  / object bbox center shift midpoint result ok)
  (setq midpoint (/ (+ old-left old-right) 2.0) ok t)
  (foreach object objects
    (if (and ok (/= object frame))
      (progn
        (setq bbox (zomo:bbox object))
        (if bbox
          (progn
            (setq center (/ (+ (caar bbox) (caadr bbox)) 2.0)
                  shift
                    (if (<= center midpoint)
                      (- target-left old-left)
                      (- target-right old-right))
                  result
                    (vl-catch-all-apply 'vla-Move
                      (list object (zomo:pt3 '(0.0 0.0 0.0))
                                   (zomo:pt3 (list shift 0.0 0.0)))))
            (if (vl-catch-all-error-p result) (setq ok nil)))))))
  ok)

(defun zomo:title-move-to-local (objects base-coordinates / object result ok)
  ;; Exploded objects are WCS entities. Store their offsets from the insertion point.
  (setq ok t)
  (foreach object objects
    (if ok
      (progn
        (setq result
          (vl-catch-all-apply 'vla-Move
            (list object
              (zomo:pt3 '(0.0 0.0 0.0))
              (zomo:pt3
                (list (- (car base-coordinates))
                      (- (cadr base-coordinates))
                      (- (if (caddr base-coordinates) (caddr base-coordinates) 0.0)))))))
        (if (vl-catch-all-error-p result) (setq ok nil)))))
  ok)

(defun zomo:rect-positive-overlap-p (a b tolerance / left bottom right top)
  (setq left (max (nth 0 a) (nth 0 b))
        bottom (max (nth 1 a) (nth 1 b))
        right (min (nth 2 a) (nth 2 b))
        top (min (nth 3 a) (nth 3 b)))
  (and (> (- right left) tolerance) (> (- top bottom) tolerance)))

(defun zomo:bbox-rect (bbox)
  (list (caar bbox) (cadar bbox) (caadr bbox) (cadadr bbox)))

(defun zomo:title-overlaps-p (bbox occupied-rects tolerance / overlap rect occupied)
  (setq overlap nil rect (zomo:bbox-rect bbox))
  (foreach occupied occupied-rects
    (if (or
          (not (listp occupied))
          (/= 4 (length occupied))
          (not (vl-every 'numberp occupied))
          (zomo:rect-positive-overlap-p rect occupied tolerance))
      (setq overlap t)))
  overlap)

(defun zomo:unique-title-name (blocks / seed name suffix result)
  (setq seed (itoa (getvar "MILLISECS")) suffix 0 result nil)
  (while (null result)
    (setq name (strcat "ZOMO_VIEW_TITLE_" seed "_" (itoa suffix)))
    (if (vl-catch-all-error-p
          (vl-catch-all-apply 'vla-Item (list blocks name)))
      (setq result name)
      (setq suffix (1+ suffix))))
  result)

(defun zomo:title-frame-bounds-match-p (bbox target-left target-right tolerance)
  (and bbox
       (<= (abs (- (caar bbox) target-left)) tolerance)
       (<= (abs (- (caadr bbox) target-right)) tolerance)))

(defun zomo:title-bounds-match-p (bbox target-left target-right tolerance)
  ;; Compatibility alias: bbox must be the actual frame bbox.
  (zomo:title-frame-bounds-match-p bbox target-left target-right tolerance))

(defun zomo:title-unit-scale-p (block tolerance)
  (and
    (<= (abs (- (vla-get-XScaleFactor block) 1.0)) tolerance)
    (<= (abs (- (vla-get-YScaleFactor block) 1.0)) tolerance)
    (<= (abs (- (vla-get-ZScaleFactor block) 1.0)) tolerance)))

(defun zomo:rebuild-title (source-handle old-reference-value target-left target-right
                           attributes occupied-rects tolerance / document blocks source
                           old-reference owner values base-point base-coordinates copy
                           exploded frame source-frame-bbox old-left old-right block-name
                           new-block copied copied-list new-frame new-frame-bbox new-reference
                           new-bbox target-local-left target-local-right error-value success
                           attributes-restored delete-status review-needed)
  (setq document (vla-get-ActiveDocument (vlax-get-acad-object))
        blocks (vla-get-Blocks document)
        source (zomo:title-object document source-handle)
        old-reference (zomo:title-object document old-reference-value)
        exploded nil copied nil new-reference nil new-block nil
        success nil review-needed nil)
  (cond
    ((or (null source) (not (numberp target-left)) (not (numberp target-right))
         (>= target-left target-right) (not (numberp tolerance)) (<= tolerance 0.0))
      (list (cons 'status "ERROR") (cons 'message "INVALID_TITLE_ARGUMENTS")))
    (t
      (setq owner (zomo:title-owner-object document source)
            values
              (zomo:merge-attribute-values
                (zomo:title-attribute-values source) attributes)
            base-point (vl-catch-all-apply 'vla-get-InsertionPoint (list source)))
      (if (or (null owner) (vl-catch-all-error-p base-point)
              (null (setq base-coordinates (zomo:title-point-list base-point))))
        (list (cons 'status "ERROR") (cons 'message "SOURCE_TITLE_UNREADABLE"))
        (progn
          (setq copy (vl-catch-all-apply 'vla-Copy (list source)))
          (if (vl-catch-all-error-p copy)
            (list (cons 'status "ERROR") (cons 'message "SOURCE_COPY_FAILED"))
            (progn
              (setq error-value (vl-catch-all-apply 'vla-Explode (list copy))
                    exploded (zomo:variant-object-list error-value)
                    delete-status (zomo:title-delete-status copy)
                    copy nil)
              (if (/= delete-status "DELETED")
                (setq error-value "SOURCE_COPY_DELETE_UNCONFIRMED"
                      review-needed (= delete-status "UNKNOWN"))
                (progn
                  (setq frame (zomo:title-frame-object exploded)
                        source-frame-bbox (if frame (zomo:bbox frame) nil))
                  ;; Old left/right edges come from the identified frame, not overall text bbox.
                  (if (or (null exploded) (null frame) (null source-frame-bbox))
                    (setq error-value "TITLE_FRAME_REBUILD_FAILED")
                    (progn
                      (setq old-left (caar source-frame-bbox)
                            old-right (caadr source-frame-bbox)
                            target-local-left (- target-left (car base-coordinates))
                            target-local-right (- target-right (car base-coordinates)))
                      (if (or
                            (not
                              (zomo:title-set-frame-edges
                                frame old-left old-right target-left target-right tolerance))
                            (not
                              (zomo:title-shift-content
                                exploded frame old-left old-right target-left target-right))
                            (not (zomo:title-move-to-local exploded base-coordinates)))
                        (setq error-value "TITLE_FRAME_REBUILD_FAILED")
                        (progn
                          (setq block-name (zomo:unique-title-name blocks)
                                new-block
                                  (vl-catch-all-apply 'vla-Add
                                    (list blocks (zomo:pt3 '(0.0 0.0 0.0)) block-name)))
                          (if (vl-catch-all-error-p new-block)
                            (progn
                              (setq new-block nil error-value "TITLE_BLOCK_CREATE_FAILED"))
                            (progn
                              (setq copied
                                (vl-catch-all-apply 'vla-CopyObjects
                                  (list document (zomo:object-array exploded) new-block)))
                              (if (vl-catch-all-error-p copied)
                                (setq copied nil error-value "TITLE_CONTENT_COPY_FAILED")
                                (progn
                                  (setq copied-list (zomo:variant-object-list copied)
                                        new-frame (zomo:title-frame-object copied-list)
                                        new-frame-bbox (if new-frame (zomo:bbox new-frame) nil)
                                        new-reference
                                          (vl-catch-all-apply 'vla-InsertBlock
                                            (list owner (zomo:pt3 base-coordinates)
                                                  block-name 1.0 1.0 1.0 0.0)))
                                  (if (vl-catch-all-error-p new-reference)
                                    (progn
                                      (setq new-reference nil error-value "TITLE_INSERT_FAILED"))
                                    (progn
                                      (zomo:title-copy-properties source new-reference)
                                      (setq attributes-restored
                                              (zomo:restore-title-attributes new-reference values)
                                            new-bbox (zomo:bbox new-reference)
                                            success
                                              (and
                                                attributes-restored
                                                (zomo:title-frame-bounds-match-p
                                                  new-frame-bbox
                                                  target-local-left target-local-right tolerance)
                                                (zomo:title-unit-scale-p new-reference tolerance)
                                                ;; Whole-reference bbox is used only for overlap.
                                                (not
                                                  (zomo:title-overlaps-p
                                                    new-bbox occupied-rects tolerance))))
                                      (if (not success)
                                        (setq error-value
                                          (if attributes-restored
                                            "TITLE_INVARIANT_FAILED"
                                            "TITLE_ATTRIBUTE_RESTORE_FAILED"))))))))))))))))
              (if (not review-needed)
                (zomo:cleanup-objects exploded))
              (setq exploded nil)
              (if (and success old-reference)
                (progn
                  (setq delete-status (zomo:title-delete-status old-reference))
                  (cond
                    ((= delete-status "DELETED") nil)
                    ((= delete-status "UNKNOWN")
                      (setq success nil review-needed t
                            error-value "OLD_REFERENCE_DELETE_UNCONFIRMED"))
                    (t
                      (setq success nil error-value "OLD_REFERENCE_DELETE_FAILED")))))
              (cond
                (success (vla-get-Handle new-reference))
                (review-needed
                  ;; State is uncertain: do not delete any more references or definitions.
                  (list
                    (cons 'status "REVIEW")
                    (cons 'message error-value)
                    (cons 'new-reference
                      (if new-reference (vla-get-Handle new-reference) nil))))
                (t
                  (if new-reference (zomo:title-delete-status new-reference))
                  (if new-block (zomo:title-delete-status new-block))
                  (list
                    (cons 'status "ERROR")
                    (cons 'message
                      (if (= (type error-value) 'STR)
                        error-value
                        "TITLE_REBUILD_FAILED")))))))))))

(princ)
