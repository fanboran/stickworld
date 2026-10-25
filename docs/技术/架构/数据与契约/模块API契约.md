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
# [Q] 创建一个 Construction Project, building 状态=PLANNED

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

# 工作委派（Job 板消费面，units 侧 AIController 消费）
func register_worker(worker: Node) -> void            # 实体注入 construction 引用时入池
func unregister_worker(worker: Node) -> void          # 实体销毁时出池（防悬垂引用）
func try_assign_worker(worker: Node, hint: Dictionary = {}) -> bool
# [Q] Job 板认领：按（距离→挂板序）挑最近项目，按项目缺料状态与 hint 定族；
#     hint = {can_build: bool, can_haul: bool, has_warehouse: bool}（编队职责过滤 +
#     仓库可达性，调用方组装），缺省两族皆可；认领即项目成员化（首人自动开工）
func get_worker_job(worker: Node) -> Dictionary        # {kind: "build"/"haul", project}；未派工 {}
func refresh_worker_job(worker: Node, hint: Dictionary = {}) -> Dictionary
# [Q] 持有任务族别刷新：材料耗尽 build→haul、材料到货 haul→build（原项目内原地换，
#     不发射派工信号）；无可领族/未持任务返回 {}
func get_worker_project(worker: Node) -> RefCounted    # 任务绑定的项目（两族同源）
func get_available_workers() -> Array                  # 空闲工人名单（organization 域消费）
func get_nearest_warehouse(pos: Vector2) -> Node2D     # 搬运取货点查询
```

> **🔄 模块化重构后（B1+ 阶段，详见 [建筑模块化设计.md](../场景与战斗/建筑模块化设计.md)）**：
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

## 二、技能模块 `modules/skill/api.gd`（骨架占位：技能台账，结构已接线、内容待策划）

> 技能本位（04-科技系统 v2）：科技=长在具体火柴人身上的技能（制造/使用/组织
> 三类，会/不会二元）；无阵营科技池——"我国会什么"是台账的派生查询。
> 机制面（训练/研究的组织职能、死亡移除、"需技能"标注消费、组织技能前置
> 接线）待内容批次实装。

```gdscript
# 习得一项技能（生产入口：时刻取 WorldState.game_time；师承记录供谱系图）
static func learn_skill(skill_id: String, holder_id: String, source: SkillRecord.Source,
        teacher_holder_id := "") -> Dictionary
# [P] skill_id 在技能定义表注册（制造/使用/组织三类）；holder_id 非空
# [Q] 成功：台账追加 + manager 发 skill_learned；已会拒绝（会/不会二元无层次）
#     source ∈ {BIRTH, CONQUEST, TALENT, EVENT, TRAINING, RESEARCH}

# 派生查询（阵营技能 = 台账聚合，无中央解锁池）
static func knows(holder_id: String, skill_id: String) -> bool
static func faction_knows(skill_id: String) -> bool   # 存在持有者即会；在场性归物流与组织
static func holders_of(skill_id: String) -> Array     # 谁会
static func skills_of(holder_id: String) -> Array     # 某人会什么

# 定义注册表
static func get_skills() -> Array
static func get_skill(skill_id: String) -> Dictionary
static func get_skills_of_category(category: String) -> Array  # "制造"/"使用"/"组织"
static func get_records() -> Array                    # 台账本体（SkillRecord）

# 存档（模块自订阅 game_saving/game_loaded 直写 world_state 模块行 'skill'）
static func get_save_data() -> Dictionary
static func load_save_data(data: Dictionary) -> void
static func reset_for_new_run() -> void
```

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

# ⚠ 市场参数接口属旧市场模型实录；新口径价格机制为提案级（初期高度非市场），随 8.15 经济重做重审。
# 市场参数调节（L4+ 层级可用）
func set_price_ceiling(resource_id: String, price: float) -> Dictionary
func set_price_floor(resource_id: String, price: float) -> Dictionary
func set_tax_rate(rate: float) -> Dictionary
```

