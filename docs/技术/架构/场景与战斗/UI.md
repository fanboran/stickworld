# UI 架构

> 拆分自 [场景与战斗架构.md](../场景与战斗/场景与战斗架构.md) §十。
> 关联文档：[`场景宿主架构.md`](场景宿主架构.md)（GameRoot/UIRoot；环境系统详见该文档 §2.5）、[`事件总线信号契约.md`](EventBus信号契约.md)

---

## 十、UI 分层

### 10.1 三层 UI + 小地图

```
UIRoot (常驻)
├── GlobalHUD              ← 顶层常驻：时间速度、资源数、通知、居中模式按钮
├── ModePanel              ← 模式相关：整体替换
│   ├── VillagePanel       (建设菜单、村民管理、库存)
│   ├── BattlePanel        (框选信息、指令按钮、编制树)
│   └── PossessPanel       (附身时的角色控制 HUD)
├── ContextPanel           ← 上下文相关：选中什么显示什么
│   ├── BuildingInspector  (选中建筑)
│   ├── SquadInspector     (选中编制)
│   └── CommanderPanel     (附身指挥官时的管理面板)
├── HudOverlay             ← 常驻 HUD 部件槽（有尺寸的容器，见 §10.7）
│   ├── BuildMenu          ← 建造按钮 + 两阶段放置（见 §10.7.3）
│   ├── Minimap            ← 小地图（屏幕正上方中央，详见 §10.4）
│   └── ZoomBar            ← 缩放条
└── ModalOverlay           ← 弹窗（暂停菜单、组织架构总览、世界地图）
```

#### 10.1.1 GlobalHUD 详细设计

> **当前实现**：[global_hud.gd](../../../../stick-world/modules/ui_global/scripts/hud/global_hud.gd) 120 行，显示时间速度、游戏时间、通知、居中模式按钮。**未显示资源数量**（资源系统未接入，见 [建筑与定居点.md](建筑与定居点.md) §9.4 / P0-11）。

GlobalHUD 节点结构（含资源显示扩展）：

```
GlobalHUD (Control)
├── TopBar (HBoxContainer)               ← 顶部状态条
│   ├── SpeedLabel                       ← 时间速度（1x/2x/暂停）
│   ├── TimeLabel                        ← 游戏内时间（Day 3, 14:30）
│   ├── ResourceBar (HBoxContainer)      ← 资源数量条
│   │   ├── ResourceSlot[res_wood]       ← 木材图标 + 数量
│   │   ├── ResourceSlot[res_stone]      ← 石料图标 + 数量
│   │   ├── ResourceSlot[res_metal_ore]  ← 铁矿图标 + 数量
│   │   ├── ResourceSlot[res_gold]       ← 黄金图标 + 数量
│   │   └── ResourceSlot[res_diamond]    ← 钻石图标 + 数量（沥青已根除待清退，不在 HUD）
│   └── CenteredButton                   ← 居中模式按钮
├── NotificationLabel                    ← 通知文字（淡入淡出）
└── ClockWidget                          ← 圆形表盘（详见现有实现）
```

**ResourceBar 资源显示**：

| 属性 | 设计 |
|------|------|
| 显示资源 | 现行 5 种（木/石/铁/金/钻，见 `resource_bar.gd`；沥青已根除待清退，不在 HUD） |
| 数据来源 | `resources_api.get_stock(resource_id, "player_territory")` |
| 更新方式 | 信号驱动：订阅 `resources_api.resource_changed` 信号，非每帧轮询 |
| 显示格式 | `[图标] 数量`（如 `🪵 150`），数量变化时短暂高亮（0.5s 黄色闪烁） |
| 不足提示 | 收到 `resource_not_enough` 信号时，对应 ResourceSlot 闪红 + NotificationLabel 显示"木材不足" |
| 交互 | P0 仅显示；P1 点击展开详情面板（产出/消耗/历史趋势） |

