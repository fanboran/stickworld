# ui_global：全局 UI 层（容器体系 + 手绘皮肤 + 通用控件）

> 本模块只放**跨模块共享的 UI 容器与通用控件**，深度耦合某业务模块的面板归属该模块 `ui/` 子目录（垂直切片原则）：
> - **UIRoot 容器体系**：三层 UI（GlobalHUD / ModePanel / ContextPanel）+ 槽位路由（HudOverlay / ModalOverlay / SystemOverlay）+ HUD zone 定位表 + 统一模态栈
> - **Sketch 手绘皮肤体系**：SketchButton 变体表驱动 + StickTheme 全局主题 + StickTokens 设计 Token，主菜单与游戏内同一皮肤
> - **通用 HUD 部件**：Minimap / ZoomBar / ClockWidget / ResourceBar / NotificationFeed 等
> - **模板层**（`scenes/templates/`）：各界面骨架的可运行陈列，F6 逐个验收
>
> 架构口径（三层 UI 分层 / 布局铁律 / 槽位路由）见 [docs/技术/架构/场景与战斗/UI.md](../../../docs/技术/架构/场景与战斗/UI.md)；业务面板由 `SystemSetup`（modules/world 装配器）挂进本层容器，模块代码不跨模块 `get_node`。

---

## 目录结构

