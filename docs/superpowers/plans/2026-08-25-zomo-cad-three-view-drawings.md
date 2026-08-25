# ZOMO-CAD-Three View Drawings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 创建一个可由 AI 自动调用、可供公司同事安装、内置公司 CAD 预设，并支持 Rhino、SketchUp 与已有 DWG 三种入口的三视图施工图 Skill。

**Architecture:** 在仓库内先构建一个可分发但未安装的 Skill 包。`SKILL.md` 负责自动触发和模式路由，条件性规则放入 references，内置 DWG 和清单放入 assets，确定性的模板检查、曲线清理、视口布局、图名块重建和图纸审计放入 AutoLISP scripts。所有模型入口先转换为统一三视图任务规格，再由 CAD MCP 和脚本完成公司标准图纸。

**Tech Stack:** Codex Skill YAML/Markdown、AutoCAD 2022、best-cad-mcp、Rhino MCP、SketchUp MCP 适配说明、AutoLISP/Visual LISP、Python 3 标准库 `unittest`、PowerShell、Git。

## Global Constraints

- UI 显示名称必须是 `ZOMO-CAD-Three View Drawings`。
- Skill 目录和 YAML 名称必须是 `zomo-cad-three-view-drawings`。
- `policy.allow_implicit_invocation` 必须为 `true`。
- 公司预设必须位于 `assets/ZOMO-CAD-Preset.dwg`，运行时只能复制后使用，不能写入或覆盖母版。
- Skill 包中不得出现员工用户名绝对路径、项目专属对象句柄或固定项目坐标。
- 自动调用不等于自动写入；只有明确的“出图、绘制、调整、修改、更新”任务才允许修改目标文件。
- 默认连接用户已打开的软件；未经授权不得新开、关闭、替换或保存 Rhino、SketchUp、AutoCAD 会话。
- CAD MCP 与模型 MCP 优先；Computer Use 不能自动降级使用。
- 图名块禁止非等比缩放，X/Y/Z 缩放为 1/1/1；相邻图名块不得重叠；同一图名块内部文字可以重叠。
- 当前环境的 SketchUp MCP 尚未验证；真实适配测试通过前只能标为“已设计、未验证”。
- 生产源文件、本次 3DM、SKP、DWG 和预设母版不得作为测试写入目标。

---

## File map

实施将在仓库中创建以下可分发源包，不直接写入 `$env:USERPROFILE\.codex\skills`：

```text
skills/zomo-cad-three-view-drawings/
├─ SKILL.md                              自动触发、入口路由、共同安全约束
├─ agents/openai.yaml                    UI 名称、简介、默认提示和自动调用策略
├─ assets/ZOMO-CAD-Preset.dwg            公司 CAD 预设二进制副本
├─ assets/preset-manifest.json           预设版本、文件名、SHA-256
├─ references/rhino-workflow.md          Rhino MCP 模式
├─ references/sketchup-workflow.md       SketchUp MCP 模式及未验证边界
├─ references/cad-layer-and-linetype-rules.md
├─ references/material-evidence-rules.md
├─ references/layout-and-title-block-rules.md
├─ references/quality-checklist.md
├─ scripts/zomo-common.lsp               共享包围框、属性、报告与对象数组函数
├─ scripts/inspect-template.lsp           预设语义检查与标准索引
├─ scripts/clean-view-curves.lsp          样条转线、重线和无效线清理
├─ scripts/arrange-three-view-layout.lsp  三视口创建、缩放、隔离与锁定
├─ scripts/rebuild-view-title-block.lsp   保持原比例的图名块重建
└─ scripts/audit-three-view-drawing.lsp   保存前硬约束检查

tests/
├─ test_skill_package.py                 包结构、元数据、引用和敏感路径测试
├─ test_preset_manifest.py               预设校验值测试
└─ test_lisp_contracts.py                LSP 公共接口静态契约测试
```

共享运行时接口：

```text
(zomo:inspect-template report-path) -> T 或抛出明确错误
(zomo:clean-selection selection-set tolerance) -> 结果 alist
(zomo:arrange-three-view layout-name view-specs) -> 视口 handle alist
(zomo:rebuild-title source-handle left right attribute-values) -> 新块 handle
(zomo:audit-three-view layout-name view-title-pairs report-path) -> PASS/FAIL alist
```

`view-specs` 的每个元素采用：

