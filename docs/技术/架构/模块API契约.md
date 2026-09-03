# 模块 API 规范

> 底层架构第四阶段：各玩法模块的 api.gd 公共接口定义。
> 函数签名 + 前置条件 + 后置条件。不含实现细节。

---

## 约定

- 每个模块暴露**唯一入口** `api.gd`，外部只能通过此文件调用
- 参数用强类型（Godot 4 GDScript 支持类型注解）
- 返回 `Result` 模式：成功返回数据，失败返回 `{"ok": false, "error": "原因"}`
- `[P]` = 前置条件，`[Q]` = 后置条件

---

## 一、经营建设模块 `modules/construction/api.gd`

```gdscript
# 建造
func start_construction(region_id: String, building_type: String, org_id: String) -> Dictionary
# [P] region_id 属于玩家控制区域, org_id 存在且标签=ENGINEERING
# [Q] 创建一个 Construction Project, building 状态=PLANNED, 发射 building_started

# 查询
func get_buildings_in_region(region_id: String) -> Array[String]
func get_building_state(building_id: String) -> Dictionary

# 升级
func upgrade_building(building_id: String) -> Dictionary
# [P] building 状态=OPERATIONAL, 科技满足升级条件
# [Q] building 状态=UPGRADING

# 拆除
func demolish_building(building_id: String) -> Dictionary
# [Q] 资源部分回收, building 状态=DESTROYED, 发射 building_removed

# 修理
func repair_building(building_id: String, org_id: String) -> Dictionary
# [P] building 状态=DAMAGED
```

> **🔄 模块化重构后（B1+ 阶段，详见 [建筑模块化设计.md](建筑模块化设计.md)）**：
> 
> 上述 `building_type` 字符串将被 `BuildingDef` 配方取代，签名改为：
> 
> ```gdscript
> # 建造（模块化版本）
> func start_construction(region_id: String, building_def: BuildingDef, cell_x: int, org_id: String) -> Dictionary
> # [P] building_def 是 config/buildings/defs/ 下的 .tres 资源
> # [P] BuildingGenApi 已注册所需材质和模块
> # [Q] 创建项目并调 BuildingGen.generate(def) 产出节点
>
> # 直接生成（绕过建造过程，用于 InitialBuildingsList）
> func spawn_operational_building(def_id: String, cell_x: int, width: int = 1) -> Dictionary
> # [Q] 按 def_id 瞬间生成 OPERATIONAL 状态的 Building，挂到 BuildingHost
>
> # 后期追加模块到已有建筑
> func add_module_to_building(building_id: String, layer_index: int, module_id: String, cell_pos: Vector2i) -> Dictionary
> # [P] layer_index 在 0..def.size.y-1 范围
> # [P] cell_pos 不与其他模块 footprint 冲突
> # [Q] 实例化模块并挂到对应 layer.Modules_Slot，前景墙按需重建
> ```

---

## 一-A、建筑生成模块 `modules/building_gen/api.gd`（B0+ 阶段新增）

```gdscript
# 资源注册
func register_material(material: MaterialDef) -> void
func register_module(module: ModuleDef) -> void
func register_roof(roof: RoofShape) -> void

# 资源查询
func get_material(material_id: String) -> MaterialDef
func get_module(module_id: String) -> ModuleDef
func get_roof(shape_id: String) -> RoofShape

# 程序化生成
func generate_building(def: BuildingDef) -> Node2D
# [P] def.default_material 或 def.layers[*].material_id 已注册
# [P] def.layers[*].module_specs 引用的 module_id 已注册
# [Q] 返回的节点树结构遵循 [建筑模块化设计.md] §三 的 BuildingEntity 节点结构
#     包含 Layers / Roof / InteractionZone / PassageBarrier / Footprint
#     模块占位格的前景墙已挖洞（不生成）
#     透明化时遍历所有层的 FrontLayer.Walls_Front 做批量 alpha→0.3
```

---

## 一-B、纹理生成模块 `modules/texture_gen/api.gd`（2026-07 从 building_gen 解耦）

