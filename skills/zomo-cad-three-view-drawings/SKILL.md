---
name: zomo-cad-three-view-drawings
description: 当用户需要把 Rhino、SketchUp、3DM、SKP 或 DWG 模型制作或整理为公司标准的 AutoCAD 平面、正立面和侧立面施工图时使用；不用于单纯建模、渲染、普通 CAD 问答或机械加工图。
---

# ZOMO-CAD-Three View Drawings

## Outcome

使用内置公司预设的副本，把 Rhino、SketchUp 或已有 DWG 整理为平面、正立面和侧立面施工图，并生成可核查的材料证据与质量报告。

## Before acting

1. 识别当前项目、输入、输出、图幅、比例和所需视图。
2. 检查对应模型 MCP 与 AutoCAD CAD MCP（Rhino MCP、SketchUp MCP、AutoCAD CAD MCP）。
3. 只连接用户已打开的软件；先读取，后修改。
4. 不要覆盖源文件，不要修改预设母版。
5. Computer Use 仅在 MCP 能力缺失且用户明确授权时使用。

隐式调用仅允许分析、解释或准备方案；实际变更必须获得用户明确请求，且请求中应明确包含“出图”“绘制”“调整”“修改”或“更新”之一。未获得该明确请求前，不得写入、覆盖或修改任何模型、图纸或文件。

## Route

- Rhino/3DM：读取 `references/rhino-workflow.md`。
- SketchUp/SKP：读取 `references/sketchup-workflow.md`。
- 已有二维 DWG：跳过模型投影，直接进入 CAD 清理。
- 需要刷线：读取 `references/cad-layer-and-linetype-rules.md`。
- 需要材质工艺判断：读取 `references/material-evidence-rules.md`。
- 需要布局或图名块：读取 `references/layout-and-title-block-rules.md`。
- 保存前：读取 `references/quality-checklist.md`。

## Shared workflow

复制预设 → 读取标准 → 生成/清理三视图 → 语义分层 → 尺寸与材料证据 → 三视口布局 → 图名块和图框属性 → 审计 → 授权保存。

## Stop conditions

缺少 MCP、单位或正面方向存在实质歧义、会覆盖源文件、无法识别图框、关键材料冲突或保存需要新授权时停止并报告。
