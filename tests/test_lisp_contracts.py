from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "zomo-cad-three-view-drawings" / "scripts"


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
            "vla-put-viewcenter",
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
            "viewcenter",
            "viewtarget",
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


if __name__ == "__main__":
    unittest.main()
