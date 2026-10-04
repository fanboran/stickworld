# UI 实现

> 本目录是 stick-world **UI 实现侧**文档：组件库、主题系统、模态栈、设置、
> 布局铁律、图标管线与界面接线方案——UI 怎么搭、怎么摆、怎么换肤。
> **设计意图**（设计语言/界面框架/各屏规划）在 [`docs/设计/UI/`](../../设计/UI/README.md)；
> 场景图 UI 运行时分层（GlobalHUD/槽位路由）在
> [`docs/技术/架构/场景与战斗/UI.md`](../架构/场景与战斗/UI.md)。

## 文档地图

| 篇目 | 内容 |
|------|------|
| [弹窗与模态](弹窗与模态.md) | 模态栈规则（UIModalStack）、确认框族、Toast 通知、Tooltip、4 种弹窗行为模板 |
| [组件库](组件库.md) | 标准组件清单与用法、数据驱动装配模式（Token→Style→Theme→Kit 分层） |
| [设置界面](设置界面.md) | 设置分类与设置项总表（SETTINGS_SCHEMA）、按键绑定与无障碍预留、落盘与生效链路 |
| [拓展性](拓展性.md) | 换肤/主题热切换/字体切换、大界面注册挂点、多分辨率 |
| [布局规则与AI自检](布局规则与AI自检.md) | 摆放铁律（禁手写 position）、标准摆放 API、AI 提交前自检流程 |
| [UI系统重构参考](UI系统重构参考.md) | 《药剂工艺》反编译参考与本仓实现映射（LayerOrder/UIModalStack） |
| [图标清单与缺口](图标清单与缺口.md) | 图标管线成品全量清单（定稿/未定稿）、UI 接线点现况、待制作母题缺口 |
| [组织界面与AI状态接线](组织界面与AI状态接线.md) | 组织界面与 AI 状态观测的接线总体方案（W1~W4 批次） |
| [UI运行时架构优化方案](UI运行时架构优化方案.md) | 暂停原语化/HUD 槽位/按钮变体三项优化（已实施，留作设计依据） |

## 模板索引（`modules/ui_global/scenes/templates/`）

| 场景 | 内容 | 对应设计篇 |
|------|------|---------|
| `template_index.tscn` | **总览导航页**（模板入口，F6 运行它即可逐个点开） | — |
| `main_menu_template.tscn` | 主菜单：标题 + 数据驱动菜单列 + 版本角标 | 03 |
| `settings_template.tscn` | 设置界面：左分类右内容，整页 schema 驱动 | 07→设置界面 |
| `hud_template.tscn` | 游戏内 HUD：顶栏/小地图框/快捷栏/通知流 | 04 |
| `workspace_template.tscn` | 工作区预设：军事/科研/工程/行政/商业标签切换 | 04 |
| `component_gallery.tscn` | 组件展示页：全族控件陈列 + 主题回归自检 | 组件库 |

主题层（`modules/ui_global/scripts/theme/`，正式共享基础设施，模板与游戏内 UI 共用）：

| 脚本 | 职责 |
|------|------|
| `stick_tokens.gd`（StickTokens） | 全部视觉常量：颜色/字号/间距/圆角/时长 |
| `stick_style.gd`（StickStyle） | StyleBox 构造器：窗体/按钮族/标签页/进度条/分隔线 |
| `stick_theme.gd`（StickTheme） | 打包成可挂根节点的 Theme（`theme = StickTheme.create()`） |
| `stick_kit.gd`（StickKit） | 组件装配器：label/button/section/toast/confirm |

## 与现有代码的关系

- 模板是**落地样例与新界面的起点**：新界面从模板复制起步；现有界面在向 `.tscn`
  迁移时顺手换用 StickTheme。
- `core/ui_framework/` 是 L0 布局原语（`UIKit.full_rect()/widget()` 出口），不含主题；
  主题实现在 `modules/ui_global/scripts/theme/`——分层契约见
  `stick-world/core/ui_framework/README.md`。
- 布局铁律不变：场景是布局唯一真相源，模板全部遵守（骨架在 `.tscn`，内容由 StickKit 装配）。

## 占位界面（`modules/ui_global/`）

依赖系统（科技/物流/成就/组织报表等）尚未建立的**大界面空面板**集中在 ui_global 模块
（`scripts/placeholders/` + `scenes/placeholders/`），样式与入口已就绪，系统接入时替换填充。
详见 [`modules/ui_global/api.gd`](../../../stick-world/modules/ui_global/api.gd)
与设计侧 `02-界面框架.md` §4.4；验收入口 F6 运行 `ui_placeholder_preview.tscn`。

## 关键约定速查

| 事项 | 见 |
|------|-----|
| 布局铁律 / AI 自检 / 截图工具 | [布局规则与AI自检](布局规则与AI自检.md) |
| 4 种弹窗行为模板 | [弹窗与模态](弹窗与模态.md) §六 |
| 层号常量 / 模态栈蓝图 | [UI系统重构参考](UI系统重构参考.md) + `LayerOrder` |
| 界面通达表（入口+快捷键） | 设计侧 `02-界面框架.md` §六 |
| 测试命令 | AGENTS.md（`tests/run_all.sh` / `check_godot_errors.sh` / 截图自检） |
