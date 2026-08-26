(vl-load-com)

;; This file expects zomo-common.lsp to be loaded first.
;; Static contract only: Task 9 must exercise these COM paths in an isolated DWG.

(defun zomo:cleanup-objects (objects / object cleanup-status delete-status)
  ;; A caller may commit deletion of the old reference only after DELETED.
  (setq cleanup-status "DELETED")
  ;; Continue after a failed delete so rollback remains best-effort, but retain
  ;; the most conservative aggregate status for the caller's commit gate.
  (while objects
    (setq object (car objects) objects (cdr objects))
    (if object
      (progn
        (setq delete-status (zomo:title-delete-status object))
        (cond
          ((= delete-status "UNKNOWN") (setq cleanup-status "UNKNOWN"))
          ((and (= delete-status "FAILED") (/= cleanup-status "UNKNOWN"))
            (setq cleanup-status "FAILED"))))))
  cleanup-status)

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
    ((= (type value) 'SAFEARRAY)
      (setq result
        (vl-catch-all-apply 'vlax-safearray->list (list value)))
      (if (vl-catch-all-error-p result) nil result))
    (t nil)))

(defun zomo:title-alist-value (key values / pair)
  (if (and (listp values) (setq pair (assoc key values))) (cdr pair) nil))

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

(defun zomo:title-safe-get (object property / value)
  (setq value (vl-catch-all-apply 'vlax-get-property (list object property)))
  (if (vl-catch-all-error-p value) nil value))

(defun zomo:title-safe-put (object property value / result)
  (if (null value)
    t
    (progn
      (setq result
        (vl-catch-all-apply 'vlax-put-property (list object property value)))
      (not (vl-catch-all-error-p result)))))

(defun zomo:title-block-definition (blocks source / name result)
  (setq name (vl-catch-all-apply 'vla-get-Name (list source)))
  (if (vl-catch-all-error-p name)
    nil
    (progn
      (setq result (vl-catch-all-apply 'vla-Item (list blocks name)))
      (if (vl-catch-all-error-p result) nil result))))

(defun zomo:title-attribute-definitions (block / result object object-name)
  (setq result nil)
  (if block
    (vlax-for object block
      (setq object-name (zomo:title-safe-get object 'ObjectName))
      (if (= object-name "AcDbAttributeDefinition")
        (setq result (cons object result)))))
  (reverse result))

(defun zomo:title-attribute-mode (attribute / mode item property bit value)
  (setq mode 0)
  (foreach item '((Invisible . 1) (Constant . 2) (Verify . 4)
                  (Preset . 8) (LockPosition . 16))
    (setq property (car item) bit (cdr item)
          value (zomo:title-safe-get attribute property))
    (if (= value :vlax-true) (setq mode (+ mode bit))))
  mode)

(defun zomo:title-attribute-definition-metadata (attribute / insertion alignment-point)
  (setq insertion
    (zomo:title-point-list (zomo:title-safe-get attribute 'InsertionPoint))
        alignment-point
          (zomo:title-point-list
            (zomo:title-safe-get attribute 'TextAlignmentPoint)))
  (if (or (null insertion)
          (null (zomo:title-safe-get attribute 'TagString))
          (null (zomo:title-safe-get attribute 'Height)))
    nil
    (list
      (cons 'tag (strcase (zomo:title-safe-get attribute 'TagString)))
      (cons 'prompt (zomo:title-safe-get attribute 'PromptString))
      (cons 'default (zomo:title-safe-get attribute 'TextString))
      (cons 'height (zomo:title-safe-get attribute 'Height))
      (cons 'mode (zomo:title-attribute-mode attribute))
      (cons 'insertion-point insertion)
      (cons 'alignment-point alignment-point)
      (cons 'alignment (zomo:title-safe-get attribute 'Alignment))
      (cons 'rotation (zomo:title-safe-get attribute 'Rotation))
      (cons 'scale-factor (zomo:title-safe-get attribute 'ScaleFactor))
      (cons 'oblique-angle (zomo:title-safe-get attribute 'ObliqueAngle))
      (cons 'text-generation-flag
        (zomo:title-safe-get attribute 'TextGenerationFlag))
      (cons 'thickness (zomo:title-safe-get attribute 'Thickness))
      (cons 'style-name (zomo:title-safe-get attribute 'StyleName))
      (cons 'layer (zomo:title-safe-get attribute 'Layer))
      (cons 'linetype (zomo:title-safe-get attribute 'Linetype))
      (cons 'color (zomo:title-safe-get attribute 'Color))
      (cons 'lineweight (zomo:title-safe-get attribute 'Lineweight))
      (cons 'bbox (zomo:bbox attribute)))))

(defun zomo:title-attribute-metadata-list (definitions / result definition metadata)
  (setq result nil)
  (foreach definition definitions
    (setq metadata (zomo:title-attribute-definition-metadata definition))
    (if metadata (setq result (cons metadata result))))
  (reverse result))

(defun zomo:title-tags-from-objects (objects / result object tag)
  (setq result nil)
  (foreach object objects
    (setq tag (zomo:title-safe-get object 'TagString))
    (if tag (setq result (cons (strcase tag) result))))
  (reverse result))

(defun zomo:title-tags-from-metadata (metadata-list / result metadata)
  (setq result nil)
  (foreach metadata metadata-list
    (setq result (cons (zomo:title-alist-value 'tag metadata) result)))
  (reverse result))

(defun zomo:title-sort-tags (tags)
  (vl-sort tags '(lambda (first second) (vl-string-lessp first second))))

(defun zomo:title-tag-sets-equal-p (first second)
  (and (= (length first) (length second))
       (equal (zomo:title-sort-tags first) (zomo:title-sort-tags second))))

(defun zomo:title-filter-attribute-metadata (metadata-list expected-tags / result metadata)
  (setq result nil)
  (foreach metadata metadata-list
    (if (member (zomo:title-alist-value 'tag metadata) expected-tags)
      (setq result (cons metadata result))))
  (reverse result))

(defun zomo:title-constant-attributes (block / value)
  (setq value
    (vl-catch-all-apply 'vla-GetConstantAttributes (list block)))
  (zomo:variant-object-list value))

(defun zomo:title-reference-attributes (block / result attribute tag existing item)
  (setq result (zomo:get-attributes block))
  (foreach attribute (zomo:title-constant-attributes block)
    (setq tag (zomo:title-safe-get attribute 'TagString) existing nil)
    (if tag
      (progn
        (setq tag (strcase tag))
        (foreach item result
          (if (= tag (strcase (zomo:title-safe-get item 'TagString)))
            (setq existing t)))
        (if (not existing) (setq result (append result (list attribute)))))))
  result)

(defun zomo:title-attribute-values (block / result attribute tag value)
  (setq result nil)
  (foreach attribute (zomo:title-reference-attributes block)
    (setq tag (zomo:title-safe-get attribute 'TagString)
          value (zomo:title-safe-get attribute 'TextString))
    (if (and tag (= (type value) 'STR))
      (setq result (cons (cons (strcase tag) value) result))))
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

(defun zomo:title-attribute-by-tag (attributes tag / result attribute attribute-tag)
  (setq result nil)
  (foreach attribute attributes
    (setq attribute-tag (zomo:title-safe-get attribute 'TagString))
    (if (and attribute-tag (= tag (strcase attribute-tag)))
      (setq result attribute)))
  result)

(defun zomo:restore-title-attributes (block values expected-tags /
                                      attributes current-tags attribute pair result restored tag
                                      current-value verified-value)
  (setq attributes (zomo:title-reference-attributes block)
        current-tags (zomo:title-tags-from-objects attributes)
        restored (zomo:title-tag-sets-equal-p current-tags expected-tags))
  ;; An expected non-empty tag set can never pass through an empty attribute loop.
  (if (and expected-tags (null attributes)) (setq restored nil))
  (foreach tag expected-tags
    (if restored
      (progn
        (setq attribute (zomo:title-attribute-by-tag attributes tag)
              pair (assoc tag values))
        (if (or (null attribute) (null pair) (/= (type (cdr pair)) 'STR))
          (setq restored nil)
          (progn
            (setq current-value (zomo:title-safe-get attribute 'TextString))
            (if (null current-value)
              (setq restored nil)
              (if (/= current-value (cdr pair))
                (progn
                  (setq result
                    (vl-catch-all-apply 'vla-put-TextString
                      (list attribute (cdr pair)))
                        verified-value
                          (zomo:title-safe-get attribute 'TextString))
                  (if (or (vl-catch-all-error-p result)
                          (null verified-value)
                          (/= verified-value (cdr pair)))
                    (setq restored nil))))))))))
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

(defun zomo:title-shift-point-x (point shift)
  (if point
    (list (+ (car point) shift)
          (cadr point)
          (if (caddr point) (caddr point) 0.0))
    nil))

(defun zomo:title-add-attribute-definition (new-block metadata source-left source-right
                                             target-left target-right /
                                             bbox center midpoint shift insertion alignment-point
                                             attribute result ok)
  (setq bbox (zomo:title-alist-value 'bbox metadata)
        midpoint (/ (+ source-left source-right) 2.0)
        center (if bbox (/ (+ (caar bbox) (caadr bbox)) 2.0) nil))
  (if (null center)
    nil
    (progn
      (setq shift
        (if (<= center midpoint)
          (- target-left source-left)
          (- target-right source-right))
            insertion
              (zomo:title-shift-point-x
                (zomo:title-alist-value 'insertion-point metadata) shift)
            alignment-point
              (zomo:title-shift-point-x
                (zomo:title-alist-value 'alignment-point metadata) shift)
            result
              (vl-catch-all-apply 'vla-AddAttribute
                (list new-block
                  (zomo:title-alist-value 'height metadata)
                  (zomo:title-alist-value 'mode metadata)
                  (if (zomo:title-alist-value 'prompt metadata)
                    (zomo:title-alist-value 'prompt metadata) "")
                  (zomo:pt3 insertion)
                  (zomo:title-alist-value 'tag metadata)
                  (if (zomo:title-alist-value 'default metadata)
                    (zomo:title-alist-value 'default metadata) ""))))
      (if (vl-catch-all-error-p result)
        nil
        (progn
          (setq attribute result
                ok
                  (and
                    (zomo:title-safe-put attribute 'StyleName
                      (zomo:title-alist-value 'style-name metadata))
                    (zomo:title-safe-put attribute 'Layer
                      (zomo:title-alist-value 'layer metadata))
                    (zomo:title-safe-put attribute 'Linetype
                      (zomo:title-alist-value 'linetype metadata))
                    (zomo:title-safe-put attribute 'Color
                      (zomo:title-alist-value 'color metadata))
                    (zomo:title-safe-put attribute 'Lineweight
                      (zomo:title-alist-value 'lineweight metadata))
                    (zomo:title-safe-put attribute 'Rotation
                      (zomo:title-alist-value 'rotation metadata))
                    (zomo:title-safe-put attribute 'ScaleFactor
                      (zomo:title-alist-value 'scale-factor metadata))
                    (zomo:title-safe-put attribute 'ObliqueAngle
                      (zomo:title-alist-value 'oblique-angle metadata))
                    (zomo:title-safe-put attribute 'TextGenerationFlag
                      (zomo:title-alist-value 'text-generation-flag metadata))
                    (zomo:title-safe-put attribute 'Thickness
                      (zomo:title-alist-value 'thickness metadata))
                    (zomo:title-safe-put attribute 'Alignment
                      (zomo:title-alist-value 'alignment metadata))
                    (zomo:title-safe-put attribute 'TextAlignmentPoint alignment-point)))
          (if ok
            attribute
            (progn
              (zomo:title-delete-status attribute)
              nil)))))))

(defun zomo:title-rebuild-attribute-definitions (new-block metadata-list
                                                  source-left source-right
                                                  target-left target-right /
                                                  result ok metadata attribute)
  (setq result nil ok t)
  (foreach metadata metadata-list
    (if ok
      (progn
        (setq attribute
          (zomo:title-add-attribute-definition
            new-block metadata source-left source-right target-left target-right))
        (if attribute
          (setq result (cons attribute result))
          (setq ok nil)))))
  (list (cons 'ok ok) (cons 'objects (reverse result))))

(defun zomo:bbox-contained-p (inner outer tolerance)
  (and inner outer
       (>= (caar inner) (- (caar outer) tolerance))
       (>= (cadar inner) (- (cadar outer) tolerance))
       (<= (caadr inner) (+ (caadr outer) tolerance))
       (<= (cadadr inner) (+ (cadadr outer) tolerance))))

(defun zomo:title-objects-contained-p (objects frame frame-bbox tolerance /
                                        ok object bbox)
  (setq ok t)
  (foreach object objects
    (if (and ok (/= object frame))
      (progn
        (setq bbox (zomo:bbox object))
        (if (not (zomo:bbox-contained-p bbox frame-bbox tolerance))
          (setq ok nil)))))
  ok)

(defun zomo:title-translate-bbox (bbox offset / minimum maximum)
  (setq minimum (car bbox) maximum (cadr bbox))
  (list
    (mapcar '+ minimum offset)
    (mapcar '+ maximum offset)))

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

(defun zomo:title-unrotated-p (block tolerance / rotation)
  (setq rotation (vl-catch-all-apply 'vla-get-Rotation (list block)))
  (and (not (vl-catch-all-error-p rotation))
       (<= (abs rotation) tolerance)))

(defun zomo:rebuild-title (source-handle old-reference-value target-left target-right
                           attributes occupied-rects tolerance / document blocks source
                           old-reference owner values base-point base-coordinates copy
                           exploded frame source-frame-bbox old-left old-right block-name
                           new-block copied copied-list new-frame new-frame-bbox new-reference
                           new-bbox target-local-left target-local-right error-value success
                           attributes-restored delete-status review-needed source-definition
                           source-attribute-objects source-attribute-tags attribute-definitions
                           attribute-metadata source-definition-attribute-tags
                           source-local-left source-local-right attribute-rebuild-result
                           new-attribute-definitions new-definition-attribute-tags
                           new-definition-contained new-reference-attributes
                           new-reference-attribute-tags new-reference-attributes-contained
                           new-frame-world-bbox cleanup-status)
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
            source-definition (zomo:title-block-definition blocks source)
            source-attribute-objects (zomo:title-reference-attributes source)
            source-attribute-tags
              (zomo:title-tags-from-objects source-attribute-objects)
            attribute-definitions
              (zomo:title-attribute-definitions source-definition)
            attribute-metadata
              (zomo:title-filter-attribute-metadata
                (zomo:title-attribute-metadata-list attribute-definitions)
                source-attribute-tags)
            source-definition-attribute-tags
              (zomo:title-tags-from-metadata attribute-metadata)
            values
              (zomo:merge-attribute-values
                (zomo:title-attribute-values source) attributes)
            base-point (vl-catch-all-apply 'vla-get-InsertionPoint (list source)))
      (if (or (null owner) (null source-definition)
              (vl-catch-all-error-p base-point)
              (null (setq base-coordinates (zomo:title-point-list base-point)))
              (not (zomo:title-unit-scale-p source tolerance))
              (not (zomo:title-unrotated-p source tolerance)))
        (list (cons 'status "ERROR") (cons 'message "SOURCE_TITLE_UNREADABLE"))
        (if (not
              (zomo:title-tag-sets-equal-p
                source-attribute-tags source-definition-attribute-tags))
          (list (cons 'status "ERROR") (cons 'message "TITLE_ATTRIBUTE_TAG_MISMATCH"))
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
                                        source-local-left (- old-left (car base-coordinates))
                                        source-local-right (- old-right (car base-coordinates))
                                        attribute-rebuild-result
                                          (zomo:title-rebuild-attribute-definitions
                                            new-block attribute-metadata
                                            source-local-left source-local-right
                                            target-local-left target-local-right)
                                        new-attribute-definitions
                                          (zomo:title-alist-value 'objects attribute-rebuild-result)
                                        new-definition-attribute-tags
                                          (zomo:title-tags-from-objects
                                            new-attribute-definitions)
                                        new-definition-contained
                                          (and
                                            (zomo:title-alist-value 'ok attribute-rebuild-result)
                                            new-frame-bbox
                                            (zomo:title-tag-sets-equal-p
                                              source-attribute-tags
                                              new-definition-attribute-tags)
                                            (zomo:title-objects-contained-p
                                              (append copied-list new-attribute-definitions)
                                              new-frame new-frame-bbox tolerance))
                                        new-reference
                                          (vl-catch-all-apply 'vla-InsertBlock
                                            (list owner (zomo:pt3 base-coordinates)
                                                  block-name 1.0 1.0 1.0 0.0)))
                                  (if (vl-catch-all-error-p new-reference)
                                    (progn
                                      (setq new-reference nil error-value "TITLE_INSERT_FAILED"))
                                    (progn
                                      (zomo:title-copy-properties source new-reference)
                                      (setq new-reference-attributes
                                              (zomo:title-reference-attributes new-reference)
                                            new-reference-attribute-tags
                                              (zomo:title-tags-from-objects
                                                new-reference-attributes)
                                            attributes-restored
                                              (zomo:restore-title-attributes
                                                new-reference values source-attribute-tags)
                                            new-frame-world-bbox
                                              (if new-frame-bbox
                                                (zomo:title-translate-bbox
                                                  new-frame-bbox base-coordinates)
                                                nil)
                                            new-reference-attributes-contained
                                              (zomo:title-objects-contained-p
                                                new-reference-attributes nil
                                                new-frame-world-bbox tolerance)
                                            new-bbox (zomo:bbox new-reference)
                                            success
                                              (and
                                                new-definition-contained
                                                (zomo:title-tag-sets-equal-p
                                                  source-attribute-tags
                                                  new-reference-attribute-tags)
                                                attributes-restored
                                                new-reference-attributes-contained
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
                                          (cond
                                            ((not
                                              (zomo:title-tag-sets-equal-p
                                                source-attribute-tags
                                                new-definition-attribute-tags))
                                              "TITLE_ATTRIBUTE_TAG_MISMATCH")
                                            ((not
                                              (zomo:title-tag-sets-equal-p
                                                source-attribute-tags
                                                new-reference-attribute-tags))
                                              "TITLE_ATTRIBUTE_TAG_MISMATCH")
                                            ((not attributes-restored)
                                              "TITLE_ATTRIBUTE_VALUE_MISMATCH")
                                            ((or (not new-definition-contained)
                                                 (not new-reference-attributes-contained))
                                              "TITLE_CONTENT_OUTSIDE_FRAME")
                                            (t
                                            "TITLE_INVARIANT_FAILED"))))))))))))))))
              ;; Exploded paper-space copies are always best-effort cleaned,
              ;; even when an earlier mutation already made the state uncertain.
              (setq cleanup-status (zomo:cleanup-objects exploded))
              (if (/= cleanup-status "DELETED")
                (setq success nil review-needed t
                      error-value "TITLE_CLEANUP_UNCONFIRMED"))
              (setq exploded nil)
              (if (and success (= cleanup-status "DELETED") old-reference)
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
                        "TITLE_REBUILD_FAILED")))))))))))))

(princ)
