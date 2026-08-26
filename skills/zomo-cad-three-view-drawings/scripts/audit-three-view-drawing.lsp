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

(defun zomo:audit-report-json (passed issues measurements / issue-json)
  (setq issue-json (mapcar 'zomo:audit-issue-json (reverse issues)))
  (zomo:audit-json-object
    (list
      (cons "passed" (if passed "true" "false"))
      (cons "issues" (zomo:audit-json-array issue-json))
      (cons "measurements" measurements))))

(defun zomo:audit-write-report (path json / stream write-result close-result)
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

(defun zomo:audit-three-view (layout-name view-title-pairs report-path /
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
        json (zomo:audit-report-json passed issues measurements))
  (if (and (= (type report-path) 'STR) (> (strlen report-path) 0))
    (if (not (zomo:audit-write-report report-path json))
      (setq issues (zomo:audit-add-issue issues "OUTPUT_SAVED" "REPORT" "writable UTF-8 report" "write failed" "ERROR")
            passed nil)))
  (list (cons 'status (if passed "PASS" "FAIL"))
        (cons 'passed passed)
        (cons 'issues (reverse issues))
        (cons 'measurements measurements)))

(princ)
