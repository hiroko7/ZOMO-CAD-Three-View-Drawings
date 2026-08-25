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


if __name__ == "__main__":
    unittest.main()
