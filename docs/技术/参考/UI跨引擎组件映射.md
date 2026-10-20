# UI 跨引擎组件映射（stick-world ↔ pirate-crew）

> **是什么**：stick-world（Godot）UI 体系与 pirate-crew-3d-unity（Unity UGUI）复刻层的**组件级对账契约**——每个 Godot 组件在 Unity 侧的对应物、当前状态、归属批次。像素级复刻任务（见 `docs/项目/交接/UI跨引擎像素级复刻-进度与交接.md`）以此为组件清单的唯一对账表；任一仓新增/删除 UI 组件须同步改本表。
> **真相源方向**：视觉令牌/贴图/变体表单向 game-2 → Unity（`tools/ui_sync/sync_to_unity.py`）；本表是结构契约，双向维护（哪边改组件哪边更新对应行）。
> 状态图例：✅ 已落地并过验证｜♻ 存量复用（对参数即得）｜**P1/P2** 计划批次｜✖ 不迁移（含理由）。

## 0. 已统一的三层底座（P0 完成）

| game-2 | Unity | 状态 | 说明 |
|---|---|---|---|
| `theme/stick_tokens.gd` | `Scripts/UI/Stick/Tokens/StickTokens.generated.cs` | ✅ | 48 常量代码生成，禁手改；改令牌走导出器重跑同步 |
| `theme/stick_icons.gd` | `StickTokens.IconMotifs/IconSemantic/LoadIcon()` | ✅ | 93 母题 + 6 语义映射，Resources 路径 `UI/StickWorld/icons/` |
| `sketch/sketch_draw.gd` | `Stick/Paint/SketchDrawMath.cs` + `SketchWobbleGraphic.cs` | ✅ | wobble 噪声逐位一致、0.12s 重掷、顶点色 AA 羽化 |
| `core/ui_framework/components/progress_painter.gd` | `Stick/Paint/SketchBarGraphic.cs` | ✅ | bg+前景+1px 描边语义、clamp、SetProgress |
| `theme/sketch_textures.gd`（贴图帧驱动） | `Skin/SketchBoil.cs` + `Skin/Sketch9Slice.cs` | ♻ | 机制忠实移植件；贴图路径切 `UI/StickWorld/`、节拍已对齐 7.5fps |
| `sketch/sketch_fonts.gd` | TMP `Fonts/StickHand-Regular SDF`（dynamic 72pt） | ✅ | 资产级统一；embolden 0.6 粗体→TMP 按档校准（P1） |
| 资产层 `assets/ui/sketch/`(81)/fonts(4)/icons(93) | `Assets/Resources/UI/StickWorld/` | ✅ | SHA256 清单 `--verify` 门禁 |
| `sketch_style.gd` 按钮变体表（6 变体×五态） | `StickTokens.ButtonVariants`（枚举+struct+字典） | ✅ | 变体级已统一；**运行时消费组件见 P1** |
| 贴图槽位 27 | 同名同步 | ✅ | Unity 旧集本地槽（pip/ring/fill/cell）为 pirate 专属 tint 槽，保留（见 §5） |

## 1. sketch 手绘控件族（`modules/ui_global/scripts/sketch/`）→ Unity `Stick/Controls/`（P1 主力）

| game-2 | Unity 对应物 | 批次 | 移植要点 |
|---|---|---|---|
| sketch_button.gd（6 变体） | SketchButton（Button + SketchBoil 四态槽） | **P1** | 变体表驱动（ButtonVariants 字典），五态字色/描边/伪粗逐项取 tokens |
| sketch_panel.gd | SketchPanel（Sketch9Slice + tokens 面板内边距） | **P1** | DARK/LIGHT 两档 = panel / panel_light 槽 |
| sketch_progress.gd | SketchBarGraphic 复用 + 贴图槽变体（progress_bg/fill） | **P1** | 屏幕空间进度条薄壳 |
| sketch_separator.gd | SketchSeparator（sep_h/sep_v 贴图件） | **P1** | 薄件，随面板批 |
| sketch_hslider.gd | SketchSlider（SketchWobbleGraphic 自绘轨道+圆点滑块） | **P1** | gd 是全自绘——用 Painter 核，不用 Unity 原生 Slider 皮肤 |
| sketch_check_box.gd | SketchToggle（方形，SDF 兜底图标 18²） | **P1** | 勾选符号走 wobble 自绘（对齐 sketch_icons 兜底口径） |
| sketch_check_button.gd | SketchSwitch（拨动 34×18） | **P1** | 同上 |
| sketch_option_button.gd | SketchDropdown（TMP_Dropdown 换肤或自绘弹层） | P2 | 弹层列表项仍走 SketchButton |
| sketch_line_edit.gd | SketchInputField（TMP_InputField 换肤） | P2 | 光标/选区色取 tokens |
| sketch_tab_bar.gd / sketch_tab_container.gd | SketchTabBar / SketchTabContainer | P2 | 页签 boiling 描边 + ACCENT 下划线 |
| sketch_gear_button.gd | SketchGearButton（ICON_SQUARE 变体特例） | P2 | 小件 |
| sketch_icons.gd（SDF 扰动兜底图标） | （随 Toggle/Switch 一并） | P2 | 仅兜底小图标，大图标走 StickIcons |
| sketch_cloud.gd | ✖ 不迁移 | — | 大世界云是世界景物，非 UI；pirate 无此需求 |
| sketch_fonts.gd | ✅（资产级，见 §0） | — | — |
| sketch_draw.gd | ✅（见 §0） | — | — |

## 2. 骨架层（根/模态栈/弹窗体系）→ Unity `Stick/Frame/`（P1 后段）