---

## 四、扩张模块 `modules/expansion`（无对外 api）

expansion 模块不设 `api.gd` 对外契约面（据点玩法层的配置/编排/出入口按 [`docs/设计/完整版蓝图.md`](../../../设计/完整版蓝图.md) §6.1 拆除，模块收敛为纯管道）；仅保留驻军生成服务：

```gdscript
# scripts/garrison_spawner.gd（RefCounted 纯服务，无节点、无信号）
func spawn_garrison(map: Node, row: Dictionary) -> Array
# 按 map 内 ConquestAnchor 布阵刷出守军实体，返回守军实体名单
# [P] row 为编成 Dictionary 直接传入：{garrison: [{profile, count, tier}], commander: {profile}}
# [Q] ConquestAnchor 位于 modules/world/scripts/map/（HD-2D 宿主直接消费）
# 数据源：编成由调用方给定，将来 = 世界模型政权账面；当前无生产调用方（测试可代发驱动）
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
func list_root_orgs() -> Array[String]
# 森林多根列举（OrgPanel 树构建入口）

func set_org_name(org_id: String, new_name: String) -> Dictionary
# [Q] 成功发射 org_restructured

func list_preset_names() -> Array[String]
# presets.tres 预设名去重列表（"从预设创建"入口数据源）

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
func set_personnel(org_id: String, stickman_ids: Array) -> Dictionary
# 整表重设成员（清旧表重写，不触发补位引擎）；编队读档重建人员账专用

# 存档恢复
func restore_from_world() -> void
# 读档收编：把 WorldState 容器里的组织收编为本模块工作集（save_handler 存档恢复
# 编排调用，前置 = 编队已清场；语义见 OrganizationManager.restore_from_world_container）

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
# [Q] 每创建一个组织发射一次 org_created
func apply_preset(data: Dictionary, parent_id: String) -> Dictionary
# v2 蓝图直灌（export_as_preset 产物格式），信号语义同 load_preset
func export_as_preset(org_id: String) -> Dictionary

# 逐层指挥链（批次 3-F1，架构文档 组织系统架构.md §四）
func build_dispatch_plan(org_id: String, order: Dictionary) -> Dictionary
# 逐层投递计划：hop 0 玩家跳（from_org=""，from_tier=0）+ BFS 层序展开到 L1，同令透传
# data: {root_org, leaf_orgs, hops}；错误："org_not_found" / "no_subordinate"
func get_delivery_time(from_org: String, to_org: String) -> float
# 一跳传播秒数（传输层 v1：距离÷媒介速度；层级数不直接生延迟）——3-F2 combat 接力执行消费
func set_transport_providers(position_provider: Callable, player_position_provider: Callable, region_distance_provider: Callable) -> void
# 装配注入传输层三 provider（system_setup 接线；location 由 manager 内部接线，不占装配面）
func set_attribute_provider(provider: Callable) -> void
# 装配注入 cmd 属性查询（补位排序）：stickman_id -> float，失败返回 -1 沉底
func get_succession_candidates(org_id: String) -> Array[Dictionary]
# 补位候选序 [{id, cmd}, ...] 按 cmd 降序（平局按池序；现任指挥官不在池）
func evaluate_report_gate(org_id: String, type: String, payload: Dictionary) -> bool
# 上报门控（§4.4 三档表）：commander_lost 必报恒 true；HIGH 不报 casualty/contact；
# MEDIUM casualty 按存活比阈值（var_report_casualty_threshold）；LOW 全量
func file_report(org_id: String, report: Dictionary) -> void
# 提交上报（combat 挂点入口；schema 校验后发 report_filed）
# 信号 report_filed(org_id, report)：report={type, filed_at, payload}，组织侧只透传不解释
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

# 接管
func user_control_commander(org_id: String, tier: int) -> Dictionary
# 玩家直接操控该组织的指挥官
func release_user_control() -> Dictionary

# 呼叫支援
func call_reinforcements(battle_id: String, org_id: String) -> Dictionary
func call_airstrike(battle_id: String, target: Vector2) -> Dictionary  # 巫师空袭

# 编队存档（读档完整性批次；行格式权威 = save_handler._save_formation，
# world_state 表 module_name='formation'，成员/排长以 entities 表 ent_* 为稳定键）
func export_for_save() -> Dictionary
# 导出班 + 排（火力组不入档；实体以 iid 为键，save_handler 换算稳定键）。{} = 无编队
func restore_from_save(data: Dictionary, entity_map: Dictionary) -> int
# 从存档行重建班 + 排（前置 = 清场 + 组织已收编）。返回恢复班数
func clear_squads_for_load() -> void
# 读档清场：只清编队本地态不触组织侧（disband_all_squads 会经组织侧反注销容器组织，
# mid-session 读档撞 id 即断链——语义见 FormationSystem.clear_squads_for_load）
```