**信号订阅代码示意**：

```gdscript
# global_hud.gd 扩展
func _setup_resource_bar(resources_api: Node) -> void:
    resources_api.resource_changed.connect(_on_resource_changed)
    resources_api.resource_not_enough.connect(_on_resource_not_enough)
    # 初始化显示当前库存
    for res_id in ["res_wood", "res_stone", "res_metal_ore", "res_gold", "res_diamond"]:
        var amount := resources_api.get_stock(res_id, "player_territory")
        _update_resource_slot(res_id, amount)

func _on_resource_changed(res_id: String, amount: float, delta: float, _region_id: String) -> void:
    if _resource_slots.has(res_id):
        _update_resource_slot(res_id, amount)
        _flash_slot(res_id, delta > 0)  # 正增负减，颜色区分
```

> **依赖**：ResourceBar 需要 P0-11（资源系统装配）完成后才能接入。当前 GlobalHUD 代码已预留扩展点（TopBar 是 HBoxContainer，可追加子节点）。

### 10.2 模式切换响应

切换城镇→战斗模式：
- `ModePanel` 整体 swap：`VillagePanel` → `BattlePanel`
- `ContextPanel` 清空（无选中）
- `GlobalHUD` 不变（时间/资源继续显示）
- `InputDispatcher.set_mode(BATTLE)`
- `BattlePanel` 显示当前 `battle_instance` 概要

### 10.3 模块结构

全局 UI 层（`modules/ui_global/`）只放**跨模块共享的容器与通用控件**；深度耦合某业务模块 API 的面板归属该模块的 `ui/` 子目录（垂直切片原则）：

```
modules/ui_global/           # 全局 UI 层：容器 + 通用控件
├── api.gd
├── scripts/
│   ├── ui_root.gd           # UIRoot 主控
│   ├── hud/                 # GlobalHUD / ClockWidget / Minimap（+ minimap_painter / minimap_window）/ ZoomBar（薄壳）/ ZoomSlider（公共缩放条机件）/ ResourceBar
│   ├── panels/              # ModePanel（容器）/ ContextPanel（容器）/ SettingsMenuPanel
│   └── indicators/          # 游玩指示器（附身圆圈/悬停方框/中键图标）
└── scenes/
    ├── ui_root.tscn
    ├── hud/global_hud.tscn
    ├── panels/mode_panel.tscn    # 含 Village/Battle/Possess 槽位（内容由各模块装配）
    ├── panels/context_panel.tscn
    └── overlays/            # modal_overlay.tscn / resource_bar.tscn

modules/<模块>/ui/           # 模块专属 UI（各模块自包含）
├── combat/ui/               # battle_panel.gd（战斗面板）/ formation_panel.gd（编制窗口）
├── construction/ui/         # build_menu.gd（建造菜单；控件经 StickKit/Sketch 组件出口创建）
├── player_control/ui/       # possess_panel.gd（附身面板）
└── world_map/ui/            # 战略图面板/提示等
```

> **装配方式**：业务面板由 `SystemSetup`（world 模块装配器）挂到 UIRoot 的槽位/弹窗层节点，模块代码不跨模块 `get_node`。全屏 UI 根一律用 `UIKit.full_rect()` 创建（强制 FULL_RECT），HUD 部件挂 `HudOverlay` 槽（见 §10.7）。

#### UI 公共层 L0/L1 分层

- **L0 = `core/ui_framework/`**：纯布局原语与无依赖组件，零资产、零模块依赖。现有
  `ui_kit.gd`（`UIKit` 布局出口，class_name 全局不变）与 `components/progress_painter.gd`
  （`ProgressPainter` 世界空间进度条 `_draw` 公共基类，建筑双进度条/火柴人动作条共用）。