```lisp
((role . "front")
 (model-center . (6190.0 1510.0))
 (paper-rect . (left bottom right top))
 (custom-scale . 0.02))
```

坐标只在运行时由当前项目计算，以上数字只说明数据类型，不得进入 Skill 脚本默认值。

### Task 1: 建立未安装的 Skill 包骨架

**Files:**
- Create: `skills/zomo-cad-three-view-drawings/SKILL.md`
- Create: `skills/zomo-cad-three-view-drawings/agents/openai.yaml`
- Create: `tests/test_skill_package.py`

**Interfaces:**
- Consumes: 已批准设计规格。
- Produces: 可被后续任务填充的 Skill 根目录，以及 `SkillPackageTests` 静态测试入口。

- [ ] **Step 1: 写入失败的包结构测试**

```python
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
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
python -m unittest tests.test_skill_package -v
```

Expected: FAIL，提示 `SKILL.md` 或 `agents/openai.yaml` 不存在。

- [ ] **Step 3: 使用官方初始化器创建骨架**

Run:

```powershell
python "C:\Users\ZOMOZOMO\.codex\skills\.system\skill-creator\scripts\init_skill.py" `
  zomo-cad-three-view-drawings `
  --path "skills" `
  --resources scripts,references,assets `
  --interface "display_name=ZOMO-CAD-Three View Drawings" `
  --interface "short_description=将 Rhino、SketchUp 或 DWG 整理为公司标准三视图施工图"
```

Expected: 创建 Skill 目录、`SKILL.md`、`agents/openai.yaml` 及三个资源目录。

- [ ] **Step 4: 修正 UI 策略并写入最小合法入口**

`agents/openai.yaml` 至少包含：

```yaml
interface:
  display_name: ZOMO-CAD-Three View Drawings
  short_description: 将 Rhino、SketchUp 或 DWG 整理为公司标准三视图施工图
  default_prompt: 根据当前模型和项目资料，使用公司 CAD 预设生成或调整平面、正立面和侧立面施工图。
policy:
  allow_implicit_invocation: true
```

`SKILL.md` frontmatter 至少包含：

```yaml
---
name: zomo-cad-three-view-drawings
description: 当用户需要把 Rhino、SketchUp、3DM、SKP 或 DWG 模型制作或整理为公司标准的 AutoCAD 平面、正立面和侧立面施工图时使用；不用于单纯建模、渲染、普通 CAD 问答或机械加工图。
---
```

- [ ] **Step 5: 运行测试确认通过**

Run: `python -m unittest tests.test_skill_package -v`

Expected: `OK`。

- [ ] **Step 6: 提交本任务**

```powershell
git add skills/zomo-cad-three-view-drawings tests/test_skill_package.py
git commit -m "feat: scaffold ZOMO three-view CAD skill"
```

Expected: 仅提交骨架和测试。若 Git 作者身份仍未配置，停止提交并向用户索取公司使用的姓名和邮箱，不得虚构。

### Task 2: 打包公司预设并建立不可变清单

**Files:**
- Create: `skills/zomo-cad-three-view-drawings/assets/ZOMO-CAD-Preset.dwg`
- Create: `skills/zomo-cad-three-view-drawings/assets/preset-manifest.json`
- Create: `tests/test_preset_manifest.py`

**Interfaces:**
- Consumes: 用户批准的源预设 `C:\Users\ZOMOZOMO\Desktop\CAD预设.dwg`。
- Produces: `preset-manifest.json`，字段固定为 `version`、`filename`、`sha256`、`source_label`。

- [ ] **Step 1: 写入失败的校验值测试**

```python
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_preset_manifest -v`

Expected: FAIL，提示预设或清单不存在。

- [ ] **Step 3: 只读确认源文件并复制二进制资产**

```powershell
Get-Item -LiteralPath "C:\Users\ZOMOZOMO\Desktop\CAD预设.dwg" |
  Select-Object FullName,Length,LastWriteTime,IsReadOnly
Copy-Item -LiteralPath "C:\Users\ZOMOZOMO\Desktop\CAD预设.dwg" `
  -Destination "skills\zomo-cad-three-view-drawings\assets\ZOMO-CAD-Preset.dwg"
```

Expected: 源文件存在，目标为独立副本，源文件时间和大小未改变。

- [ ] **Step 4: 计算 SHA-256 并用 apply_patch 写入清单**

