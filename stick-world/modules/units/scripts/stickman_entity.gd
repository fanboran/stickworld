class_name StickmanEntity
extends CharacterBody2D
## 火柴人实体 —— 物理+碰撞外壳。
##
## 详见 docs/技术/架构/场景与战斗/场景与战斗架构.md §7.1。
## 在已有 StickmanRig（纯渲染骨架）外包一层 CharacterBody2D，
## 承担物理移动、碰撞、User Control 接口。
##
## 移动与驱动：
##   - 玩家 User Control 时 WASD 控制移动/攻击（entity_user_control）
##   - 未 User Control 时由 AIController 决策驱动（战斗/工作/采集/闲逛行为全量在役）
##
## 子节点结构：
##   StickmanEntity (CharacterBody2D)
##   ├── RigHost (Node2D, 实例化 stickman_test.tscn，禁用其脚本)
##   │   ├── StickmanRig (Skeleton2D)
##   │   └── Node2D (IK markers parent)
##   ├── VisualController (Node, visual_controller.gd —— 动画播放/头顶进度条)
##   ├── InteractionController (Node, interaction_controller.gd —— 按F交互/提示弹窗)
##   └── CollisionShape2D
##
## 子域助手（方法体所在，_init 注入回引，跨域状态字段全留本类）：
##   entity/entity_motion.gd     —— 移动/分离/加减速（WALK_ANIM_BASE/ANIM_SPEED_MULT/
##                                  IDLE_THRESHOLD/SEPARATION_* 运动常量随迁）
##   entity/entity_user_control.gd —— 玩家 User Control 输入（移动/攻击/举盾/模式切换；
##                                  引擎回调 _input/_unhandled_input 薄壳留本类）
##   entity/entity_scale_rig.gd  —— 渲染判定缩放/markers 同步/接触阴影/碰撞基准
##   entity/entity_regen.gd      —— 生命恢复（接管慢回/脱战回血，回血常量随迁）
##   entity/entity_facing.gd     —— 翻面控制（节流/滞回/出生宽限/战斗朝向锁/瞄准俯仰；
##                                  _facing 本体留本类）
##   entity/entity_death.gd      —— 死亡收口/尸体淡出/遗物/受击处理与打击感
##                                  （击退冲量/硬直/尸体计时字段留本类）
##   entity/entity_lod.gd        —— LOD 性能分档（档位/频率常量随迁，无状态）
##   entity/entity_tuning.gd     —— BalanceConfig 兵种数值/移动校准（static 缓存随迁）

# ─────────────────────────────── 常量 ────────────────────────────────
## 基础行走速度（px/s）—— ×1.6 加速后
var WALK_SPEED: float = 160.0
## 奔跑速度（= 步行 ×2：现实中跑步约为步行两倍步速，run≈2×walk 是动作游戏通行比例）
var RUN_SPEED: float = 320.0
## 火柴人渲染缩放（对齐 stickman_test.BASE_SCALE * 1.5，适配 DESIGN_HEIGHT=1080）
var BASE_SCALE: float = 0.5
## 主手武器类型 -> 攻击动画名：单一真相源在 StickmanAnims.WEAPON_ATTACK_ANIM。
## 表现侧（本文件 play_attack）与战斗侧（weapon_mount 订阅命中帧事件）共用同一张表，
## 避免"播矛刺动画、却按剑的命中帧结算"的错配。
const WEAPON_ATTACK_ANIM: Dictionary = preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT.WEAPON_ATTACK_ANIM
## 动画名/变体池（死亡与受击变体选择用）
const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT
const StickProf := preload("res://core/services/stick_prof.gd")
## 状态效果组件脚本（BURN/POISON/SLOW/STUN；显式 preload 防 headless class_name 未注册）
const ScriptStatusEffects := preload("res://modules/units/scripts/entity/status_effects.gd")


## 视觉控制器组件脚本（动画播放/头顶进度条）
const _VisualControllerScript: GDScript = preload("res://modules/units/scripts/entity/visual_controller.gd")
## 交互控制器组件脚本（按F交互/提示弹窗）
const _InteractionControllerScript: GDScript = preload("res://modules/units/scripts/entity/interaction_controller.gd")
## 头顶血条组件脚本（受击后显示 HP，满血隐藏）
const _HealthBarScript: GDScript = preload("res://modules/stick_rig/api.gd").HEALTH_BAR_SCRIPT
## 蓄力轨迹预览组件脚本（拉弓/投矛抛物线预测点、杖落点 AOE 圈）
const _AimPreviewScript: GDScript = preload("res://modules/units/scripts/entity/aim_trajectory_preview.gd")
## 运动助手脚本（移动/分离/加减速，方法体所在）
const _MotionScript: GDScript = preload("res://modules/units/scripts/entity/entity_motion.gd")
## User Control 输入助手脚本（玩家控制，方法体所在）
const _UserControlScript: GDScript = preload("res://modules/units/scripts/entity/entity_user_control.gd")
## 缩放/骨架同步助手脚本（渲染判定缩放/markers 同步，方法体所在）
const _ScaleRigScript: GDScript = preload("res://modules/units/scripts/entity/entity_scale_rig.gd")
## 回血助手脚本（接管慢回/脱战回血，方法体所在）
const _RegenScript: GDScript = preload("res://modules/units/scripts/entity/entity_regen.gd")
## 朝向助手脚本（翻面节流/滞回/战斗朝向锁/瞄准俯仰，方法体所在）
const _FacingScript: GDScript = preload("res://modules/units/scripts/entity/entity_facing.gd")
## 死亡与受击助手脚本（死亡收口/尸体/遗物/受击反馈，方法体所在）
const _DeathScript: GDScript = preload("res://modules/units/scripts/entity/entity_death.gd")
## 个体装备记录生成器（spawn 按兵种建档；显式 preload 防 headless class_name 未注册）
const _EntityLoadoutScript: GDScript = preload("res://modules/units/scripts/entity/entity_loadout.gd")
## LOD 分档助手脚本（表现层性能分档，方法体所在）
const _LodScript: GDScript = preload("res://modules/units/scripts/entity/entity_lod.gd")
## 数值校准助手脚本（BalanceConfig 兵种/移动调参，方法体所在）
const _TuningScript: GDScript = preload("res://modules/units/scripts/entity/entity_tuning.gd")
## 批模拟内核类型经 combat api 契约出口引用（禁直连 class_name BattleSim，
## 重命名即静默断多处——见 audit §4.3）
const ScriptBattleSim := preload("res://modules/combat/api.gd").BATTLE_SIM_SCRIPT

# ─────────────────────────────── @export ────────────────────────────────
## 是否被玩家接管（true=玩家控制，false=AI 控制）
@export var user_controlled: bool = false:
	set(v):
		user_controlled = v
		_on_user_control_changed(v)

## 兵种数据 ID（对齐 config/units/stickmen.tres 的行 id；默认平原步兵）
@export var stickman_def_id: String = "stm_plain_001"

## 在飞箭矢伤害估计（11d MissingArrowsTolerance 消费口径）：WeaponMount 发射
## 箭矢时累加满伤害，箭矢终态（命中/插地）扣减——行为层据此避免对将死目标浪费箭。
## 估计口径允许偏差（箭可能命中非登记目标）。
## 状态承载在 IncomingThreatLedger（与 arrow_threat_time 同账本），此为兼容委托。
var incoming_arrow_damage: float:
	get: return _threat_ledger.incoming_arrow_damage
	set(value): _threat_ledger.incoming_arrow_damage = value

## 箭矢威胁账本（在飞伤害估计 + 威胁时刻，语义方法见 IncomingThreatLedger）
var _threat_ledger := IncomingThreatLedger.new()

## 移动加速度（px/s²）
@export var accel: float = 600.0
## 减速度（px/s²）
@export var decel: float = 800.0