- **L1 = `modules/ui_global/`**：视觉实现层——sketch 手绘控件族、主题资产
  （StickTheme/StickStyle/SketchStyle/StickTokens/StickIcons）、StickScreen/StickWindow
  屏幕与窗口体系、StickKit 装配器、ZoomSlider 公共缩放条机件、keymap 键鼠说明组件族
  （KeymapView/SketchKeyboard/SketchMouse + 按键注册表，数据 `data/keymap/`）。
- 依赖方向只允许 L1 → L0（ui_global/world_map/units/construction 等 → core 合法，
  core 不 import 任何模块）；跨模块组件引用走 class_name，不加 preload。
- 主题不进 core（贴图/Token 是视觉资产，属 L1）；core 不另抽 Screen 基类
  （StickScreen 已是统一弹窗基类，避免空抽象）。契约细则见
  [core/ui_framework/README.md](../../../../stick-world/core/ui_framework/README.md)。

### 10.4 Minimap 小地图系统

小地图 = **顶部中央的本地块缩略图**（地表材质分区 + 建筑 + 实体点 + 视野框），
与它右侧的 L1 世界缩略窗、下方的缩放条同属「顶部小地图区」。

#### 10.4.1 位置与尺寸

- **位置**：屏幕正上方中央——`top_center` zone，保留区 = 顶栏左右两段按钮群之间的空档
  **减去 L1 缩略窗占位**（缩略窗贴小地图右侧并列，故「小地图 + 缩略窗」这一对在空档内居中）
- **尺寸**：高固定 `120`；**宽按等比例尺随地图宽推出**——地面带像素高（`高 × ground_ratio`，
  与画面同构图）代表地图的世界地面深，由此得"世界 px / 小地图 px"，横向同比例尺取宽，
  钳在 `[360, 空档宽 − 缩略窗占位]`（比例尺与防撞合同详见 §10.4.7）
- **层级**：`UIRoot` 槽 `HudOverlay`（z 高于 `GlobalHUD` 顶栏，故顶栏按钮群不会抢走小地图上的鼠标事件），低于 `ModalOverlay`

#### 10.4.2 实现形态

绘制全部走 `_draw`（**无子节点树**——地图是实时数据，重建节点树不如直接落笔），
且**双路径**：有照片底图走照片路径，无则退回纯数据平面图。

| 文件 | 职责 |
|------|------|
| `modules/ui_global/scripts/hud/minimap.gd` | 部件：体量自适应、交互（跳转/展开）、装配入口 |
| `modules/ui_global/scripts/hud/minimap_painter.gd` | **绘制核**：两条绘制路径（照片底图 / 数据平面图）+ 投影换算 + 图层顺序（与放大版共用，保证两处点位逐像素对得上） |
| `modules/ui_global/scripts/hud/minimap_window.gd` / `minimap_canvas.gd` | 放大版浮窗（StickWindow·FLOATING）与其绘制区 |
| `modules/hd2d/scripts/hd2d_world.gd` → `bake_minimap_strip()` | **照片底图烘焙**：只留前排建筑 + 地面的真渲染，降采样成街带贴图（见 §10.4.8） |
| `modules/hd2d/scripts/hd2d_minimap_style.gd` | 建筑 def → 功能类型 + 近似世界材质色（**平面图路径**用；照片路径不用近似色） |

**数据供给在组件名下、朝地图侧一行**：`map.get_minimap_layout()`
（`modules/world/scripts/map/map_base.gd` 虚方法，返回
`{surfaces: [{x0, x1, color}], buildings: [{x, width, terrain, def, type, color}]}`，
世界 px 口径；`hd2d_map_base.gd` 覆写 = 3D 街景地表条带 + 前排建筑 + 2D 宿主里的
玩家自建建筑）。UI 侧不遍历地图节点树、不读地图私有字段。

#### 10.4.3 显示内容

