# UI 与环境

> 拆分自 [场景与战斗架构.md](../场景与战斗架构.md) §十、§十一。
> 关联文档：[`场景宿主架构.md`](场景宿主架构.md)（GameRoot/UIRoot）、[`事件总线信号契约.md`](EventBus信号契约.md)

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
├── Minimap                ← 小地图（屏幕正上方中央，详见 §10.4）
└── ModalOverlay           ← 弹窗（暂停菜单、组织架构总览、世界地图）
```

#### 10.1.1 GlobalHUD 详细设计

> **当前实现**：[global_hud.gd](file:///f:/VSCode/game-2/stick-world/modules/ui/scripts/global_hud.gd) 120 行，显示时间速度、游戏时间、通知、居中模式按钮。**未显示资源数量**（资源系统未接入，见 [建筑与定居点.md](建筑与定居点.md) §9.4 / P0-11）。

GlobalHUD 节点结构（含资源显示扩展）：

```
GlobalHUD (Control)
├── TopBar (HBoxContainer)               ← 顶部状态条
│   ├── SpeedLabel                       ← 时间速度（1x/2x/暂停）
│   ├── TimeLabel                        ← 游戏内时间（Day 3, 14:30）
│   ├── ResourceBar (HBoxContainer)      ← 资源数量条
│   │   ├── ResourceSlot[res_wood]       ← 木材图标 + 数量
│   │   ├── ResourceSlot[res_stone]      ← 石料图标 + 数量
│   │   ├── ResourceSlot[res_metal_ore]  ← 金属矿图标 + 数量
│   │   └── ResourceSlot[res_black_asphalt] ← 黑色沥青图标 + 数量
│   └── CenteredButton                   ← 居中模式按钮
├── NotificationLabel                    ← 通知文字（淡入淡出）
└── ClockWidget                          ← 圆形表盘（详见现有实现）
```

**ResourceBar 资源显示**：

| 属性 | 设计 |
|------|------|
| 显示资源 | P0 的 4 种基础资源（[建筑与定居点.md](建筑与定居点.md) §9.4.1） |
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
    for res_id in ["res_wood", "res_stone", "res_metal_ore", "res_black_asphalt"]:
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

```
modules/ui/
├── api.gd
├── global_hud/
├── mode_panels/
│   ├── village_panel.tscn
│   ├── battle_panel.tscn
│   └── possess_panel.tscn
├── context_panels/
│   ├── building_inspector.tscn
│   ├── squad_inspector.tscn
│   └── commander_panel.tscn
├── modals/
│   ├── pause_menu.tscn
│   ├── org_tree_overview.tscn
│   └── strategic_map_modal.tscn   # 战略图模态窗口
├── minimap/                    # 小地图（详见 §10.4）
│   ├── minimap.gd
│   ├── minimap.tscn
│   └── minimap_renderer.gd     # 缩略图生成
└── widgets/                    # 通用控件（按钮、进度条、列表）
```

### 10.4 Minimap 小地图系统

#### 10.4.1 位置与尺寸

- **位置**：屏幕正上方中央（`anchor_top = 0`，水平居中）
- **尺寸**：默认 `240x80`（可配置），按地图长宽比自适应
- **层级**：`UIRoot` 子节点，`z_index` 高于游戏画面，低于 `ModalOverlay`

#### 10.4.2 节点结构

```
Minimap (Control)                      ← 屏幕正上方中央
├── Background (Panel)                 ← 背景框
├── MapThumbnail (TextureRect)         ← 整图缩略图（程序生成或预渲染）
├── ViewportRect (ColorRect)           ← 当前屏幕视野框（红色边框）
├── PlayerDot (ColorRect)              ← 角色位置点（绿色）
└── BuildingLayer (Node2D)             ← 建筑物图标容器
    └── BuildingIcon[] (ColorRect)     # 每个建筑一个小图标