# ─────────────────────────────── 地面约束（§7.1.1）────────────────────────────────
## 地面线 Y（由 MapInstance.spawn_entity 注入，火柴人可走区域顶部）
var ground_y: float = 450.0
## 地面底部 Y（火柴人可走区域底部，= ground_y + DESIGN_HEIGHT * ground_ratio）
var ground_bottom: float = 882.0
## 地面约束口径：false = 2D 图口径（origin=髋、脚在 origin+foot_offset，
## 约束面内收 foot_offset）；true = origin 空间直用（HD-2D 图：视觉脚线=origin，
## 传来的 [ground_y, ground_bottom] 即行走带本身——再内收会让角色走进
## 建筑带身后，视觉被楼卡遮挡、青箱与蓝带整体脱钩，创始人 2026-09-15）
var _ground_constraints_origin_space: bool = false
## X 活动范围左边界（由 MapInstance 注入）
var map_left: float = 0.0
## X 活动范围右边界（由 MapInstance 注入）
var map_right: float = 8192.0
## 脚部到节点原点的 Y 偏移（_ready 从模型 marker 动态计算 × body_scale——
## 9q：缩放单位（如 minidon 0.65×）的脚必须随体型上移，否则悬空 ≈0.35×脚距。
## 基准值存 _foot_offset_base，_apply_scale 时重算；全部消费点（地面带约束/
## 出生日/存档对齐）直接读本字段即得缩放后真值）
var foot_offset: float = 45.0
## foot_offset 基准值（body_scale=1.0 时的脚距，_ready 计算一次）
var _foot_offset_base: float = 45.0

# ─────────────────────────────── 地图引用（§7.1.2）────────────────────────────────
## 地图引用（供地形倍率/交互/脱困查询，由 VillageMap.spawn_entity 注入）
var _map_ref: Node2D = null
## 地图方法存在性缓存（注入时确定，生命周期内不变）：分离查询/地形倍率每物理帧
## 都要走 has_method 字符串反射，大群单位下是纯浪费——注入时查一次记布尔
var _map_has_query: bool = false
var _map_has_terrain_mult: bool = false

# ─────────────────────────────── AI 移动（§7.1 / §7.2）────────────────────────────────
## AI 控制器引用（_ready 时自动获取子节点）
var _ai_controller: Node = null
## AI 设定的移动方向（归一化），由 ai_move() 设置
var _ai_move_dir: Vector2 = Vector2.ZERO
## AI 是否要求奔跑
var _ai_running: bool = false
## BattleSim 批模拟注册（D 刀：参战 AI 单位模拟状态出节点树）。
## 非 null 时本实体的移动/分离/边界/冷却/命中时序由 sim 批处理，
## 实体降级为渲染/受击代理（_physics_process 跳过 move_and_slide 等）。
var _sim: ScriptBattleSim = null
## 本实体在 sim SoA 里的下标（<0 = 未注册）
var _sim_sid: int = -1
## Construction 模块 API 引用（由 GameRoot spawn 时注入的是 ConstructionApi 实例，供 AIController 查询派工；可能为 null）
var _construction_manager: Node = null

# ─────────────────────────────── 战斗（§7.1 / §8）────────────────────────────────
## 阵营 ID（0=未参战，1/2=敌对双方，由 BattleInstance 分配）
var faction_id: int = 0
## 军衔（现实军衔体系数据层；任命链 formation 侧写、渲染方经血条消费）：
##   0 = 士兵（大头兵，默认）
##   1 = 班长（战术轮转层：阵亡免费无缝继任，军衔点跟职务走）
##   2 = 排长（指挥链层：阵亡无法现场补员 = 持续指挥链缺口）
##   2 = 排长（编制最高现役层；旧 rank 3 战场指挥官随摆场件根除，2026-10-14）
## 消费方：血条军衔点渲染（set_rank 已做转发挂点，渲染侧未接线时静默跳过）。
var rank: int = 0
## 所属战斗实例引用（null=未参战）
var _battle_instance: Node = null
## 固体互撞层脏标记（set_battle_instance 时强制下一拍重算一次）
var _solid_mask_dirty: bool = true
## 最后一次被敌方箭矢瞄准的时刻（s，Time.get_ticks_msec 换算；-999=无威胁）。
## 由 WeaponMount._fire_arrow 出弓瞬间写入**目标**实体，供矛兵举盾感知
## （SWL SpeartonAi.IsAnyArrowThreat / _lastArrowThreatTime 直译）。
## 状态承载在 _threat_ledger，此为兼容委托（duck-typing 协议不变）。
var arrow_threat_time: float:
	get: return _threat_ledger.arrow_threat_time
	set(value): _threat_ledger.arrow_threat_time = value

## 正在被治疗截止时刻（s，Time.get_ticks_msec 换算；-1e9=无）。
## A9 · R5 防扎堆治疗（RWR consider_someone_already_healing_wounded_distance
## 同构）：治疗方施放 HOT 时写入**目标**实体，TargetFinder.find_weakest_ally
## 据此跳过"已有祭司在治"的伤员——多个治疗者不扎堆同一目标。
var being_healed_until: float = -1.0e9

# ─────────────────────────────── 编队角色（编制预设派生）────────────────────────────────
## 角色类型（fighter/builder/worker，由编队预设写入，仅展示/标记；
## 行为限制由所属编队的职责范围决定，见 FormationSystem.is_work_allowed）
var role: String = ""
## FormationSystem 引用（由 GameRoot spawn 时注入，供 AIController 查询队伍职责；可能为 null）
var _formation_system: Node = null

# ─────────────────────────────── 职业（小镇生活，town_life 模块写入）────────────────────────────────
## 职业 id（initial_content spawn 时经 TownLifeAPI 分配写入；
## 空串 = 待业/无职业，非空 = 在职。契约见 modules/town_life/api.gd——
## 实体侧只存弱类型 id，职业语义（档案/着装/工位）全部归 town_life 模块）
var _profession_id: String = ""
## 村民身份标志（小镇生活批次 4）：initial_content.spawn_npcs 对村民置 true。
## 与职业解耦——待业村民（职业空串）与征用离岗村民都仍是"村民"；
## 战斗/敌方单位不置此标志，AI 侧行为过滤（wander 作用域等）靠它区分
## "待业村民"与"无职业战斗单位"（二者职业都是空串，行为语义相反）。
var is_villager: bool = false

# ─────────────────────────────── 运行时 ────────────────────────────────
## StickmanRig 引用（渲染骨架）；HD-2D 图为 null（视觉走 billboard 唯一骨架）
var rig: Node2D = null
## 本实体在 HD-2D 图上：2D 画布视觉链路已删除，渲染全部走 billboard
var _billboard_visual: bool = false
## IK markers 父节点引用
var _markers_parent: Node2D = null
## 当前速度（标量，px/s）
var _current_speed: float = 0.0
## 是否在奔跑
var _is_running: bool = false
## 是否处于搬运状态（搬运工持物，walk 切换为 walk_carry 动画）
var _carrying: bool = false
## 动作动画锁定（如 build 敲击），锁定时 _play_anim 不切换动画
## （由 visual_controller 跨脚本读写，故加忽略）
@warning_ignore("unused_private_class_variable")
var _action_locked: bool = false
## 玩家按F建造的动画计时器（>0 表示正在播放 build 动画）
var _player_build_timer: float = 0.0
## 朝向（1=右，-1=左）。翻面节流/滞回/战斗朝向锁逻辑在 entity_facing.gd
##（节流态随迁助手）；本字段多处直读（受击方向判定/渲染缩放）故留本类
var _facing: int = 1
## 当前动画名
var _current_anim: String = "idle"
## 散步模式（true=只走不跑，按 Alt 切换）
var _walk_only: bool = false