| 元素 | 来源 | 频率 |
|------|------|------|
| **底图** | 照片路径：`map.get_minimap_base()` 的烘焙贴图（真渲染街带，含真实建筑美术与地表）；平面图路径：地表色带 + 建筑色块（下两行） | 地图加载时烘一次 |
| 地表材质色带 | `get_minimap_layout().surfaces`（按铺地顺序叠色，故主街石板压住城外草地） | 15Hz |
| 建筑 | 同上前排建筑，按**真占地**画俯视块（世界宽 × 占地纵深，取自与 F3 碰撞带同源的烘焙占地口径）：**实际材质色**（默认）/ **功能类型色**（放大版） | 15Hz |
| 实体点 | `map.get_entities()`：玩家（绿点 + 呼吸光环）/ 同阵营（蓝）/ 敌方（红）/ 中立 NPC·村民（淡土石） | 15Hz |
| 视野框 | `CameraRig.get_viewport_rect_world()` | 15Hz |

节流常量 `UPDATE_HZ = 15`——实体点与视野框不需要每帧重算。

覆盖层两条路径都要画：单位点、视野框、以及**照片里没有的建筑**（玩家自建/后改，
`baked == false` 的那些，见 §10.4.8）。平面图路径里建筑按**真占地**画块而非"图标"
——立面高在俯视图里没有对应维度，画成图标会让房子看着比实际小得多（脚下真占地整片空着）。

#### 10.4.4 坐标映射

```
小地图 X = (世界 X - map_left) / 地图宽 × 小地图宽
小地图 Y = 天地分界 + (世界 Y - ground_y) / (ground_bottom - ground_y) × 地面带高
```

- 天地分界 = `高 × (1 - ground_ratio)`：地面带高 = `高 × ground_ratio`（与画面同构图，本作城镇约 57%）
- 地面带内的世界纵深才映射到地面带内，故**站位前后可读**（靠后 = 画得靠上），
  不是一律钉在分界线上；越出 `[ground_y, ground_bottom]` 的 Y 被钳到地面带边缘
- 换算唯一出口在 `minimap_painter.gd`（`world_to_x` / `world_to_y` / `x_to_world`），
  顶部小地图与放大版共用——两处点位必须逐像素一致

#### 10.4.5 交互

| 操作 | 行为 |
|------|------|
| 左键点击小地图 | 相机跳转到点击位置（RTS 式观察），暂停自动跟随（详见 [场景宿主架构.md](场景宿主架构.md) §2.4.5） |
| 左键拖动小地图 | 相机持续跟随拖动位置 |
| 双击 / 点右上角展开把手 | 发 `expand_requested` → 装配层打开**放大版浮窗**（`MinimapWindow`，非模态，ESC/✕ 关闭）。单击保留相机跳转语义，故展开不复用单击 |
| 点 L1 世界缩略窗 | 打开 L1 大图（Tab 三态第三步；见 §10.3） |

放大版浮窗内点地图同样跳转相机；L1 缩略窗贴在 Minimap 右侧，订阅其 `resized`
跟随重定位（小地图变宽时自动让位）。

#### 10.4.6 公共 API

```gdscript
# Minimap
set_map_info(map_left, map_right, ground_y, ground_ratio)  # 地图加载时调用
get_map_info() -> Array                                    # 复用同一投影（放大版取用）
get_map_width_px() -> float                                # 当前体量（外部/测试读取口）
minimap_to_world_x(x) -> float                             # 点击跳转与外部查询共用
signal expand_requested                                    # 请求展开放大版
```

#### 10.4.7 宽度自适应与跨度合同

顶部中央的可用横向范围 = **顶栏左右两段按钮群之间的空档**（`hud_zone_layout.gd` 的
`TOP_CENTER_FREE_LEFT_PX` / `TOP_CENTER_FREE_RIGHT_PX`，取自 `global_hud.tscn` 实测；
布局真相源是 zone 表，部件不自造数值）。空档里还要留出 L1 缩略窗的占位
（`TOP_CENTER_THUMBNAIL_SLOT` = 间隙 8 + 缩略窗宽 120），故：