```
modules/ui_global/
├── api.gd                              # UIAPI：对外契约（PanelType 枚举 / 容器节点路径 / create_save_panel）
├── README.md                           # 本文件
├── scripts/
│   ├── ui_root.gd                      # UIRoot（CanvasLayer）：槽位路由 add_to_slot + zone 落位 place_in_zone + 模式面板切换 + 通知转发
│   ├── hud_zone_layout.gd              # HudZoneLayout：HUD zone 注册表（ZONES 表）与定位引擎——层级归 slot，定位归 zone
│   ├── ui_modal_stack.gd               # UIModalStack：统一模态栈（层键字典 + ESC 逐层 pop + 随栈暂停/输入屏蔽）
│   ├── uikit.gd                        # UIKit：代码创建出口——full_rect() 全屏根 / widget() 角落部件（不自设 anchor）
│   ├── stick_screen.gd                 # StickScreen：排他模态弹窗基类（全屏遮罩 + 居中面板 + body/footer）
│   ├── stick_window.gd                 # StickWindow：非模态浮动窗口基类（FLOATING/DOCK/POPOVER，不入模态栈）
│   ├── stick_confirm_dialog.gd         # StickConfirmDialog：模态确认框（入 UIModalStack CONFIRM 层）
│   ├── debug_ui_inspector.gd           # F3 UI 名称检查器（悬停显示控件名 + 脚本来源）
│   ├── theme/                          # 皮肤层
│   │   ├── stick_tokens.gd             #   StickTokens：设计 Token 唯一真相源（颜色/字号/间距/时长），不写字面量
│   │   ├── stick_icons.gd              #   StickIcons：图标管线成品取图入口（assets/icons/<母题>_64.png）
│   │   ├── sketch_style.gd             #   SketchStyle：沸腾贴图九宫格 StyleBox + 按钮变体表（SketchButton 视觉唯一来源）
│   │   ├── sketch_textures.gd          #   SketchTextures：沸腾帧贴图集（assets/ui/sketch）+ 帧驱动
│   │   ├── stick_style.gd              #   StickStyle：StyleBox 分发（Theme 兜底与开发模板用，调用点换肤不动）
│   │   ├── glass_style.gd              #   GlassStyle：玻璃 StyleBox 变体（对照陈列用）
│   │   ├── stick_theme.gd              #   StickTheme：Theme 构建器（UIRoot 启动挂满全部槽位）
│   │   └── layer_order.gd              #   LayerOrder：CanvasLayer 层号 + UIRoot 内 z_index 常量（Z_MODAL/Z_SYSTEM/Z_INSPECTOR）
│   ├── sketch/                         # Sketch 控件族（血条同源 boiling 手绘）
│   │   ├── sketch_button.gd            #   SketchButton：kind 查 SketchStyle 变体表（DARK/ACCENT/PRIMARY/DANGER/PAPER/ICON_SQUARE）
│   │   ├── sketch_gear_button.gd       #   齿轮自绘按钮（ICON_SQUARE 档，底与描边自绘）
│   │   ├── sketch_tab_bar.gd           #   SketchTabBar：页签作过滤器（boiling 描边 + 琥珀下划线自绘）
│   │   ├── sketch_tab_container.gd     #   SketchTabContainer：多页面签容器（与 TabBar 同源自绘）
│   │   ├── sketch_panel.gd             #   SketchPanel：手绘面板底（DARK/LIGHT 两档）
│   │   ├── sketch_check_box.gd / sketch_check_button.gd / sketch_line_edit.gd / sketch_option_button.gd / sketch_hslider.gd / sketch_progress.gd / sketch_separator.gd
│   │   ├── sketch_draw.gd              #   SketchDraw：手绘绘制库（wobble 噪声 + 0.12s 沸腾节拍）
│   │   ├── sketch_fonts.gd             #   SketchFonts：StickHand 程序化手写字体加载（缺失回退引擎默认）
│   │   ├── sketch_icons.gd             #   SketchIcons：原生控件主题兜底图标（SDF 定型扰动）
│   │   └── sketch_cloud.gd             #   SketchCloud：大世界手绘云（世界级元素，非 UI 控件）
│   ├── hud/                            # 常驻 HUD 部件（只声明体量，定位归 zone 表）
│   │   ├── global_hud.gd               #   GlobalHUD：顶栏通栏（功能入口按钮群 + 资源条 host），setup 注入 CameraRig/GameRoot
│   │   ├── clock_widget.gd             #   ClockWidget：24h 表盘 + 下半圆 P 社式速度弧（点击弧段调速）
│   │   ├── minimap.gd                  #   Minimap：顶部中央小地图（点击/拖动跳转相机，set_map_info 喂地图信息）
│   │   ├── zoom_bar.gd                 #   ZoomBar：小地图正下方缩放条（滑块/滚轮双向同步，读 CameraRig）
│   │   ├── resource_bar.gd             #   ResourceBar：材料横条（订阅 ResourcesApi.resource_changed 信号驱动）
│   │   ├── notification_feed.gd        #   NotificationFeed：左下通知流（EventBus ui_notification 驱动，上限 5 条自动过期）
│   │   ├── quest_panel.gd              #   QuestPanel：左上目标卡（纯被动显示，装配层调 show_quest/mark_done）
│   │   └── fps_counter.gd              #   FpsCounter：设置面板「显示 FPS」开关驱动
│   ├── panels/                         # 三层 UI 面板与菜单
│   │   ├── mode_panel.gd               #   ModePanel：模式面板容器（Village/Battle/Possess 槽位可见性切换）
│   │   ├── context_panel.gd            #   ContextPanel：上下文面板（右缘列 + 具名槽，槽由装配层填内容）
│   │   ├── settings_menu_panel.gd      #   SettingsMenuPanel：设置菜单（左分类右内容，schema 驱动）
│   │   └── pause_menu_panel.gd         #   PauseMenuPanel：ESC 暂停菜单
│   ├── menus/                          # 主菜单与流程
│   │   ├── main_menu.gd                #   MainMenu：启动第一屏（数据驱动菜单列，读档/新游戏跳载入屏）
│   │   ├── save_panel.gd               #   SavePanel：存档管理（经 UIAPI.create_save_panel 统一构造）
│   │   ├── loading_screen.gd           #   载入屏跳板：把常驻加载层挂到场景树根（跨场景存活零缝）
│   │   ├── loading_spinner.gd          #   加载环
│   │   └── menu_birds.gd               #   主菜单手绘飞鸟
│   ├── overlays/                       # 全屏覆盖层
│   │   ├── world_loading_overlay.gd    #   世界加载覆盖层（分段真实进度，game_root 经 group 认领）
│   │   ├── battle_banner.gd / victory_overlay.gd / opening_hint_overlay.gd / map_transition_overlay.gd
│   ├── indicators/                     # 游玩指示器（依赖由 SystemSetup 装配注入，不自行查找）
│   │   ├── hover_indicator.gd          #   悬停四角呼吸方框（画与命中判定共用同一矩形）
│   │   └── middle_scroll_overlay.gd    #   中键滚动方向图标
│   ├── placeholders/                   # 大界面空面板占位（preset 表驱动，系统落地后移入业务模块 ui/）
│   │   ├── placeholder_presets.gd / ui_placeholder_panel.gd / ui_placeholder_preview.gd
│   ├── templates/                      # UI 模板脚本（模板清单是数据，见 template_index.gd TEMPLATES）
│   │   ├── template_index.gd           #   模板总览导航页（scenes/templates/template_index.tscn，F6 入口）
│   │   ├── main_menu_template.gd / settings_template.gd / hud_template.gd / workspace_template.gd / component_gallery.gd
│   ├── effects/
│   │   └── generative_backdrop.gd      #   GenerativeBackdrop：模态生成艺术背景（旋转立方体 + 鼠标排斥）
│   └── loading/
│       └── boot_warmup.gd              #   BootWarmup：进世界前分帧预热编译闭包（加载屏进度真实化）
└── scenes/
    ├── ui_root.tscn                    # UIRoot 槽位层级真相源（GlobalHUD/ModePanel/ContextPanel/HudOverlay/SystemOverlay/ModalOverlay）
    ├── hud/
    │   └── global_hud.tscn             # 顶栏通栏场景
    ├── panels/
    │   ├── mode_panel.tscn             # Village/Battle/Possess 槽位
    │   └── context_panel.tscn          # SquadInspector 具名槽
    ├── menus/
    │   ├── main_menu.tscn
    │   └── loading_screen.tscn
    ├── overlays/
    │   └── modal_overlay.tscn
    ├── placeholders/
    │   └── ui_placeholder_preview.tscn # 占位面板验收入口
    └── templates/                      # 模板场景：template_index 总览 + 5 张模板，F6 逐个点开验收
```

