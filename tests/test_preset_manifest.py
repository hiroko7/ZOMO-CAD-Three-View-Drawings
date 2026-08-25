from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "skills" / "zomo-cad-three-view-drawings" / "assets"


class PresetManifestTests(unittest.TestCase):
    def test_preset_matches_manifest(self):
        preset = ASSETS / "ZOMO-CAD-Preset.dwg"
        manifest = json.loads((ASSETS / "preset-manifest.json").read_text(encoding="utf-8"))
        digest = hashlib.sha256(preset.read_bytes()).hexdigest()
        self.assertEqual(manifest["filename"], preset.name)
        self.assertEqual(manifest["sha256"], digest)
        self.assertRegex(manifest["version"], r"^\d{4}\.\d{2}-v\d+$")
        self.assertEqual(manifest["source_label"], "ZOMO company CAD preset")


if __name__ == "__main__":
    unittest.main()