```gdscript
# 材质查询
static func list_materials() -> Array[StringName]
static func has_material(material_id: StringName) -> bool

# CPU 程序化贴图（委托 ProceduralMaterials）
static func make_wood_pillar(w, h, base_color) -> ImageTexture
static func make_wood_plank(w, h, base_color) -> ImageTexture
static func make_straw_thatch(w, h, base_color) -> ImageTexture
static func make_thatch_layered(w, h, seed) -> ImageTexture
static func make_thatch_for_polygon(w, h, seed) -> ImageTexture
static func create_thatch_material(tex) -> ShaderMaterial
static func make_stone_dark(w, h, base_color) -> ImageTexture
static func make_metal_iron(w, h) -> ImageTexture
static func make_solid(w, h, color) -> ImageTexture

# GPU Shader 材质
static func load_shader_material(material_id) -> ShaderMaterial
# [P] material_id 已注册（list_materials 返回包含它）
# [Q] 返回 ShaderMaterial（未设置 uniform，调用方按需配置）

static func apply_material(target, material_id) -> ShaderMaterial
# [P] target is CanvasItem, material_id 已注册
# [Q] target.material 被替换，返回新 ShaderMaterial

# 茅草 CPU 笔迹适配（@tool 场景用）
static func apply_thatch_cpu(polygon) -> void
# [P] polygon is Polygon2D 且 polygon.polygon.size() >= 3
```

---

## 二、科技模块（阶段 1 按新策略重建，契约以届时实现为准）

> 科技系统按"征服获得即解锁"设计（无研究状态机），模块当前未实现。
> 重建时以 [`../../设计/系统/04-科技系统.md`](../../设计/系统/04-科技系统.md) 的策略为准补充契约。

---

## 三、资源模块 `modules/resources/api.gd`

```gdscript
# 查询库存
func get_stock(resource_id: String, region_id: String = "") -> float
func get_all_stocks() -> Dictionary

# 查询价格
func get_price(resource_id: String, region_id: String) -> float

# 消耗/增加（由其他系统调用，发射 resource_changed）
func consume(resource_id: String, amount: float, region_id: String, reason: String) -> Dictionary
# [P] amount <= get_stock(resource_id, region_id)
# [Q] 库存扣减, 发射 resource_changed 或 resource_not_enough

func produce(resource_id: String, amount: float, region_id: String, source: String) -> Dictionary
# [Q] 库存增加, 发射 resource_changed

# 转移（运输系统调用）
func transfer(resource_id: String, amount: float, from_region: String, to_region: String) -> Dictionary
# [Q] from 扣减, to 增加（有运输损耗, 实际到达 = amount * (1 - 损耗率)）

# 市场参数调节（L4+ 层级可用）
func set_price_ceiling(resource_id: String, price: float) -> Dictionary
func set_price_floor(resource_id: String, price: float) -> Dictionary
func set_tax_rate(rate: float) -> Dictionary
```

---

## 四、扩张模块 `modules/expansion/api.gd`（未实现，阶段 2 设计契约）

```gdscript
# 地块查询
func get_region(region_id: String) -> Dictionary
func get_adjacent_regions(region_id: String) -> Array[String]
func get_regions_by_owner(owner_id: String) -> Array[String]
func get_control_percentage(region_id: String) -> float

# 控制度变化（战斗系统调用）
func add_control(region_id: String, amount: float, new_owner: String) -> Dictionary
# [Q] 控制度增加, 达到 100% 时发射 territory_gained

func lose_control(region_id: String, amount: float) -> Dictionary
# [Q] 控制度减少, 降至 0% 时发射 territory_lost

# 外交
func declare_war(target_id: String, casus_belli: String) -> Dictionary
func propose_peace(target_id: String, terms: Dictionary) -> Dictionary
func propose_alliance(target_id: String) -> Dictionary
func annex_vassal(vassal_id: String) -> Dictionary

# 殖民
func start_colonization(region_id: String, org_id: String) -> Dictionary
# [P] region 无主
```

---

## 五、组织模块 `modules/organization/api.gd`（核心模块）

