from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SKILL = ROOT / "skills" / "zomo-cad-three-view-drawings"


class SkillPackageTests(unittest.TestCase):
    def test_required_entrypoints_exist(self):
        self.assertTrue((SKILL / "SKILL.md").is_file())
        self.assertTrue((SKILL / "agents" / "openai.yaml").is_file())

    def test_skill_identity_and_implicit_invocation(self):
        skill_text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        yaml_text = (SKILL / "agents" / "openai.yaml").read_text(encoding="utf-8")
        self.assertIn("name: zomo-cad-three-view-drawings", skill_text)
        self.assertIn("display_name: ZOMO-CAD-Three View Drawings", yaml_text)
        self.assertIn("allow_implicit_invocation: true", yaml_text)

    def test_implicit_invocation_is_analysis_only(self):
        skill_text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        yaml_text = (SKILL / "agents" / "openai.yaml").read_text(encoding="utf-8")
        self.assertNotIn("[TODO:", skill_text)
        self.assertIn("隐式调用仅允许分析、解释或准备方案", skill_text)
        self.assertIn("实际变更必须获得用户明确请求", skill_text)
        for verb in ("出图", "绘制", "调整", "修改", "更新"):
            self.assertIn(verb, skill_text)
        self.assertIn("仅分析、解释或准备方案", yaml_text)
        self.assertIn("明确请求", yaml_text)

    def test_entrypoint_routes_modes_and_references(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        for token in (
            "Rhino MCP", "SketchUp MCP", "AutoCAD CAD MCP",
            "references/rhino-workflow.md",
            "references/sketchup-workflow.md",
            "references/material-evidence-rules.md",
            "references/layout-and-title-block-rules.md",
            "references/quality-checklist.md",
        ):
            self.assertIn(token, text)

    def test_entrypoint_preserves_authorization_boundaries(self):
        text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
        for token in ("不要覆盖源文件", "不要修改预设母版", "Computer Use", "用户明确授权"):
            self.assertIn(token, text)

    def test_model_and_cad_references_define_required_contracts(self):
        refs = SKILL / "references"
        rhino = (refs / "rhino-workflow.md").read_text(encoding="utf-8")
        sketchup = (refs / "sketchup-workflow.md").read_text(encoding="utf-8")
        cad = (refs / "cad-layer-and-linetype-rules.md").read_text(encoding="utf-8")
        self.assertIn("三视图任务规格", rhino)
        self.assertIn("不得保存或关闭 Rhino 源文件", rhino)
        self.assertIn("已设计、未验证", sketchup)
        self.assertIn("不得自动改用 Computer Use", sketchup)
        for semantic_class in ("主要可见外轮廓", "次要轮廓", "隐藏线", "中心线", "材质分缝"):
            self.assertIn(semantic_class, cad)


if __name__ == "__main__":
    unittest.main()