```

#### 10.4.3 显示内容

| 元素 | 来源 | 更新频率 |
|------|------|---------|
| 地图缩略图 | `minimap_renderer` 生成（地图加载时一次） | 地图切换时重生成 |
| 视野框 | `CameraRig.get_viewport_rect()` 映射到缩略图坐标 | 每帧（或 10Hz 节流） |
| 角色点 | 玩家实体 `global_position.x` 映射；Y 固定在 `ground_y` 对应位置 | 每帧 |
| 建筑图标 | `BuildingHost` 子节点，按 `building_type` 着色 | 建筑增减时增量更新 |

#### 10.4.4 坐标映射

```
缩略图坐标 = (世界坐标 - map_left) * (缩略图宽 / 地图宽)
```

- Y 轴：地图垂直范围 `[sky_top, ground_y + depth]` 映射到缩略图高度
- 角色点 Y 固定在 `ground_y` 对应的缩略图位置（约下方 1/3）

#### 10.4.5 交互

| 操作 | 行为 |
|------|------|
| 左键点击小地图 | 相机跳转到点击位置（RTS 式观察），暂停自动跟随（详见 [场景宿主架构.md](场景宿主架构.md) §2.4.5） |
| 左键拖动小地图 | 相机持续跟随拖动位置 |
| 鼠标悬停（可选，P0 不做） | 显示该位置坐标/建筑名提示 |

**点击跳转实现：**
```gdscript
func _on_gui_input(event):
    if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
        var world_x := (event.position.x / size.x) * (map_right - map_left) + map_left
        camera_rig.jump_to_x(world_x)  # 手动控制，暂停自动跟随
```

#### 10.4.6 公共 API

```gdscript
# Minimap
set_map_info(map_left, map_right, ground_y, ground_ratio)  # 地图加载时调用
update_player_position(x: float)                           # 每帧调用
update_viewport_rect(rect: Rect2)                          # 每帧调用（来自 CameraRig）
refresh_buildings(buildings: Array)                        # 建筑变化时调用
```

#### 10.4.7 缩略图生成策略

`minimap_renderer.gd` 负责生成缩略图，三种策略（按优先级）：

1. **预渲染纹理**（首选）：地图配置里指定 `thumbnail.png`，直接使用
2. **程序生成**（兜底）：读取 `TerrainLayer.GroundPolygon` 顶点 + `DecorationLayer` 装饰物，用 `Viewport` 离屏渲染缩略图
3. **纯色填充**（最小可用）：地面绿色矩形 + 天空蓝色矩形，无装饰

P0 阶段先用策略 3（纯色填充），后续迭代到策略 1/2。

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
- 完工/取消时由 `ConstructionManager` 移除

#### 10.6.2 火柴人头顶动作进度条

`ActionProgressIndicator`（Node2D）显示在火柴人头顶（y = -130）：
- 搬运工取货/交付停留时显示（0.5s 填满）
- 建造工敲击 build 动画时显示（1.8s 填满）
- 玩家按 E 敲击建造时显示
- 完成后隐藏

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

---

## 十一、环境系统

### 11.1 模块结构

```
modules/environment/
├── api.gd
├── sky_system.gd              # 天空：极光、星星、太阳/月亮
├── weather_system.gd          # 天气：雨/雪/沙尘暴
├── ground_system.gd           # 地面：纹理重复、震动摇晃
├── lighting_system.gd         # 光照：随时间变化
└── biome_system.gd            # 生物群落：地理位置决定基调
```

### 11.2 跨场景保持

环境系统是 `GameRoot` 的常驻子节点。地图切换时只是切换 `WorldChunkHost` 的子节点，**环境继续工作**。

环境参数（天气、时间、地理位置）挂在 `WorldState`（Autoload）上，不挂场景。

### 11.3 关键技术点

| 效果 | 实现方式 |
|------|---------|
| 极光 | `Shader` + 噪波纹理 + 时间动画 |
| 星星 | `GPUParticles2D` 或 Shader 顶点 |
| 下雨 | `GPUParticles2D` + 风向参数 |
| 沙尘暴 | `GPUParticles2D` + 屏幕色染 + 能见度衰减 |
| 地面震动 | `GroundShakeRig` 父节点 `position` 抖动（参考相机抖动） |
| 光照变化 | `CanvasModulate.color` 按 `time_of_day` 插值 |
| 生物群落基调 | `biome_system` 提供参数，`sky`/`weather`/`ground` 各自读取 |