- **等比例尺**（横纵一致，房屋/地块不变形）：`世界 px / 小地图 px = 地面世界深 / (小地图高 × ground_ratio)`。
  横向同比例尺取宽 ⇒ 地图越宽小地图越宽（"保持比例尺"）
- **上限**：`top_center_map_max_width` = 空档宽 − 缩略窗占位。小地图在区内居中，
  缩略窗随后落在右端占位里 ⇒「小地图 + 缩略窗」这一对在空档内居中
- **下限 360**：空档太窄或地图过小时退回固定宽度，接受比例失真，不把地图缩到看不清
- 本作城镇（7080 世界 px）得 787 px 宽、比例尺 9.0；战场（6144）得 683 px。若地图宽超出
  空档能给的宽度，宽度被钳住、比例尺随之略失真（单向、渐增）
- **放大版**：地图区 = 顶部小地图矩形 × `ZOOM(1.5)`（同比）——同一张图放大，两处比例尺
  一致、底图与点位都不被拉伸；地图区是长条（世界本身 11.5:1），窗口因此是宽扁窗

改顶部布局的流程：改 `global_hud.tscn` 顶栏按钮后跑 `probe_hud_bands.tscn` 复测，
把新数值回填 zone 表，再跑 `verify_hud_zones.tscn` 验防撞合同仍成立。

#### 10.4.8 照片底图（"干净管线"）与平面图兜底

**底图用真渲染，不做近似。** `hd2d_world.bake_minimap_strip()` 在地图加载时（加载覆盖层
之下）把整条街烘成一张街带贴图：

- **取景**：正交相机按"地图全宽"取景（`set_cam_fit_width_px`，绕开玩家缩放档钳制），
  构图锚与游戏内一致；裁切以**行走带前沿**为底、按小地图矩形的宽高比向上取。
- **只留建筑与地面**（临烘隐藏）：火柴人（`_char_host`）、自然物与道具
  （`_prop_root`，含野外树木/矿物）、云牌（`_cloud_root`，云贴图异步烘制故按容器隐藏）、
  背景楼群（`_card_root` 中前排之后的剪影）。天幕/月盘挂在主相机上、后处理层是
  CanvasLayer——都**不在烘焙视口里**，天然不进图。
- **怎么只取 3D**：烘焙走**共享主视口 World3D 的 SubViewport + 专用正交相机**，而不是
  截主视口——主视口会连 UI/加载屏/后处理一起拍进去（实测拍到过加载屏）。SubViewport
  同时解决三件事：分辨率与玩家窗口解耦、不吃主相机景深属性、天空天然出局。
  平时 `render_target_update_mode = DISABLED`，不留常驻渲染通道。
- **去天空**：烘焙期把默认清屏色清成透明 → 贴图的天空处透明，露出小地图自己的背衬平色
  （天空 token），切换昼夜时背衬色可随主题走。
- **已知限制**：光照被冻结在烘焙时刻（换昼夜不重烘）；烘焙在加载期同步做（约 3 帧，
  玩家看不见）。

**平面图兜底**（`get_minimap_base()` 为空时，或非 HD-2D 图）：由地图侧数据供给绘制——
地表材质色带（HD-2D 侧铺地时记账，见 `_ground_strips` / `get_minimap_layout`）、建筑按
def 归到近似材质色。放大版的"类型着色 + 图例"属这条路径（照片本身就是实际颜色，
故有底图时该开关隐藏）。

### 10.5 DebugOverlay 调试覆盖层

调试覆盖层用于可视化所有运行时不可见的标记（占地格/障碍/地面线/触发器等），是后续开发的必备工具。

#### 10.5.1 模块结构

