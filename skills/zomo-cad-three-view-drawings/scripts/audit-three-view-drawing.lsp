(vl-load-com)

; Save-preflight audit for a paper-space front / side / plan drawing.
; Load zomo-common.lsp first.  Each view-title-pairs item is an alist containing
; role, viewport-handle, title-handle and, when applicable, isolation-verifier,
; expected-scale, preset-checksum, actual-preset-checksum, output-path and
; visual-export-path.  The audit never saves, exports, or changes the drawing.

(defun zomo:audit-hex-digit (number)
  (substr "0123456789ABCDEF" (1+ number) 1))

(defun zomo:audit-hex2 (number)
  (strcat (zomo:audit-hex-digit (fix (/ number 16)))
          (zomo:audit-hex-digit (rem number 16))))

(defun zomo:audit-json-escape (value / text index code character escaped)
  (setq text (if (= (type value) 'STR) value (vl-princ-to-string value))
        index 1
        escaped "")
  (while (<= index (strlen text))
    (setq character (substr text index 1)
          code (ascii character)
          escaped
            (strcat escaped
              (cond
                ((= code 34) "\\\"")
                ((= code 92) "\\\\")
                ((= code 8) "\\b")
                ((= code 9) "\\t")
                ((= code 10) "\\n")
                ((= code 12) "\\f")
                ((= code 13) "\\r")
                ((< code 32) (strcat "\\u00" (zomo:audit-hex2 code)))
                (T character))))
    (setq index (1+ index)))
  escaped)

(defun zomo:audit-json-string (value)
  (strcat "\"" (zomo:audit-json-escape value) "\""))

(defun zomo:audit-json-number (value / text)
  (if (numberp value)
    (progn
      (setq text (rtos (float value) 2 12))
      (cond ((= (substr text 1 1) ".") (strcat "0" text))
            ((= (substr text 1 2) "-.") (strcat "-0" (substr text 2)))
            (T text)))
    "null"))

(defun zomo:audit-join (items separator / result item)
  (if items
    (progn
      (setq result (car items))
      (foreach item (cdr items) (setq result (strcat result separator item)))
      result)
    ""))

(defun zomo:audit-json-array (items)
  (strcat "[" (zomo:audit-join items ",") "]"))

(defun zomo:audit-json-member (pair)
  (strcat (zomo:audit-json-string (car pair)) ":" (cdr pair)))

(defun zomo:audit-json-object (members)
  (strcat "{" (zomo:audit-join (mapcar 'zomo:audit-json-member members) ",") "}"))

(defun zomo:audit-value (key values / pair)
  (setq pair (assoc key values))
  (if pair (cdr pair) nil))

(defun zomo:audit-role (value)
  (cond ((= (type value) 'STR) (strcase value))
        ((= (type value) 'SYM) (strcase (vl-symbol-name value)))
        (T "UNSPECIFIED")))

(defun zomo:audit-object (document value / result)
  (cond
    ((vlax-objectp value) value)
    ((and (= (type value) 'STR) (> (strlen value) 0))
      (setq result (vl-catch-all-apply 'vla-HandleToObject (list document value)))
      (if (vl-catch-all-error-p result) nil result))
    (T nil)))

(defun zomo:audit-safe-get (object property fallback / result)
  (setq result (vl-catch-all-apply 'vlax-get-property (list object property)))
  (if (vl-catch-all-error-p result) fallback result))

(defun zomo:audit-live-p (object / result)
  (and object
       (not (vl-catch-all-error-p
              (setq result (vl-catch-all-apply 'vla-get-ObjectName (list object)))))))

(defun zomo:audit-bbox-rect (object / bbox)
  (setq bbox (zomo:bbox object))
  (if bbox
    (list (caar bbox) (cadar bbox) (caadr bbox) (cadadr bbox))
    nil))

(defun zomo:audit-positive-overlap-p (a b tolerance / left bottom right top)
  (and a b
       (setq left (max (nth 0 a) (nth 0 b))
             bottom (max (nth 1 a) (nth 1 b))
             right (min (nth 2 a) (nth 2 b))
             top (min (nth 3 a) (nth 3 b)))
       (> (- right left) tolerance)
       (> (- top bottom) tolerance)))

(defun zomo:audit-issue (code role expected actual severity)
  (list (cons 'code code) (cons 'role role) (cons 'expected expected)
        (cons 'actual actual) (cons 'severity severity)))

(defun zomo:audit-add-issue (issues code role expected actual severity)
  (cons (zomo:audit-issue code role expected actual severity) issues))

(defun zomo:audit-issue-json (issue)
  (zomo:audit-json-object
    (list
      (cons "code" (zomo:audit-json-string (zomo:audit-value 'code issue)))
      (cons "role" (zomo:audit-json-string (zomo:audit-value 'role issue)))
      (cons "expected" (zomo:audit-json-string (zomo:audit-value 'expected issue)))
      (cons "actual" (zomo:audit-json-string (zomo:audit-value 'actual issue)))
      (cons "severity" (zomo:audit-json-string (zomo:audit-value 'severity issue))))))

(defun zomo:audit-has-errors-p (issues / issue found)
  (setq found nil)
  (foreach issue issues
    (if (= (zomo:audit-value 'severity issue) "ERROR") (setq found T)))
  found)

(defun zomo:audit-viewport-p (object)
  (= (zomo:audit-safe-get object 'ObjectName "") "AcDbViewport"))

(defun zomo:audit-active-paper-viewports (layout / block object number result)
  (setq result nil
        block (zomo:audit-safe-get layout 'Block nil))
  (if block
    (vlax-for object block
      (if (and (zomo:audit-viewport-p object)
               (setq number (zomo:audit-safe-get object 'Number 0))
               (> number 1))
        (setq result (cons object result)))))
  (reverse result))

(defun zomo:audit-expected-title-tags ()
  '("PROJECT_NAME" "DRAWING_TITLE" "DATE" "SCALE" "DESIGN" "DRAWN" "CHECKED" "VERSION"))

(defun zomo:audit-title-tags-present-p (title / attributes attribute tags tag expected ok)
  (setq attributes (zomo:get-attributes title)
        tags nil)
  (foreach attribute attributes
    (setq tag (strcase (zomo:audit-safe-get attribute 'TagString ""))
          tags (cons tag tags)))
  (setq ok T)
  (foreach expected (zomo:audit-expected-title-tags)
    (if (not (member expected tags)) (setq ok nil)))
  ok)

(defun zomo:audit-title-unit-scale-p (title tolerance)
  (and (<= (abs (- (zomo:audit-safe-get title 'XScaleFactor 0.0) 1.0)) tolerance)
       (<= (abs (- (zomo:audit-safe-get title 'YScaleFactor 0.0) 1.0)) tolerance)
       (<= (abs (- (zomo:audit-safe-get title 'ZScaleFactor 0.0) 1.0)) tolerance)))

(defun zomo:audit-call-isolation-verifier (pair viewport / verifier result)
  (setq verifier (zomo:audit-value 'isolation-verifier pair))
  (if (= (type verifier) 'SYM)
    (progn
      (setq result (vl-catch-all-apply verifier (list viewport pair)))
      (and (not (vl-catch-all-error-p result)) result))
    nil))

(defun zomo:audit-curve-length (object / entity end-param value)
  (setq entity (vlax-vla-object->ename object)
        end-param (vl-catch-all-apply 'vlax-curve-getEndParam (list entity)))
  (if (vl-catch-all-error-p end-param)
    nil
    (progn
      (setq value (vl-catch-all-apply 'vlax-curve-getDistAtParam (list entity end-param)))
      (if (vl-catch-all-error-p value) nil value))))

(defun zomo:audit-model-geometry (document tolerance / model object object-name bbox
                                             length-result spline-count
                                             zero-length-count invalid-count dimension-count hidden-dimensions)
  (setq model (vla-get-ModelSpace document)
        spline-count 0 zero-length-count 0 invalid-count 0 dimension-count 0 hidden-dimensions 0)
  (vlax-for object model
    (setq object-name (zomo:audit-safe-get object 'ObjectName "")
          bbox (zomo:bbox object))
    (if (= object-name "AcDbSpline") (setq spline-count (1+ spline-count)))
    (if (null bbox) (setq invalid-count (1+ invalid-count)))
    (if (wcmatch object-name "AcDb*Dimension")
      (progn
        (setq dimension-count (1+ dimension-count))
        (if (= (zomo:audit-safe-get object 'Visible :vlax-true) :vlax-false)
          (setq hidden-dimensions (1+ hidden-dimensions)))))
    (if (wcmatch object-name "AcDbLine,AcDb*Polyline,AcDbArc,AcDbCircle,AcDbEllipse,AcDbSpline")
      (progn
        (setq length-result (zomo:audit-curve-length object))
        (if (and (numberp length-result) (<= length-result tolerance))
          (setq zero-length-count (1+ zero-length-count))))))
  (list (cons 'spline-count spline-count)
        (cons 'zero-length-count zero-length-count)
        (cons 'invalid-count invalid-count)
        (cons 'dimension-count dimension-count)
        (cons 'hidden-dimensions hidden-dimensions)))

(defun zomo:audit-report-json-legacy (passed issues measurements / issue-json)
  (setq issue-json (mapcar 'zomo:audit-issue-json (reverse issues)))
  (zomo:audit-json-object
    (list
      (cons "passed" (if passed "true" "false"))
      (cons "issues" (zomo:audit-json-array issue-json))
      (cons "measurements" measurements))))

(defun zomo:audit-write-report-legacy (path json / stream write-result close-result)
  (setq stream (vl-catch-all-apply 'open (list path "w" "utf8")))
  (cond
    ((vl-catch-all-error-p stream)
      (prompt (strcat "\nZOMO_AUDIT_THREE_VIEW_WRITE_ERROR: cannot open report path: " path))
      nil)
    (T
      (setq write-result (vl-catch-all-apply 'write-line (list json stream))
      close-result (vl-catch-all-apply 'close (list stream)))
      (cond
        ((vl-catch-all-error-p write-result)
          (prompt "\nZOMO_AUDIT_THREE_VIEW_WRITE_ERROR: cannot write report.") nil)
        ((vl-catch-all-error-p close-result)
          (prompt "\nZOMO_AUDIT_THREE_VIEW_WRITE_ERROR: cannot close report.") nil)
        (T T)))))

(defun zomo:audit-three-view-legacy (layout-name view-title-pairs report-path /
                               document layout pairs viewport-count viewports pair role
                               viewport title viewport-rect title-rect expected-scale actual-scale
                               tolerance issues title-rects geometry visual-export-path visual-status
                               output-path expected-checksum actual-checksum passed measurements json layout-result)
  (setq tolerance 0.01
        issues nil
        document (vla-get-ActiveDocument (vlax-get-acad-object))
        pairs (if (listp view-title-pairs) view-title-pairs nil)
        layout nil)
  (if (= (type layout-name) 'STR)
    (setq layout-result
      (vl-catch-all-apply 'vla-Item (list (vla-get-Layouts document) layout-name))
      layout (if (vl-catch-all-error-p layout-result) nil layout-result)))
  (if (null layout)
    (setq issues (zomo:audit-add-issue issues "VIEWPORT_COUNT" "ALL" "existing paper layout" "layout not found" "ERROR")
          viewports nil)
    (setq viewports (zomo:audit-active-paper-viewports layout)))
  (setq viewport-count (length viewports))
  (if (/= viewport-count 3)
    (setq issues (zomo:audit-add-issue issues "VIEWPORT_COUNT" "ALL" "3" (itoa viewport-count) "ERROR")))
  (if (/= (length pairs) 3)
    (setq issues (zomo:audit-add-issue issues "VIEWPORT_COUNT" "ALL" "3 view-title pairs" (itoa (length pairs)) "ERROR")))
  (foreach pair pairs
    (setq role (zomo:audit-role (zomo:audit-value 'role pair))
          viewport (zomo:audit-object document (zomo:audit-value 'viewport-handle pair))
          title (zomo:audit-object document (zomo:audit-value 'title-handle pair))
          viewport-rect (if viewport (zomo:audit-bbox-rect viewport) nil)
          title-rect (if title (zomo:audit-bbox-rect title) nil)
          expected-scale (zomo:audit-value 'expected-scale pair)
          actual-scale (if viewport (zomo:audit-safe-get viewport 'CustomScale nil) nil))
    (if (or (null viewport) (not (zomo:audit-live-p viewport)))
      (setq issues
        (zomo:audit-add-issue issues "VIEWPORT_LOCKED" role "existing locked viewport" "missing" "ERROR")
        issues (zomo:audit-add-issue issues "VIEWPORT_SCALE" role "declared scale" "missing viewport" "ERROR")
        issues (zomo:audit-add-issue issues "VIEW_ISOLATION" role "verified isolated view" "missing viewport" "ERROR"))
      (progn
        (if (/= (zomo:audit-safe-get viewport 'DisplayLocked :vlax-false) :vlax-true)
          (setq issues (zomo:audit-add-issue issues "VIEWPORT_LOCKED" role "true" "false" "ERROR")))
        (if (or (not (numberp expected-scale))
                (not (numberp actual-scale))
                (> (abs (- expected-scale actual-scale)) tolerance))
          (setq issues (zomo:audit-add-issue issues "VIEWPORT_SCALE" role
                        (if (numberp expected-scale) (rtos expected-scale 2 6) "declared scale")
                        (if (numberp actual-scale) (rtos actual-scale 2 6) "unavailable") "ERROR")))
        (if (not (zomo:audit-call-isolation-verifier pair viewport))
          (setq issues (zomo:audit-add-issue issues "VIEW_ISOLATION" role "verified isolated view" "not verified" "ERROR")))))
    (if (or (null title) (null title-rect) (null viewport-rect))
      (setq issues
        (zomo:audit-add-issue issues "TITLE_VIEWPORT_LEFT" role "left edges aligned" "missing title or bounds" "ERROR")
        issues (zomo:audit-add-issue issues "TITLE_VIEWPORT_RIGHT" role "right edges aligned" "missing title or bounds" "ERROR")
        issues (zomo:audit-add-issue issues "TITLE_VIEWPORT_WIDTH" role "same width" "missing title or bounds" "ERROR"))
      (progn
        (if (> (abs (- (nth 0 title-rect) (nth 0 viewport-rect))) tolerance)
          (setq issues (zomo:audit-add-issue issues "TITLE_VIEWPORT_LEFT" role "left edges aligned" "misaligned" "ERROR")))
        (if (> (abs (- (nth 2 title-rect) (nth 2 viewport-rect))) tolerance)
          (setq issues (zomo:audit-add-issue issues "TITLE_VIEWPORT_RIGHT" role "right edges aligned" "misaligned" "ERROR")))
        (if (> (abs (- (- (nth 2 title-rect) (nth 0 title-rect))
                          (- (nth 2 viewport-rect) (nth 0 viewport-rect)))) tolerance)
          (setq issues (zomo:audit-add-issue issues "TITLE_VIEWPORT_WIDTH" role "same width" "different width" "ERROR")))))
    (if (or (null title) (not (zomo:audit-title-unit-scale-p title tolerance)))
      (setq issues (zomo:audit-add-issue issues "TITLE_UNIFORM_SCALE" role "1/1/1" "not 1/1/1" "ERROR")))
    (if (or (null title) (not (zomo:audit-title-tags-present-p title)))
      (setq issues (zomo:audit-add-issue issues "FRAME_ATTRIBUTES" role "all required frame attributes" "missing attributes" "ERROR")))
    (setq title-rects (cons (cons role title-rect) title-rects))
    (setq expected-checksum (zomo:audit-value 'preset-checksum pair)
          actual-checksum (zomo:audit-value 'actual-preset-checksum pair))
    (if (or (null expected-checksum) (null actual-checksum) (/= expected-checksum actual-checksum))
      (setq issues (zomo:audit-add-issue issues "PRESET_CHECKSUM" role "declared preset checksum" "missing or mismatched" "ERROR")))
    (setq output-path (zomo:audit-value 'output-path pair))
    (if (or (not (= (type output-path) 'STR)) (not (findfile output-path)))
      (setq issues (zomo:audit-add-issue issues "OUTPUT_SAVED" role "authorized output file exists" "not confirmed" "ERROR"))))
  (while title-rects
    (foreach pair (cdr title-rects)
      (if (zomo:audit-positive-overlap-p (cdar title-rects) (cdr pair) tolerance)
        (setq issues (zomo:audit-add-issue issues "TITLE_PAIR_OVERLAP" (caar title-rects)
                      "no positive-area title overlap" (car pair) "ERROR"))))
    (setq title-rects (cdr title-rects)))
  (setq geometry (zomo:audit-model-geometry document tolerance))
  (if (> (zomo:audit-value 'hidden-dimensions geometry) 0)
    (setq issues (zomo:audit-add-issue issues "DIMENSION_VISIBILITY" "ALL" "visible dimensions"
                  (itoa (zomo:audit-value 'hidden-dimensions geometry)) "ERROR")))
  (if (> (zomo:audit-value 'spline-count geometry) 0)
    (setq issues (zomo:audit-add-issue issues "SPLINE_COUNT" "ALL" "0 or documented review"
                  (itoa (zomo:audit-value 'spline-count geometry)) "WARNING")))
  (if (> (zomo:audit-value 'zero-length-count geometry) 0)
    (setq issues (zomo:audit-add-issue issues "ZERO_LENGTH_COUNT" "ALL" "0"
                  (itoa (zomo:audit-value 'zero-length-count geometry)) "ERROR")))
  (if (> (zomo:audit-value 'invalid-count geometry) 0)
    (setq issues (zomo:audit-add-issue issues "INVALID_GEOMETRY" "ALL" "0 invalid objects"
                  (itoa (zomo:audit-value 'invalid-count geometry)) "ERROR")))
  (setq visual-export-path (if pairs (zomo:audit-value 'visual-export-path (car pairs)) nil)
        visual-status (if (and (= (type visual-export-path) 'STR) (findfile visual-export-path))
                        "EXPORTED_NOT_VISUALLY_REVIEWED" "NOT_EXPORTED"))
  (setq issues (zomo:audit-add-issue issues
                (if (= visual-status "NOT_EXPORTED") "VISUAL_EXPORT_UNAVAILABLE" "VISUAL_EXPORT_REVIEW_REQUIRED")
                "ALL" "manual PDF/image visual review" visual-status "WARNING"))
  (setq passed (not (zomo:audit-has-errors-p issues))
        measurements
          (zomo:audit-json-object
            (list
              (cons "viewportCount" (zomo:audit-json-number viewport-count))
              (cons "viewTitlePairCount" (zomo:audit-json-number (length pairs)))
              (cons "splineCount" (zomo:audit-json-number (zomo:audit-value 'spline-count geometry)))
              (cons "zeroLengthCount" (zomo:audit-json-number (zomo:audit-value 'zero-length-count geometry)))
              (cons "invalidGeometryCount" (zomo:audit-json-number (zomo:audit-value 'invalid-count geometry)))
              (cons "dimensionCount" (zomo:audit-json-number (zomo:audit-value 'dimension-count geometry)))
              (cons "visualExportStatus" (zomo:audit-json-string visual-status))))
        json (zomo:audit-report-json-legacy passed issues measurements))
  (if (and (= (type report-path) 'STR) (> (strlen report-path) 0))
    (if (not (zomo:audit-write-report-legacy report-path json))
      (setq issues (zomo:audit-add-issue issues "OUTPUT_SAVED" "REPORT" "writable UTF-8 report" "write failed" "ERROR")
            passed nil)))
  (list (cons 'status (if passed "PASS" "FAIL"))
        (cons 'passed passed)
        (cons 'issues (reverse issues))
        (cons 'measurements measurements)))

; Strict policy layer.  It replaces the early compatibility implementation above.
; It is deliberately read-only for the drawing; only the requested report is written.

(defun zomo:audit-proper-list-p (value / cursor)
  (setq cursor value)
  (while (consp cursor) (setq cursor (cdr cursor)))
  (null cursor))

(defun zomo:audit-alist-p (value / item ok)
  (setq ok (zomo:audit-proper-list-p value))
  (if ok
    (foreach item value
      (if (or (not (consp item)) (listp (car item))) (setq ok nil))))
  ok)

(defun zomo:audit-nonempty-string-p (value)
  (and (= (type value) 'STR) (> (strlen value) 0)))

(defun zomo:audit-canonical-path (path / found)
  (if (zomo:audit-nonempty-string-p path)
    (progn
      (setq found (findfile path))
      (strcase (vl-string-translate "/" "\\" (if found found path))))
    nil))

(defun zomo:audit-unique-p (values / remaining item ok)
  (setq remaining values ok T)
  (while (and remaining ok)
    (setq item (car remaining) remaining (cdr remaining))
    (if (member item remaining) (setq ok nil)))
  ok)

(defun zomo:audit-roles-exact-p (roles)
  (and (= (length roles) 3)
       (zomo:audit-unique-p roles)
       (member "FRONT" roles) (member "SIDE" roles) (member "PLAN" roles)))

(defun zomo:audit-isolation-pass-p (result / status)
  (cond
    ((= result T) T)
    ((and (zomo:audit-alist-p result)
          (setq status (zomo:audit-value 'status result))
          (= (strcase (vl-princ-to-string status)) "PASS")) T)
    (T nil)))

(defun zomo:audit-checksum-p (value)
  (and (zomo:audit-nonempty-string-p value)
       (= (strlen value) 64)
       (wcmatch (strcase value) "[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]*")))

(defun zomo:audit-output-authorized-p (document output-path source-path preset-path / active saved output source preset full-result saved-result)
  ; Reject an authorized output path when it is also a source or preset path.
  (setq full-result (vl-catch-all-apply 'vla-get-FullName (list document))
        saved-result (vl-catch-all-apply 'vla-get-Saved (list document))
        active (zomo:audit-canonical-path (if (vl-catch-all-error-p full-result) nil full-result))
        saved (if (vl-catch-all-error-p saved-result) :vlax-false saved-result)
        output (zomo:audit-canonical-path output-path)
        source (zomo:audit-canonical-path source-path)
        preset (zomo:audit-canonical-path preset-path))
  (and output active (= output active) (= saved :vlax-true)
       (or (null source) (/= output source))
       (or (null preset) (/= output preset))))

(defun zomo:audit-all-equal-p (values / first ok item)
  (setq first (car values) ok T)
  (foreach item (cdr values)
    (if (/= item first) (setq ok nil)))
  ok)

(defun zomo:audit-object-handle (object)
  (strcase (zomo:audit-safe-get object 'Handle "")))

(defun zomo:audit-layout-handle-list (viewports / result viewport)
  (setq result nil)
  (foreach viewport viewports (setq result (cons (zomo:audit-object-handle viewport) result)))
  (reverse result))

(defun zomo:audit-set-equal-p (left right)
  (and (= (length left) (length right))
       (zomo:audit-unique-p left) (zomo:audit-unique-p right)
       (vl-every '(lambda (item) (member item right)) left)))

(defun zomo:audit-title-attribute-value (title tag / attribute value)
  (setq value nil)
  (foreach attribute (zomo:get-attributes title)
    (if (= (strcase (zomo:audit-safe-get attribute 'TagString "")) tag)
      (setq value (zomo:audit-safe-get attribute 'TextString ""))))
  value)

(defun zomo:audit-title-attributes-filled-p (title / tag value ok)
  (setq ok T)
  (foreach tag (zomo:audit-expected-title-tags)
    (setq value (zomo:audit-title-attribute-value title tag))
    (if (not (zomo:audit-nonempty-string-p value)) (setq ok nil)))
  ok)

(defun zomo:audit-scale-text-matches-p (title actual-scale declared-text / value)
  (setq value (zomo:audit-title-attribute-value title "SCALE"))
  (and (numberp actual-scale) (zomo:audit-nonempty-string-p declared-text)
       (= (strcase value) (strcase declared-text))))

(defun zomo:audit-verified-dimension-evidence-p (evidence / verifier result)
  (setq verifier (zomo:audit-value 'dimension-verifier evidence)
        result (if (= (type verifier) 'SYM)
                 (vl-catch-all-apply verifier (list evidence))
                 nil))
  (and (zomo:audit-isolation-pass-p (if (vl-catch-all-error-p result) nil result))
       (= (zomo:audit-value 'model-space evidence) T)
       (= (zomo:audit-value 'paper-space evidence) T)
       (= (zomo:audit-value 'layer-visible evidence) T)
       (= (zomo:audit-value 'viewport-contained evidence) T)))

(defun zomo:audit-measurements-json (measurements / pair members value)
  (setq members nil)
  (foreach pair measurements
    (setq value (cdr pair))
    (setq members
      (cons (cons (vl-princ-to-string (car pair))
              (cond ((numberp value) (zomo:audit-json-number value))
                    ((= value T) "true") ((null value) "false")
                    (T (zomo:audit-json-string value)))) members)))
  (zomo:audit-json-object (reverse members)))

(defun zomo:audit-report-json (passed issues measurements / issue-json)
  (setq issue-json (mapcar 'zomo:audit-issue-json (reverse issues)))
  (zomo:audit-json-object
    (list (cons "passed" (if passed "true" "false"))
          (cons "issues" (zomo:audit-json-array issue-json))
          (cons "measurements" (zomo:audit-measurements-json measurements)))))

(defun zomo:audit-write-report (path json / temp stream write-result close-result rename-result)
  ; Atomic report publication: invalidate a previous report before preparing temp output,
  ; so a failed attempt cannot leave a stale passed=true report for this drawing.
  (if (not (zomo:audit-nonempty-string-p path))
    (progn (prompt "\nZOMO_AUDIT_THREE_VIEW_WRITE_ERROR: cannot open report path.") nil)
    (progn
      (if (findfile path) (vl-file-delete path))
      (setq temp (strcat path ".zomo-audit-tmp-" (itoa (getvar "MILLISECS")))
            stream (vl-catch-all-apply 'open (list temp "w" "utf8")))
      (cond
        ((or (null stream) (vl-catch-all-error-p stream))
          (prompt "\nZOMO_AUDIT_THREE_VIEW_WRITE_ERROR: cannot open temporary report.") nil)
        (T
          (setq write-result (vl-catch-all-apply 'write-line (list json stream))
                close-result (vl-catch-all-apply 'close (list stream)))
          (if (or (vl-catch-all-error-p write-result) (vl-catch-all-error-p close-result))
            (progn (if (findfile temp) (vl-file-delete temp))
                   (prompt "\nZOMO_AUDIT_THREE_VIEW_WRITE_ERROR: cannot write or close report.") nil)
            (progn
              (setq rename-result (vl-catch-all-apply 'vl-file-rename (list temp path)))
              (if (or (vl-catch-all-error-p rename-result) (not rename-result))
                (progn (if (findfile temp) (vl-file-delete temp))
                       (prompt "\nZOMO_AUDIT_THREE_VIEW_WRITE_ERROR: cannot publish atomic report.") nil)
                T))))))))

(defun zomo:audit-strict-issues (document layout viewports pairs tolerance / roles vhandles thandles layout-handles
                                  paths output source preset active pair role viewport title scale text checksum actual provenance
                                  evidence count issues scales exception verifier verifier-result)
  (setq issues nil roles nil vhandles nil thandles nil paths nil scales nil
        layout-handles (zomo:audit-layout-handle-list viewports)
        active (zomo:audit-canonical-path (zomo:audit-safe-get document 'FullName nil)))
  (foreach pair pairs
    (setq role (zomo:audit-role (zomo:audit-value 'role pair))
          viewport (zomo:audit-object document (zomo:audit-value 'viewport-handle pair))
          title (zomo:audit-object document (zomo:audit-value 'title-handle pair))
          output (zomo:audit-value 'output-path pair)
          source (zomo:audit-value 'source-path pair)
          preset (zomo:audit-value 'preset-path pair)
          checksum (zomo:audit-value 'preset-checksum pair)
          actual (zomo:audit-value 'actual-preset-checksum pair)
          provenance (zomo:audit-value 'preset-checksum-provenance pair)
          scale (if viewport (zomo:audit-safe-get viewport 'CustomScale nil) nil)
          text (zomo:audit-value 'expected-scale-text pair)
          evidence (zomo:audit-value 'dimension-evidence pair)
          count (if (zomo:audit-alist-p evidence) (zomo:audit-value 'dimension-count evidence) nil)
          verifier (zomo:audit-value 'isolation-verifier pair)
          verifier-result (if (= (type verifier) 'SYM)
                            (vl-catch-all-apply verifier (list viewport pair)) nil))
    (setq roles (cons role roles) paths (cons (zomo:audit-canonical-path output) paths))
    (if viewport (setq vhandles (cons (zomo:audit-object-handle viewport) vhandles) scales (cons scale scales)))
    (if title (setq thandles (cons (zomo:audit-object-handle title) thandles)))
    (if (not (zomo:audit-output-authorized-p document output source preset))
      (setq issues (zomo:audit-add-issue issues "OUTPUT_SAVED" role "authorized output path, active FullName, Saved=true" "unauthorized output or unsaved active drawing" "ERROR")))
    (if (not (zomo:audit-isolation-pass-p (if (vl-catch-all-error-p verifier-result) nil verifier-result)))
      (setq issues (zomo:audit-add-issue issues "VIEW_ISOLATION" role "exact T or status PASS" "FAIL, REVIEW, malformed, or verifier error" "ERROR")))
    (if (or (not (zomo:audit-checksum-p checksum)) (not (zomo:audit-checksum-p actual))
            (/= checksum actual) (not (zomo:audit-nonempty-string-p provenance)))
      (setq issues (zomo:audit-add-issue issues "PRESET_CHECKSUM" role "64-hex checksum with provenance" "missing, malformed, mismatched, or unproven" "ERROR")))
    (if (or (null title) (not (zomo:audit-title-attributes-filled-p title)))
      (setq issues (zomo:audit-add-issue issues "FRAME_ATTRIBUTES" role "required tags with non-empty values" "missing or blank" "ERROR")))
    (if (or (null title) (not (zomo:audit-scale-text-matches-p title scale text)))
      (setq issues (zomo:audit-add-issue issues "VIEWPORT_SCALE" role "SCALE text matches actual CustomScale" "missing or mismatched" "ERROR")))
    (cond
      ((or (not (zomo:audit-alist-p evidence)) (not (numberp count)))
        (setq issues (zomo:audit-add-issue issues "DIMENSION_VISIBILITY" role "per-role dimension evidence" "cannot confirm" "WARNING")))
      ((<= count 0)
        (setq issues (zomo:audit-add-issue issues "DIMENSION_VISIBILITY" role "at least one dimension" "0" "ERROR")))
      ((not (zomo:audit-verified-dimension-evidence-p evidence))
        (setq issues (zomo:audit-add-issue issues "DIMENSION_VISIBILITY" role "visible, layer-on, contained evidence" "cannot confirm" "WARNING")))))
  (setq roles (reverse roles) vhandles (reverse vhandles) thandles (reverse thandles) paths (reverse paths) scales (reverse scales))
  (if (not (zomo:audit-roles-exact-p roles))
    (setq issues (zomo:audit-add-issue issues "VIEWPORT_COUNT" "ALL" "FRONT/SIDE/PLAN exactly once" "role set invalid" "ERROR")))
  (if (or (not (zomo:audit-unique-p vhandles)) (not (zomo:audit-unique-p thandles))
          (not (zomo:audit-set-equal-p vhandles layout-handles)))
    (setq issues (zomo:audit-add-issue issues "VIEWPORT_COUNT" "ALL" "unique title/viewport handles; viewport handles must exactly match layout" "pair mapping invalid" "ERROR")))
  (if (or (not (zomo:audit-all-equal-p paths)) (not active) (not (= (car paths) active)))
    (setq issues (zomo:audit-add-issue issues "OUTPUT_SAVED" "ALL" "one authorized output path" "output paths disagree" "ERROR")))
  (setq exception (zomo:audit-value 'scale-exception-reason (car pairs)))
  (if (and (not (zomo:audit-all-equal-p scales)) (not (zomo:audit-nonempty-string-p exception)))
    (setq issues (zomo:audit-add-issue issues "VIEWPORT_SCALE" "ALL" "uniform scale or explicit exception reason" "scales differ without reason" "ERROR")))
  issues)

(defun zomo:audit-run (layout-name pairs / document layout layout-result viewports legacy strict issues measurements visual-status)
  (setq document (vla-get-ActiveDocument (vlax-get-acad-object))
        layout-result (vl-catch-all-apply 'vla-Item (list (vla-get-Layouts document) layout-name))
        layout (if (vl-catch-all-error-p layout-result) nil layout-result)
        viewports (if layout (zomo:audit-active-paper-viewports layout) nil))
  (if (null layout)
    (list (cons 'issues (list (zomo:audit-issue "VIEWPORT_COUNT" "ALL" "existing paper layout" "layout not found" "ERROR")))
          (cons 'measurements (list (cons 'viewportCount 0))))
    (progn
      (setq legacy (zomo:audit-three-view-legacy layout-name pairs nil)
            strict (zomo:audit-strict-issues document layout viewports pairs 0.01)
            issues (append (zomo:audit-value 'issues legacy) strict)
            measurements (list (cons 'viewportCount (length viewports))
                               (cons 'viewTitlePairCount (length pairs))
                               (cons 'activeDocument (zomo:audit-safe-get document 'FullName ""))
                               (cons 'saved (= (zomo:audit-safe-get document 'Saved :vlax-false) :vlax-true))
                               (cons 'visualExportStatus "NOT_VISUALLY_REVIEWED")))
      (list (cons 'issues issues) (cons 'measurements measurements)))))

(defun zomo:audit-three-view (layout-name view-title-pairs report-path / result run issues measurements json passed)
  (cond
    ((not (zomo:audit-nonempty-string-p report-path))
      (setq issues (list (zomo:audit-issue "OUTPUT_SAVED" "REPORT" "report path is required" "missing or invalid" "ERROR"))
            measurements (list (cons 'reportPath ""))))
    ((or (not (zomo:audit-proper-list-p view-title-pairs))
         (not (vl-every 'zomo:audit-alist-p view-title-pairs)))
      (setq issues (list (zomo:audit-issue "VIEWPORT_COUNT" "ALL" "proper list of pair alists" "malformed input" "ERROR"))
            measurements (list (cons 'reportPath report-path))))
    (T
      (setq result (vl-catch-all-apply 'zomo:audit-run (list layout-name view-title-pairs)))
      (if (vl-catch-all-error-p result)
        (setq issues (list (zomo:audit-issue "INVALID_GEOMETRY" "ALL" "auditable drawing" "COM or runtime error" "ERROR"))
              measurements (list (cons 'reportPath report-path)))
        (setq issues (zomo:audit-value 'issues result)
              measurements (zomo:audit-value 'measurements result)))))
  (setq passed (not (zomo:audit-has-errors-p issues))
        json (zomo:audit-report-json passed issues measurements))
  (if (not (zomo:audit-write-report report-path json))
    (setq issues (zomo:audit-add-issue issues "OUTPUT_SAVED" "REPORT" "atomic UTF-8 report" "write failed" "ERROR")
          passed nil))
  (list (cons 'status (if passed "PASS" "FAIL")) (cons 'passed passed)
        (cons 'issues (reverse issues)) (cons 'measurements measurements)))

(princ)