# ─────────────────────────────── 受击反馈（近战打击感）────────────────────────────────
## 击退冲量速度（受击时注入，随帧衰减）。冲量写入与红闪逻辑在 entity_death.gd，
## 衰减在宿主物理帧（get_knockback_velocity 消费 + tests/dev 基准直写相关字段）
var _knockback_velocity: Vector2 = Vector2.ZERO
## 受击硬直剩余时间（秒，>0 时 AI 停止行动；行业最佳实践 hit stun；
## 时长常量与写入在 entity_death.gd）
var _hit_stun_timer: float = 0.0
## 兵种移速倍率（WeaponMount 按行为档案 move_mult 写入：SWL 兵种机动性差异——
## Swordwrath 轻快 1.3×、Spearton 沉稳 0.85×，全员同速 = 没有兵种机动性）
var move_speed_mult: float = 1.0
## 护甲移速乘子（背包装备系统写入：三件 speed_penalty 乘积；1.0 = 无护甲）
var armor_speed_factor: float = 1.0
## 护甲减伤率（背包装备系统写入：三件 damage_reduction 加和，封顶 0.6）。
## DamagePipeline 单位类型减伤段经 get_armor_factor() 消费
var armor_damage_reduction: float = 0.0
## 个体属性标签（GDD §6.1 世界盒子式：影响适合的工作与战斗行为；
## 出生掷骰 基础10±3，行为消费按批次接线）。键：str/int/agi/cft/cmd
var attributes: Dictionary = {}
## 体型缩放倍率（SWL minidon 召唤护卫比常规兵种小一圈；1.0 = 正常体型）。
## 影响 rig 渲染 + Collider/Range/Hitbox 判定 + 血条高度，经 set_body_scale 设置。
var body_scale: float = 1.0
## 尸体停留/淡出时长常量与淡出驱动在 entity_death.gd（tick_corpse）；
## 计时字段留本类（tests/dev 基准经 Node.set 直写）
## 尸体淡出计时（<0 = 未启动；死亡碰撞禁用后置 CORPSE_LIFETIME）
var _corpse_fade_timer: float = -1.0
## 最近受击时刻（ms，脱火恢复判定；回血常量在 entity_regen.gd）
var _last_hit_ms: int = -999999
## 脱战回血/接管回血常量与结算在 entity_regen.gd
## 死亡后 Collider 禁用倒计时（s；-1=已禁用/未死。在 _physics_process 死亡分支计时，
## 替代 SceneTreeTimer lambda——清场竞态下 lambda 捕获失效报错）
var _dead_disable_timer: float = -1.0
## 分离扫描帧计数（O(n²) 扫描隔物理帧跑，帧率优化）
var _sep_frame_counter: int = 0
## AI 半频节拍计数与相位（0/1 错开均摊负载）；分离扫描节流分频——
## 60Hz 物理下隔帧（=30Hz），30Hz 物理下逐帧（维持有效频率）
var _ai_tick_counter: int = 0
var _ai_phase: int = 0
var _ai_rate_div: int = 2
var _sep_rate_div: int = 2
## 分离扫描相位（实例奇偶——批3 错峰：扫描帧按奇偶错开，全场不同刻同拍）
var _sep_phase: int = 0

# ─────────────────────────────── 群体分离（防叠人/1字长蛇）────────────────────────────────
## 分离检测半径（真身与推力参数在 entity_motion.gd；bench_units_main.gd 直读本壳）。
const SEPARATION_RADIUS: float = preload("res://modules/formation/api.gd").SEPARATION_RADIUS
## 头顶血条组件引用（_mount_components 装配）
var _health_bar: Node = null

# ─────────────────────────────── 战斗组件引用（§7.1）────────────────────────────────
@onready var health_component: Node = get_node_or_null("HealthComponent")
@onready var hitbox: Area2D = get_node_or_null("Hitbox")
@onready var weapon_mount: Node2D = get_node_or_null("WeaponMount")

# ─────────────────────────────── 子组件引用 ────────────────────────────────
## 视觉控制器（动画播放/头顶进度条，_ready 装配）
var _visual: Node = null
## 交互控制器（按F交互/提示弹窗，_ready 装配）
var _interaction: Node = null
## 运动助手（移动/分离/加减速方法体所在）
var _motion: RefCounted = null
## User Control 输入助手（玩家控制方法体所在）
var _user_control: RefCounted = null
## 蓄力轨迹预览（拉弓/投矛期间的抛物线预测点；_ready 装配，隐藏待命）
var _aim_preview: Node2D = null
## 缩放/骨架同步助手（渲染判定缩放/markers 同步方法体所在）
var _scale_rig: RefCounted = null
## 回血助手（接管慢回/脱战回血方法体所在）
var _regen: RefCounted = null
## 朝向助手（翻面节流/滞回/战斗朝向锁/瞄准俯仰方法体所在）
var _facing_helper: RefCounted = null
## 死亡与受击助手（死亡收口/尸体/遗物/受击反馈方法体所在）
var _death: RefCounted = null
## LOD 分档助手（表现层性能分档方法体所在）
var _lod: RefCounted = null
## 数值校准助手（BalanceConfig 兵种/移动调参方法体所在）
var _tuning: RefCounted = null


func _init() -> void:
	# 子域助手注入（_init 注入防 spawn 侧 add_child 前调用撞 null）
	_motion = _MotionScript.new(self)
	_user_control = _UserControlScript.new(self)
	_scale_rig = _ScaleRigScript.new(self)
	_regen = _RegenScript.new(self)
	_facing_helper = _FacingScript.new(self)
	_death = _DeathScript.new(self)
	_lod = _LodScript.new(self)
	_tuning = _TuningScript.new(self)


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _enter_tree() -> void:
	# 禁用 RigHost 上的 stickman_test.gd 脚本，阻止其 _ready/_process/_input 运行
	# 必须在 _ready 之前完成
	var rig_host := get_node_or_null("RigHost")
	if rig_host != null and rig_host.get_script() != null:
		rig_host.set_script(null)


## 玩家按 Alt 切换散步/奔跑模式（仅 User Control 时生效）
## Q 键切换建造/战斗模式（仅 User Control 时生效）
## 键判定走 InputBindings 动作表（is_action_pressed 默认过滤键盘重复）
## 鼠标攻击/举盾在 _unhandled_input（GUI 优先：点 UI 控件的事件到不了游戏侧，
## 无需 hovered 让路补丁——该补丁依赖 hover 缓存时序，建造菜单按钮曾被误吞）
func _input(event: InputEvent) -> void:
	if not user_controlled:
		return
	if event.is_action_pressed("user_control/toggle_walk_run"):
		_walk_only = not _walk_only
		if _walk_only and _is_running:
			_is_running = false
			_current_speed = WALK_SPEED
			_visual.play("walk")
	elif event.is_action_pressed("user_control/toggle_combat"):
		_toggle_combat_mode()
	elif event.is_action_pressed("user_control/swing"):
		# 空挥（复刻原版 User Control）：无目标也出攻击动作，纯动作无伤害
		_user_control._player_swing()
		if get_viewport() != null:
			get_viewport().set_input_as_handled()


func _ready() -> void:
	# 个体属性出生掷骰（基础 10 ± 3；行为/AI 消费按批次接线）
	if attributes.is_empty():
		attributes = {
			"str": 7 + randi() % 7,
			"int": 7 + randi() % 7,
			"agi": 7 + randi() % 7,
			"cft": 7 + randi() % 7,
			"cmd": 7 + randi() % 7,
		}
	# 先拿到 StickmanRig 和 IK markers 引用——必须在 _mount_components 之前：
	# VisualController.setup 连接 rig.animation_finished（攻击播完回切），
	# 顺序颠倒时 rig 为 null，连接静默丢失（曾致攻击动画播完永不回切）
	# HD-2D 图（视觉唯一骨架方向）：实体不建 2D 骨架树——billboard 自带骨架
	# 是唯一视觉骨架；脚偏移仍按 marker 实算（骨架树帧末才释放），数值不变
	var hd_map: Node = null
	var map_parent: Node = get_parent()
	if map_parent != null:
		hd_map = map_parent.get_parent()
	var rig_host := get_node_or_null("RigHost")
	if hd_map != null and hd_map.has_method("uses_billboard_visuals") 			and hd_map.uses_billboard_visuals():
		_billboard_visual = true
	if not _billboard_visual and rig_host != null:
		rig = rig_host.get_node_or_null("OutlineGroup/StickmanRig")
		_markers_parent = rig_host.get_node_or_null("OutlineGroup/Node2D")
	# 装配子组件（VisualController / InteractionController）
	_mount_components()
	# 状态效果组件（SWL ApplyBurn/... + legend 状态 System 最小集：BURN/POISON/SLOW/STUN）
	_status_effects = get_node_or_null("StatusEffects")
	if _status_effects == null:
		var se: Node = ScriptStatusEffects.new()
		se.name = "StatusEffects"
		add_child(se)
		_status_effects = se
	# 接触阴影（Demo 打磨：脚底椭圆软阴影，Terraria 式落地感；纯视觉 z 垫底）
	if _billboard_visual:
		# 2D 骨架树帧末释放（foot_offset 已在上方按 marker 实算完毕）
		var stale_rig := get_node_or_null("RigHost")
		if stale_rig != null:
			stale_rig.queue_free()
	else:
		_scale_rig._spawn_contact_shadow()
	# 从 BalanceConfig 读取兵种数值（未命中回退 @export 默认，行为零回归；
	# 方法体在 entity_tuning.gd——兵种覆盖 + 移动/缩放校准 + static 调参缓存）
	_tuning.apply_balance_data()
	# 获取 AIController 子节点（§7.1）
	_ai_controller = get_node_or_null("AIController")
	_ai_phase = int(get_instance_id() % 2)
	_sep_phase = _ai_phase
	# 30Hz 物理刻下同样保持隔刻节流（perf/battle-30fps：反转原"降级放弃节流"分支）。
	# 60Hz 时代设计的分频在 30Hz 下若退化为 div=1，AI 行为 update（逐刻 duck-typing
	# + 目标全敌打分）与分离网格查询会全部逐刻全量跑满。div=2 时：AI 行为按 _ai_phase
	# （实例 id 奇偶）对半交错降为 15Hz，physics_update 传 delta*rate_div 倍增保持
	# 游戏时间语义不变（行为计时器均为 delta 累积）；分离扫描同步减半查询总量。
	if Engine.get_physics_ticks_per_second() < 60:
		_ai_rate_div = 2
		_sep_rate_div = 2
	# 从模型 marker 动态计算 foot_offset 基准（适配不同参考系）；
	# 实际 foot_offset = 基准 × body_scale（_apply_scale 内重算，9q）
	_foot_offset_base = _scale_rig._calculate_foot_offset()
	foot_offset = _foot_offset_base
	# 碰撞基准捕获（方法体在 entity_scale_rig.gd；时序：foot_offset 后、_apply_scale 前）
	_scale_rig._capture_collision_bases()
	# 应用初始缩放
	_apply_scale()
	# 播放 idle
	_visual.play("idle")
	# 战斗组件：死亡信号连接
	if health_component != null:
		health_component.died.connect(_on_died)
		health_component.damaged.connect(_on_damaged)