---

## 对外契约

业务代码只经以下入口使用本模块，不引用内部脚本路径：

| 入口 | 说明 |
|---|---|
| `UIAPI`（api.gd） | `PanelType` 枚举（VILLAGE/BATTLE/POSSESS）、容器节点路径常量、`create_save_panel()` |
| `UIRoot` | 槽位路由 `get_slot` / `add_to_slot(slot_name, node)`；zone 落位 `place_in_zone(zone, control)`；`apply_mode_panel` / `set_context_content` / `open_modal` / `get_modal_stack` |
| `UIModalStack` | `Layer` 层键枚举、`push(obj, layer)` / `pop()` / `find(node)`（ESC 逐层退栈的单一权威） |
| `UIKit` | `full_rect(script, name)` 全屏根 / `widget(script, name)` 角落部件 |
| `StickKit` | 控件装配器：`sketch_button` / `label` / `section` / `motif_badge` / `toast` / `confirm` / `safe_rect` / `dock` |
| 控件类 | `SketchButton` / `SketchPanel` / `SketchTabBar` / `SketchTabContainer` / `StickScreen` / `StickWindow` 等全局 class_name，业务模块 `ui/` 直接继承或实例化 |
| `StickTheme` / `StickTokens` | 主题构建与设计 Token（颜色/字号/间距，不手写字面量） |
| `LayerOrder` | 层号常量（CanvasLayer 层号 + UIRoot 内 z_index） |

`UIRoot` 经 `add_to_group("ui_root")` 可被 `get_tree().get_first_node_in_group("ui_root")` 定位（无 UIRoot 的场景如主菜单自行兜底）。

---

## 依赖

- **core autoload**：`EventBus`（ui_notification 通知流）、`WorldState` / `TimeManager`（ClockWidget 时间与速度）、`ConfigManager`（FPS 开关）、`AudioManager`（StickKit 按钮点击/hover 音）、`SaveManager`（主菜单读档）、`DebugApi`（modules/debug_gui：zone 画框与 UI 检查器随 F3 显隐）
- **资产**：`res://assets/fonts/StickHand-Regular.ttf`（手写字体）、`res://assets/ui/sketch/`（沸腾帧贴图）、`res://assets/icons/`（管线图标成品）
- **使用方**：modules/world（SystemSetup 装配全部容器与 HUD 部件）、modules/world_map、modules/organization、modules/construction、modules/combat、modules/player_control 的 `ui/` 经全局 class_name 使用控件

---

## 开发注意事项

### 加一个 HUD 部件的完整步骤

以 ZoomBar 的真实装配链路（modules/world/scripts/setup/system_setup.gd）为范本：