```
modules/debug/                        ← 新建
├── api.gd                            # DebugApi：注册绘制器、切换可见性
├── scripts/
│   ├── debug_overlay.gd              # 主控（CanvasLayer，F3 切换）
│   ├── debug_legend.gd               # 启动图例常驻显示（小字）
│   └── debug_drawers/                # 各类调试绘制器
│       ├── grid_drawer.gd            # PlacementGrid 占用（绿）+ BuildMask（红）
│       ├── barrier_drawer.gd         # WalkBarrier（蓝）+ PassageBarrier（紫）
│       ├── building_drawer.gd        # 建筑边界框（白）
│       ├── ground_line_drawer.gd     # ground_y 线（黄）+ ground_bottom 线（青）
│       ├── chunk_trigger_drawer.gd   # Chunk 触发器范围（紫矩形）
│       └── entity_state_drawer.gd    # 火柴人状态文字
└── scenes/
    └── debug_overlay.tscn
```

#### 10.5.2 启动图例（常驻小字）

游戏启动时在屏幕左上角显示**小字号**图例，**不淡出**，常驻显示（直到玩家按 F3 关闭调试模式）。图例内容：

```
[F3] 调试
绿格=占地  红格=不可建  蓝区=地图障碍  紫区=建筑障碍
黄线=地面线  青线=地面底  白框=建筑  紫框=Chunk触发
```

图例字号小（约 10pt），半透明（alpha=0.6），不遮挡游戏画面。F3 切换调试模式时图例同步显示/隐藏。

#### 10.5.3 显示内容明细

| 元素 | 颜色 | 来源 | 说明 |
|------|------|------|------|
| PlacementGrid 占用格 | 绿色半透明 | `PlacementGrid._cells` | 已被建筑占用的格子 |
| BuildMask 不可放建筑格 | 红色半透明 | `PlacementGrid.blockage_mask` | 地形限制不可放建筑 |
| WalkBarrier 地图障碍 | 蓝色半透明 | `MapInstance.WalkBarrier` 下 Area2D | 悬崖/高楼边缘，火柴人不可穿越；含工地临时障碍 |
| PassageBarrier 建筑障碍 | 紫色半透明 | 各建筑 `PassageBarrier` Area2D | 建筑本体不可通行区域 |
| ground_y 地面线 | 黄色线 | `MapInstance.ground_y` | 火柴人可走区域顶部 |
| ground_bottom 地面底线 | 青色线 | `MapInstance.ground_bottom` | 火柴人可走区域底部 |
| 建筑边界框 | 白色边框 | `BuildingHost` 子节点 | 每个建筑的 Footprint 矩形 |
| 建筑名称 | 黄色文字 | `BuildingHost` + `buildings.tres` | 建筑上方显示中文名 + def_id |
| Chunk 触发器范围 | 紫色矩形边框 | `MapInstance.ChunkTriggers` | 流式加载触发区域 |
| 垂直地形网格 | 橙色细线 | `MapInstance` ground_y~ground_bottom | 32px 分行，资源点定位用 |
| 资源点标记 | 彩色方块 + 储量 | `resource_node` group | 木=绿/石=灰/铁=棕，F3 控制 |
| 世界坐标标尺 | 灰色刻度 | `MapInstance.ground_y` 线上 | 每 10 格标 cell 编号，世界原点★标记 |
| 火柴人状态文字 | 白色文字 | `EntityHost` 下 StickmanEntity | 速度/动画/朝向/坐标 |
| 火柴人碰撞箱 | 白色边框 | `StickmanEntity.Collider` | 脚部碰撞箱 |
| 火柴人详细信息 | 白色文字 | `EntityHost` 下 StickmanEntity | HP/行为/目标等 |
| FPS / 实体数 | 白色文字 | 引擎 | 屏幕左下角 |

#### 10.5.4 交互

| 按键 | 行为 |
|------|------|
| F3 | 切换调试覆盖层显示/隐藏（记忆到 `settings.cfg`） |
| F1（可选） | 仅切换图例显示 |

#### 10.5.5 实现要点