```gdscript
# 创建
func create_organization(name: String, tag: String, tier: int, parent_id: String) -> Dictionary
# [P] tier 必须在 1-5 范围内, tag 有效, parent 的 tier = tier+1（若存在）
# [Q] 发射 org_created

# 查询
func get_organization(org_id: String) -> Dictionary
func get_child_orgs(org_id: String) -> Array[String]
func get_orgs_by_tag(tag: String) -> Array[String]
func get_orgs_in_region(region_id: String) -> Array[String]

# 编制管理
func set_personnel_template(org_id: String, template: Dictionary) -> Dictionary
# template 如 {"rifleman": 4, "machine_gunner": 1, "mage": 1}
# [Q] 发射 org_restructured

func set_equipment_template(org_id: String, template: Dictionary) -> Dictionary

func set_autonomy(org_id: String, level: String) -> Dictionary
# level: "high" / "medium" / "low"

func set_default_behavior(org_id: String, behavior: Dictionary) -> Dictionary
# 见 combat.md 的战术行为配置

func assign_commander(org_id: String, stickman_id: String) -> Dictionary
func remove_commander(org_id: String) -> Dictionary

# 人员管理
func assign_stickman(org_id: String, stickman_id: String, role: String) -> Dictionary
func remove_stickman(org_id: String, stickman_id: String) -> Dictionary

# 层级调整
func insert_tier(org_id: String, new_org_name: String, position: String) -> Dictionary
# 在 org 和其 parent 之间插入一个新组织, position="above"/"below"

func remove_tier(org_id: String) -> Dictionary
# 删除该组织，其子组织自动上挂到 parent

# 解散
func disband_organization(org_id: String) -> Dictionary
# [Q] 所有人员回归待分配池, 子组织上挂到 parent, 发射 org_disbanded

# 预设
func load_preset(preset_name: String, parent_id: String) -> Dictionary
func export_as_preset(org_id: String) -> Dictionary
```

---

## 六、战斗模块 `modules/combat/api.gd`

```gdscript
# 创建战斗
func initiate_battle(attacker_org_id: String, defender_region_id: String) -> Dictionary
# [Q] 创建 Battle 实例, 发射 battle_started

# 查询
func get_active_battles() -> Array[String]
func get_battle_state(battle_id: String) -> Dictionary

# 指令（玩家手动干预）
func issue_order(battle_id: String, org_id: String, order_type: String, params: Dictionary) -> Dictionary
# order_type: "advance" / "defend" / "flank" / "retreat" / "hold"

# 附身
func possess_commander(org_id: String, tier: int) -> Dictionary
# 玩家直接操控该组织的指挥官
func release_possession() -> Dictionary

# 呼叫支援
func call_reinforcements(battle_id: String, org_id: String) -> Dictionary
func call_airstrike(battle_id: String, target: Vector2) -> Dictionary  # 巫师空袭
```

---

## 七、物流模块 `modules/logistics/api.gd`（未实现，阶段 2 设计契约）

```gdscript
# 创建物流路线
func create_supply_chain(origin_region: String, dest_region: String, 
                          resource_id: String, quantity: float, 
                          frequency: float, carrier_org_id: String) -> Dictionary
# [P] carrier_org 标签=COMMERCE 或 MILITARY
# [Q] 发射 supply_chain 创建, 资源开始流动

# 查询
func get_supply_chains() -> Array[Dictionary]
func get_supply_efficiency(chain_id: String) -> float

# 修改
func update_supply_chain(chain_id: String, changes: Dictionary) -> Dictionary
func cancel_supply_chain(chain_id: String) -> Dictionary

# 基础设施
func build_road(from_region: String, to_region: String, org_id: String) -> Dictionary
func upgrade_road(from_region: String, to_region: String) -> Dictionary
```

---

## 八、成就模块 `modules/achievement/api.gd`（未实现，阶段 2 设计契约）

```gdscript
# 查询
func get_unlocked_badges() -> Array[String]
func get_all_badges() -> Array[Dictionary]  # {id, name, description, rarity, unlocked}

# 检查（由其他系统调用，不建议玩家手动触发）
func check_and_unlock(badge_id: String) -> Dictionary
# [Q] 若条件满足 -> 解锁, 发射 badge_unlocked
```

---

## 九、模块间 API 依赖图

> 仅含已实现模块（construction / building_gen / texture_gen / resources / organization / combat / world_map / world / units / player_control / environment / fx / debug_gui）。
> technology（见 §二）、expansion / logistics / achievement（未实现）为阶段 2 设计契约，实现时补充出边。
> world 为组装根：SystemSetup 集中装配各模块组件，跨模块依赖汇聚于此而非散布（详见 场景与战斗架构.md）。

