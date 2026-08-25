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


if __name__ == "__main__":
    unittest.main()