Run:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath `
  "skills\zomo-cad-three-view-drawings\assets\ZOMO-CAD-Preset.dwg"
```

记录命令输出的 64 位小写 SHA-256。使用 apply_patch 创建清单，固定写入 `version: 2026.08-v1`、`filename: ZOMO-CAD-Preset.dwg`、`source_label: ZOMO company CAD preset`，并把刚刚读取到的完整哈希逐字写入 `sha256`；清单中不得保留示例值。

- [ ] **Step 5: 运行测试确认通过**

Run: `python -m unittest tests.test_preset_manifest -v`

Expected: `OK`。

- [ ] **Step 6: 提交本任务**

```powershell
git add skills/zomo-cad-three-view-drawings/assets tests/test_preset_manifest.py
git commit -m "feat: package versioned ZOMO CAD preset"
```

### Task 3: 完成自动路由的 SKILL.md

**Files:**
- Modify: `skills/zomo-cad-three-view-drawings/SKILL.md`
- Modify: `tests/test_skill_package.py`

**Interfaces:**
- Consumes: 三种输入模式和六个 reference 文件名。
- Produces: 自动触发、只读预检、模式路由、共享九步流程和停止条件。

- [ ] **Step 1: 增加失败的路由与边界测试**

在 `SkillPackageTests` 增加：

```python
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_skill_package -v`

Expected: FAIL，缺少路由和授权文本。

- [ ] **Step 3: 写入完整 SKILL.md**

正文按以下确定结构实现，不复制各 reference 的详细内容：

```markdown
# ZOMO-CAD-Three View Drawings

## Outcome
使用内置公司预设的副本，把 Rhino、SketchUp 或已有 DWG 整理为平面、正立面和侧立面施工图，并生成可核查的材料证据与质量报告。

## Before acting
1. 识别当前项目、输入、输出、图幅、比例和所需视图。
2. 检查对应模型 MCP 与 AutoCAD CAD MCP。
3. 只连接用户已打开的软件；先读取，后修改。
4. 不要覆盖源文件，不要修改预设母版。
5. Computer Use 仅在 MCP 能力缺失且用户明确授权时使用。

## Route
- Rhino/3DM：读取 references/rhino-workflow.md。
- SketchUp/SKP：读取 references/sketchup-workflow.md。
- 已有二维 DWG：跳过模型投影，直接进入 CAD 清理。
- 需要刷线：读取 references/cad-layer-and-linetype-rules.md。
- 需要材质工艺判断：读取 references/material-evidence-rules.md。
- 需要布局或图名块：读取 references/layout-and-title-block-rules.md。
- 保存前：读取 references/quality-checklist.md。

## Shared workflow
复制预设 → 读取标准 → 生成/清理三视图 → 语义分层 → 尺寸与材料证据 → 三视口布局 → 图名块和图框属性 → 审计 → 授权保存。

## Stop conditions
缺少 MCP、单位或正面方向存在实质歧义、会覆盖源文件、无法识别图框、关键材料冲突或保存需要新授权时停止并报告。
```

- [ ] **Step 4: 运行测试和官方验证器**

```powershell
python -m unittest tests.test_skill_package -v
python "C:\Users\ZOMOZOMO\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  "skills\zomo-cad-three-view-drawings"
```

Expected: unittest `OK`，quick validator 返回合法 Skill。

- [ ] **Step 5: 提交本任务**

```powershell
git add skills/zomo-cad-three-view-drawings/SKILL.md tests/test_skill_package.py
git commit -m "feat: route automatic three-view drawing workflow"
```

### Task 4: 编写 Rhino、SketchUp 与 CAD 表现 references

**Files:**
- Create: `skills/zomo-cad-three-view-drawings/references/rhino-workflow.md`
- Create: `skills/zomo-cad-three-view-drawings/references/sketchup-workflow.md`
- Create: `skills/zomo-cad-three-view-drawings/references/cad-layer-and-linetype-rules.md`
- Modify: `tests/test_skill_package.py`

**Interfaces:**
- Consumes: 模型 MCP 对象、统一三视图任务规格。
- Produces: `role`、`model-center`、`paper-rect`、`custom-scale` 字段和语义线类映射规则。

- [ ] **Step 1: 增加失败的 reference 内容测试**

```python
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
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_skill_package -v`