# BalanceConfig 兵种数值/移动校准方法体在 entity_tuning.gd（_tuning，
# _ready 内调用；static 调参缓存随迁助手）。


## 实例化并挂载子组件（VisualController / InteractionController / HealthBar）。
## 组件通过 setup(entity) 拿到本实体引用。
func _mount_components() -> void:
	_visual = Node.new()
	_visual.set_script(_VisualControllerScript)
	_visual.name = "VisualController"
	add_child(_visual)
	if _visual.has_method("setup"):
		_visual.setup(self)

	_interaction = Node.new()
	_interaction.set_script(_InteractionControllerScript)
	_interaction.name = "InteractionController"
	add_child(_interaction)
	if _interaction.has_method("setup"):
		_interaction.setup(self)

	# 头顶血条（受击后显示，满血隐藏）
	_health_bar = Node2D.new()
	_health_bar.set_script(_HealthBarScript)
	_health_bar.name = "HealthBar"
	add_child(_health_bar)
	if _health_bar.has_method("setup"):
		_health_bar.setup(get_node_or_null("HealthComponent"))
	if _billboard_visual and _health_bar.has_method("set_crowd_data_mode"):
		# HD-2D（血条随骨架进 billboard）：2D 画布条不画——画布坐标与 3D
		# 投影纵向错开 (1-k) 倍，直绘血条悬浮在部队上方；切数据模式只产
		# 状态，宿主逐帧拉 get_bar_state() 喂 billboard 内镜像条
		_health_bar.set_crowd_data_mode(true)

	# 蓄力轨迹预览（拉弓/投矛抛物线点列、杖落点 AOE 圈；默认隐藏待命）
	_aim_preview = Node2D.new()
	_aim_preview.set_script(_AimPreviewScript)
	_aim_preview.name = "AimTrajectoryPreview"
	add_child(_aim_preview)


func _physics_process(delta: float) -> void:
	var _pt := StickProf.t0()
	_physics_tick(delta)
	StickProf.t1("实体物理", _pt)


func _physics_tick(delta: float) -> void:
	# 死亡收口（2026-08-31 审计 P0-1）：尸体没有物理帧——不跑 AI、不减速回切
	# （正是这套回切把 0.8s 死亡动画在 0.25s 内覆盖成 walk/idle，尸体"站起来"）、
	# 不做分离推挤（尸体不当墙、不滑行）、不受击退。
	if is_dead():
		# Collider 禁用计时与尸体淡出驱动在 entity_death.gd tick_corpse
		_death.tick_corpse(delta)
		_sync_markers_transform()
		return
	# 眩晕（SWL StunSystem 语义）：既不跑 AI 也不移动，瘫在原地
	if is_stunned():
		velocity = Vector2.ZERO
		_ai_move_dir = Vector2.ZERO
		_sync_markers_transform()
		return
	# 暂停冻结由引擎总闸负责（本实体 PAUSABLE：暂停期物理/AI/AnimationPlayer
	# 一并冻结——原 is_paused 自查与"暂停冻结动画"补丁随换闸删除）；
	# 步长经 sim_delta 携带速度档（AI/计时/动画节奏随档位缩放）
	if TimeManager != null:
		delta = TimeManager.sim_delta(delta)
	# y 排序（2.5D 遮挡正确性）：y 越大（屏幕越靠下=离镜头越近）z 越高——
	# 修复"远处单位身体盖住近处单位的手/武器"（此前绘制顺序=生成顺序）。
	# sim 模式由 BattleSim._write_back 批量写（与位置同一写回点），此处跳过
	if not _sim_active():
		var zi := int(global_position.y * 0.1)
		if zi != z_index:
			z_index = zi
	# 仅在被 User Control 时处理玩家输入
	if user_controlled:
		_user_control._handle_player_input(delta)
		_regen.tick_user_control_regen(delta)
	else:
		# AI 控制：先让 AIController 决策（设置 _ai_move_dir），再处理移动。
		# 战斗性能优化：AI 决策与行为状态机降到 30Hz（隔物理帧、传倍增 delta
		# 保持计时/加速度速率；移动仍逐帧平滑；相位按实例奇偶均摊负载）
		_ai_tick_counter += 1
		if _ai_controller != null and _ai_controller.has_method("physics_update") \
				and _ai_tick_counter % _ai_rate_div == _ai_phase % _ai_rate_div:
			_ai_controller.physics_update(delta * float(_ai_rate_div))
		_handle_ai_input(delta)
		# 静态分离（soft-body 位置互推）已随固体碰撞语义退役（裁决#40b：
		# 任何单位不被其他单位位移）。非 sim 战斗的"不穿人"由本体的单位层
		# 物理互撞承担（_update_solid_collision_mask：battle 期 mask 开单位层，
		# move_and_slide 贴边停/滑动；聚落期关闭保持原软分离观感）。
		if not _sim_active():
			_update_solid_collision_mask()

	if _sim_active():
		# sim 模式：移动/分离/边界/击退衰减/z_index 全由 BattleSim 批处理；
		# 实体只保留 AI 决策节流（上方）+ 意图速度标量/动画（_handle_ai_input→
		# _apply_movement 末尾写 sim）+ 硬直/markers。
		_regen.tick_rest_hp_recovery(delta)
		if _hit_stun_timer > 0.0:
			_hit_stun_timer = maxf(0.0, _hit_stun_timer - delta)
		_sync_markers_transform()
		# 玩家建造动画计时（按F敲击后 1.8 秒解除动作锁定）——接管单位不入 sim，
		# 此分支实际不可达；保留判定防未来注册口径变化时漏计时
		if _player_build_timer > 0.0:
			_player_build_timer -= delta
			set_action_progress(1.0 - _player_build_timer / 1.8)
			if _player_build_timer <= 0.0:
				_player_build_timer = 0.0
				hide_action_progress()
				clear_action()
		return

	# 火柴人可在地面范围内上下左右移动（详见 §7.1.1）
	velocity += _knockback_velocity
	# 零位移早退（perf/battle-30fps）：移动速度与击退速度都≈0（上行为二者合成，
	# 合成后≈0 即两者都≈0）时跳过 move_and_slide——CharacterBody2D 即便零位移
	# 也要付一次 body_test_motion 碰撞查询，而全工程无 is_on_floor/is_on_wall
	# 消费（查询结果无人读），满编 96 单位逐刻白付纯属浪费；站位由下方 Y/X clamp
	# 与静态分离位置修正维持，减速停止由 _apply_movement 显式写 velocity 完成。
	# 击退中合成速度非零，照常执行。
	if not velocity.is_zero_approx():
		# 倍速作用于位移积分（暂停原语化）：放大合成速度=放大本帧步长
		# （move_and_slide 为扫掠检测，步长放大不隧穿）；积分后还原语义速度，
		# 下帧由 AI/输入路径重新赋值
		var prev_velocity := velocity
		if TimeManager != null:
			velocity = prev_velocity * TimeManager.speed_factor()
		move_and_slide()
		velocity = prev_velocity
	# 脱战回血（9j）：脱离火线 5s 后 HP 缓慢恢复（上限 25% max_hp；接管单位走接管慢回）
	_regen.tick_rest_hp_recovery(delta)
	# 击退冲量衰减（衰减常量在 entity_death.gd，与 battle_sim.KNOCKBACK_DECAY 同值纪律）
	if _knockback_velocity != Vector2.ZERO:
		var kb_len: float = _knockback_velocity.length()
		var dec: float = _DeathScript.KNOCKBACK_DECAY * delta
		if kb_len <= dec:
			_knockback_velocity = Vector2.ZERO
		else:
			_knockback_velocity = _knockback_velocity.normalized() * (kb_len - dec)
	# 受击硬直计时递减
	if _hit_stun_timer > 0.0:
		_hit_stun_timer = maxf(0.0, _hit_stun_timer - delta)
	# Y 范围约束：脚部保持在 [ground_y, ground_bottom] 内（口径见
	# _ground_constraints_origin_space 注——HD-2D 图直用，2D 图内收 foot_offset）
	var y_min: float = ground_y if _ground_constraints_origin_space else ground_y - foot_offset
	var y_max: float = ground_bottom if _ground_constraints_origin_space else ground_bottom - foot_offset
	global_position.y = clampf(global_position.y, y_min, y_max)
	# X 边界约束
	global_position.x = clampf(global_position.x, map_left, map_right)
	_sync_markers_transform()
	# 玩家建造动画计时（按F敲击后 1.8 秒解除动作锁定）
	if _player_build_timer > 0.0:
		_player_build_timer -= delta
		set_action_progress(1.0 - _player_build_timer / 1.8)
		if _player_build_timer <= 0.0:
			_player_build_timer = 0.0
			hide_action_progress()
			clear_action()
	# 玩家交互提示（靠近仓库/工地时显示）
	_interaction.update_hint()
	# 按住 E 连续采集（动作锁解除后自动续作）
	if user_controlled:
		_interaction.try_hold_interact()