---

## 六-A、战斗阵列模块 `modules/formation/api.gd`（已实现契约）

```gdscript
# 间距/物理分离单一真相源（常量；units 实体链与 combat 批模拟同源读取）
const SEPARATION_RADIUS_X: float        # 分离半径·横向轴（椭圆口径，提案待实测）
const SEPARATION_RADIUS_Y: float        # 分离半径·纵深轴（约横向 1.5 倍，提案待实测）
const SEPARATION_RADIUS: float          # 兼容别名（=X；消费方改椭圆判定前自动跟随横向）
const SPREAD_SPACING_DEFAULT: float     # 横向间距默认值（balance.variables var_spread_spacing 覆盖）
const ROW_GAP_DEFAULT: float            # 列间距默认值（balance.variables var_row_gap 覆盖；≥ Y+余量）
const UNITS_PER_COLUMN: int             # 每列人数基准档（班级现役列高按人数 4~6 自适应）
const FOLLOW_DEADZONE: float            # 跟队/落定死区
const ARRIVE_TOLERANCE: float           # 相位计划到位容差默认值（config/ai/squad_phase_plan.tres 覆盖）
const COHESION_SPREAD_RADIUS_BASE: float      # 班散布半径基准（8 人班，聚拢死区）
const COHESION_SPREAD_RADIUS_PER_MEMBER: float  # 每增 1 人半径增量
const COHESION_PULL_PER_PX: float       # 聚拢回拉斜率（线性段）
const COHESION_PULL_MAX: float          # 聚拢回拉上限（防磁铁）
const COHESION_ENGAGED_SCALE: float     # 接战回拉衰减系数
const COHESION_AVG_SPEED_DEADZONE: float  # 班均速死区（站桩不对齐）
const ALIGNMENT_STEER_SCALE: float      # 对齐收敛权重（1/s）
# （聚拢/间距数值全部提案待实测校准）

# 运行期实例（FormationSystem，class_name 全局）：由装配层创建并注入，消费方 duck 调用
# create_squad / assign_leader / add_unit / get_squad_units / get_squad_leader
# get_squad_dest(squad_id, unit, base_pos, mode)   # mode: "formation" / "line" / "rally"
# set_squad_follow_squad / get_squad_target / is_unit_in_formation
# notify_squad_order / notify_org_order            # 号令触发相位计划（推进类枚举 = tactics Orders.OrderType）
# ── 排聚合层（现实军衔体系重排：班 rank1 → 排 rank2 → 连挂载点 company_id 预留）──
# create_platoon(squad_ids, name="") -> platoon_id   # 班聚合为排（未属他排）
# assign_platoon_leader(pid, unit) -> bool           # 排长须为排内班成员（rank 2）
# get_platoon_leader / get_platoon_squads / get_platoon_of_squad / get_unit_platoon
# get_platoon_units / get_all_platoons / get_platoon_count
# disband_platoon(pid)                               # 班保留转独立
# has_squad_command_chain(squad_id) -> bool          # 排长缺口 → false（该排失去集火）
# 信号 platoon_created / platoon_leader_lost          # 排长阵亡 = 指挥链缺口（无补位）
# ── 班内聚拢（Boids 式裁剪；力经消费方转向通道，不直改位置）──
# get_unit_cohesion_steer(unit) -> Vector2           # 聚拢+对齐转向建议（ZERO=死区内/避战/无班）
# get_squad_spread_radius(squad_id) -> float         # 聚拢死区半径（按班人数放宽）
```