Expected: FAIL，reference 文件不存在。

- [ ] **Step 3: 写 Rhino reference**

文件必须完整规定：现有 Rhino slot 选择、单位/轴向/命名视图读取、正面歧义确认、二维投影、圆弧保留、样条转换目标、源模型不变、对象/图层/材质身份写入统一规格以及独立输出层。

- [ ] **Step 4: 写 SketchUp reference**

文件必须完整规定：MCP 能力检查、现有窗口、单位/轴/场景/标签/组/组件/隐藏/材质读取、优先正交场景、三视图输出、统一规格、禁止自动使用 Computer Use/导入 Rhino，以及测试通过前显示“已设计、未验证”。

- [ ] **Step 5: 写 CAD 线类 reference**

文件使用表格定义：

```markdown
| 语义类 | 判断证据 | 预设目标 | 禁止做法 |
|---|---|---|---|
| 主要可见外轮廓 | 构件外边界、遮挡关系、效果图 | 预设主要轮廓层 | 按源颜色全选 |
| 次要轮廓 | 构造内边、层板和细部 | 预设中粗/细线层 | 与主轮廓同宽 |
| 隐藏线 | 被遮挡、上方或内部构件 | 预设隐藏线层 | 使用连续实线 |
| 中心线 | 对称、轴线、定位中心 | 预设中心线层 | 代替尺寸定位 |
| 材质分缝 | 饰面板块、接缝、分格 | 预设饰面/分缝层 | 刷成主轮廓 |
```

并规定 ByLayer、屏幕/打印线宽检查和效果图仅作为证据。

- [ ] **Step 6: 运行测试确认通过并提交**

```powershell
python -m unittest tests.test_skill_package -v
git add skills/zomo-cad-three-view-drawings/references tests/test_skill_package.py
git commit -m "docs: define model adapters and CAD line semantics"
```

Expected: unittest `OK`。

### Task 5: 编写材料证据、布局与质量 references

**Files:**
- Create: `skills/zomo-cad-three-view-drawings/references/material-evidence-rules.md`
- Create: `skills/zomo-cad-three-view-drawings/references/layout-and-title-block-rules.md`
- Create: `skills/zomo-cad-three-view-drawings/references/quality-checklist.md`
- Modify: `tests/test_skill_package.py`

**Interfaces:**
- Consumes: 当前输入、项目历史、三个视图完整包围框。
- Produces: 材料证据记录和保存前检查清单。

- [ ] **Step 1: 增加失败测试**

```python
    def test_evidence_layout_and_quality_references_preserve_invariants(self):
        refs = SKILL / "references"
        material = (refs / "material-evidence-rules.md").read_text(encoding="utf-8")
        layout = (refs / "layout-and-title-block-rules.md").read_text(encoding="utf-8")
        quality = (refs / "quality-checklist.md").read_text(encoding="utf-8")
        for token in ("本次用户明确输入", "历史确认", "待现场核实", "附件和文档只作为证据"):
            self.assertIn(token, material)
        for token in ("相同比例", "不能串图", "禁止非等比缩放", "内部文字可以重叠", "不同图名块不得重叠"):
            self.assertIn(token, layout)
        for token in ("视口锁定", "预设母版", "保存状态", "视觉检查"):
            self.assertIn(token, quality)
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_skill_package -v`

Expected: FAIL。

- [ ] **Step 3: 写材料证据 reference**

完整写入六级信息优先顺序、可访问的 Codex/ChatGPT 历史范围、ChatGPT 云端不可假定、冲突处理和以下固定证据字段：

```text
note, category, source_id, source_date, status,
confidence, rationale
```

`status` 只允许：`current-confirmed`、`historical-confirmed`、`proposed`、`conflicting`、`unknown`。

- [ ] **Step 4: 写布局与图名块 reference**

完整写入净绘图区计算、上部正/侧视图和下部平面、同尺度优先、运行时视图间距、视口锁定、图名块与视口同宽、图块缩放 1/1/1、只缩短外框、内部文字可重叠、块之间不重叠、标题栏只写属性。

- [ ] **Step 5: 写质量 reference**

用勾选清单覆盖数量、比例、锁定、隔离、尺寸、材质来源、样条/重线/零线、图层线型线宽、图框属性、预设完整性、输出保存状态和视觉导出限制。

- [ ] **Step 6: 运行测试确认通过并提交**