# ─────────────────────────────── 玩家输入（按F / H 由交互控制器处理）────────────────────────────────

## 玩家 User Control 时按F：交互（取放材料 / 敲击建造，实现见 InteractionController）。
## 按H：脱离卡死。键位走 InputMap action（user_control/interact / user_control/escape_stuck）。
## 鼠标左键攻击（§7.5；按下/松开两态走蓄力状态机）、右键举盾同在此层：
## GUI（mf=STOP 控件）优先消费鼠标——点建造菜单/编制按钮的事件到不了这里，
## 不再需要 hovered 让路补丁。攻击消费后 set_input_as_handled，挡住同层的
## 相机拖动（world/drag 同为左键，"空地拖移"注释本就要求攻击优先消费）。
func _unhandled_input(event: InputEvent) -> void:
	if not user_controlled:
		return
	if event.is_action_pressed("user_control/interact"):
		_interaction.try_interact()
	elif event.is_action_pressed("user_control/escape_stuck"):
		escape_stuck()
	elif event is InputEventMouseButton and event.is_action_pressed("user_control/attack"):
		# 玩家按下：按武器分流（弓/矛/杖蓄力，近战直接攻击）
		_user_control._player_attack_press()
		if get_viewport() != null:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.is_action_released("user_control/attack"):
		# 玩家松开：蓄力收口（放箭/投矛/施法；非蓄力态静默）
		_user_control._player_attack_release()
		if get_viewport() != null:
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton \
			and (event.is_action_pressed("user_control/block") or event.is_action_released("user_control/block")):
		# 副手盾：按住右键举盾、松开放下
		_user_control._set_player_blocking(event.pressed)
		if event.pressed:
			get_viewport().set_input_as_handled()


# ─────────────────────────────── 玩家输入 ────────────────────────────────

## 护甲减伤余率（DamagePipeline 消费：0.82 = 三件锁子减伤 18%）。
func get_armor_factor() -> float:
	return 1.0 - clampf(armor_damage_reduction, 0.0, 1.0)


# ─────────────────────────────── AI 输入处理 ────────────────────────────────

## AI 驱动移动（方法体在 entity_motion.gd；bench_units_main.gd 直呼本壳，契约保持）。
func _handle_ai_input(delta: float) -> void:
	_motion._handle_ai_input(delta)


## 获取头顶血条组件（供测试/调试）
func get_health_bar() -> Node:
	return _health_bar


## 统一移动处理（方法体在 entity_motion.gd；user_control 经实体回引共用的入口）。
func _apply_movement(delta: float, dir: Vector2, run: bool, allow_run: bool) -> void:
	_motion._apply_movement(delta, dir, run, allow_run)


# ─────────────────────────────── 渲染同步 ────────────────────────────────

## 渲染/判定缩放应用（方法体在 entity_scale_rig.gd；翻面/foot_offset 重算联动）。
func _apply_scale() -> void:
	_scale_rig._apply_scale()


## 设置体型缩放（方法体在 entity_scale_rig.gd；behavior_attack 与 tests/dev duck 调用）。
func set_body_scale(v: float) -> void:
	_scale_rig.set_body_scale(v)


## markers 变换同步（方法体在 entity_scale_rig.gd；bench_units_main.gd 直呼本壳）。
func _sync_markers_transform() -> void:
	_scale_rig._sync_markers_transform()


# ─────────────────────────────── 动画 API（转发到 VisualController）────────────────────────────────

## 设置搬运状态：搬运工持物时 walk 切换为 walk_carry 动画。
## 由 BehaviorHaul 在 enter/exit 时调用。
func set_carrying(v: bool) -> void:
	_visual.set_carrying(v)


## 是否处于搬运状态（供交互/UI 查询，2026-08 收敛：替代组件直读 _carrying 私有字段）
func is_carrying() -> bool:
	return _carrying


## 设置玩家建造敲击计时（交互控制器触发敲击时调用，替代组件直写私有字段）
func set_player_build_timer(v: float) -> void:
	_player_build_timer = v


## 锁定动作动画（如 build 敲击），锁定期间动画不切换。
## 由 BehaviorWork 在工地播放建造动画时调用。
func set_action_anim(anim_name: String) -> void:
	_visual.set_action_anim(anim_name)


## 解除动作锁定，恢复正常动画（根据当前速度切 walk/idle）。
func clear_action() -> void:
	_visual.clear_action()


## 设置头顶动作进度（0~1，>0 显示，0 隐藏）。由 BehaviorHaul/BehaviorWork/玩家调用。
func set_action_progress(ratio: float) -> void:
	_visual.set_progress(ratio)


## 隐藏头顶动作进度条。
func hide_action_progress() -> void:
	_visual.hide_progress()


## 当前动作进度观测口（0~1；-1 = 无进行中动作）。HD-2D billboard 镜像逐帧
## 读取（街上 2D 进度条随 RigHost 隐藏，劳作可视化走 billboard 自带 3D 条）。
func get_action_progress() -> float:
	return _visual.get_progress_value() if _visual != null else -1.0


## 获取当前动画名
func get_current_anim() -> String:
	return _current_anim


# ─────────────────────────────── 玩家战斗模式（Q 键切换）────────────────────────────────

## 切换建造/战斗模式（方法体在 entity_user_control.gd；test_combat_control.gd 无守卫直呼）。
func _toggle_combat_mode() -> void:
	_user_control._toggle_combat_mode()


## 获取所在地图引用（可能为 null，供 AI 行为查询玩家等）。
func get_map() -> Node2D:
	return _map_ref


# ─────────────────────────────── 玩家攻击（§7.5）────────────────────────────────