1. **建脚本**：`stick-world/modules/ui_global/scripts/hud/<部件>.gd`（extends Control 系）。`_ready` 里只声明体量 `custom_minimum_size`，**不自算屏幕坐标**——定位归 zone 表。
2. **建场景**（按需）：有固定节点结构就建 `.tscn`（场景是布局唯一真相源）；结构简单的部件可只用脚本，由装配层 `UIKit.widget()` 实例化（ZoomBar 即纯脚本）。
3. **装配**（写在世界装配器 SystemSetup，部件不自挂树）：
   ```gdscript
   const _ZoomBarScript: GDScript = preload("res://"
           + "modules/ui_global/scripts/hud/zoom_bar.gd")
   var zb := UIKit.widget(_ZoomBarScript, "ZoomBar")
   _root.ui_root.add_to_slot("HudOverlay", zb)          # 层：画在 HUD 槽
   _root.ui_root.place_in_zone(&"top_center", zb)        # 位：钉进 zone（表里没有会 push_warning）
   zb.setup(_root.camera_rig)                            # 依赖注入，部件不自查
   ```
4. **接线**：数据来源走 `setup()` 注入或订阅 EventBus 信号（如 NotificationFeed 订阅 `ui_notification`），部件不跨模块 `get_node`。
5. **调布局**：位置/防撞全在 `scripts/hud/hud_zone_layout.gd` 的 `ZONES` 表——改布局 = 改表不改部件；新角落加 zone 条目（anchors/region/mode）。F3 可视化 zone 保留区画框，部件越界保留区会 push_warning（每部件一次）。

zone 现有五区：`top_bar`（顶栏通栏）/ `top_left_stack`（左上堆叠：资源条→任务卡）/ `top_center`（顶部中央堆叠：Minimap→ZoomBar）/ `top_right`（右上成组：时钟→天数时间）/ `bottom_left`（左下通知流）。

### 加一个按钮 / 页签变体改哪张表

- **按钮**：改 `scripts/theme/sketch_style.gd` 的 `_build_variants()` 变体表。变体 = 全属性集（base 贴图槽前缀 / 五态字色 / 描边 / 伪粗 / 图标模式 / 底透明度），调用点零 override；要新观感 = 加变体条目，键序与 `SketchButton.Kind`、`StickKit.ButtonKind` 同名同序。贴图槽位 = `base + _normal/hover/pressed/disabled`（SketchTextures 沸腾帧，缺档回退 `btn_normal`）。调用统一走 `StickKit.sketch_button(parent, text, callback, kind)`。变体先在 `stick-world/tests/dev/sketch_compare.tscn` 陈列评审再入表。
- **页签**：页签底色/文字走主题（`sketch_style.gd` 的 `tab_normal/tab_hover/tab_selected` 贴图槽，经 `StickTheme._apply_tabs` 挂上）；boiling 描边与选中琥珀下划线在 `sketch_tab_bar.gd` / `sketch_tab_container.gd` 的 `_draw()`。页签作过滤器用 `SketchTabBar`，多页面板用 `SketchTabContainer`。

### 布局与样式红线

- **禁止 `Control.new()` 当 UI 根**：默认 anchor(0,0)/size 0，锚定子控件静默不可见。全屏 UI 根一律 `UIKit.full_rect()`，角落部件一律 `UIKit.widget()` + zone 落位。
- **槽位化路由**：UI 挂槽走 `UIRoot.add_to_slot()`，槽在 `ui_root.tscn` 声明；槽名可带路径（如 `ContextPanel/SquadInspector` 具名槽）。
- **调用点零 `add_theme_*_override`**：SketchButton 视觉全归变体表；列表行内图标走 `set_list_icon()`（icon_max_width 由组件接管）。
- **颜色/字号/间距取 `StickTokens`**，不写字母量；弹窗与浮动窗口定位用 `StickKit.safe_rect()` / `clamp_to_safe_rect()` 避让常驻 HUD 预留区。
- **toast 与确认框自动挂 SystemOverlay**（`StickKit.toast` / `StickKit.confirm`），在模态之上，不随调用者层。
- 堆叠 zone 成员须挂在「顶部通栏全宽、原点即屏左上」的父级下（GlobalHUD / HudOverlay 均满足），同一组 offsets 在不同父级下才产生相同屏幕位置。