```
construction ──-> resources (消耗建材)
             ──-> building_gen (经 api 加载建筑场景; Building 为其公共类型)
resources    ──-> (无出向 API 依赖, 通过 EventBus 通信)
organization ──-> resources (征兵消耗沥青)
             ──-> construction (建设组织)
             ──-> combat (军事组织)
combat       ──-> resources (消耗弹药/食物)
             ──-> organization (伤亡)
             ──-> units (经公共类型 TargetFinder / StickmanEntity)
world_map    ──-> ui_global (主题工具箱 StickKit/StickTheme/StickStyle)
world        ──-> 各模块 (组装根 SystemSetup 集中装配)
units        ──-> player_control (经 PlayerControlAPI 注册表取 InputDispatcher)
```

---

*下一阶段：Autoload 依赖图。*

---

## 十、战略图模块 `modules/world_map/api.gd`

> L1 单层战略图已实装（P0 新 0.9，Tab 键），集成测试 `test_strategic_map_p0` / `test_l2_strategic_map` / `test_l3_strategic_map` 全绿。
> 战略图开/关通知走 EventBus（`strategic_map_opened` / `strategic_map_closed`），进入场景图走 `EventBus.travel_requested`。

```gdscript
# 初始化（由 system_setup 装配时调用）
func initialize(json_path: String, base_dir: String) -> void
# [Q] 加载 L1 世界数据（8 聚落 + 空聚落 + MST 道路 + 边界索引图）

# 查询
func query_at_screen(screen_pos: Vector2) -> Dictionary
# [Q] 返回 {"settlement": SettlementRef, "tile": L1TileDef}（索引图像素解码命中）

func get_settlement_ref(settlement_id: String) -> SettlementRef
func get_all_settlements() -> Array[SettlementRef]

# 进出
func enter_settlement(settlement_id: String) -> void
# [Q] 发射 EventBus.travel_requested(map_id) 并关闭战略图；空聚落不可进入

func close_strategic_map() -> void
# [Q] 控制器 visible=false 并发射 EventBus.strategic_map_closed（恢复场景图输入）

# 模块本地信号
signal settlement_clicked(settlement_id: String)
signal settlement_activated(settlement_id: String)
signal region_hovered(tile_id: String, settlement_id: String)
```

---

## 十一、单位模块 `modules/units/api.gd`（UnitsAPI）

> 类型契约 + 资源路径层：外部模块经全局 class_name（StickmanEntity/StickmanRig/AIController 等）的公共方法交互；
> 实体场景经 `UnitsAPI.STICKMAN_ENTITY_SCENE` 常量引用（替代直接 preload 内部路径）。

```gdscript
# 场景资源（外部实例化火柴人实体的统一入口）
const STICKMAN_ENTITY_SCENE: PackedScene

# StickmanRig 公共 API（渲染骨架）
play(anim_name: String)              # 播放动画
get_current_anim() -> String
get_bone_by_id(id: int) -> Node2D
get_bone_ids() -> Array
# 常量：ANIM_IDLE / ANIM_WALK / ANIM_ATTACK / ANIM_DEAD
#       WeaponType（SWORD / SPEAR / BOW / SHIELD / UNARMED）

# StickmanEntity 公共 API（物理+碰撞外壳）
set_possessed(bool) / is_possessed() -> bool
get_facing() -> int                  # 1=右，-1=左
ai_move(dir: Vector2, run: bool) / ai_stop()
get_ai_controller() -> Node
set_ground_constraints(...)          # 注入地面约束参数
set_map_reference(map: Node2D)       # 注入地图引用
# 常量：WALK_SPEED / RUN_SPEED / BASE_SCALE

# AIController 公共 API
get_current_behavior() -> String     # 当前行为名（idle/move/...）
get_state_machine() -> BehaviorStateMachine
```

---

## 十二、世界模块 `modules/world/api.gd`（WorldAPI）

> 常量与枚举契约层：GameRoot / MapInstance 的节点路径约定（修改 GameRoot 节点结构需同步该文件）。
> 场景旅行信号经 EventBus（map_loaded / map_unloaded / travel_started / travel_completed），本模块订阅 game_paused / game_resumed。