> 实现全在 `scripts/`（编队总成/间距真相源/槽位几何/跟队/相位计划/快照/权威值/上报）与 `ui/`（编制窗口/L1 班组卡）；
> 外部模块禁止 preload 内部脚本。号令的语义与目标选择在 tactics（`TacticalOrders`/`TargetFinder`）、下发链在 combat（`CommandChain`），阵列只回答落点与到位判定。

---

## 六-B、战术决策模块 `modules/tactics/api.gd`（已实现契约）

```gdscript
# 战术号令脚本（TacticalOrders：OrderType 枚举 ADVANCE_ALL/SPRINT/HOLD_POSITION/RETREAT/TAKE_COVER/RALLY
# + issue 编制直令（target_id = 班 squad_id 或班内火力组 ft_id——火力组寻址见 formation 契约）
# / issue_to_org 组织逐层；formation/command_chain/org 引用由装配层注入，不静态依赖）
const Orders: GDScript

# 目标选择脚本（TargetFinder：find_target / find_weakest_ally / find_targets_in_arc，
# 规则经 opts 链式过滤——prefer_low_hp / prefer_large / fixate_on / ignore_current_attackers / max_attackers_per_target）
const Finder: GDScript

# 夺点结算脚本（CapturePoint：位置/半径/归属/进度；半径内单方积分、双方冻结互消、
# 满进度易主并发模块信号 capture_owner_changed(point_id, from_faction, to_faction)；
# get_capture_state() 只读探测——Benchmark 选手基类按此方法名识别旗点）
const CapturePoint: GDScript

# 班级意图规划器（SquadIntentPlanner：0.5s 节拍攻点/驻防/接火打分选意图 + 惯性防抖，
# 翻译 TacticalOrders 下发；tick(delta) 外部可驱动不宿主耦合；单位数据经调用方注入
# provider 回传——L2 零出向；同局两台恰好一台 setup(drives_settlement=true) 管占领结算）
const IntentPlanner: GDScript
```

> 从 combat 聚合迁出的共享战术词汇：units（行为层选目标）、formation（小队共享目标 + 相位计划号令判定）、
> combat（team_ai 号令编排/效用打分/战斗面板）三方单向依赖，combat⇄units 环（AR-2）根因消除。
> 消费方一律经本文件常量 preload（显式链保 headless 防御惯例），禁止 preload scripts/ 内部文件。
> CapturePoint/IntentPlanner 当前接线在观察场（tests/dev/battle_arena.gd 夺点模式），
> 生产战场接线挂后续批次（TeamAi 与意图规划器的号令权仲裁已在 TeamAi.set_planner_suppressed 留口）。

---

## 六-C、骨架渲染模块 `modules/stick_rig/api.gd`（已实现契约，L1）

```gdscript
# 脚本出口（显式 preload 链）
const ANIMS_SCRIPT: GDScript          # StickmanAnims：动画名/变体池/WEAPON_ATTACK_ANIM 单一真相源
const HEALTH_BAR_SCRIPT: GDScript     # HealthBarIndicator：头顶血条 + crowd GPU 烘制参数
const OUTLINE_SCRIPT: GDScript        # StickmanOutline：CanvasGroup 双 pass 描边（hd2d 消费）
const CROWD_RENDERER_SCRIPT: GDScript # crowd 批量渲染器（combat BattleInstance 装配）

# 场景与武器视觉词汇
const RIG_SCENE_PATH: String          # 骨架场景（实体场景与 HD-2D billboard 共用实例源）
enum WeaponType { SWORD, SPEAR, BOW, PICKAXE, STAFF, MERIC, NONE }  # 装备状态数值口径
const WEAPON_SCENE_PATHS: Dictionary  # 武器类型 -> 表现场景路径（WeaponMount const 转发保持旧引用点）
```

