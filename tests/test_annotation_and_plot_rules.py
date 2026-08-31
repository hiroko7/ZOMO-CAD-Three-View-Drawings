from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[1]


class AnnotationAndPlotRulesTests(unittest.TestCase):
    def test_bundled_plot_style_matches_manifest(self):
        asset = ROOT / "assets" / "黑白2.ctb"
        manifest = json.loads(
            (ROOT / "assets" / "preset-manifest.json").read_text(encoding="utf-8")
        )
        self.assertTrue(asset.is_file())
        self.assertEqual(manifest["plot_style"]["filename"], asset.name)
        self.assertEqual(
            manifest["plot_style"]["sha256"],
            hashlib.sha256(asset.read_bytes()).hexdigest(),
        )

    def test_annotation_rules_are_routed_and_scale_aware(self):
        entrypoint = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        rules = (
            ROOT / "references" / "annotation-and-dimension-rules.md"
        ).read_text(encoding="utf-8")
        self.assertIn("references/annotation-and-dimension-rules.md", entrypoint)
        for token in (
            "视口比例",
            "不是固定数值",
            "横平竖直",
            "不得相互叠压",
            "每张图集中放置一次",
            "黑白2.ctb",
        ):
            self.assertIn(token, rules)

    def test_project_evidence_and_mainline_rules_are_explicit(self):
        entrypoint = (ROOT / "SKILL.md").read_text(encoding="utf-8")
        evidence = (
            ROOT / "references" / "material-evidence-rules.md"
        ).read_text(encoding="utf-8")
        self.assertIn("唯一主线", entrypoint)
        for token in ("其他 Codex 任务/会话记录", "PDF", "效果图", "材料清单"):
            self.assertIn(token, evidence)


if __name__ == "__main__":
    unittest.main()
