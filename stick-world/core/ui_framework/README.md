# core/ui_framework（L0 UI 公共层）

纯布局原语与无依赖组件。**零资产、零模块依赖**：本目录不引用任何 `modules/` 内容，
不加载贴图/字体/主题资源，只提供布局与绘制的最小公共语义。

## 清单

| 文件 | 内容 |
| --- | --- |
| `ui_kit.gd` | `UIKit`：代码创建 UI 的合规出口——`full_rect()` 全屏根 / `widget()` 角落部件（落实「场景是布局唯一真相源」，禁 `Control.new()` 当 UI 根） |
| `components/progress_painter.gd` | `ProgressPainter`：世界空间进度条 `_draw` 公共基类（bg/fg 双 rect + 描边 + clampf），世界空间进度条统一继承复用 |

## 分层契约（L0 / L1）

- **L0 = `core/ui_framework/`（本目录）**：纯布局原语与无依赖组件。只有不依赖任何
  视觉资产、任何模块的代码才能进来。
- **L1 = `modules/ui_global/`**：视觉实现层——sketch 手绘控件族、主题资产
  （StickTheme/StickStyle/SketchStyle/StickTokens/StickIcons）、StickScreen/StickWindow
  屏幕与窗口体系、StickKit 装配器。依赖方向只允许 L1 → L0
  （ui_global/world_map/units/construction → core 合法，core 不 import 任何模块）。

## 为什么不建 core/theme

主题（贴图皮肤、颜色 Token、字号、字体）是**视觉资产**，属 L1 设计语言范畴；
L0 要求零资产，把 theme 下沉 core 会迫使 core 携带资源依赖，违背分层。
主题实况在 `modules/ui_global/scripts/theme/`。

## 为什么不抽 core Screen 基类

全项目弹窗/屏幕已有统一基类 `StickScreen`（`modules/ui_global/scripts/stick_screen.gd`，
遮罩 + PanelContainer + 标题/body/footer 骨架，open/close/toggle 契约）。再在 core 抽一个
Screen 抽象只会得到一层空转发——避免空抽象，屏幕体系留在 L1。