> 火柴人唯一视觉骨架（AGENTS.md 核心指令 6）：骨骼/动画/描边/血条/crowd 合批/武器表现组件归本模块（L1），
> 实体侧（units）持数据与状态机经 api 驱动渲染。对实体的运行时协作走鸭子协议（节点名/has_method/get），
> L1 不反向依赖 L2；hd2d 的角色 billboard 经本 api 取骨架场景/描边/血条/武器镜像（AR-1 清偿）。

---

## 七、物流模块 `modules/logistics/api.gd`（骨架占位：结构已接线、机制待 06 号设计实装）

> 骨架做实：载体（载体/载具并一表）+ 道路占位表装载注册表 + 运输计划 CRUD
> （计划**挂组织节点**——06 §2.3，字段集见 TransportPlan）。机制面（网络节点/
> 路线建模、承运人派工、路线状态、补给线惩罚）待设计实装，占位方法走未实现
> 守卫。设计真相源 [`../../../设计/系统/06-物流系统.md`](../../../设计/系统/06-物流系统.md)。

```gdscript
# 占位表注册表（BalanceResource 行数组，行内容待策划——id placeholder 前缀/数值统一 10）
static func get_carriers() -> Array
static func get_roads() -> Array
static func get_carrier(carrier_id: String) -> Dictionary   # 未命中 {}

# 运输计划 CRUD（owner_org_id = 持有计划的组织节点；CargoKind ∈ {ITEM, RESOURCE, PERSONNEL}）
static func add_transport_plan(owner_org_id: String, origin: String, destination: String,
        cargo_id: String, cargo_kind: TransportPlan.CargoKind, amount: int,
        frequency_days: int, priority: TransportPlan.Priority) -> Dictionary
# [P] owner_org_id 非空（计划必须挂在组织节点上）；origin/destination 非空且不同；cargo_id 非空
# [Q] 成功：{"ok": true, "plan_id": "tp_NNN"} + manager 发 transport_plan_added

static func remove_transport_plan(plan_id: String) -> Dictionary
static func get_transport_plans() -> Array

# 机制守卫（待 06 §四组织封装递进实装）
static func assign_carrier(plan_id: String, stickman_iid: int) -> Dictionary
# [Q] 恒 {"ok": false, "error": "骨架占位：承运人派工待 06 号设计实装"}

# 存档（模块自订阅 game_saving/game_loaded 直写 world_state 模块行 'logistics'）
static func get_save_data() -> Dictionary
static func load_save_data(data: Dictionary) -> void
static func reset_for_new_run() -> void
```

---

## 八、成就模块 `modules/achievement/api.gd`（骨架占位：结构已接线、逐枚清单待创始人）

> 骨架做实：平权手工清单占位表（无稀有度、无隐藏档，07 号）+ 幂等解锁记录
> （获得时刻 + 帝国状态快照）。图章存档绑定。机制面（条件判定、图章墙 UI
> 的灰暗剪影、Steam 同步）待逐枚清单定稿后实装。设计真相源
> [`../../../设计/系统/07-成就系统.md`](../../../设计/系统/07-成就系统.md)。