## 玩家鼠标左键攻击（方法体在 entity_user_control.gd；test_user_control.gd 守卫调用）。
func _player_attack() -> void:
	_user_control._player_attack()


## 找最近敌人在武器射程内（方法体在 entity_user_control.gd；test_user_control.gd 守卫调用）。
func _find_nearest_enemy_in_range() -> Node:
	return _user_control._find_nearest_enemy_in_range()


## 玩家蓄力瞄准中查询（方法体在 entity_user_control.gd；hitstop 互斥/轨迹预览消费）。
func is_aim_charging() -> bool:
	return _user_control.is_aim_charging()


## 蓄力轨迹预览刷新（方法体在 entity_user_control.gd 每帧调用；按武器分流：
## 弓/矛=抛物线预测点列，杖=鼠标落点 AOE 圈）。
func update_charge_preview(origin: Vector2, velocity: Vector2) -> void:
	if _aim_preview == null or not is_instance_valid(_aim_preview):
		return
	var wt: int = -1
	if weapon_mount != null and "weapon_type" in weapon_mount:
		wt = int(weapon_mount.weapon_type)
	if wt == 4:
		if weapon_mount.has_method("get_spell_aoe_radius"):
			_aim_preview.set_spell_aoe(get_global_mouse_position(),
					weapon_mount.get_spell_aoe_radius())
	elif wt == 2 or wt == 1:
		var g: float = weapon_mount.get_charge_gravity() if weapon_mount.has_method("get_charge_gravity") else 2000.0
		_aim_preview.set_trajectory(origin, velocity, g)


## 隐藏蓄力预览（松手出手/取消接管路径统一收口）
func hide_charge_preview() -> void:
	if _aim_preview != null and is_instance_valid(_aim_preview):
		_aim_preview.set_trajectory_active(false)


# ─────────────────────────────── 接管增益（SWL Unit 真值）────────────────────────────────
# 接管慢回与脱战回血的常量/结算在 entity_regen.gd（_regen）；物理帧调用点
# 在 _physics_tick（sim 分支与常规分支）。


# ─────────────────────────────── 公共 API ────────────────────────────────

## 由 MapInstance.spawn_entity 调用，注入地面约束参数（§7.1.1）
func set_ground_constraints(p_ground_y: float, p_ground_bottom: float, p_map_left: float, p_map_right: float, p_origin_space: bool = false) -> void:
	ground_y = p_ground_y
	ground_bottom = p_ground_bottom
	map_left = p_map_left
	map_right = p_map_right
	# 口径翻转时重摆物理脚印：注入发生在 add_child 之后（_ready 已跑过，
	# Collider 当时按默认 2D 口径摆）——origin 空间须把箱挪回脚线
	var flag_changed: bool = _ground_constraints_origin_space != p_origin_space
	_ground_constraints_origin_space = p_origin_space
	if flag_changed:
		_apply_scale()


## 由 MapInstance.spawn_entity 调用，注入地图引用（供通行障碍查询，§7.1.2）
func set_map_reference(p_map: Node2D) -> void:
	_map_ref = p_map
	# 方法存在性随注入的地图而定 → 注入时查一次记布尔，免每物理帧 has_method 反射
	_map_has_query = p_map != null and p_map.has_method("query_neighbors")
	_map_has_terrain_mult = p_map != null and p_map.has_method("get_move_speed_mult_at_x")


## 物理查询：实体的 Collider 形状位于 pos 时是否与任何物理体（建筑/工地障碍/其他实体）碰撞。
## 排除自身（否则查询自己的位置永远命中自己）。用于脱困采样判定与测试。
func is_position_blocked(pos: Vector2) -> bool:
	var col := get_node_or_null("Collider") as CollisionShape2D
	if col == null or col.shape == null:
		return false
	var space := get_world_2d().direct_space_state
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = col.shape
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [get_rid()]
	query.transform = Transform2D(0.0, pos)
	return not space.intersect_shape(query, 1).is_empty()


## 脱离卡死（H 键 / HUD 脱困按钮）：随机传送到附近空旷地带。
## 以当前位置为中心，半径 200px 起随机采样（每圈 24 次），用物理查询
## 判定空旷（is_position_blocked）；逐级扩大到 3200px；仍找不到则沿左右
## 线性扫描最近空旷点；兜底回地图中心。只动 X（Y 由地面约束管理）。
func escape_stuck() -> void:
	if _map_ref == null or not is_instance_valid(_map_ref):
		return
	var world_left: float = float(_map_ref.map_left) if "map_left" in _map_ref else -100000.0
	var world_right: float = float(_map_ref.map_right) if "map_right" in _map_ref else 100000.0
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var radius: float = 200.0
	var found: bool = false
	while radius <= 3200.0 and not found:
		for attempt in range(24):
			var probe_x: float = global_position.x + rng.randf_range(-radius, radius)
			probe_x = clampf(probe_x, world_left + 50.0, world_right - 50.0)
			if not is_position_blocked(Vector2(probe_x, global_position.y)):
				global_position.x = probe_x
				found = true
				break
		radius *= 2.0
	# 随机采样未命中（密集建筑区）：沿左右线性扫描最近的空旷点
	if not found:
		for step in range(20, 4001, 20):
			for s in [-1.0, 1.0]:
				var probe_x: float = global_position.x + s * step
				probe_x = clampf(probe_x, map_left + 50.0, map_right - 50.0)
				if not is_position_blocked(Vector2(probe_x, global_position.y)):
					global_position.x = probe_x
					found = true
					break
			if found:
				break
	if not found:
		global_position.x = (map_left + map_right) * 0.5


## 切换 User Control 状态
func set_user_controlled(p: bool) -> void:
	user_controlled = p


func is_user_controlled() -> bool:
	return user_controlled


## BattleSim 注册注入（BattleInstance.add_unit 调用；sid<0 = 注册失败/未启用）。
func set_battle_sim(sim: ScriptBattleSim, sid: int) -> void:
	_sim = sim
	_sim_sid = sid if sim != null else -1


func get_battle_sim() -> ScriptBattleSim:
	return _sim


func get_battle_sim_sid() -> int:
	return _sim_sid


## sim 是否接管本实体（注册有效且实体未死亡——死亡刻起交还实体死亡分支）
func _sim_active() -> bool:
	return _sim != null and _sim_sid >= 0 and not is_dead()


## 获取朝向
func get_facing() -> int:
	return _facing


## 是否在 billboard 视觉图上（HD-2D：2D 骨架树已删，crowd 2D 代理不适用）
func is_on_billboard_map() -> bool:
	return _billboard_visual


func _on_user_control_changed(p: bool) -> void:
	# 接管时交还 sim（玩家输入直驱旧实体链——sim 只服务 AI 单位）
	if p and _sim != null and _sim_sid >= 0:
		_sim.unregister_unit(self)
		_sim = null
		_sim_sid = -1
	# 接管时退出小兵渲染代理（玩家身体必须富管线：unregister 内部
	# 解 hook 恢复 rig 可见 + 武器 reparent 回手骨）
	if p and has_meta("crowd_slot"):
		var slot: Dictionary = get_meta("crowd_slot")
		var crowd = slot.get("renderer")
		if crowd != null:
			var crowd_obj = crowd.get_ref() if crowd is WeakRef else crowd
			if crowd_obj != null:
				crowd_obj.call("unregister_unit", slot)
		remove_meta("crowd_slot")
	# 接管切换时重置速度，避免残留
	if not p:
		_current_speed = 0.0
		_is_running = false
		velocity = Vector2.ZERO
		# 退出接管强制收口蓄力态
		_user_control.cancel_charge()
		hide_charge_preview()
	# 取消 User Control 时也清除 AI 移动方向，避免残留
	_ai_move_dir = Vector2.ZERO
	_ai_running = false


# ─────────────────────────────── AI 移动接口（供 AIController / behavior 调用）────────────────────────────────

## AI 设定移动方向。dir 应为归一化向量，run=true 强制奔跑。
func ai_move(dir: Vector2, run: bool = false) -> void:
	_ai_move_dir = dir
	_ai_running = run


## AI 停止移动。
func ai_stop() -> void:
	_ai_move_dir = Vector2.ZERO
	_ai_running = false


## 获取 AIController 引用（可能为 null）。
func get_ai_controller() -> Node:
	return _ai_controller