```gdscript
# GameRoot 常驻子节点相对路径
const PATH_ENVIRONMENT / PATH_CAMERA_RIG / PATH_SCENE_LOADER / PATH_INPUT_DISPATCHER
const PATH_WORLD_CHUNK_HOST / PATH_UI_ROOT / PATH_BATTLE_DIRECTOR

# MapInstance 子节点相对路径（节选，全表见 api.gd）
const PATH_MAP_PLACEMENT_GRID / PATH_MAP_TERRAIN_LAYER / PATH_MAP_BUILDING_HOST
const PATH_MAP_ENTITY_HOST / PATH_MAP_WALK_BARRIER / PATH_MAP_FOREGROUND_LAYER

enum MapType { VILLAGE, BATTLEFIELD, ROAD, INDOOR, MEGA_INTERIOR }
enum TravelMode { WALK, FAST_TRAVEL, TELEPORT }
enum EntrySide { LEFT, RIGHT }
```

---

## 十三、玩家控制模块 `modules/player_control/api.gd`（PlayerControlAPI）

```gdscript
enum Mode { NONE, EXPLORE, BUILD, BATTLE, POSSESS, INDOOR, UI }

# InputDispatcher 注册表（GameRoot 装配时注册；units 等模块经此获取，替代 group 反查）
static func register_input_dispatcher(dispatcher: Node) -> void
static func get_input_dispatcher() -> Node

# PossessionInterface 公共 API（附身操控）
get_possessed_entity() -> Node2D
possess(entity: Node2D) -> void
release() -> void
```

> 信号契约：`InputDispatcher.mode_changed(old_mode: int, new_mode: int)`。
> 附身流程（BATTLE 框选 → 附身按钮 → set_possessed + 相机跟随 + TimeManager 降速 → WASD/左键/ESC）见 api.gd 头注释。

---

## 十四、环境模块 `modules/environment/api.gd`（EnvironmentAPI）

> P0 阶段仅实现时间→光照映射（CanvasModulate 按 LIGHT_KEYFRAMES 插值）；天空/天气/地面震动/生物群系为 P1 规划。

```gdscript
const HOURS_PER_DAY: int = 24
const LIGHT_KEYFRAMES: Array  # 时间[小时] -> CanvasModulate.color（深夜/黎明/早晨/正午/下午/黄昏/入夜 共 8 关键帧）
```

---

## 十五、特效模块 `modules/fx/api.gd`

> 无状态特效服务：无 api 节点实例、无信号契约。对外入口是全局类 FxPool 的静态方法（组查找模式，业务方不持有池节点引用）。

```gdscript
# 业务方调用示例（效果 ID 常量表见 FxLibrary：BUILD_DUST / GATHER_DEBRIS / HIT_SPARK 等）
FxPool.spawn_burst(get_tree(), FxLibrary.HIT_SPARK, global_position)
```

> 池实例由 SystemSetup 挂载到 GameRoot（group "fx_pool"）；无池环境（纯逻辑测试）spawn_burst 静默跳过不报错。
> 依赖方向：fx → core 单向（WorldZ z 序常量），任何模块可安全依赖 fx。

---

## 十六、调试模块 `modules/debug_gui/api.gd`（DebugApi，autoload 单例）

> 唯一以 autoload 注册的模块级 api（project.godot: `DebugApi`）。生产模块经 `EventBus.debug_visibility_changed`
> 订阅调试显隐（避免依赖 debug_gui autoload）；绘制器注册等管理操作直连 DebugApi。

```gdscript
# 信号
signal visibility_changed(is_visible: bool)
signal legend_visibility_changed(is_visible: bool)
signal drawer_enabled_changed(drawer_name: String, enabled: bool)
signal tools_visibility_changed(is_visible: bool)   # 交互式工具面板，独立于 F3 总开关

# 绘制器注册（各模块注册自己的调试绘制器）
func register_drawer(drawer_name: String, drawer: Callable) -> void
func unregister_drawer(drawer_name: String) -> void
func set_drawer_enabled(drawer_name: String, enabled: bool) -> void
func toggle_drawer(drawer_name: String) -> void

# 全局可见性
func toggle_visibility() -> void          # F3 切换
func set_overlay_visible(v: bool) -> void
func is_visible() -> bool

# 调试上下文附加数据（装配层注入，随每帧 ctx 下发给绘制器）
func set_ctx_extra(key: String, value) -> void
func get_ctx_extra(key: String, default: Variant = null) -> Variant
```