```gdscript
# 解锁一枚图章（幂等：已获得再调用 = 无操作不重发信号——收藏不膨胀）
static func unlock(def_id: String, empire_snapshot: Dictionary = {}) -> Dictionary
# [P] def_id 在占位表注册
# [Q] 首次成功：记录追加（快照存副本）+ manager 发 achievement_unlocked；重复返回 {"ok": true, "already": true}

# 查询
static func is_unlocked(def_id: String) -> bool
static func get_achievement_defs() -> Array     # 占位表全行
static func get_achievement_def(def_id: String) -> Dictionary
static func get_records() -> Array              # AchievementRecord（def_id/时刻/快照）

# 存档（模块自订阅 game_saving/game_loaded 直写 world_state 模块行 'achievement'）
static func get_save_data() -> Dictionary
static func load_save_data(data: Dictionary) -> void
static func reset_for_new_run() -> void
```

---

## 八B、构筑谱系模块 `modules/blueprint/api.gd`（骨架占位：结构已接线、调优杆待 11 号定稿）

> 骨架做实：蓝图节点（编制模板/建筑型号/部门章程三种定名对象，GDD §6.8）定名/
> 退役/重新启用 CRUD + DAG 不变量校验（11 §二）。谱系存档绑定、不跨档继承。
> 机制面（派生/融合、熟练度成长、纹章生成算法）待 11 §三调优杆定稿后实装。
> 设计真相源 [`../../../设计/系统/11-构筑谱系系统.md`](../../../设计/系统/11-构筑谱系系统.md)。

```gdscript
# 定名（占位入口：正式入口 = 从组织预设/建筑型号/章程"封存"，随各域实装）
static func create_blueprint(display_name: String, kind: BlueprintNode.Kind, parents: Array = []) -> Dictionary
# [P] display_name 非空；parents 中母本皆存在；在役槽位 < 上限（占位常量 10）
# [Q] 成功：节点入册（代数 = 母本最大 +1）+ DAG 校验兜底 + manager 发 blueprint_created

static func retire_blueprint(blueprint_id: String) -> Dictionary
# [Q] 不删除，归荣誉档案（退役不丢源流线）+ manager 发 blueprint_retired

static func reactivate_blueprint(blueprint_id: String) -> Dictionary
# [P] 在役槽位 < 上限（受同 create 约束）

# 机制守卫（待 11 §三调优杆定稿）
static func derive_blueprint(parent_id: String, display_name: String) -> Dictionary
static func fuse_blueprint(parent_a: String, parent_b: String, display_name: String) -> Dictionary
# [Q] 恒 {"ok": false, "error": "骨架占位：派生/融合待 11 号调优杆定稿"}

# 查询与不变量
static func is_acyclic() -> bool                # DAG 环检测（11 §二不变量）
static func get_blueprints(include_retired := true) -> Array
static func active_count() -> int

# 存档（模块自订阅 game_saving/game_loaded 直写 world_state 模块行 'blueprint'）
static func get_save_data() -> Dictionary
static func load_save_data(data: Dictionary) -> void
static func reset_for_new_run() -> void
```

---

## 八C、组织槽位板 `modules/organization/scripts/slots/org_slot_system.gd`（骨架占位：01 §2.4 纯机制）

> 组织 = 功能槽位的集合；每槽至少一名人员激活（空槽 = 职能不运转）；槽位可放机构
> （组织嵌套组织，嵌套成环拒绝）。职能名是自由字符串，不设预设枚举（职能清单属内容）。
> 骨架期消费方仅单测/灰盒台，直接经 class_name 访问——接入 organization/api.gd
> 公共面随内容批次落（该文件受行数棘轮约束，本批零增行）。实现见 OrgSlotBoard 类头。

