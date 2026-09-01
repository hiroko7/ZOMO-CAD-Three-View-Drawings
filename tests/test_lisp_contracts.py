from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"


def parse_lisp_forms(text):
    """Parse enough AutoLISP to inspect executable forms, excluding comments."""
    tokens = []
    index = 0
    while index < len(text):
        char = text[index]
        if char.isspace():
            index += 1
        elif char == ";":
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline + 1
        elif char in "()'":
            tokens.append(char)
            index += 1
        elif char == '"':
            end = index + 1
            escaped = False
            while end < len(text):
                current = text[end]
                if escaped:
                    escaped = False
                elif current == "\\":
                    escaped = True
                elif current == '"':
                    break
                end += 1
            if end >= len(text):
                raise AssertionError("unterminated AutoLISP string")
            tokens.append(text[index : end + 1])
            index = end + 1
        else:
            end = index
            while end < len(text) and not text[end].isspace() and text[end] not in "();'\"":
                end += 1
            tokens.append(text[index:end].lower())
            index = end

    def parse_one(position):
        token = tokens[position]
        if token == "(":
            result = []
            position += 1
            while tokens[position] != ")":
                item, position = parse_one(position)
                result.append(item)
            return result, position + 1
        if token == "'":
            quoted, position = parse_one(position + 1)
            return ["quote", quoted], position
        if token == ")":
            raise AssertionError("unexpected ')' in AutoLISP")
        return token, position + 1

    forms = []
    position = 0
    while position < len(tokens):
        form, position = parse_one(position)
        forms.append(form)
    return forms


def walk_lisp(form):
    if isinstance(form, list):
        yield form
        for item in form:
            yield from walk_lisp(item)