## 由 GameRoot spawn 时注入 ConstructionApi 引用（供 AIController 查询派工）
func set_construction_manager(manager: Node) -> void:
	_construction_manager = manager
	# 把 NPC 注册为可派工工人（api.gd 已转发 register_worker）
	if manager != null and manager.has_method("register_worker"):
		manager.register_worker(self)


## 获取 ConstructionApi 引用（可能为 null）
func get_construction_manager() -> Node:
	return _construction_manager


## 销毁时反注册派工池，防止悬垂引用（2026-08 收敛）
func _exit_tree() -> void:
	if _construction_manager != null and is_instance_valid(_construction_manager) \
			and _construction_manager.has_method("unregister_worker"):
		_construction_manager.unregister_worker(self)
	_construction_manager = null
	# sim 注销（尸体淡出 queue_free / 清场释放的统一出口；sim 侧清 strike 槽与引用）
	if _sim != null and _sim_sid >= 0:
		_sim.unregister_unit(self)
	_sim = null
	_sim_sid = -1
	# 小兵渲染代理槽位注销（清实例段 + 解 rig hook；实体随 queue_free 释放）
	if has_meta("crowd_slot"):
		var slot: Dictionary = get_meta("crowd_slot")
		var crowd = slot.get("renderer")
		if crowd != null:
			var crowd_obj = crowd.get_ref() if crowd is WeakRef else crowd
			if crowd_obj != null:
				crowd_obj.call("unregister_unit", slot)
		remove_meta("crowd_slot")


## 由 GameRoot spawn 时注入 FormationSystem 引用（供 AIController 查询队伍职责）。
## 弱类型 Node 注入 + duck 协议，契约声明见 modules/combat/api.gd 头部"编队职责查询契约"。
## 未注入（如测试直生实体）时视为"未编队"，不限制行为。
func set_formation_system(fs: Node) -> void:
	_formation_system = fs


## 获取 FormationSystem 引用（可能为 null）
func get_formation_system() -> Node:
	return _formation_system


## 由 GameRoot spawn 时注入 OrganizationApi 引用（玩家招兵交互经它转发，
## organization/api.gd 招兵段；NPC 不注入）
var _organization_api: Node = null


func set_organization_api(api: Node) -> void:
	_organization_api = api


func get_organization_api() -> Node:
	return _organization_api


## 获取地图引用（spawn 时由 MapBase 注入；可能为 null——AI 模块读
## town_center_world_x 等聚落锚点用，见 ai_controller wander 决策）
func get_map_reference() -> Node2D:
	return _map_ref


## 个体装备记录（loadout 奠基，设计文档 10 §3.4）：{main_hand/off_hand/armor_*
## -> def_id} + 弹药 {"ammo": {def_id: count}}。spawn/读档回填时经 set_loadout
## 应用（main_hand 覆盖兵种默认 weapon_type——玩家全能换装的同一单点驱动）；
## 死亡掉落按本记录个体化生成（entity_death）。
var _loadout: Dictionary = {}


## 应用个体装备记录：main_hand 有值且是玩家可用武器 def 时覆盖 weapon_type
func set_loadout(d: Dictionary) -> void:
	_loadout = d
	var main_id: StringName = StringName(String(d.get("main_hand", "")))
	if main_id == &"":
		return
	for wt in ItemsAPI.WEAPON_ITEM_BY_TYPE:
		if ItemsAPI.WEAPON_ITEM_BY_TYPE[wt] == main_id:
			if weapon_mount != null and is_instance_valid(weapon_mount):
				weapon_mount.weapon_type = int(wt)
			return


func get_loadout() -> Dictionary:
	return _loadout


## spawn 按兵种生成个体装备记录（掉落个体化第一步；weapon_type setter 单点
## 驱动——外部 spawn 设武器即建档）。守卫：接管实体不建档（玩家装备不属于
## NPC 个体）、已有记录不覆盖（读档 set_loadout 先写档再设武器）。
func note_spawn_weapon(weapon_type: int) -> void:
	if user_controlled or not _loadout.is_empty():
		return
	var shield: bool = false
	if weapon_mount != null and is_instance_valid(weapon_mount):
		shield = bool(weapon_mount.equipped_shield) \
				or (bool(weapon_mount.shield_enabled) and weapon_type == _EntityLoadoutScript.WEAPON_TYPE_SPEAR)
	_loadout = _EntityLoadoutScript.for_spawn(weapon_type, shield)


## 写入职业 id（initial_content spawn 时经 TownLifeAPI 分配；弱类型协议，
## 契约见 modules/town_life/api.gd）。空串 = 待业——批次 4 征兵离岗走此通道。
func set_profession(id: String) -> void:
	_profession_id = id


## 获取职业 id（空串 = 待业/无职业）。
func get_profession() -> String:
	return _profession_id


## 设置角色类型（由 FormationSystem 编队时写入）。
func set_role(r: String) -> void:
	role = r


## 获取角色类型（空=未编队）。
func get_role() -> String:
	return role


# ─────────────────────────────── 战斗 API（§8）────────────────────────────────
# 死亡收口/尸体淡出/遗物/受击处理/打击感的方法体在 entity_death.gd（_death）；
# 以下为信号挂点与对外薄壳（health_component 信号连接、WeaponMount/AI duck 调用）。

## 死亡处理：停止移动、播放死亡动画、禁用受击、通知战斗实例（细则见助手）。
func _on_died() -> void:
	_death.on_died()


## 遗物容器查询（翻包交互/物理帧翻空检测消费）
func get_loot_container() -> ItemContainer:
	return _death.get_loot_container()


## 受击处理（反编译参考实装 B）：按攻击者方位 vs 自身朝向判定正面/背面，
## 触发受击插播（细则见 entity_death.gd）。
func _on_damaged(amount: float, source: Node) -> void:
	_death.on_damaged(amount, source)


## 是否处于受击硬直（>0 表示被打停中；AI 行为据此暂停行动）。
func is_in_hit_stun() -> bool:
	return _death.is_in_hit_stun()


# ─────────────────────────────── 状态效果（SWL ApplyBurn/... 直译）────────────────────────────────

## 状态效果组件缓存（_ready 装配后生命周期内不变；is_stunned 每物理帧
## 查询走缓存，免每帧 get_node 路径解析）
var _status_effects: Node = null
## 组件方法存在性缓存（首次查询记布尔）：is_stunned/_handle_acceleration 每物理帧
## 都要查 has_stun/get_speed_mult，大群单位下 has_method 字符串反射是纯浪费
var _se_has_stun: bool = false
@warning_ignore("unused_private_class_variable")
var _se_has_speed_mult: bool = false
var _se_checked: bool = false
## 战斗实例方法存在性缓存（同上，_update_solid_collision_mask 每物理帧消费）
var _battle_has_is_active: bool = false
## weapon_mount 方法/字段存在性缓存（@onready 装配后不变；举盾移速/受击每帧消费）
@warning_ignore("unused_private_class_variable")
var _wm_has_blocking: bool = false
@warning_ignore("unused_private_class_variable")
var _wm_has_block_move_mult: bool = false
@warning_ignore("unused_private_class_variable")
var _wm_checked: bool = false

## 获取状态效果组件（_ready 装配；测试桩可能无）
func get_status_effects() -> Node:
	if _status_effects == null or not is_instance_valid(_status_effects):
		_status_effects = get_node_or_null("StatusEffects")
	return _status_effects


## 施加状态效果（BURN/POISON/SLOW/STUN；转发 StatusEffects.apply）
func apply_status(type: int, duration: float, power: float = 0.0, source: Node = null) -> void:
	var se: Node = get_status_effects()
	if se != null and se.has_method("apply"):
		se.apply(type, duration, power, source)


## 是否被眩晕（AI 据此停滞：StunSystem 语义——被打晕时既不追也不打）
func is_stunned() -> bool:
	var se: Node = get_status_effects()
	if se == null:
		return false
	# has_stun 方法存在性不变 → 首次查一次记布尔（免每帧 has_method 字符串反射）
	if not _se_checked:
		_se_checked = true
		_se_has_stun = se.has_method("has_stun")
	return _se_has_stun and se.has_stun()