```gdscript
# 槽位增删（组织能做什么由槽位集合决定）
static func add_slot(org_id: String, function_name: String) -> Dictionary
static func remove_slot(org_id: String, function_name: String) -> Dictionary
# [P] org_id/function_name 非空；add 不重复、remove 需存在
# [Q] 拆槽连同激活关系整体移除；拆运转中的槽发 slot_deactivated

# 人员激活（一槽可多人；"至少一名人员激活"是运转条件）
static func assign_person(org_id: String, function_name: String, holder_id: String) -> Dictionary
static func unassign_person(org_id: String, function_name: String, holder_id: String) -> Dictionary
# [Q] 首次激活发 slot_activated；最后一人撤走发 slot_deactivated

# 机构激活（组织嵌套：机构以组织形态运转该职能；一槽至多一机构）
static func assign_institution(org_id: String, function_name: String, institution_org_id: String) -> Dictionary
# [P] institution ≠ 自身；嵌套不成环（全边搜索）
static func unassign_institution(org_id: String, function_name: String) -> Dictionary

# 查询（组织的强弱来自"哪些槽位被什么激活"，不看面板数字）
static func is_slot_active(org_id: String, function_name: String) -> bool
static func active_functions(org_id: String) -> Array   # 在运转的职能清单
static func get_slots(org_id: String) -> Array          # [{function, persons, institution, active}]

# 存档（自订阅 game_saving/game_loaded 直写 world_state 模块行 'org_slots'）
static func get_save_data() -> Dictionary
static func load_save_data(data: Dictionary) -> void
static func reset_for_new_run() -> void
```

---

## 九、模块间 API 依赖图

> 已实现模块（construction / building_gen / texture_gen / resources / organization（含槽位板子域 scripts/slots/，见 §八C）/ combat / formation / tactics / stick_rig / world_map / world / units / player_control / environment / fx / debug_gui / inventory / expansion / town_life）+ 四个骨架占位模块（logistics / skill / achievement / blueprint——零出向零装配，无 API 依赖边）。
> expansion 未实现；骨架模块机制面随设计定稿后补充出边。
> world 为组装根：SystemSetup 集中装配各模块组件，跨模块依赖汇聚于此而非散布（详见 场景与战斗架构.md）。

```
construction ──-> resources (消耗建材)
             ──-> building_gen (经 api 加载建筑场景; Building 为其公共类型)
resources    ──-> (无出向 API 依赖, 通过 EventBus 通信)
organization ──-> resources (招兵扣 RECRUIT_COST 木/石)
             ──-> construction (建设组织)
             ──-> combat (军事组织)
combat       ──-> resources (消耗弹药——待接线；无食物资源)
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

# 图层开关（底图恒地形；政治/城市/交通/资源四层独立开关可叠加，三视图共享全局静态 MapModeManager）
func set_layer_on(layer: int, on: bool) -> void
# [P] layer ∈ MapModeManager.Layer{POLITICAL, CITY, TRAFFIC, RESOURCE}
# [Q] 设置层开关并广播 layer_toggled（HUD 开关条/图例/渲染器同步）；同值静默

func is_layer_on(layer: int) -> bool
# [Q] 返回该层当前开关态；默认 政治=开 城市=开 交通=关 资源=关

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
set_user_controlled(bool) / is_user_controlled() -> bool
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
enum Mode { NONE, EXPLORE, BUILD, BATTLE, USER_CONTROL, INDOOR, UI }

# InputDispatcher 注册表（GameRoot 装配时注册；units 等模块经此获取，替代 group 反查）
static func register_input_dispatcher(dispatcher: Node) -> void
static func get_input_dispatcher() -> Node

# UserControlInterface 公共 API（User Control 操控）
get_user_controlled_entity() -> Node2D
control(entity: Node2D) -> void
release() -> void
```

> 信号契约：`InputDispatcher.mode_changed(old_mode: int, new_mode: int)`。
> 接管流程（BATTLE 框选 → 接管按钮 → set_user_controlled + 相机跟随 + TimeManager 降速 → WASD/左键/ESC）见 api.gd 头注释。

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
# 业务方调用示例（效果 ID 常量表见 FxLibrary：BUILD_DUST / GATHER_DEBRIS / AMBIENT_SPARKLE）
FxPool.spawn_burst(get_tree(), FxLibrary.BUILD_DUST, global_position)
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