```powershell
python -m unittest tests.test_skill_package -v
git add skills/zomo-cad-three-view-drawings/references tests/test_skill_package.py
git commit -m "docs: define evidence layout and quality rules"
```

### Task 6: 实现 LSP 公共接口与模板检查

**Files:**
- Create: `skills/zomo-cad-three-view-drawings/scripts/zomo-common.lsp`
- Create: `skills/zomo-cad-three-view-drawings/scripts/inspect-template.lsp`
- Create: `tests/test_lisp_contracts.py`

**Interfaces:**
- Produces: `zomo:pt3`、`zomo:bbox`、`zomo:object-array`、`zomo:get-attributes`、`zomo:inspect-template`。

- [ ] **Step 1: 写失败的 LSP 契约测试**

```python
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "skills" / "zomo-cad-three-view-drawings" / "scripts"


class LispContractTests(unittest.TestCase):
    def assertDefines(self, filename, names):
        text = (SCRIPTS / filename).read_text(encoding="utf-8").lower()
        for name in names:
            self.assertIn(f"(defun {name.lower()}", text)

    def test_common_contract(self):
        self.assertDefines("zomo-common.lsp", (
            "zomo:pt3", "zomo:bbox", "zomo:object-array", "zomo:get-attributes"
        ))

    def test_template_contract(self):
        self.assertDefines("inspect-template.lsp", ("zomo:inspect-template",))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_lisp_contracts -v`

Expected: FAIL，LSP 文件不存在。

- [ ] **Step 3: 实现共享函数**

`zomo-common.lsp` 使用 Visual LISP，并提供以下实际函数骨架：

```lisp
(vl-load-com)

(defun zomo:pt3 (p)
  (vlax-3d-point (list (float (car p)) (float (cadr p))
                       (float (if (caddr p) (caddr p) 0.0)))))

(defun zomo:bbox (obj / p1 p2 result)
  (setq result (vl-catch-all-apply 'vla-GetBoundingBox (list obj 'p1 'p2)))
  (if (vl-catch-all-error-p result)
    nil
    (list (vlax-safearray->list p1) (vlax-safearray->list p2))))

(defun zomo:object-array (objects / data)
  (setq data (vlax-make-safearray vlax-vbObject
               (cons 0 (1- (length objects)))))
  (vlax-safearray-fill data objects)
  data)

(defun zomo:get-attributes (block / value)
  (if (= :vlax-true (vla-get-HasAttributes block))
    (progn
      (setq value (vla-GetAttributes block))
      (vlax-safearray->list (vlax-variant-value value)))
    nil))
```

- [ ] **Step 4: 实现模板检查函数**

`zomo:inspect-template` 接收报告路径，遍历当前文档的 layers、layouts、blocks、dimstyles 和 textstyles，记录名称、对象类型、有效块名、属性标签和纸空间包围框。报告必须包含 `document`、`layers`、`layouts`、`blocks`、`dimstyles`、`textstyles` 六个顶级键；无法写入报告时返回明确错误且不修改图纸。

- [ ] **Step 5: 静态测试和只读 AutoCAD 隔离测试**

```powershell
python -m unittest tests.test_lisp_contracts -v
```

Expected: `OK`。

随后仅在预设副本中通过 CAD MCP 加载脚本，调用：

```lisp
(zomo:inspect-template (strcat (getvar "TEMPPREFIX") "zomo-template-index.json"))
```

Expected: 报告生成，预设副本实体计数和保存时间不变。

- [ ] **Step 6: 提交本任务**

```powershell
git add skills/zomo-cad-three-view-drawings/scripts/zomo-common.lsp `
        skills/zomo-cad-three-view-drawings/scripts/inspect-template.lsp `
        tests/test_lisp_contracts.py
git commit -m "feat: inspect CAD preset through reusable LSP contracts"
```

### Task 7: 实现曲线清理、三视口布局和图名块重建

**Files:**
- Create: `skills/zomo-cad-three-view-drawings/scripts/clean-view-curves.lsp`
- Create: `skills/zomo-cad-three-view-drawings/scripts/arrange-three-view-layout.lsp`
- Create: `skills/zomo-cad-three-view-drawings/scripts/rebuild-view-title-block.lsp`
- Modify: `tests/test_lisp_contracts.py`

