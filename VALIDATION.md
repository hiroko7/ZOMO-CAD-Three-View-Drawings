# Validation record

Validated on Windows with AutoCAD COM through CAD MCP on 2026-08-27.

- Runtime preflight passed, including AutoCAD COM and visual export support.
- The embedded preset was copied to an isolated DWG before any live test.
- The company preset SHA-256 still matches `assets/preset-manifest.json`.
- `布局1` was inspected from the real DWG: one A3 frame, three custom viewports, three view-title blocks, and material MLeaders were detected.
- Template inspection produced the required JSON sections: document, layers, layouts, blocks, dimstyles, and textstyles.
- A real layout PDF was exported from AutoCAD and rasterized for visual inspection.
- The auditor was updated to use preset-derived/custom attribute tags instead of hard-coded English company fields.
- 46 automated contract and package tests passed.
- Codex `quick_validate.py` passed for both the repository copy and the installed copy.
- Distribution ZIP contains `SKILL.md` and the embedded DWG preset.

The source preset and the user's unrelated active project drawing were not modified or saved.
