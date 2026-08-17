# UI 体系规划

> 本目录是 stick-world **UI 体系的唯一规划入口**：设计语言、界面框架、各界面规范、
> 组件库与拓展性方案。配套可运行模板位于
> `stick-world/modules/ui_global/scenes/templates/`（F6 可直接运行，入口 `template_index.tscn`）。
> 方向性原则的上游文档是 [`../UI设计规范.md`](../UI设计规范.md)（设计哲学/工作区预设/层级 UI 表），
> 本目录负责把它落成完整的界面体系与可复用的视觉系统。

---

## 设计目标

1. **窗户不是海报**：界面是纯黑半透明的"玻璃窗"，游戏画面永远透出来——黑色沥青世界观的天然延续。
2. **一套 token 管全部**：颜色/字号/间距/圆角集中在 `StickTokens`，换肤 = 换一个 token 文件。
3. **内容数据驱动**：加一个菜单项/设置项/工作区 = 加一行数据，不写 UI 代码。
4. **按需呈现**：信息密度服从当前管理层级（L1 个体 → L5 帝国），随缩放渐隐渐显。

---

## 文档地图

| 篇目 | 内容 |
|------|------|
| [01-设计语言](01-设计语言.md) | 视觉哲学、色彩/字号/形状/动效 token 表、图标规范 |
| [02-界面框架](02-界面框架.md) | 屏幕状态机、UI 层级栈、**界面要素总表**（全部界面一览） |
| [03-主菜单与流程](03-主菜单与流程.md) | 启动流程、主菜单、新游戏、载入屏、读档 |
| [04-游戏内HUD](04-游戏内HUD.md) | HUD 布局分区、层级渐隐渐显、工作区预设、时间控制 |
| [05-弹窗与模态](05-弹窗与模态.md) | 模态栈规则、确认框族、Toast 通知、Tooltip |
| [06-组件库](06-组件库.md) | 标准组件清单与用法、数据驱动装配模式 |
| [07-设置界面](07-设置界面.md) | 设置分类与设置项总表、按键绑定与无障碍预留 |
| [08-拓展性](08-拓展性.md) | 换肤/主题热切换/字体切换、大界面注册挂点、多分辨率 |

---

## 模板索引（`modules/ui_global/scenes/templates/`）

| 场景 | 内容 | 对应文档 |
|------|------|---------|
| `template_index.tscn` | **总览导航页**（模板入口，F6 运行它即可逐个点开） | — |
| `main_menu_template.tscn` | 主菜单：标题 + 数据驱动菜单列 + 版本角标 | 03 |
| `settings_template.tscn` | 设置界面：左分类右内容，整页 schema 驱动 | 07 |
| `hud_template.tscn` | 游戏内 HUD：顶栏/小地图框/快捷栏/通知流 | 04 |
| `workspace_template.tscn` | 工作区预设：军事/科研/工程/行政/商业标签切换 | 04 |
| `component_gallery.tscn` | 组件展示页：全族控件陈列 + 主题回归自检 | 06 |

主题层（`modules/ui_global/scripts/templates/theme/`）：

| 脚本 | 职责 |
|------|------|
| `stick_tokens.gd`（StickTokens） | 全部视觉常量：颜色/字号/间距/圆角/时长 |
| `stick_style.gd`（StickStyle） | StyleBox 工厂：窗体/按钮族/标签页/进度条/分隔线 |
| `stick_theme.gd`（StickTheme） | 打包成可挂根节点的 Theme（`theme = StickTheme.create()`） |
| `stick_kit.gd`（StickKit） | 组件装配工厂：label/button/section/toast/confirm |

---

## 与现有代码的关系

- 模板是**落地样例与新界面的起点**：新界面从模板复制起步；现有界面（GlobalHUD /
  SettingsMenuPanel / SavePanel 等）在向 `.tscn` 迁移时顺手换用 StickTheme。
- 现有 `core/ui_framework/`（UITheme 常量 / BaseScreen / PanelKit）继续有效；
  StickTheme 是其演进方向——字号常量已对齐（22/13/14/11），Token 集是超集。
- 布局铁律不变：场景是布局唯一真相源，模板全部遵守（骨架在 `.tscn`，内容工厂装配）。

---

## 落地路线

| 阶段 | 工作 |
|------|------|
| P0 后期 | 模板验收；主菜单接入启动流程（project.godot 主场景前插主菜单场景） |
| P1 | 现有面板迁移 `.tscn` + 换 StickTheme；载入屏；读档界面卡片化；按键绑定页 |
| P2 | 层级皮肤变体（石头→羊皮纸→全息）；图标资产入库（`assets/ui/`）；主题热切换设置项 |