| game-2 | Unity 对应物 | 批次 | 移植要点 |
|---|---|---|---|
| ui_root.gd（UIRoot 槽位路由） | StickUIRoot（Canvas 下具名槽容器 + `AddToSlot()`） | **P1** | 槽位表同名：HudOverlay/ModePanel/ModalOverlay…；禁手挂 add_child |
| ui_modal_stack.gd（7 层键模态栈） | StickModalStack | **P1** | 纯逻辑直译：层键字典/逐层 pop/ESC/首层暂停 |
| stick_screen.gd（模态弹窗基类） | StickScreen（遮罩+居中面板+标题/body/footer） | **P1** | 遮罩背景 generative_backdrop 先以纯压暗替代（见 §4） |
| stick_window.gd（FLOATING/DOCK/POPOVER） | StickWindow | **P1** | 拖拽/锚点弹出/点外自关行为对齐 |
| stick_confirm_dialog.gd | StickConfirmDialog（固定 CONFIRM 层） | **P1** | 点遮罩不关语义保留 |
| theme/layer_order.gd | StickLayerOrder（常量表） | **P1** | 层号数值 1:1 |
| core/ui_framework/ui_kit.gd（full_rect/widget） | StickUIKit（RectTransform 布局出口） | **P1** | Godot 容器数学（min size 分配）按 StickLayout 移植，**不硬凑 LayoutGroup** |
| theme/stick_kit.gd（数据驱动装配器） | StickKit（label/button/panel/confirm… 装配出口） | **P1** | "加一项=加一行数据"模式保留 |
| theme/stick_theme.gd（Theme 构建器） | ✖ 无直接对等 | — | UGUI 无全局 Theme 机制；等价物= StickKit/StickUIKit 统一样式出口 |
| theme/stick_style.gd / sketch_style.gd（样式分发） | 消费端并入 StickKit + ButtonVariants | — | 样式构造逻辑分散到各控件（UGUI 惯例） |
| theme/glass_style.gd（玻璃兜底皮肤） | ✖ 不迁移 | — | 兜底皮肤无复刻意义；pirate 只走 sketch 单皮肤 |
| debug_ui_inspector.gd | ✖ 不迁移 | — | Unity 自有 Inspector/调试体系 |

## 3. 世界空间手绘条族（数据镜像架构，P1）

| game-2 | Unity 对应物 | 批次 | 移植要点 |
|---|---|---|---|
| units/entity/health_bar_indicator.gd | StickHealthBar（SketchBarGraphic 驱动） | **P1** | 阵营色圆点+横条/满血隐藏/受击显示；**数据在实体侧、渲染走镜像**（AGENTS.md #6 同款） |
| units/entity/action_progress_indicator.gd | StickActionBar | **P1** | 头顶 y=-130 动作条 |
| construction/scripts/build_progress_indicator.gd | StickBuildBars（双条：材料蓝/建造绿） | **P1** | 宽=占地×32px 口径按 pirate 网格换算 |
| HD-2D billboard 镜像（char_sprite_3d.gd 数据模式） | world-space Canvas / 朝屏 quad | **P1** | pirate 为 3D：条挂 world-space Canvas；对账=条本体 1:1 局部渲染 diff |

## 4. HUD 部件（`hud/`）→ Unity `Stick/Hud/`（P2，随界面换装逐个）

| game-2 | Unity 对应物 | 批次 | 移植要点 |
|---|---|---|---|
| hud_zone_layout.gd（zone 定位表） | StickHudZones（表驱动锚点定位器） | **P2** | ZONES 表数值 1:1（anchor 比例+像素 region+fill/dock/stack） |
| global_hud.gd / resource_bar.gd / clock_widget.gd / minimap.gd / zoom_bar.gd+zoom_slider.gd / quest_panel.gd / notification_feed.gd / fps_counter.gd | StickHud 同名件 | **P2** | 逐件过条本体/整屏 diff；minimap/clock 属世界映射部件，视觉复刻+数据按 pirate 玩法接 |
| effects/generative_backdrop.gd | P2（先纯压暗遮罩） | **P2** | 旋转立方网格+鼠标排斥的生成艺术遮罩，视 pirate 观感需求立项 |

## 5. 界面与业务面板（panels/menus/overlays/keymap/…）→ P2 逐界面换装（不逐一列表）

main_menu / settings_menu_panel / pause_menu_panel / save_panel / loading_screen / mode_panel / context_panel / overlays 5 件 / keymap 组件族（sketch_keyboard+sketch_mouse+注册表）/ indicators 2 件 / placeholders 3 件 / templates 6 件：**不按组件迁移，按界面换装**——Unity 侧同名界面用 StickKit 重建 + StickTokens 供样式，逐屏出 golden diff（对账靶子=game-2 `templates/component_gallery`，Unity 侧 P2 建同款陈列页）。keymap 组件族数据源（keyboard_layouts.json）一并同步。

## 6. 对账与维护纪律

1. **新增组件**：任一仓新增 UI 组件，本表加一行（game-2 侧先定设计→Unity 侧按行落地）；两侧同名不同物（如 SketchButton 与 Unity 旧 UiKit 按钮）以本表为归属判据。
2. **验收口径**：屏幕空间组件走 1920×1080 整屏/区域 diff（`tools/ui_sync/diff_ui.py`，文本行按容差、图形严格）；世界空间条族走条本体 1:1 局部渲染 diff。
3. **Unity 旧皮肤三套退场对照**（UiTheme 木纸 / MenuUiBuilder 玻璃 / UiSkin 夜海蓝）：换装完一个界面即在 Unity 交接档勾销一项，最终全量退役（UiSkinTests 同步改写）。
4. pirate 专属件（tint 槽 pip/ring/fill/cell、WeaponColor/CrewColor 色表、UiMotion 动效规则）**保留**，不属复刻退场范围——它们是 pirate 玩法语义层，与设计语言正交。
