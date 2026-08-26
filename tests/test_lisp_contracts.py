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
        self.assertLess(body.index("(listp rect)"), body.index("(length rect)"))

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
        self.assertIn("title_attribute_restore_failed", text)
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


if __name__ == "__main__":
    unittest.main()