- `DebugOverlay` 是 `CanvasLayer`，`z_index` 最高（高于游戏画面和 UI）
- 用 `_draw()` 在 Control 上绘制（不是 Node2D，避免相机移动影响坐标）
- 调试数据通过 `DebugApi` 收集，各模块注册自己的调试信息提供者
- 启动时调用 `debug_legend.show_legend()`，图例常驻不淡出
- 性能：调试绘制器按需启用，关闭调试模式时所有 `_draw` 跳过
- 世界坐标到屏幕坐标的转换：`world_to_screen(pos) = (pos - camera.global_position) * effective_zoom + viewport_size * 0.5`

#### 10.5.6 公共 API

```gdscript
# DebugApi（autoload 单例）
register_drawer(name: String, drawer: Callable)   # 各模块注册绘制器
unregister_drawer(name: String)
toggle_visibility()                                # F3 切换
is_visible() -> bool
show_legend()                                      # 显示图例（常驻）
hide_legend()
```

#### 10.5.7 各模块注册绘制器

| 模块 | 注册的绘制器 | 触发时机 |
|------|------------|---------|
| `world` | grid_drawer / barrier_drawer / ground_line_drawer / chunk_trigger_drawer / terrain_grid / resource_nodes / world_ruler | 地图加载时 |
| `buildings` | building_drawer / building_names | 建筑增减时 |
| `units` | entity_state_drawer / entity_collider_drawer / entity_info | 单位生成时 |

#### 10.5.8 ResourceNode 调试标签

- `ResourceNode` 的调试标签（资源类型中文名）由 `DebugApi.visibility_changed` 信号驱动，不再每帧 `_process` 检查
- F3 关闭调试时标签隐藏，开启时显示

### 10.6 建造进度条与交互弹窗

#### 10.6.1 建筑头顶双进度条

建造中的建筑头顶显示双进度条（`BuildProgressIndicator`），挂到 `MapInstance.BuildMaskLayer`：

```
  ┌──────────────────┐
  │ ████░░░░░░░░░░░░ │  ← 材料条（蓝色）
  │ ████████░░░░░░░░ │  ← 建造条（绿色）
  └──────────────────┘
```

- 上方蓝色条：材料进度 `[0,1]`（搬运工交付推进）
- 下方绿色条：建造进度 `[0,1]`（建造工敲击推进，受材料限制：建造 ≤ 材料）
- 宽度 = 建筑占地宽度 * 32px，位置在 `ground_y - 220`
- 绘制继承 `ProgressPainter`（`core/ui_framework/components/progress_painter.gd`，bg/fg 双 rect + 描边公共基类）
- 完工/取消时由 `ConstructionManager` 移除

#### 10.6.2 火柴人头顶动作进度条

`ActionProgressIndicator`（Node2D）显示在火柴人头顶（y = -130）：
- 搬运工取货/交付停留时显示（0.5s 填满）
- 建造工敲击 build 动画时显示（1.8s 填满）
- 玩家按 E 敲击建造时显示
- 完成后隐藏
- 绘制继承 `ProgressPainter`（同建筑双进度条，单条配置）

#### 10.6.3 交互弹窗

玩家附身时靠近仓库/工地，在**目标建筑上方**显示交互提示弹窗：

- 节点结构：`Node2D`（挂到 `foreground_layer`，z_index=20）+ `Label`（带 `StyleBoxFlat` 暗色圆角背景）
- 位置：建筑 PassageBarrier 中心 X，`ground_y - 280` Y
- 样式：黑色 80% 透明背景 + 白色 25% 半透明 1px 边框 + 4px 圆角
- 内容根据状态自动切换：
  - 仓库 + 未搬运 -> "按E拿起建材"
  - 仓库 + 搬运中 -> "按E放回材料"
  - 工地 + 搬运中 -> "按E交付材料"
  - 工地 + 未搬运 + 材料充足 -> "按E敲击建造"
  - 工地 + 未搬运 + 材料不足 -> "材料不足，等待搬运"
- 无交互目标时弹窗隐藏