class LispContractTests(unittest.TestCase):
    def read_script(self, filename):
        path = SCRIPTS / filename
        self.assertTrue(path.is_file(), f"missing script: {filename}")
        return path.read_text(encoding="utf-8")

    def assertDefines(self, filename, names):
        text = self.read_script(filename).lower()
        for name in names:
            with self.subTest(name=name):
                self.assertIn(f"(defun {name.lower()}", text)

    def lisp_defuns(self, filename):
        forms = parse_lisp_forms(self.read_script(filename))
        return {
            form[1]: form
            for form in forms
            if isinstance(form, list) and len(form) >= 4 and form[:1] == ["defun"]
        }

    def lisp_calls(self, form, name):
        return [node for node in walk_lisp(form) if node and node[0] == name.lower()]

    def assertBalancedParentheses(self, filename):
        text = self.read_script(filename)
        depth = 0
        in_string = False
        escaped = False
        in_comment = False
        for char in text:
            if char == "\n":
                in_comment = False
                continue
            if in_comment:
                continue
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
                continue
            if char == ";":
                in_comment = True
            elif char == '"':
                in_string = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                self.assertGreaterEqual(depth, 0, f"extra ')' in {filename}")
        self.assertFalse(in_string, f"unterminated string in {filename}")
        self.assertEqual(depth, 0, f"unbalanced parentheses in {filename}")

    def test_all_lisp_scripts_have_balanced_parentheses(self):
        for path in sorted(SCRIPTS.glob("*.lsp")):
            with self.subTest(filename=path.name):
                self.assertBalancedParentheses(path.name)

    def test_common_contract(self):
        self.assertDefines(
            "zomo-common.lsp",
            ("zomo:pt3", "zomo:bbox", "zomo:object-array", "zomo:get-attributes"),
        )

    def test_common_helpers_cover_com_failure_and_empty_input(self):
        text = self.read_script("zomo-common.lsp").lower()
        self.assertIn("vl-load-com", text)
        self.assertRegex(
            text,
            r"\(vl-catch-all-apply\s+'vla-getboundingbox",
        )
        self.assertIn("(vl-catch-all-error-p result)", text)
        self.assertRegex(
            text,
            r"\(defun\s+zomo:object-array[\s\S]*?\(if\s+objects",
        )
        self.assertIn("(vlax-variant-value value)", text)

    def test_get_attributes_handles_non_block_objects(self):
        text = self.read_script("zomo-common.lsp").lower()
        function = re.search(
            r"\(defun\s+zomo:get-attributes(?P<body>[\s\S]*?)\n\s*\(princ\)",
            text,
        )
        self.assertIsNotNone(function)
        body = function.group("body")
        self.assertRegex(body, r"\(vl-catch-all-apply\s+'vla-get-hasattributes")
        self.assertRegex(body, r"\(vl-catch-all-apply\s+'vla-getattributes")

    def test_template_contract(self):
        self.assertDefines("inspect-template.lsp", ("zomo:inspect-template",))

    def test_template_report_has_exact_required_top_level_keys(self):
        text = self.read_script("inspect-template.lsp")
        match = re.search(
            r"; ZOMO_TOP_LEVEL_KEYS_BEGIN(?P<body>.*?)"
            r"; ZOMO_TOP_LEVEL_KEYS_END",
            text,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, "top-level JSON key declaration is missing")
        keys = re.findall(r'\(cons\s+"([^"]+)"', match.group("body"))
        self.assertEqual(
            keys,
            ["document", "layers", "layouts", "blocks", "dimstyles", "textstyles"],
        )

    def test_template_report_traverses_required_collections(self):
        text = self.read_script("inspect-template.lsp").lower()
        for collection in ("layers", "layouts", "blocks", "dimstyles", "textstyles"):
            with self.subTest(collection=collection):
                self.assertIn(f"vla-get-{collection}", text)
        for field in (
            '"objecttype"',
            '"effectiveblockname"',
            '"attributetags"',
            '"paperspaceboundingbox"',
        ):
            with self.subTest(field=field):
                self.assertIn(field, text)

    def test_template_json_strings_escape_quotes_slashes_and_controls(self):
        text = self.read_script("inspect-template.lsp").lower()
        self.assertIn("(defun zomo:json-escape", text)
        for char_code in (8, 9, 10, 12, 13, 34, 92):
            with self.subTest(char_code=char_code):
                self.assertRegex(text, rf"\(=\s+code\s+{char_code}\)")
        self.assertIn("\\u00", text)
        self.assertRegex(
            text,
            r'\(vl-catch-all-apply\s+\'open\s+\(list\s+path\s+"w"\s+"utf8"\)\)',
        )

    def test_template_inspection_is_read_only_and_reports_write_errors(self):
        text = self.read_script("inspect-template.lsp").lower()
        for forbidden in (
            "(command ",
            "(command-s ",
            "(entmake",
            "(entmod",
            "vla-add",
            "vla-delete",
            "vla-save",
            "vla-copyfrom",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, text)
        self.assertIn("zomo_inspect_template_write_error", text)
        self.assertRegex(text, r"\(vl-catch-all-apply\s+'open")
        self.assertRegex(text, r"\(vl-catch-all-apply\s+'write-line")
        self.assertRegex(text, r"\(vl-catch-all-apply\s+'close")

    def test_static_geometry_layout_and_title_function_contracts(self):
        self.assertDefines("clean-view-curves.lsp", ("zomo:clean-selection",))
        self.assertDefines("arrange-three-view-layout.lsp", ("zomo:arrange-three-view",))
        self.assertDefines("rebuild-view-title-block.lsp", ("zomo:rebuild-title",))

    def test_static_curve_cleaner_is_selection_scoped_and_tolerance_guarded(self):
        text = self.read_script("clean-view-curves.lsp").lower()
        self.assertIn("sslength", text)
        self.assertIn("ssname", text)
        self.assertIn("tolerance", text)
        self.assertIn('"review"', text)
        self.assertIn("spline-count-before", text)
        self.assertIn("spline-count-after", text)
        self.assertIn("zero-length-removed", text)
        self.assertIn("duplicate-removed", text)
        self.assertIn("zomo:merge-collinear-lines", text)
        self.assertNotIn("_all", text)

    def test_static_curve_cleaner_routes_destructive_com_through_guarded_helpers(self):
        text = self.read_script("clean-view-curves.lsp").lower()
        self.assertIn("(defun zomo:delete-object-status", text)
        self.assertIn("destructive-ok", text)
        self.assertIn('"unknown"', text)
        self.assertIn("vlax-erased-p", text)
        self.assertNotRegex(text, r"\(vla-delete\s+")
        for creator in ("vla-add3dpoly", "vla-addline"):
            with self.subTest(creator=creator):
                self.assertRegex(
                    text,
                    rf"\(vl-catch-all-apply\s+'{creator}",
                )

    def test_static_three_view_layout_uses_roles_and_locks_equal_scale_viewports(self):
        text = self.read_script("arrange-three-view-layout.lsp").lower()
        for role in ('"front"', '"side"', '"plan"'):
            with self.subTest(role=role):
                self.assertIn(role, text)
        for property_name in (
            "vla-put-center",
            "vla-put-width",
            "vla-put-height",
            "vla-put-customscale",
            "vla-put-displaylocked",
        ):
            with self.subTest(property_name=property_name):
                self.assertIn(property_name, text)
        for forbidden in ("vla-move", "vla-scaleentity", "_.move", "_.scale"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, text)
        self.assertIn("vla-get-modeltype", text)
        self.assertIn("paper_layout_required", text)

    def test_static_three_view_layout_centers_model_through_active_viewport_zoom(self):
        text = self.read_script("arrange-three-view-layout.lsp").lower()
        self.assertDefines(
            "arrange-three-view-layout.lsp",
            ("zomo:activate-paper-viewport", "zomo:zoom-viewport-center"),
        )
        self.assertIn("vla-put-activepviewport", text)
        self.assertIn("vla-put-mspace", text)
        self.assertIn("vl-catch-all-apply 'command-s", text)
        self.assertIn('(list "_.zoom" "_c"', text)
        self.assertNotIn("vl-cmdf", text)
        self.assertNotIn("vla-put-viewcenter", text)
        self.assertNotIn("vla-put-viewtarget", text)

    def test_static_three_view_layout_requires_direction_isolation_and_rollback(self):
        text = self.read_script("arrange-three-view-layout.lsp").lower()
        self.assertIn("view-direction", text)
        self.assertIn("isolation-verifier", text)
        self.assertIn("vla-put-direction", text)
        self.assertIn("view_isolation_required", text)
        self.assertIn("view_isolation_failed", text)
        self.assertIn("(while (and created ok)", text)
        self.assertDefines(
            "arrange-three-view-layout.lsp",
            ("zomo:viewport-state", "zomo:restore-viewport-state"),
        )
        for property_name in (
            "center",
            "width",
            "height",
            "customscale",
            "displaylocked",
            "viewporton",
            "direction",
        ):
            with self.subTest(property_name=property_name):
                self.assertIn(property_name, text)
        valid_rect = re.search(
            r"\(defun\s+zomo:valid-rect-p(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(valid_rect)
        body = valid_rect.group("body")
        self.assertLess(body.index("zomo:proper-list-p rect"), body.index("(length rect)"))

    def test_static_three_view_layout_rejects_malformed_nested_specs_before_assoc(self):
        text = self.read_script("arrange-three-view-layout.lsp").lower()
        self.assertDefines("arrange-three-view-layout.lsp", ("zomo:alist-p",))
        validator = re.search(
            r"\(defun\s+zomo:valid-three-view-specs-p(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(validator)
        body = validator.group("body")
        self.assertIn("(vl-every 'zomo:alist-p view-specs)", body)
        self.assertLess(
            body.index("(vl-every 'zomo:alist-p view-specs)"),
            body.index("zomo:role-count"),
        )

    def test_static_title_rebuild_copies_source_and_inserts_unit_scale(self):
        text = self.read_script("rebuild-view-title-block.lsp").lower()
        self.assertIn("vla-copy", text)
        self.assertIn("vla-explode", text)
        self.assertIn("zomo:get-attributes", text)
        self.assertRegex(text, r"'vla-add[\s\S]*?\(list\s+blocks")
        self.assertIn("vla-insertblock", text)
        self.assertRegex(
            text,
            r"vla-insertblock[\s\S]*?1\.0[\s\S]*?1\.0[\s\S]*?1\.0",
        )
        self.assertIn("target-left", text)
        self.assertIn("target-right", text)
        self.assertIn("zomo:title-overlaps-p", text)
        self.assertIn("zomo:cleanup-objects", text)
        self.assertIn("zomo:title-delete-status old-reference", text)
        self.assertIn("title_attribute_value_mismatch", text)
        self.assertIn("old_reference_delete_failed", text)

    def test_static_title_rebuild_uses_local_coordinates_and_actual_frame_bounds(self):
        text = self.read_script("rebuild-view-title-block.lsp").lower()
        self.assertDefines(
            "rebuild-view-title-block.lsp",
            ("zomo:title-move-to-local", "zomo:title-frame-bounds-match-p"),
        )
        self.assertIn("source-frame-bbox", text)
        self.assertIn("new-frame-bbox", text)
        self.assertIn("target-local-left", text)
        self.assertIn("target-local-right", text)
        self.assertRegex(
            text,
            r"'vla-add[\s\S]*?\(list\s+blocks\s+\(zomo:pt3\s+'?\(0\.0\s+0\.0\s+0\.0\)\)",
        )
        self.assertIn("new-bbox occupied-rects", text)
        self.assertIn("vlax-erased-p", text)
        self.assertIn("(zomo:cleanup-objects exploded)", text)
        self.assertIn('(= cleanup-status "deleted")', text)

    def test_static_title_rebuild_uses_safe_vla_identity_comparison(self):
        text = self.read_script("rebuild-view-title-block.lsp").lower()
        self.assertDefines(
            "rebuild-view-title-block.lsp",
            ("zomo:title-object-key", "zomo:title-same-object-p"),
        )
        identity = re.search(
            r"\(defun\s+zomo:title-same-object-p(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(identity)
        self.assertIn("zomo:title-object-key", identity.group("body"))
        self.assertIn("vl-catch-all-apply", identity.group("body"))
        self.assertIn("(if (vl-catch-all-error-p result) :unknown result)", identity.group("body"))
        self.assertIn("vla-get-handle", text)
        self.assertIn("vla-get-objectid", text)
        self.assertIn(":unknown", text)
        self.assertIn("(eq same-object :unknown)", text)
        self.assertNotRegex(text, r"\(/=\s*object\s+frame\)")
        self.assertNotRegex(text, r"\(/=\s*frame\s+object\)")
        self.assertEqual(text.count("zomo:title-same-object-p object frame"), 2)

    def test_static_title_containment_preserves_nil_frame_mode_and_unknown_review(self):
        text = self.read_script("rebuild-view-title-block.lsp").lower()
        contained = re.search(
            r"\(defun\s+zomo:title-objects-contained-p(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(contained)
        body = contained.group("body")
        nil_frame = body.index("(null frame)")
        identity = body.index("zomo:title-same-object-p object frame")
        self.assertLess(nil_frame, identity)
        self.assertIn("zomo:bbox-contained-p bbox frame-bbox tolerance", body)
        self.assertIn("(setq ok :unknown)", body)
        self.assertIn("(eq ok t)", body)

        self.assertIn("content-shift-status", text)
        self.assertIn("(eq new-definition-contained :unknown)", text)
        self.assertIn("(eq new-reference-attributes-contained :unknown)", text)
        self.assertIn('"title_identity_unconfirmed"', text)
        self.assertIn('(cons \'status "review")', text)
        identity_gate = text.index("(if (eq new-definition-contained :unknown)")
        insert_call = text.index("'vla-insertblock")
        self.assertLess(identity_gate, insert_call)

    def test_static_title_rebuild_recreates_attribute_definitions_and_verifies_tags_values(self):
        text = self.read_script("rebuild-view-title-block.lsp").lower()
        self.assertDefines(
            "rebuild-view-title-block.lsp",
            (
                "zomo:title-attribute-definitions",
                "zomo:title-attribute-definition-metadata",
                "zomo:title-add-attribute-definition",
                "zomo:title-tag-sets-equal-p",
            ),
        )
        self.assertRegex(text, r"\(vl-catch-all-apply\s+'vla-addattribute")
        self.assertIn("vla-getconstantattributes", text)
        self.assertIn("source-attribute-tags", text)
        self.assertIn("new-definition-attribute-tags", text)
        self.assertIn("new-reference-attribute-tags", text)
        self.assertIn("title_attribute_tag_mismatch", text)
        self.assertIn("title_attribute_value_mismatch", text)
        restore = re.search(
            r"\(defun\s+zomo:restore-title-attributes(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(restore)
        self.assertIn("expected-tags", restore.group("body"))
        self.assertIn("zomo:title-tag-sets-equal-p", restore.group("body"))

    def test_static_title_rebuild_filters_exploded_attribute_definitions_and_enumerates_new_block(self):
        text = self.read_script("rebuild-view-title-block.lsp").lower()
        self.assertDefines(
            "rebuild-view-title-block.lsp",
            ("zomo:title-copyable-objects",),
        )
        copyable = re.search(
            r"\(defun\s+zomo:title-copyable-objects(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(copyable)
        self.assertIn('"acdbattributedefinition"', copyable.group("body"))
        self.assertIn("zomo:title-copyable-objects exploded", text)
        self.assertIn("zomo:object-array copyable-exploded", text)
        self.assertIn("zomo:title-attribute-definitions new-block", text)

    def test_static_title_tag_comparison_preserves_duplicate_multiplicity_aab_vs_abb(self):
        text = self.read_script("rebuild-view-title-block.lsp").lower()
        self.assertNotIn("vl-sort", text)
        self.assertDefines(
            "rebuild-view-title-block.lsp",
            ("zomo:title-remove-tag-once", "zomo:title-tag-sets-equal-p"),
        )
        comparator = re.search(
            r"\(defun\s+zomo:title-tag-sets-equal-p(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(comparator)
        self.assertIn("zomo:title-remove-tag-once", comparator.group("body"))
        self.assertIn("remaining", comparator.group("body"))

        def multiset_equal(left, right):
            remaining = list(right)
            for tag in left:
                try:
                    remaining.remove(tag)
                except ValueError:
                    return False
            return not remaining

        self.assertTrue(multiset_equal(["A", "A", "B"], ["B", "A", "A"]))
        self.assertFalse(multiset_equal(["A", "A", "B"], ["A", "B", "B"]))

    def test_static_title_rebuild_checks_content_containment_and_cleanup_commit_gate(self):
        text = self.read_script("rebuild-view-title-block.lsp").lower()
        self.assertDefines(
            "rebuild-view-title-block.lsp",
            (
                "zomo:bbox-contained-p",
                "zomo:title-objects-contained-p",
                "zomo:cleanup-objects",
            ),
        )
        self.assertIn("new-definition-contained", text)
        self.assertIn("new-reference-attributes-contained", text)
        self.assertIn("title_content_outside_frame", text)
        self.assertIn("cleanup-status", text)
        self.assertIn("title_cleanup_unconfirmed", text)
        cleanup = re.search(
            r"\(defun\s+zomo:cleanup-objects(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(cleanup)
        self.assertIn("(while objects", cleanup.group("body"))
        self.assertIn('(= delete-status "unknown")', cleanup.group("body"))
        self.assertIn('(= delete-status "failed")', cleanup.group("body"))
        self.assertIn("(setq cleanup-status (zomo:cleanup-objects exploded))", text)
        old_delete = text.index("zomo:title-delete-status old-reference")
        cleanup_gate = text.index('(= cleanup-status "deleted")')
        self.assertLess(cleanup_gate, old_delete)

    def test_static_three_view_layout_guards_all_geometry_lengths_and_catches_validator_boundary(self):
        text = self.read_script("arrange-three-view-layout.lsp").lower()
        self.assertDefines("arrange-three-view-layout.lsp", ("zomo:view-geometry-error",))
        for function_name in (
            "zomo:valid-rect-p",
            "zomo:valid-model-center-p",
            "zomo:valid-direction-p",
        ):
            function = re.search(
                rf"\(defun\s+{re.escape(function_name)}(?P<body>[\s\S]*?)\n\s*\(defun",
                text,
            )
            self.assertIsNotNone(function)
            body = function.group("body")
            self.assertLess(body.index("zomo:proper-list-p"), body.index("(length"))
        geometry = re.search(
            r"\(defun\s+zomo:view-geometry-error(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(geometry)
        self.assertIn("vl-catch-all-apply", geometry.group("body"))
        self.assertIn("geometry-error", text)

    def test_audit_contract(self):
        self.assertDefines("audit-three-view-drawing.lsp", ("zomo:audit-three-view",))

    def test_audit_uses_preset_derived_attributes_instead_of_company_specific_english_tags(self):
        text = self.read_script("audit-three-view-drawing.lsp").lower()
        for hardcoded in (
            '"project_name"', '"drawing_title"', '"date"', '"design"',
            '"drawn"', '"checked"', '"version"',
        ):
            self.assertNotIn(hardcoded, text)
        self.assertIn("required-title-tags", text)
        self.assertIn("scale-attribute-tag", text)
        self.assertIn("zomo:get-attributes title", text)
        self.assertIn("wcmatch", text)

    def test_audit_covers_all_quality_checklist_invariants_and_honest_visual_status(self):
        text = self.read_script("audit-three-view-drawing.lsp").lower()
        required_codes = (
            "viewport_count",
            "viewport_locked",
            "viewport_scale",
            "view_isolation",
            "title_viewport_left",
            "title_viewport_right",
            "title_viewport_width",
            "title_uniform_scale",
            "title_pair_overlap",
            "dimension_visibility",
            "spline_count",
            "zero_length_count",
            "invalid_geometry",
            "frame_attributes",
            "preset_checksum",
            "output_saved",
        )
        for code in required_codes:
            with self.subTest(code=code):
                self.assertIn(code, text)
        for key in ('"passed"', '"issues"', '"measurements"'):
            with self.subTest(key=key):
                self.assertIn(key, text)
        for issue_key in ('"code"', '"role"', '"expected"', '"actual"', '"severity"'):
            with self.subTest(issue_key=issue_key):
                self.assertIn(issue_key, text)
        self.assertIn('"visual_export_unavailable"', text)
        self.assertIn('"warning"', text)
        self.assertIn('"error"', text)

    def test_audit_report_writer_is_utf8_escaped_and_explicit_about_write_errors(self):
        text = self.read_script("audit-three-view-drawing.lsp").lower()
        self.assertIn("(defun zomo:audit-json-escape", text)
        for char_code in (8, 9, 10, 12, 13, 34, 92):
            with self.subTest(char_code=char_code):
                self.assertRegex(text, rf"\(=\s+code\s+{char_code}\)")
        self.assertIn("\\u00", text)
        self.assertRegex(
            text,
            r'\(vl-catch-all-apply\s+\'open\s+\(list\s+temp\s+"w"\s+"utf8"\)\)',
        )
        self.assertIn('"temp_open_failed"', text)
        self.assertIn('"temp_write_failed"', text)
        self.assertRegex(text, r"\(vl-catch-all-apply\s+'write-line")
        self.assertRegex(text, r"\(vl-catch-all-apply\s+'close")

    def test_audit_preflight_rejects_unproven_output_before_it_can_pass(self):
        text = self.read_script("audit-three-view-drawing.lsp").lower()
        self.assertDefines(
            "audit-three-view-drawing.lsp",
            (
                "zomo:audit-proper-list-p",
                "zomo:audit-alist-p",
                "zomo:audit-canonical-path",
                "zomo:audit-output-authorized-p",
                "zomo:audit-roles-exact-p",
                "zomo:audit-unique-p",
                "zomo:audit-isolation-pass-p",
                "zomo:audit-checksum-p",
                "zomo:audit-measurements-json",
            ),
        )
        for required in (
            "vla-get-fullname",
            "vla-get-saved",
            "authorized output path",
            "source or preset path",
            "report path is required",
            "output paths disagree",
            "viewport handles must exactly match layout",
            "front/side/plan exactly once",
            "zomo:audit-publication-result",
            "vl-file-rename",
        ):
            with self.subTest(required=required):
                self.assertIn(required, text)

    def test_audit_policy_helpers_define_strict_pass_contracts(self):
        text = self.read_script("audit-three-view-drawing.lsp").lower()
        isolation = re.search(
            r"\(defun\s+zomo:audit-isolation-pass-p(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(isolation)
        body = isolation.group("body")
        self.assertIn("(eq result t)", body)
        self.assertIn('"pass"', body)
        self.assertIn("zomo:audit-alist-p result", body)

        checksum = re.search(
            r"\(defun\s+zomo:audit-checksum-p(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(checksum)
        self.assertIn("(= (strlen value) 64)", checksum.group("body"))
        self.assertIn("zomo:audit-hex-string-p", checksum.group("body"))

    def test_audit_report_measurements_remain_structured_until_json_boundary(self):
        text = self.read_script("audit-three-view-drawing.lsp").lower()
        report = re.search(
            r"\(defun\s+zomo:audit-report-json\s+(?P<body>[\s\S]*?)\n\s*\(defun",
            text,
        )
        self.assertIsNotNone(report)
        self.assertIn("zomo:audit-measurements-json", report.group("body"))
        self.assertIn("(cons 'measurements measurements)", text)

    def test_audit_safety_uses_boolean_identity_and_recoverable_report_publish(self):
        text = self.read_script("audit-three-view-drawing.lsp").lower()
        self.assertIn("(eq result t)", text)
        self.assertIn("(eq value t)", text)
        self.assertNotIn("(= result t)", text)
        self.assertNotIn("(= value t)", text)
        self.assertIn("zomo:audit-report-path-p", text)
        self.assertIn("zomo:audit-safe-rename", text)
        self.assertIn("backup", text)
        self.assertIn("zomo:audit-scale-text-from-custom-scale", text)
        self.assertIn("zomo:audit-hex-string-p", text)
        self.assertIn("preset-artifact-resolver", text)

    def test_audit_preflight_blocks_writer_for_invalid_or_protected_report_paths(self):
        text = self.read_script("audit-three-view-drawing.lsp").lower()
        self.assertIn("zomo:audit-report-safe-to-write-p", text)
        self.assertIn("recovery_failed", text)
        self.assertIn("zomo:audit-protected-path-p", text)
        self.assertIn("(eq (zomo:audit-value 'model-space evidence) t)", text)
        self.assertIn("(eq (zomo:audit-value 'paper-space evidence) t)", text)
        self.assertIn("(eq (zomo:audit-value 'layer-visible evidence) t)", text)
        self.assertIn("(eq (zomo:audit-value 'viewport-contained evidence) t)", text)

    def test_audit_writer_guards_protected_paths_before_any_filesystem_side_effect(self):
        defuns = self.lisp_defuns("audit-three-view-drawing.lsp")
        writer = defuns["zomo:audit-write-report"]
        self.assertEqual(writer[2][:3], ["path", "json", "protected-paths"])
        guard = writer[3]
        self.assertEqual(guard[0], "if")
        self.assertEqual(
            guard[1],
            ["not", ["zomo:audit-report-safe-to-write-p", "path", "protected-paths"]],
        )
        rejected_branch = guard[2]
        rejected_calls = {node[0] for node in walk_lisp(rejected_branch) if node}
        self.assertTrue({"zomo:audit-publication-result"}.issubset(rejected_calls))
        self.assertTrue(
            rejected_calls.isdisjoint(
                {"open", "vl-file-rename", "vl-file-delete", "zomo:audit-unique-temp-path"}
            )
        )

    def test_audit_publication_boundary_returns_structured_status_branches(self):
        defuns = self.lisp_defuns("audit-three-view-drawing.lsp")
        result = defuns["zomo:audit-publication-result"]
        result_keys = {
            call[1][1]
            for call in self.lisp_calls(result, "cons")
            if len(call) >= 3 and isinstance(call[1], list) and call[1][:1] == ["quote"]
        }
        self.assertEqual(result_keys, {"status", "target", "temp", "backup", "error"})

        writer = defuns["zomo:audit-write-report"]
        statuses = {
            call[1]
            for call in self.lisp_calls(writer, "zomo:audit-publication-result")
            if len(call) >= 3
        }
        self.assertEqual(
            statuses,
            {'"PUBLISHED"', '"PUBLISH_FAILED_RESTORED"', '"RECOVERY_FAILED"'},
        )
        restored_branches = [
            node for node in walk_lisp(writer) if node[:2] == ["if", "restored"]
        ]
        self.assertEqual(len(restored_branches), 1)
        self.assertTrue(
            self.lisp_calls(restored_branches[0][2], "zomo:audit-publication-result")
        )
        self.assertTrue(
            self.lisp_calls(restored_branches[0][3], "zomo:audit-publication-result")
        )

    def test_audit_main_validates_pairs_once_and_routes_publication_statuses(self):
        defuns = self.lisp_defuns("audit-three-view-drawing.lsp")
        main = defuns["zomo:audit-three-view"]
        self.assertEqual(len(self.lisp_calls(main, "zomo:audit-report-safe-to-write-p")), 1)
        writer_calls = self.lisp_calls(main, "zomo:audit-write-report")
        self.assertEqual(writer_calls, [["zomo:audit-write-report", "report-path", "json", "protected-paths"]])
        status_checks = {
            call[2]
            for call in self.lisp_calls(main, "=")
            if len(call) == 3 and call[1] == "publication-status"
        }
        self.assertEqual(
            status_checks,
            {'"PUBLISHED"', '"PUBLISH_FAILED_RESTORED"', '"RECOVERY_FAILED"'},
        )
        recovery_issues = [
            call
            for call in self.lisp_calls(main, "zomo:audit-add-issue")
            if len(call) > 2 and call[2] == '"RECOVERY_FAILED"'
        ]
        self.assertEqual(len(recovery_issues), 1)

        safe = defuns["zomo:audit-report-safe-to-write-p"]
        self.assertTrue(self.lisp_calls(safe, "zomo:audit-canonical-path-list-p"))
        self.assertFalse(self.lisp_calls(safe, "foreach"))
        self.assertFalse(self.lisp_calls(safe, "assoc"))

    def test_audit_removes_legacy_writers_and_manages_unique_artifacts(self):
        defuns = self.lisp_defuns("audit-three-view-drawing.lsp")
        for removed in (
            "zomo:audit-report-json-legacy",
            "zomo:audit-write-report-legacy",
            "zomo:audit-three-view-legacy",
        ):
            self.assertNotIn(removed, defuns)
        core = defuns["zomo:audit-core-checks"]
        core_calls = {node[0] for node in walk_lisp(core) if node}
        self.assertTrue(core_calls.isdisjoint({"open", "write-line", "close", "vl-file-rename"}))

        writer = defuns["zomo:audit-write-report"]
        self.assertEqual(len(self.lisp_calls(writer, "zomo:audit-unique-temp-path")), 1)
        self.assertTrue(self.lisp_calls(writer, "zomo:audit-safe-delete-artifact"))
        strict = defuns["zomo:audit-strict-issues"]
        strict_atoms = {item for node in walk_lisp(strict) for item in node if isinstance(item, str)}
        self.assertNotIn("actual-preset-checksum", strict_atoms)

        scale = defuns["zomo:audit-scale-text-from-custom-scale"]
        scale_strings = {
            item for node in walk_lisp(scale) for item in node if isinstance(item, str) and item.startswith('"')
        }
        self.assertIn('"1:"', scale_strings)
        self.assertIn('":1"', scale_strings)


if __name__ == "__main__":
    unittest.main()
