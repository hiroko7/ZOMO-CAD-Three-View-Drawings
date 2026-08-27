(vl-load-com)

; This file is intentionally read-only with respect to the active drawing.
; Load zomo-common.lsp before calling zomo:inspect-template.

(defun zomo:hex-digit (number)
  (substr "0123456789ABCDEF" (1+ number) 1))

(defun zomo:hex2 (number)
  (strcat
    (zomo:hex-digit (fix (/ number 16)))
    (zomo:hex-digit (rem number 16))))

(defun zomo:json-escape (value / text index code character escaped)
  (setq text
    (if (= (type value) 'STR)
      value
      (vl-princ-to-string value)))
  (setq index 1
        escaped "")
  (while (<= index (strlen text))
    (setq character (substr text index 1)
          code (ascii character))
    (setq escaped
      (strcat
        escaped
        (cond
          ((= code 34) "\\\"")
          ((= code 92) "\\\\")
          ((= code 8) "\\b")
          ((= code 9) "\\t")
          ((= code 10) "\\n")
          ((= code 12) "\\f")
          ((= code 13) "\\r")
          ((< code 32) (strcat "\\u00" (zomo:hex2 code)))
          (T character))))
    (setq index (1+ index)))
  escaped)

(defun zomo:json-string (value)
  (strcat "\"" (zomo:json-escape value) "\""))

(defun zomo:json-number (value / text)
  (if (numberp value)
    (progn
      (setq text (rtos (float value) 2 15))
      (cond
        ((= (substr text 1 1) ".") (strcat "0" text))
        ((= (substr text 1 2) "-.") (strcat "-0" (substr text 2)))
        (T text)))
    "null"))

(defun zomo:json-bool (value)
  (if (= value :vlax-true) "true" "false"))

(defun zomo:join (items separator / item result)
  (if items
    (progn
      (setq result (car items))
      (foreach item (cdr items)
        (setq result (strcat result separator item)))
      result)
    ""))

(defun zomo:json-array (values)
  (strcat "[" (zomo:join values ",") "]"))

(defun zomo:json-member (pair)
  (strcat (zomo:json-string (car pair)) ":" (cdr pair)))

(defun zomo:json-object (members)
  (strcat
    "{"
    (zomo:join (mapcar 'zomo:json-member members) ",")
    "}"))

(defun zomo:safe-property (object property fallback / result)
  (setq result
    (vl-catch-all-apply 'vlax-get-property (list object property)))
  (if (vl-catch-all-error-p result) fallback result))

(defun zomo:object-type (object)
  (zomo:safe-property object 'ObjectName ""))

(defun zomo:point-json (point)
  (zomo:json-array (mapcar 'zomo:json-number point)))

(defun zomo:bbox-json (object / bounds)
  (setq bounds (zomo:bbox object))
  (if bounds
    (zomo:json-array (mapcar 'zomo:point-json bounds))
    "null"))

(defun zomo:attribute-tags-json (block / attribute attributes tags)
  (setq attributes (zomo:get-attributes block)
        tags nil)
  (foreach attribute attributes
    (setq tags
      (cons
        (zomo:json-string
          (zomo:safe-property attribute 'TagString ""))
        tags)))
  (zomo:json-array (reverse tags)))

(defun zomo:effective-block-name-json (object / object-name block-name)
  (setq object-name (zomo:object-type object))
  (if (= object-name "AcDbBlockReference")
    (progn
      (setq block-name
        (zomo:safe-property
          object
          'EffectiveName
          (zomo:safe-property object 'Name "")))
      (zomo:json-string block-name))
    "null"))

(defun zomo:paper-entity-json (object)
  (zomo:json-object
    (list
      (cons "objectType" (zomo:json-string (zomo:object-type object)))
      (cons "effectiveBlockName" (zomo:effective-block-name-json object))
      (cons "attributeTags" (zomo:attribute-tags-json object))
      (cons "paperSpaceBoundingBox" (zomo:bbox-json object)))))

(defun zomo:paper-entities-json (layout / block entries object)
  (setq entries nil
        block (zomo:safe-property layout 'Block nil))
  (if block
    (vlax-for object block
      (setq entries (cons (zomo:paper-entity-json object) entries))))
  (zomo:json-array (reverse entries)))

(defun zomo:layer-json (layer)
  (zomo:json-object
    (list
      (cons "name" (zomo:json-string (zomo:safe-property layer 'Name "")))
      (cons "objectType" (zomo:json-string (zomo:object-type layer)))
      (cons "linetype" (zomo:json-string (zomo:safe-property layer 'Linetype "")))
      (cons "color" (zomo:json-number (zomo:safe-property layer 'Color 0))))))

(defun zomo:layers-json (layers / entries layer)
  (setq entries nil)
  (vlax-for layer layers
    (setq entries (cons (zomo:layer-json layer) entries)))
  (zomo:json-array (reverse entries)))

(defun zomo:layout-json (layout / model-type)
  (setq model-type (zomo:safe-property layout 'ModelType :vlax-false))
  (zomo:json-object
    (list
      (cons "name" (zomo:json-string (zomo:safe-property layout 'Name "")))
      (cons "objectType" (zomo:json-string (zomo:object-type layout)))
      (cons "isModel" (zomo:json-bool model-type))
      (cons
        "paperSpaceEntities"
        (if (= model-type :vlax-true)
          "[]"
          (zomo:paper-entities-json layout))))))

(defun zomo:layouts-json (layouts / entries layout)
  (setq entries nil)
  (vlax-for layout layouts
    (setq entries (cons (zomo:layout-json layout) entries)))
  (zomo:json-array (reverse entries)))

(defun zomo:block-json (block)
  (zomo:json-object
    (list
      (cons "name" (zomo:json-string (zomo:safe-property block 'Name "")))
      (cons "objectType" (zomo:json-string (zomo:object-type block)))
      (cons "isLayout" (zomo:json-bool (zomo:safe-property block 'IsLayout :vlax-false)))
      (cons "isXref" (zomo:json-bool (zomo:safe-property block 'IsXRef :vlax-false))))))

(defun zomo:blocks-json (blocks / block entries)
  (setq entries nil)
  (vlax-for block blocks
    (setq entries (cons (zomo:block-json block) entries)))
  (zomo:json-array (reverse entries)))

(defun zomo:named-object-json (object)
  (zomo:json-object
    (list
      (cons "name" (zomo:json-string (zomo:safe-property object 'Name "")))
      (cons "objectType" (zomo:json-string (zomo:object-type object))))))

(defun zomo:named-collection-json (collection / entries object)
  (setq entries nil)
  (vlax-for object collection
    (setq entries (cons (zomo:named-object-json object) entries)))
  (zomo:json-array (reverse entries)))

(defun zomo:document-json (document)
  (zomo:json-object
    (list
      (cons "name" (zomo:json-string (zomo:safe-property document 'Name "")))
      (cons "fullName" (zomo:json-string (zomo:safe-property document 'FullName "")))
      (cons "objectType" (zomo:json-string (zomo:object-type document))))))

(defun zomo:template-report-json (document)
  (zomo:json-object
    (list
      ; ZOMO_TOP_LEVEL_KEYS_BEGIN
      (cons "document" (zomo:document-json document))
      (cons "layers" (zomo:layers-json (vla-get-Layers document)))
      (cons "layouts" (zomo:layouts-json (vla-get-Layouts document)))
      (cons "blocks" (zomo:blocks-json (vla-get-Blocks document)))
      (cons "dimstyles" (zomo:named-collection-json (vla-get-DimStyles document)))
      (cons "textstyles" (zomo:named-collection-json (vla-get-TextStyles document)))
      ; ZOMO_TOP_LEVEL_KEYS_END
      )))

(defun zomo:write-json-file (path json / stream write-result close-result)
  (setq stream
    (vl-catch-all-apply 'open (list path "w" "utf8")))
  (if (or (vl-catch-all-error-p stream) (null stream))
    (error
      (strcat
        "ZOMO_INSPECT_TEMPLATE_WRITE_ERROR: cannot open report path: "
        path)))
  (setq write-result
    (vl-catch-all-apply 'write-line (list json stream)))
  (setq close-result
    (vl-catch-all-apply 'close (list stream)))
  (cond
    ((vl-catch-all-error-p write-result)
      (error
        (strcat
          "ZOMO_INSPECT_TEMPLATE_WRITE_ERROR: cannot write report: "
          (vl-catch-all-error-message write-result))))
    ((vl-catch-all-error-p close-result)
      (error
        (strcat
          "ZOMO_INSPECT_TEMPLATE_WRITE_ERROR: cannot close report: "
          (vl-catch-all-error-message close-result))))
    (T T)))

(defun zomo:inspect-template (report-path / document report result)
  (if (or (/= (type report-path) 'STR) (= report-path ""))
    (error "ZOMO_INSPECT_TEMPLATE_WRITE_ERROR: report path must be a non-empty string"))
  (setq document
    (vla-get-ActiveDocument (vlax-get-acad-object)))
  (setq result
    (vl-catch-all-apply 'zomo:template-report-json (list document)))
  (if (vl-catch-all-error-p result)
    (error
      (strcat
        "ZOMO_INSPECT_TEMPLATE_INSPECTION_ERROR: "
        (vl-catch-all-error-message result))))
  (setq report result)
  (zomo:write-json-file report-path report))

(princ)