## 播放攻击动画（反编译参考实装 C）：攻击命中帧触发攻击动画，
## 播完由 VisualController 监听 rig.animation_finished 回切 walk/idle。
## 按主手武器类型选择专属攻击动画（剑挥砍/矛刺/镐挥/法杖施法/弓拉弓）。
func play_attack() -> void:
	var anim := "attack"
	if weapon_mount != null and "weapon_type" in weapon_mount:
		anim = WEAPON_ATTACK_ANIM.get(int(weapon_mount.weapon_type), "attack")
	# 盾姿态分层（计划 5）：举盾时攻击动画走持盾池（Block-AttackN 随机），
	# 由 VisualController 查兵种档案解析变体；state 名不变，命中帧订阅不受影响
	var blocking: bool = weapon_mount != null and weapon_mount.has_method("is_blocking") \
			and weapon_mount.is_blocking()
	if _visual != null and _visual.has_method("play_attack"):
		_visual.play_attack(anim, blocking)
	elif _visual != null and _visual.has_method("play"):
		_visual.play(anim)


## 攻击动画播放中（behavior_attack 挥砍锁足的移动闸：动画没播完不追不挪；
## 出手不受此限——命中帧后可打断尾段照常原地出下一手）
func is_attack_anim_active() -> bool:
	return _current_anim.begins_with("attack")


## 举盾姿态变化回调（盾姿态分层，计划 5）：WeaponMount.set_blocking 驱动，
## 转发 VisualController 换持盾变体（walk/idle/attack 分层）。
func on_blocking_changed(blocking: bool) -> void:
	if _visual != null and _visual.has_method("set_block_stance"):
		_visual.set_block_stance(blocking)


# ─────────────────────────────── 朝向（翻面控制转发）────────────────────────────────
# 翻面节流/滞回/出生宽限/战斗朝向锁/瞄准俯仰的方法体在 entity_facing.gd（_facing）；
# 以下为对外薄壳（entity_motion/behavior_*/visual_controller 经实体 duck 调用）。

## 面向指定世界坐标（横向翻转；AI 开火前调用——风筝撤退中开火必须回头
## 面向目标，否则"背身拉弓"）。
func face_towards(pos: Vector2) -> void:
	_facing_helper.face_towards(pos)


## 朝向变更节流（SW3 Movement.LimitFacingChangeRate 直译）：0.5s（15 物理）内
## 只许翻一次；玩家接管豁免。返回是否生效（false=节流窗内，保持原朝向）
func try_set_facing(new_facing: int) -> bool:
	return _facing_helper.try_set_facing(new_facing)


## 移动侧意图喂入（批3 facing 滞回，_apply_movement 每物理帧调用）：
## 返回该侧翻面请求是否放行——反向意图连续 ≥ FACING_PERSIST_SECS 才 true。
func note_move_facing(side: int, delta: float) -> bool:
	return _facing_helper.note_move_facing(side, delta)


## 战斗朝向锁（behavior_attack 置位：有活跃攻击目标时 true——朝向归
## _face_target 开火瞄准管，移动不翻面）
func set_combat_face_lock(locked: bool) -> void:
	_facing_helper.set_combat_face_lock(locked)


## 写拉弓瞄准俯仰角（behavior_attack 弓手每拍按弹道解算推送；纯表现态）。
func set_aim_pitch(rad: float) -> void:
	_facing_helper.set_aim_pitch(rad)


## 读拉弓瞄准俯仰角（视觉链消费：visual_controller → rig / billboard 镜像 feed）。
func get_aim_pitch() -> float:
	return _facing_helper.get_aim_pitch()


## 立即换持械站姿（换武器时 WeaponMount 调用）：
## 仅待机态立即生效；移动/攻击等状态不打断，回 idle 时按新武器自动选姿。
func refresh_stance() -> void:
	if _visual != null and _visual.has_method("refresh_idle_stance"):
		_visual.refresh_idle_stance()


## 播放列阵到位动画（AI 完善批次 4）：到达队形位时立正挺胸，播完回 idle。
## 每单位仅首次——SWL 造兵落位礼节的节奏就是一生一次（后续是移动/战斗）；
## 战场规划器高频改令重落位若重播 = 全场反复挺胸的怪姿势（创始人验收点正），
## 班重组等需要复活重播的场景再开口子。
var _arrive_anim_done: bool = false


func play_arrive() -> void:
	if _arrive_anim_done:
		return
	_arrive_anim_done = true
	if _visual != null and _visual.has_method("play"):
		_visual.play("arrive")


## 播放格挡动画（持盾格挡时，Swordwrath-Block 转译），播完回 walk/idle。
func play_block() -> void:
	if _visual != null and _visual.has_method("play"):
		_visual.play("block")


## 设置阵营 ID（由 BattleInstance 分配）。
## 同步头顶血条的阵营色（圆点/横条 = 阵营识别的唯一视觉来源，审计 P0-4）。
func set_faction(fid: int) -> void:
	faction_id = fid
	if _health_bar != null and is_instance_valid(_health_bar) \
			and _health_bar.has_method("set_faction"):
		_health_bar.set_faction(fid)


## 设置军衔（0=士兵 / 1=班长 / 2=排长，口径见 rank 字段注释）。
## 同步转发头顶血条（军衔点渲染挂点；血条侧未接线时 has_method 静默跳过）。
func set_rank(r: int) -> void:
	rank = clampi(r, 0, 2)
	if _health_bar != null and is_instance_valid(_health_bar) \
			and _health_bar.has_method("set_rank"):
		_health_bar.set_rank(rank)


## 获取军衔。
func get_rank() -> int:
	return rank


## 获取阵营 ID
func get_faction() -> int:
	return faction_id


# ─────────────────────────────── LOD 性能分档（战斗级节流）────────────────────────────────
# 档位/频率常量与档位落点方法体在 entity_lod.gd（_lod）；此处留对外薄壳
#（UnitLodDirector 按相机距离分档下发）。

## 设置性能档位：只动表现层频率/可见性，物理与战斗逻辑不受影响（细则见助手）。
func set_perf_tier(tier: int, anim_hz: float = -1.0) -> void:
	_lod.set_perf_tier(tier, anim_hz)


## 设置所属战斗实例
func set_battle_instance(bi: Node) -> void:
	_battle_instance = bi
	_solid_mask_dirty = true


## 固体互撞层切换（裁决#40b 非 sim 战斗链；sim 链由 battle_sim._clip_axis 承担）：
## 战斗活跃期 collision_mask 开单位层（2）——move_and_slide 对其他单位 CharacterBody2D
## 贴边停/滑动，站定单位是 kinematic 不被推动 = 任何单位不被他人位移（SWL 同款
## 语义，翻译档 §7.1.2：Unit.PushApart 基类为空）；聚落期关闭（mask 回 1 只撞
## 地形），劳作穿行保持原软分离观感。状态变化才 set（免每帧触发引擎重排）。
func _update_solid_collision_mask() -> void:
	var active: bool = _battle_instance != null and is_instance_valid(_battle_instance) \
			and (not _battle_instance.has_method("is_active") or _battle_instance.is_active())
	var want: int = 1 | (2 if active else 0)
	if want == collision_mask and not _solid_mask_dirty:
		return
	_solid_mask_dirty = false
	collision_mask = want


## 获取所属战斗实例（可能为 null）
func get_battle_instance() -> Node:
	return _battle_instance


## 获取 HealthComponent（可能为 null）
func get_health() -> Node:
	return health_component


## 获取 WeaponMount（可能为 null）
func get_weapon() -> Node2D:
	return weapon_mount


## 是否已死亡
func is_dead() -> bool:
	return health_component != null and health_component.is_dead()


# ─────────────────────────────── 受击反馈（§7.5 近战打击感）────────────────────────────────
# 击退冲量写入与受击红闪方法体在 entity_death.gd（_death）。

## 受击反馈：物理击退冲量 + 受击红闪。
## 由 WeaponMount.perform_attack 命中时调用（dir 为指向目标的方向）。
## sim 模式冲量写入 sim 击退数组（批循环积分+衰减），不再写本地冲量字段。
func apply_hit_reaction(dir: Vector2, force: float) -> void:
	_death.apply_hit_reaction(dir, force)


## 获取当前击退冲量（供测试/调试）
func get_knockback_velocity() -> Vector2:
	return _knockback_velocity
