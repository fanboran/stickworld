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
| [09-布局规则与AI自检](09-布局规则与AI自检.md) | 摆放铁律、标准 API、AI 提交前自检流程、分工建议 |

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

主题层（`modules/ui_global/scripts/theme/`，正式共享基础设施，模板与游戏内 UI 共用）：

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
| P2 | 图标资产入库（`assets/ui/`）；界面缩放设置项完善 |

---

## 占位界面模块（`modules/ui_placeholder/`）

依赖系统（科技/物流/成就/组织报表等）尚未建立的**大界面空面板**集中放在此模块，
样式与入口已就绪，系统接入时替换填充。详见 [`modules/ui_placeholder/`](../../../stick-world/modules/ui_placeholder/api.gd)
与 `02-界面框架.md` §4.4；验收入口 F6 运行 `ui_placeholder_preview.tscn`。

---

## 当前状态与下一步（给接手 AI 的入口）

### 已落地（2026-08）

- **启动/流程**：主菜单接入（继续/新游戏/读档/设置/退出）、载入屏（过渡型）、**战略图懒加载**（启动 20.8s→3.2s）、世界加载覆盖层（真实加载有指示、无死灰屏）
- **统一模态栈（缺口 2）**：`UIModalStack`（ui_modal_stack.gd）层键字典 + 逐层 pop（PAUSE_MENU/SETTINGS/SAVE_PANEL/EMPIRE_PANEL/CONFIRM），替代 `GameRoot._handle_escape` 特判；输入屏蔽随栈统一（首层入栈暂停、栈空恢复；压上层自动盖住下层防双重遮罩）；确认框已栈化（ESC=取消），占位面板同类单例（重复触发提到栈顶、换预设替换）
- **分层**：ModalOverlay 盖住全部 UI（z=50）、模态打开自动暂停 + 遮罩消费鼠标 + 相机输入暂停兜底（防穿透）
- **弹窗体系**：4 种行为模板（`StickScreen`=MODAL / `StickWindow`=FLOATING/DOCK/POPOVER，见 05 §六）、编制菜单已归 FLOATING（可拖动、不变灰）、暂停菜单（帝国功能组 + K/O/J/L 快捷键直达空面板）
- **统一层号**：`LayerOrder`（layer_order.gd）+ `SystemOverlay` 系统层（toast/确认框挂它，不随调用者）
- **约束与自检**：布局铁律 + 截图自检 `tests/dev/ui_shots.tscn`（见 09）
- **防 UI 重合通用方案**：HUD 预留区 + 安全矩形（`StickKit.safe_rect` / `clamp_to_safe_rect`，顶栏 104px/底栏 88px 避让），`StickWindow` FLOATING/POPOVER 初始定位自动夹紧；回归测试 `tests/integration/test_ui_layout.tscn`（顶栏按钮↔材料条不重叠 + 弹窗不盖 HUD，headless 可跑）；材料条（ResourceBarHost）移至顶栏下方（y=64，不再压按钮行）
- **设置面板**：880×620、分类切换真生效、字段落盘 ConfigManager
- **HUD**：顶栏距边 12px、小地图 1.5 倍、缩放条条本体对齐+100%刻度+文字在条右侧、时钟缝隙对称

### 下一步（接手 AI 的待办）

1. **做做样子项清理**（待办事项.md）：通知 feed 堆叠、游戏内快捷栏、设置项"存了不生效"（window_mode/音量/show_fps 接消费方）、小地图/缩放条样式统一
2. **业务面板迁移**（Village/Battle/Possess/BuildMenu/FormationPanel 细节）到 4 模板 + StickTheme，按 09 自检
3. **模态栈深化**：强/弱模态分级（载入屏/新游戏向导屏蔽 ESC）、战略图并入层键、载入屏并入层号常量
4. **战略图性能/体验**（2026-08 已做第一档）：L3 几何烘焙 l3_geom.bin（首次打开 10.6s→0.6s，见 `战略图架构.md` §6.1a）、初始视野放大 50%；下一步可做 L3 运行时 LOD 分级（缩放切精细度）、地图数据异步加载线程化

### 关键约定速查

| 事项 | 见 |
|------|-----|
| 布局铁律 / AI 自检 / 截图工具 | 09 |
| 4 种弹窗行为模板 | 05 §六 |
| 层号常量 / 模态栈蓝图 | 10 + `LayerOrder` |
| 界面通达表（入口+快捷键） | 02 §六 |
| 测试命令 | AGENTS.md（`tests/run_all.sh` / `check_godot_errors.sh` / 截图自检） |