**Interfaces:**
- Consumes: 运行时 selection set、`view-specs`、源图名块 handle 与属性 alist。
- Produces: 清理结果 alist、视口 handle alist、新图名块 handle。

- [ ] **Step 1: 增加失败的函数契约测试**

```python
    def test_geometry_layout_and_title_contracts(self):
        self.assertDefines("clean-view-curves.lsp", ("zomo:clean-selection",))
        self.assertDefines("arrange-three-view-layout.lsp", ("zomo:arrange-three-view",))
        self.assertDefines("rebuild-view-title-block.lsp", ("zomo:rebuild-title",))
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_lisp_contracts -v`

Expected: FAIL。

- [ ] **Step 3: 实现 `zomo:clean-selection`**

函数必须：统计对象类型；只处理传入 selection set；使用指定 tolerance；将 spline 转为 polyline/arc 候选；删除零长度对象；合并可安全合并的共线片段；使用 OVERKILL 时限制到选择集；返回：

```lisp
((input-count . n)
 (spline-count-before . n)
 (spline-count-after . n)
 (zero-length-removed . n)
 (duplicate-removed . n)
 (status . "PASS"))
```

若任何转换超出 tolerance，保留原对象并将状态设为 `REVIEW`。

- [ ] **Step 4: 实现 `zomo:arrange-three-view`**

函数必须读取当前布局，通过传入的 `paper-rect` 和 `custom-scale` 创建或更新三个视口；设置 model center、paper center、宽高和 CustomScale；验证前视、侧视、平面角色各一个；最后设置 DisplayLocked 为 true。不得移动或缩放模型几何。

- [ ] **Step 5: 实现 `zomo:rebuild-title`**

函数必须：复制源块；读取全部属性值；爆炸副本而非源块；只调整外框多段线边界；移动圆圈、分隔线和需要移动的属性定义但不缩放；创建唯一新块定义；以 1/1/1 插入；恢复属性；验证 bbox 左右边界等于目标；成功后才删除目标图纸中的旧引用。失败时删除临时对象并保留原引用。

- [ ] **Step 6: 运行静态测试**

Run: `python -m unittest tests.test_lisp_contracts -v`

Expected: `OK`。

- [ ] **Step 7: 使用隔离 DWG 进行 CAD MCP 回归测试**

在临时副本中验证：

1. spline 数量降为 0 或全部标记 REVIEW；
2. 三个视口存在且锁定；
3. 三个视口在可行时 CustomScale 相同；
4. 图名块与视口左右边界和宽度相同；
5. 图名块 X/Y/Z scale 为 1/1/1；
6. 相邻图名块只有公共边界，无正面积重叠；
7. 源模型、源预设和原始测试文件未保存。

- [ ] **Step 8: 提交本任务**

```powershell
git add skills/zomo-cad-three-view-drawings/scripts tests/test_lisp_contracts.py
git commit -m "feat: clean views and arrange invariant CAD layout"
```

### Task 8: 实现保存前图纸审计

**Files:**
- Create: `skills/zomo-cad-three-view-drawings/scripts/audit-three-view-drawing.lsp`
- Modify: `tests/test_lisp_contracts.py`

**Interfaces:**
- Consumes: `layout-name`、运行时 `view-title-pairs`、报告路径。
- Produces: 包含 `passed`、`issues`、`measurements` 的审计报告和 PASS/FAIL alist。

- [ ] **Step 1: 增加失败测试**

```python
    def test_audit_contract(self):
        self.assertDefines("audit-three-view-drawing.lsp", ("zomo:audit-three-view",))
```

- [ ] **Step 2: 运行测试确认失败**

Run: `python -m unittest tests.test_lisp_contracts -v`

Expected: FAIL。

- [ ] **Step 3: 实现审计函数**

`zomo:audit-three-view` 必须检查：

```text
VIEWPORT_COUNT
VIEWPORT_LOCKED
VIEWPORT_SCALE
VIEW_ISOLATION
TITLE_VIEWPORT_LEFT
TITLE_VIEWPORT_RIGHT
TITLE_VIEWPORT_WIDTH
TITLE_UNIFORM_SCALE
TITLE_PAIR_OVERLAP
DIMENSION_VISIBILITY
SPLINE_COUNT
ZERO_LENGTH_COUNT
INVALID_GEOMETRY
FRAME_ATTRIBUTES
PRESET_CHECKSUM
OUTPUT_SAVED
```