> **设计原则**：弹窗跟随目标建筑不跟随火柴人，玩家移动时弹窗稳定在建筑上方，不晃动。

#### 10.6.4 建造两阶段放置交互（草棚宽度可调）

建造菜单选择建筑（如草棚）后进入**两阶段放置**：

1. **选址阶段**：鼠标显示条带预览（默认 def 宽度），左键放下草稿（**条带固定**，左右边界不再跟随鼠标）
2. **拉伸阶段**：**按住左键拖动**调整左右边界（拖动侧由按下位置决定：靠近左边界拖左、靠近右边界拖右，两侧互不影响）；松开后条带固定；点击「确定建造」才真正调用 `start_construction_at`（携带最终 width）
3. 右键/Esc 取消

**条带预览**（`PlacementGhost`，单节点自绘）：
- 每个单元格 = 30% 半透明蓝色填充矩形 + 描边，左右各内缩（格间留缝）
- 呼吸动画：水平只向内缩（0~+1px）、垂直 ±1.5px，周期 3s
- 端部等边三角把手（尖朝外、底边在端格内），悬停端格拉大（垂直 +5px、水平 +1px）并停呼吸、三角 ±0.5px 呼吸
- 点击反馈：端格绕中心左右震动两下 + 三角位置浅色虚影外扩消失
- 橙色 4 角角框标定未调整前的默认大小；条带上方显示格数计数器

**其他约束**：
- 放置期间关闭相机边缘滚动（避免靠近屏幕边缘拖动时世界跟着滚）
- 点「确定建造」时不再被"开始拖动"逻辑消费（先判按钮矩形）

### 10.7 UI 布局原则与槽位路由

#### 10.7.1 两条布局铁律

1. **场景是布局唯一真相源**：UI 槽位、常驻面板都在 `.tscn` 里声明（带 anchor）。**禁止 `Control.new()` + set_script 直接当 UI 根**——`Control.new()` 默认 anchor(0,0)/size 0，锚定子控件会定位到原点负坐标，导致**静默不可见**（无报错，曾致"建造"按钮消失，见 §10.7.4）。
2. **槽位化路由**：所有 UI 通过 `UIRoot.add_to_slot()` 挂到具名槽（HudOverlay / ModePanel / ModalOverlay…），由槽提供确定坐标系，不散落手写 `add_child`。

#### 10.7.2 代码创建规则

| 场景 | 做法 |
|------|------|
| 全屏面板/UI 根 | `UIKit.full_rect(script, name)`（[ui_kit.gd](../../../../stick-world/core/ui_framework/ui_kit.gd)，强制 FULL_RECT + 双向 grow） |
| 角落 HUD 部件（小地图/缩放条/建造按钮） | 自设 anchor + `UIRoot.add_to_slot("HudOverlay", ...)` |
| 弹窗/面板类 | 挂 ModalOverlay / ModePanel 等有尺寸槽 |

#### 10.7.3 槽位 API

```gdscript
# UIRoot（modules/ui_global/scripts/ui_root.gd）
get_slot(slot_name: String) -> Control     # 取具名槽
add_to_slot(slot_name: String, node) -> bool  # 挂槽（子控件 anchor 自理）
switch_mode_panel(type)                    # ModePanel 切换
open_modal(node) / close_all_modals()
```

#### 10.7.4 事故复盘（为何立此规）

`_setup_build_menu` 曾"优先用 ui_root.tscn 的 BuildMenu 节点、找不到则 `Control.new()` 回退"。回退创建丢失 .tscn 的 FULL_RECT anchor，`PRESET_BOTTOM_RIGHT` 的"建造"按钮被摆到 0 尺寸容器原点（负坐标），静默不可见。修复 = 代码创建全屏 UI 根一律 `UIKit.full_rect()` + 挂 HudOverlay 槽。规则已写入 `AGENTS.md` 核心行为指令 #5，防后续再踩。
