from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "zomo-cad-three-view-drawings" / "scripts"


class LispContractTests(unittest.TestCase):
    def read_script(self, filename):
        return (SCRIPTS / filename).read_text(encoding="utf-8")

    def assertDefines(self, filename, names):
        text = self.read_script(filename).lower()
        for name in names:
            with self.subTest(name=name):
                self.assertIn(f"(defun {name.lower()}", text)

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


if __name__ == "__main__":
    unittest.main()