每项 issue 包含 `code`、`role`、`expected`、`actual` 和 `severity`。只有 severity 为 ERROR 的数量为 0 时 `passed=true`。视觉导出失败必须写入 WARNING，不能写成已视觉通过。

- [ ] **Step 4: 运行静态测试和隔离审计**

```powershell
python -m unittest tests.test_lisp_contracts -v
```

Expected: `OK`。

在一个故意让侧视图名块重叠的临时 DWG 中运行审计，Expected: FAIL 且包含 `TITLE_PAIR_OVERLAP`。修复后再次运行，Expected: PASS。

- [ ] **Step 5: 提交本任务**

```powershell
git add skills/zomo-cad-three-view-drawings/scripts/audit-three-view-drawing.lsp `
        tests/test_lisp_contracts.py
git commit -m "feat: audit three-view drawing invariants"
```

### Task 9: 完成包验证、Rhino 标准测试和 SketchUp 验证门

**Files:**
- Modify: `skills/zomo-cad-three-view-drawings/SKILL.md`（仅修复测试发现的问题）
- Modify: `skills/zomo-cad-three-view-drawings/references/*.md`（仅修复测试发现的问题）
- Create: `artifacts/zomo-cad-three-view-drawings-validation.json`
- Create: `dist/zomo-cad-three-view-drawings.zip`

**Interfaces:**
- Consumes: 完整 Skill 包和隔离测试输出。
- Produces: 可分发 ZIP、验证报告和清晰的已验证/未验证能力状态。

- [ ] **Step 1: 运行全部静态测试**

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
python "C:\Users\ZOMOZOMO\.codex\skills\.system\skill-creator\scripts\quick_validate.py" `
  "skills\zomo-cad-three-view-drawings"
```

Expected: 所有 unittest `OK`，quick validator 通过。

- [ ] **Step 2: 扫描占位符、绝对路径和项目句柄**

```powershell
rg -n "TBD|TODO|FIXME|ZOMOZOMO|2DD76|2D926|487\.953|767\.953|839\.388" `
  "skills\zomo-cad-three-view-drawings"
```

Expected: 无匹配。测试计划和仓库外部文档中的示例不计入 Skill 包扫描。

- [ ] **Step 3: 运行 Rhino/CAD 隔离标准测试**

仅在用户明确同意测试时：复制本次 3DM 和预设到临时目录，使用 Rhino MCP 与 CAD MCP 生成新 DWG，执行 Task 7 和 Task 8 的全部硬约束检查。不得保存源 3DM、源 DWG 或 Skill 预设。

Expected: Rhino 路径标记 `verified=true`；AutoCAD 路径 `verified=true`；审计 `passed=true`。

- [ ] **Step 4: 设置 SketchUp 能力状态**

若仍无 SketchUp MCP，验证报告写：

```json
{
  "sketchup": {
    "implemented": true,
    "verified": false,
    "reason": "No callable SketchUp MCP was available during validation."
  }
}
```

如果后续安装了 SketchUp MCP，则必须使用隔离 SKP 完成场景、标签、组件、材质和三视图输出测试后才能改为 `verified=true`。

- [ ] **Step 5: 写完整验证报告**

`artifacts/zomo-cad-three-view-drawings-validation.json` 必须记录 Skill 验证、预设校验、自动触发静态检查、Rhino 状态、AutoCAD 状态、SketchUp 状态、审计结果、测试时间和限制。

- [ ] **Step 6: 创建可分发 ZIP**

```powershell
Compress-Archive -LiteralPath "skills\zomo-cad-three-view-drawings" `
  -DestinationPath "dist\zomo-cad-three-view-drawings.zip"
```

Expected: ZIP 根目录包含单一 `zomo-cad-three-view-drawings` 文件夹，内部无测试临时文件、源项目模型或输出 DWG。

- [ ] **Step 7: 最终验证 ZIP 内容**

展开到临时目录，重新运行 `quick_validate.py`、预设 SHA-256 测试和敏感路径扫描。Expected: 全部通过。

- [ ] **Step 8: 提交本任务**

```powershell
git add skills/zomo-cad-three-view-drawings tests artifacts dist
git commit -m "feat: validate and package ZOMO three-view CAD skill"
```

不要把 Skill 复制到个人或公司 Codex skills 目录；安装属于后续独立授权步骤。
