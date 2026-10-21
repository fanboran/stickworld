class_name WeaponMount
extends Node2D
const StickProf := preload("res://core/services/stick_prof.gd")
## 武器挂载点 -- 管理武器/盾牌挂载、攻击动画触发与攻击执行。
##
## 详见 docs/技术/架构/场景与战斗/场景与战斗架构.md §7.1（WeaponMount）。
## 武器挂到右手骨骼 hand_inner（跟随手臂摆动），盾牌挂左手 hand_outer。
## 武器/盾牌贴图由 tools/baking/extract_weapons.gd 从解包 universal 图集裁剪
## （Swordbasic/Spear/Shield/Bow/Pickaxe/Magicstaff），场景带 GripPoint 对齐握把。
##
## 攻击流程（由 behavior_attack / 玩家接管调用）：
##   1. can_attack() 检查冷却
##   2. perform_attack(target) 按距离 + 命中率判定，命中则 target.apply_hit_reaction()
##   3. 攻击动画（按武器类型选，见 StickmanAnims.WEAPON_ATTACK_ANIM）驱动手臂挥砍，
##      武器挂 hand_inner 自动跟随，无需程序化 Tween。
##   4. 进入冷却，update_cooldown(delta) 每帧递减
##
## 命中帧（Saga MeleeAttackSystem.Strike 语义）：
##   **读动画内嵌事件的真值**，不写死比例。解包 Spine 数据里每个攻击动画都带
##   Hit 事件（Swordwrath-Attack1 Hit@1.0s / 全长 1.3333s = 75%；
##   Spearton-Attack1 Hit@0.8667s；Archidon-Draw Hit@0.5333s；Miner-Attack1 Hit@0.6667s；
##   Magikill-Spell1 Hit@1.0s），由 tools/baking/spine_import.gd 导出为动画元数据，
##   运行期经 StickmanRig.get_anim_event_time() 读取。
##   仅当动画确实没有事件数据（如程序化动画/测试桩）时才回退到 STRIKE_FRAME_RATIO_FALLBACK。
##
## 子域拆分索引（逻辑下沉同目录助手；状态与公共 API 留本类，行为不变）：
## - weapon_balance.gd  数值校准：P5/SWL 真值覆盖 + 全局手感调参 + 冷却校验
##                      （static 库，_reload_weapons 尾部经 WeaponBalance.apply 触发）
## - weapon_ranged.gd   远程弹道：弓延迟放箭 / 杖施法 / 法术 AOE / 抛物线发射（_ranged）
## - weapon_block.gd    持盾格挡：三重判定 + blockResetInterval 节流（_block；
##                      is_shield_blocking/notify_block_succeeded facade 留本类）
## - weapon_equip.gd    挂载与换装：武器/盾挂骨 + GripPoint 对齐 + rig 事件接线 +
##                      Spine Sound→SFX 映射 + 重挂总入口（_equip）
## - weapon_strike.gd   命中帧结算：Hit 事件真值判定 + 结算本体（暴击/AOE 挥击/
##                      溅射）+ sim 到点回调 + 动画可打断判定（_strike）
## - weapon_bow_aim.gd  弓手瞄准表现窗：持瞄拉弓/移动让位/装填播段逐帧仲裁（_aim）
## - weapon_heal.gd     治疗施法：CanCastHeal/CastHeal/IsCastingHeal 直译（_heal）

const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT
## 兵种行为档案（aim_scatter 等按武器类型读取；get_spell_aoe_radius 消费）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
## 远程弹道助手（弓延迟放箭/杖施法/法术 AOE/抛物线发射）
const WeaponRanged := preload("res://modules/units/scripts/entity/weapon_ranged.gd")
## 持盾格挡助手（三重判定 + blockResetInterval 节流）
const WeaponBlock := preload("res://modules/units/scripts/entity/weapon_block.gd")
## 挂载与换装助手（武器/盾挂骨 + rig 事件接线 + Sound→SFX 映射 + 重挂总入口）
const WeaponEquip := preload("res://modules/units/scripts/entity/weapon_equip.gd")
## 命中帧结算助手（Hit 事件真值判定 + 结算本体 + sim 到点回调 + 可打断判定）
const WeaponStrike := preload("res://modules/units/scripts/entity/weapon_strike.gd")
## 弓手瞄准表现窗助手（持瞄拉弓/移动让位/装填播段逐帧仲裁）
const WeaponBowAim := preload("res://modules/units/scripts/entity/weapon_bow_aim.gd")
## 治疗施法助手（CanCastHeal/CastHeal/IsCastingHeal 直译）
const WeaponHeal := preload("res://modules/units/scripts/entity/weapon_heal.gd")
## 批模拟内核类型经 combat api 契约出口引用（禁直连 class_name BattleSim，
## 重命名即静默断多处——见 audit §4.3）
const ScriptBattleSim := preload("res://modules/combat/api.gd").BATTLE_SIM_SCRIPT

## 武器类型与表现场景映射的真相源在 stick_rig api（武器视觉词汇归 L1）；
## 此处 const 转发保持 WeaponMount.WeaponType / WEAPON_SCENE_PATHS 旧引用点不变
const WeaponType = StickRigAPI.WeaponType
const WEAPON_SCENE_PATHS: Dictionary = StickRigAPI.WEAPON_SCENE_PATHS
## 盾牌场景（挂左手）
const SHIELD_SCENE_PATH: String = StickRigAPI.WEAPON_SHIELD_PATH
## 箭矢投影物场景（弓远程攻击发射）
const ARROW_SCENE_PATH := "res://modules/units/scenes/components/arrow.tscn"
## 箭矢场景预加载（战斗性能优化：此前每箭 load() 走一次资源路径解析）
const ARROW_SCENE: PackedScene = preload("res://modules/units/scenes/components/arrow.tscn")
## 抛物线箭矢水平分速（px/s；竖直初速按距离解算，重力 ARROW_GRAVITY）
var ARROW_VX: float = 850.0
## 手动放箭力度→箭速映射区间（SWL ArrowSpeedMinPower/MaxPower 语义：
## 轻点=软箭快速平射，满蓄=全力抛射；MAX 与 AI 解算速 ARROW_VX 对齐）
var ARROW_VX_MIN: float = 380.0
var ARROW_VX_MAX: float = 850.0
## 抛物线箭矢重力（px/s²）：900px 远射弧顶 ≈ 230px（越友军头顶），150px 内近似平射
var ARROW_GRAVITY: float = 2000.0
## 箭矢预判系数（瞄移动目标时提前量 × 飞行时间 × 系数）
var ARROW_LEAD_FACTOR: float = 0.7
## 放箭延迟兜底（s）：仅当 attack_bow 动画**没有** Hit 事件元数据时使用。
## 有事件时以事件真值为准（Archidon-Draw Drawn@0.5s / Hit@0.5333s，全长 2.0s）——
## 拉弓动画在 0.5s 拉满（Drawn），0.5333s 放箭（Hit），而不是拍脑袋的 0.75s。
const BOW_FIRE_DELAY_FALLBACK: float = 0.5333
## RWR sustained_fire 连射散布（media/packages ak47.weapon：grow_step=0.40/发）：
## 每放一箭散布热度 +0.40（上限 1.2），实际散布 σ × (1+热度)。
## 恢复率按"满热度回落全程 ≈ 一个射击间隔"重标定【待实测校准】：弓手实战节奏
## ~0.26 发/s（间隔 3.85s）→ DIMINISH 0.40/s 下满热度 1.2 回落全程 3.0s < 间隔，
## 单箭热度增量 0.4 一个间隔内衰减 1.54 ≫ 0.4——两箭之间热度必然可观恢复，
## 拉弓间隙 σ 乘数回到 1.0 附近（此前 0.10/s：增长 0.104/s ≈ 恢复 0.10/s 且
## sim 模式恢复链不跑，热度数学必然顶格 1.2 → σ 常驻 ×2.2，见
## temp/诊断-箭矢弓手与盾.md §1.4 根因三）。极限射速（冷却 2.0s = 0.5 发/s）
## 下每间隔衰减 0.8 仍 > 0.4，任何可达射速都不再钉顶。
const SUSTAINED_FIRE_GROW := 0.40
const SUSTAINED_FIRE_DIMINISH := 0.40
const SUSTAINED_FIRE_HEAT_MAX := 1.2
## 散布热度（0..HEAT_MAX；behavior_attack 据此做 RWR 点射停顿）
var _sustained_fire_heat: float = 0.0
## 盾牌格挡率（持盾被近战/箭矢命中时减伤概率；原版 blockChance 同为概率掷骰）
var BLOCK_CHANCE: float = 0.35
## 格挡减伤系数（剩余伤害比例）
var BLOCK_DAMAGE_FACTOR: float = 0.15
## 格挡重置间隔（s）：一次成功格挡后，这段时间内不能再格挡。
## 复刻原版 blockResetInterval——无此节流时高攻速单位会被盾牌无限吃掉伤害。
var BLOCK_RESET_INTERVAL: float = 0.6
## 正面格挡判定：来袭方向与朝向夹角余弦大于此值才算"正面"（≈ ±75° 扇区）。
var BLOCK_FRONT_DOT: float = 0.25
## 各武器攻击射程（px）——SWL 序列化真值直译（翻译档 §7.1.1：attackRange
## 世界单位 × 52px/u，取整十）：剑/矛/镐 attackRange 1.5u≈78→80，杖（Magikill
## 施法距离）7u≈364→360，弓 range 15u≈780。接近停步/出手门按 SWL 方法体系数
## 折算（0.7/0.8，见 behavior_attack），本表只存序列化原值口径。
const WEAPON_RANGE: Dictionary = {
	WeaponType.SWORD: 80.0,
	WeaponType.SPEAR: 80.0,
	WeaponType.BOW: 780.0,
	WeaponType.PICKAXE: 80.0,
	WeaponType.STAFF: 360.0,
	WeaponType.MERIC: 400.0,  ## heal_range 兜底语义（唯一真相源仍为行为档案 heal_range，待实测校准）
}
## 二线射程（px，SWL attackRangeSecondLine 直译）：矛兵在编队第二列（前排后有
## 友军遮挡）时用 2.5u≈130 隔排刺击（SWL colInFormation==1 语义；其余兵种
## secondLine==attackRange 无行为差异，不设）。0 = 无二线。
const WEAPON_RANGE_SECOND_LINE: Dictionary = {
	WeaponType.SPEAR: 130.0,
}
## HitStop 参数（命中顿帧）
var HITSTOP_TIME_SCALE: float = 0.05
var HITSTOP_DURATION: float = 0.06
## HitStop 全局最小触发间隔（s）：多单位混战节流，0.3s 内至多冻结一次（审计 P0-2）
var HITSTOP_MIN_INTERVAL: float = 0.3
## 受击击退力度（与伤害正相关）
var KNOCKBACK_PER_DAMAGE: float = 16.0
## 装备伤害乘子（InventoryService 按主手武器 def.attack_mult 写入；玩家
## 接管实体专属——不动基础值，battle_sim 校准锚点零影响，脱离接管复位 1.0）
var equip_attack_mult: float = 1.0
## 装备攻速乘子（def.speed_mult；>1 更快——有效冷却除以它；同为玩家接管专属）
var equip_speed_mult: float = 1.0
## 弹药容器（items 域 ItemContainer；InventoryService 接管时注入玩家背包，
## 脱离接管清空）。射击对 def.ammo_id 非空的武器从此容器扣 1 发；
## null = 无弹药源（NPC 无个体背包）= 免弹——E-4 loadout 弹药消耗再收紧。
## 蓝图《武器装备与个人库存》§4.2 数据开关：ammo_id 空 = 恒免弹。
var ammo_source: ItemContainer = null
## 接管近战溅射（SWL Unit 真值 USER_CONTROLLED_SPLASH_* 直译）：玩家接管单位的
## 近战挥击扇形额外收 4 个溅射目标、溅射伤害系数 0.2——"一人成军"的爽感来源
const USER_CONTROLLED_SPLASH_HIT_LIMIT: int = 4
const USER_CONTROLLED_SPLASH_MODIFIER: float = 0.2

# ─────────────────────────────── @export ────────────────────────────────
## 主手武器类型（默认剑）
@export var weapon_type: WeaponType = WeaponType.SWORD:
	set(v):
		weapon_type = v
		# 换武器 = 换攻击动画 = 命中帧事件时间要重新解析
		_hit_time_resolved = false
		_hit_event_time = -1.0
		# spawn 按兵种生成个体装备记录（掉落个体化第一步）：外部 spawn 设武器
		# 即建档（garrison/recruit/召唤）。实体侧守卫：已有记录/接管实体不建档
		#（读档 set_loadout 先写档再设武器；玩家装备不属于 NPC 个体）
		var owner_e := get_owner_entity()
		if owner_e != null and owner_e.has_method("note_spawn_weapon"):
			owner_e.note_spawn_weapon(v)
		if is_inside_tree():
			call_deferred("_reload_weapons")
			# 持械站姿随武器分型（剑/矛/弓/镐/杖各一套 Stand），立即换姿
			call_deferred("_refresh_owner_stance")
## 是否装备盾牌（挂左手 hand_outer）。兵种默认盾：仅 SPEAR 挂模型
## （原版只有 Spearton 持盾，其余兵种此位恒 true 但不显示——语义是"可格挡兵种"）
@export var shield_enabled: bool = true:
	set(v):
		shield_enabled = v
		if is_inside_tree():
			call_deferred("_reload_weapons")
			call_deferred("_refresh_owner_stance")
## 副手显式装备盾（背包装备系统写入，任意武器配盾；与兵种默认盾独立——
## 玩家 RPG 装备语义，NPC 不感知）。格挡判定只看盾实例，两条路殊途同归。
@export var equipped_shield: bool = false:
	set(v):
		equipped_shield = v
		if is_inside_tree():
			call_deferred("_reload_weapons")
			call_deferred("_refresh_owner_stance")
## 单次命中伤害
@export var damage: float = 15.0
## 攻击射程（像素），按武器类型初始化（WEAPON_RANGE）
@export var attack_range: float = 80.0
## 二线射程（像素，SWL attackRangeSecondLine 直译；按武器类型初始化
## WEAPON_RANGE_SECOND_LINE，0 = 无二线——行为层"前排有友军遮挡时隔排刺击"）
@export var attack_range_second_line: float = 0.0
## 攻击冷却（秒）。对齐解包 Spine 攻击动画时长（Swordwrath-Attack1 = 1.33s）：
## 冷却 ≥ 动画时长才能完整播完挥剑（否则下次攻击打断未播完的动画）。
@export var cooldown: float = 1.35
## 基础命中率 [0,1]（近战高命中）
@export var base_hit_chance: float = 0.9
## 持盾移速倍率（盾姿态分层计划 5：举盾行军减速；_reload_weapons 按档案刷新）
@export var block_move_mult: float = 1.0

# ── 以下字段复刻原版 MeleeAttack_Prototype / Unit 的配置项，逐个单位可调 ──
## 一次挥击能打中的最大人数（原版 NumberOfUnitsThatCanHit）。
## 语义是 **AOE 挥击**：身前扇形内最多几个敌人吃满伤，不是"围攻上限"。
## 1 = 单体；矛/镐这类横扫武器可给 2~3。
@export var number_of_units_that_can_hit: int = 1
## 溅射可波及的额外人数（原版 NumberOfUnitsThatCanHitWithSplash）
@export var number_of_units_that_can_hit_with_splash: int = 0
## 溅射伤害系数（原版 SplashModifier，对超出 number_of_units_that_can_hit 的目标）
@export var splash_modifier: float = 0.5
## 爆头加伤（原版 Unit.headShotBonusDamage，**加值**不是倍率；箭矢爆头时叠加）
@export var head_shot_bonus_damage: float = 10.0
## 暴击率 [0,1]（原版 isCrit 掷骰）
@export var crit_chance: float = 0.0
## 暴击伤害倍率
@export var crit_damage_multiplier: float = 2.0
## 暴击自伤（原版 critBonusDamageInflictedToSelf——暴击的代价：
## 如 Swordwrath 暴击会崩断自己的剑并受伤）。0 = 无代价。
@export var crit_bonus_damage_inflicted_to_self: float = 0.0
## 挥击扇形半角（度）：AOE 挥击的判定范围
@export var strike_arc_half_angle: float = 55.0
## 命中后动画可打断比例（原版 AnimationCancelFractionOfAnimationAfterAttackHit）：
## 挥砍**命中帧已过**后，命中段剩余部分 × 此比例的尾段可被打断——下次攻击
## 不必等整条挥砍播完（冷却虽未走完也可提前出手）。0 = 关闭（等完整冷却）。
@export var animation_cancel_fraction: float = 0.5
## 反伤（原版 ApplyDamageReflect 链）：被近战/箭矢命中时把这点伤害反弹给攻击者
## （攻击者免疫与否由其 can_receive_reflect_damage 决定）。0 = 无反伤（默认）。
@export var reflect_damage: float = 0.0

# ─────────────────────────────── 运行时 ────────────────────────────────
## 域助手实例（_init 装配；状态留本类，逻辑见各助手文件头注释）
var _ranged = null
var _block = null
var _equip = null
var _strike = null
var _aim = null
var _heal = null
## 当前冷却剩余（秒）
var _cooldown_timer: float = 0.0
## 主手武器实例（挂 hand_inner 骨骼，跟随手臂）
var _weapon: Node2D = null
## 副手盾牌实例（挂 hand_outer 骨骼）
var _shield: Node2D = null
## 延迟结算：pending 目标与倒计时（弓=拉弓满弓放箭 / 杖=施法前摇到点结算，
## 视觉对齐各自攻击动画）
var _pending_ranged_target: Node = null
var _bow_fire_timer: float = 0.0
## 举盾姿态（原版 IsBlocking()）：true 时该单位处于防御姿态，才可能格挡。
## 由 AI（守备/被压制）或玩家输入切换；仅持盾单位有效。
var _blocking: bool = false
## 格挡重置计时：>0 表示刚格挡过，期间不能再挡（blockResetInterval）
var _block_reset_timer: float = 0.0
## 当前攻击动画的 Hit 事件时间（秒）；<0 = 动画无事件数据，走比例兜底
var _hit_event_time: float = -1.0
## Hit 事件时间是否已解析（换武器时重置）
var _hit_time_resolved: bool = false

# ── 弓手瞄准表现窗（2026-09-30 实机验收：持瞄要有拉弓动作、移动要有脚步）──
## true = 持瞄表现窗激活：站定播拉弓保持段（attack_bow_hold，定格拉满），
## 移动让位走姿（镜像层按武器换 walk_bow）。出手（perform_attack）即关窗。
## 仲裁逻辑下沉 weapon_bow_aim.gd（process_tick），状态留本类。
var _aim_visual_active: bool = false
## 表现窗截止时刻（_now() 秒）。AI 路径 = 瞄准开始 + 超时兜底（点射停顿 +
## 冷却残段最长 ~4.9s，超时收弓防行为切换后残窗把人钉在拉满姿态）；
## 玩家蓄力路径 = 无穷大（松手才收弓）+ 接管丢失守卫（cancel_charge 不经过
## 本挂载，接管退出/死亡时靠 _process 的 is_user_controlled 检查收弓）。
var _aim_visual_until: float = -1.0e9
## 表现窗来源：true = 玩家蓄力路径（无超时，靠接管守卫收口）；false = AI 持瞄（超时兜底）
var _aim_visual_player: bool = false
## 移动判定阈值（速度平方）：与 hd2d 镜像的 moving 口径一致（25 = 5px/s）。
## 瞄窗仲裁（weapon_bow_aim）与出手路径（perform_attack/release_player_shot/
## throw_spear_manual 的移动不播动作判定）共用本值。
const BOW_MOVE_SQ_THRESHOLD: float = 25.0
## 装填动画已播标记（SWL IsReloading 的表现侧，S1b）：本冷却窗内已播过
## attack_bow_reload——oneshot 同名 play 会从头重播，逐帧仲裁不得重入。
## 冷却尽（回拉满持瞄）或表现窗关闭时复位，一窗一次
var _reload_visual_done: bool = false

# ── 治疗能力族（P7 批次 7b：Meric 实体层 CastHeal/CanCastHeal/IsCastingHeal 直译）──
## 当前治疗动画名（dump healingAnimation 字段直译，运行时经 StickmanAnims.pick_heal_anim 随机注入）
var healing_animation: String = ""
## 上次治疗施放时间（dump lastHealTime 直译；时钟源 = _now() 现实秒，对齐 StatusEffects 混源先例）
var _last_heal_time: float = -1.0e9
## 上次治疗特效生成时间（dump lastHealEffectSpawn 直译；特效挂 P10，本批仅施放时刷计时无消费逻辑）
var _last_heal_effect_spawn: float = -1.0e9
## 施法标志位（IsCastingHeal 直译：比查询 rig 动画名更可测，unit 测试直接置位）
var _heal_anim_playing: bool = false

## 动画内嵌事件转发（Spine events[] 语义）：Sound:* 音效钩子；音效资产与播放策略
## 见 AudioManager.SFX_EVENTS / SFX_POLICY（唯一真相源）。
signal weapon_anim_event(anim_name: String, event_name: String, value: String)


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _init() -> void:
	# 助手装配（须在 _init 运行期绑定 self，不用引用 self 的字段初始化器）
	_ranged = WeaponRanged.new(self)
	_block = WeaponBlock.new(self)
	_equip = WeaponEquip.new(self)
	_strike = WeaponStrike.new(self)
	_aim = WeaponBowAim.new(self)
	_heal = WeaponHeal.new(self)


func _ready() -> void:
	# 延迟挂载：WeaponMount 是实体子节点，_ready 先于实体执行，
	# 此时 entity.rig 尚未赋值（实体 _ready 里获取），deferred 保证顺序。
	# 用完整 _reload_weapons（挂骨 + 档案刷新 + 数值校准，本体在 weapon_equip.gd），
	# 使场景文件预置 weapon_type 的兵种也能吃到数值校准（P5 批次 2）。
	call_deferred("_reload_weapons")


## 重挂武器/盾牌（weapon_type / shield_enabled 变化时；本体下沉 weapon_equip.gd，
## 保留函数名——@export setter 与 _ready 经 call_deferred 字符串调用）
func _reload_weapons() -> void:
	_equip.reload_weapons()


## 盾视觉/逻辑是否应装备（2D 挂骨与 billboard 逻辑盾共用的单一规则出口：
## 兵种默认盾绑定 SPEAR；equipped_shield = 玩家背包副手装备盾任意武器可配）
func shield_visual_enabled() -> bool:
	return (shield_enabled and weapon_type == WeaponType.SPEAR) or equipped_shield


## HP 校准只做一次（出生满血基线）；换武器只迁移伤害/冷却/爆头加值，
## 不动当前 HP（主控换武器不应回血/扣血，装备迁移归 P9 物品栏）。
## （weapon_type → 兵种 def 映射表 WEAPON_DEF_ID 已下沉 weapon_balance.gd，
## 校准入口 WeaponBalance.apply(self) 在 _reload_weapons 尾部触发。）
@warning_ignore("unused_private_class_variable")
var _hp_calibrated: bool = false


## 动画事件回调：命中帧结算 + 音效事件转发。
## **Hit（命中帧结算）只认本武器的攻击动画**——防止"播矛刺动画、被剑的事件误触发"。
## **Sound 不做动画名过滤**：动画作者在哪一帧写了 Sound，就该在哪一帧响
## （死亡倒地 `fall`/`Thump`、站姿盾牌格挡 `clang` 都声明在非攻击动画上），
## 引擎侧再拿动画名裁一刀，等于把数据侧的真相源覆盖掉。
func _on_rig_anim_event(anim_name: String, event_name: String, value: String) -> void:
	weapon_anim_event.emit(anim_name, event_name, value)
	match event_name:
		"Hit":
			if anim_name != _attack_anim_name():
				return
			_strike.try_strike_frame()
		"Sound":
			_equip.play_event_sfx(value)


## 动画播完回调（P7 批次 7b）：治疗系动画结束 → 清施法标志位。
func _on_rig_animation_finished(anim_name: String) -> void:
	if anim_name in Anims.HEAL_ANIMS:
		_heal_anim_playing = false


## 本武器的攻击动画名（与实体 play_attack 共用 StickmanAnims 的映射表）
func _attack_anim_name() -> String:
	return Anims.anim_for_weapon(weapon_type)


func _physics_process(delta: float) -> void:
	var _pt := StickProf.t0()
	_physics_tick(delta)
	StickProf.t1("武器挂载", _pt)


func _physics_tick(delta: float) -> void:
	# 暂停冻结由引擎总闸负责（本节点 PAUSABLE，暂停期冷却/放箭计时/命中帧全停）；
	# 步长经 sim_delta 携带速度档
	if TimeManager != null:
		delta = TimeManager.sim_delta(delta)
	# 格挡重置冷却两模通用（原版 blockResetInterval）：sim 模式冷却/strike/
	# 放箭计时归 BattleSim 批推进，但本计时 BattleSim 不接管——此前递减放在
	# sim 早退之后，sim 局一次成功格挡即永久锁死（节流永不过期，盾兵全场
	# 只挡得成一击）
	if _block_reset_timer > 0.0:
		_block_reset_timer = maxf(0.0, _block_reset_timer - delta)
	# RWR sustained_fire 停火恢复：**先于 sim 早退**执行（两模通吃）——原先挂在
	# update_cooldown，而 sim 模式（观察场默认）本函数在此早退、update_cooldown
	# 永不执行 → 热度只涨不消，叠加上面旧恢复率必然顶格（诊断 §1.4 根因三）
	_recover_sustained_fire(delta)
	# sim 模式（D 刀）：冷却/strike 命中帧/远程放箭计时由 BattleSim 批推进，
	# 到点回调 sim_strike_now()/sim_fire_now()——本节点 _physics_process 停跑
	if _sim() != null:
		return
	update_cooldown(delta)
	# 命中帧结算（Saga Strike 模式）
	if not _strike_fired:
		_pending_strike_elapsed += delta
	_strike.try_strike_frame()
	# 延迟发射/施法结算：远程计时到点按武器类型分派（视觉对齐攻击动画）
	if _pending_ranged_target != null:
		if is_instance_valid(_pending_ranged_target):
			_bow_fire_timer -= delta
			if _bow_fire_timer <= 0.0:
				if weapon_type == WeaponType.BOW:
					_ranged.fire_arrow(_pending_ranged_target)
				else:
					_ranged.cast_magic(_pending_ranged_target)
				_pending_ranged_target = null
		else:
			_pending_ranged_target = null


# ─────────────────────────────── 弓手瞄准表现窗 ────────────────────────────────
## 持瞄拉弓 / 移动让位的逐帧仲裁下沉 weapon_bow_aim.gd（_aim）；
## 表现窗状态（_aim_visual_* / _reload_visual_done）留本类，出手路径直接消费。


func _process(_delta: float) -> void:
	var _pt := StickProf.t0()
	_aim.process_tick(_delta)
	StickProf.t1("武器瞄窗", _pt)


# ─────────────────────────────── 公共 API ────────────────────────────────

## 是否可以攻击。
## 冷却结束 → 可以；冷却未走完但命中帧已过、动画播进"可打断尾段"
## （原版 AnimationCancelFractionOfAnimationAfterAttackHit）→ 也可以提前出手。
## 9d 边界修复：冷却已到但**上一击尚未挥到命中帧**时不许重挥——
## 冷却 ≤ 命中帧时长时（如剑 1.0s 冷却 vs 1.0s 命中帧），每次重挥都会
## 在命中帧结算前打断自己，永远打不出伤害。对齐原版"命中帧后才可打断"语义。
func can_attack() -> bool:
	# 徒手（背包装备系统主手卸空）不可攻击——玩家空手即无威胁
	if weapon_type == WeaponType.NONE:
		return false
	# sim 模式：冷却真相源在 BattleSim（本节点 _physics_process 停跑，
	# _cooldown_timer 不再推进）；pending strike 门禁语义与旧链一致
	var s := _sim()
	if s != null:
		if s.get_cooldown(_sim_sid()) > 0.0:
			return _cancel_window_latched or _strike.can_cancel_attack_anim()
		if _pending_strike_target != null and not _strike_fired:
			return false
		return true
	if _cooldown_timer > 0.0:
		return _cancel_window_latched or _strike.can_cancel_attack_anim()
	# 上一击已登记目标但还没到命中帧：等它结算（空挥/已结算不拦）
	if _pending_strike_target != null and not _strike_fired:
		return false
	return true


## 当前冷却剩余时间（本地计时口径；sim 模式下不推进，见 _cooldown_left）
func get_cooldown_remaining() -> float:
	return _cooldown_timer


## 冷却剩余（双模真相源）：sim 模式计时权威在 BattleSim（本节点
## _physics_process 早退，_cooldown_timer 冻结在出手值）；非 sim 走本地
## 逐帧递减计时。can_attack 同款取数口径，供装填仲裁等表现侧消费
func _cooldown_left() -> float:
	var s := _sim()
	if s != null:
		return s.get_cooldown(_sim_sid())
	return _cooldown_timer


## RWR sustained_fire 散布热度（0..1.2；behavior_attack 的点射停顿判定源）
## ⚠ 双职责：behavior_attack._update_aim_rhythm 在**每次持瞄开始**恰好调用本函数
## 一次（2026-09-30 核对为全库唯一调用点），弓手据此感知"持瞄开始"并拉起拉弓
## 表现窗——AI 侧零改动（aim/** 归军师）。若该调用点挪走/新增别的调用方，
## 必须同步迁走/摘除 _aim.mark_bow_aim_started，否则拉弓时机会错。
func get_sustained_fire_heat() -> float:
	_aim.mark_bow_aim_started()
	return _sustained_fire_heat


## 拉弓瞄准俯仰角（SWL Archer.Aim 射角源）：behavior_attack 每拍轮询推送到
## 实体 aim_pitch（纯表现态）。非弓武器恒 0（杖瞬发无弹道）。
func get_aim_pitch(target: Node) -> float:
	if weapon_type != WeaponType.BOW:
		return 0.0
	return _ranged.get_aim_pitch(target)


## 是否有未结算的挥砍（已发起、命中帧未到；can_attack 命中帧门禁的查询面）
func has_pending_strike() -> bool:
	return _pending_strike_target != null and not _strike_fired


## 执行一次攻击。
## 近战（剑/矛/镐）：距离 + 命中率判定，命中则目标受击反馈。
## 远程（弓）：发射箭矢投影物，命中由箭矢实际碰撞决定。
## 施法（杖）：延迟结算（attack_staff 的 Spell Hit@1.0s 前摇到点直接结算，
## SWL Magikill-Spell1 语义；弹道化见待办"魔法弹投射物"）。
## target: 目标 StickmanEntity（必须有 HealthComponent）
## 返回 {hit: bool, damage: float, reason: String}
## 复刻 Saga MeleeAttackSystem：攻击 = 播放动画 + 在命中帧（动画进度 STRIKE_FRAME_RATIO）
## 结算一次伤害。近战命中不再是概率——只要在射程内且动画挥到命中帧就命中
## （原版近战无闪避概念；命中率字段保留给未来的"犹豫/恐慌"情绪系统使用）。
func perform_attack(target: Node) -> Dictionary:
	var result: Dictionary = {"hit": false, "damage": 0.0, "reason": ""}
	if not can_attack():
		result["reason"] = "cooldown"
		return result
	if target == null or not is_instance_valid(target):
		result["reason"] = "invalid_target"
		return result
	# 弓：发射箭矢（命中由箭矢决定）；杖：延迟施法结算（本体下沉 weapon_ranged.gd）
	if weapon_type == WeaponType.BOW or weapon_type == WeaponType.STAFF:
		var ranged_result: Dictionary = _ranged.attack_ranged(target)
		# 弓出手成功 → 收瞄准表现窗并播释放段（"绷住→放"衔接；拉弓保持段是
		# 持瞄期的事，出手这拍不再回撤重拉）。kite 分支不调 play_attack，
		# 释放段由这里兜底触发；in-range 分支随后 entity.play_attack() 重播
		# 同名动画（镜像层按名去重，实体侧重播同帧同起点，无感）。
		# 移动中出手（风筝还击）不播释放段：attack_* 前缀会触发 entity_motion
		# 的攻击守卫拦住 walk 切换，1.33s 定腿滑步比无动作更糟——移动射击保持
		# 裸发射，脚步表现交给走姿。
		if weapon_type == WeaponType.BOW and str(ranged_result.get("reason")) == "fired":
			_aim.end_bow_aim_visual(false)
			var shooter: CharacterBody2D = get_owner_entity()
			if shooter == null or shooter.velocity.length_squared() <= BOW_MOVE_SQ_THRESHOLD:
				_play_swing()
		return ranged_result
	var health: Node = _get_health(target)
	if health == null or health.is_dead():
		result["reason"] = "no_health_or_dead"
		return result
	# 距离检查（近战：剑够得着才算）
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null:
		result["reason"] = "no_owner"
		return result
	var dist: float = owner_entity.global_position.distance_to(target.global_position)
	if dist > attack_range:
		result["reason"] = "out_of_range"
		return result
	# 挥砍动画（无论命中与否都有挥砍动作）。
	# 必须由发起攻击这一步自己触发：命中帧是按动画时间结算的，若等外部（AI/玩家）
	# 之后再播动画，首帧动画尚未起播 → 命中会被判成"立即结算"，对齐就白做了。
	_play_swing()
	# 登记待结算目标：动画播到命中帧时 _strike() 结算（复刻 Saga HitUpdate→Strike）
	_pending_strike_target = target
	_pending_strike_owner = owner_entity
	_strike_fired = false
	_cancel_window_latched = false
	# 进入冷却；sim 模式计时归 BattleSim（冷却 + strike 命中帧）
	var s := _sim()
	if s != null:
		s.set_cooldown(_sim_sid(), _get_effective_cooldown())
		s.register_strike(_sim_sid(), self, _strike.resolve_hit_seconds())
	else:
		_pending_strike_elapsed = 0.0
		_cooldown_timer = _get_effective_cooldown()
	result["reason"] = "striking"
	return result


## 空挥（复刻原版 User Control：接管单位无目标也可出攻击动作）。
## 播对应武器攻击动画 + 进冷却；不登记目标 → 命中帧 _strike() 无结算
## （弓空挥 = 拉弓不放箭，与原版一致）。返回是否成功起挥（冷却中为 false）。
func perform_swing() -> bool:
	if not can_attack():
		return false
	_play_swing()
	_pending_strike_target = null
	_pending_strike_owner = get_owner_entity()
	_strike_fired = false
	_cancel_window_latched = false
	var s := _sim()
	if s != null:
		s.set_cooldown(_sim_sid(), _get_effective_cooldown())
		s.register_strike(_sim_sid(), self, _strike.resolve_hit_seconds())
	else:
		_pending_strike_elapsed = 0.0
		_cooldown_timer = _get_effective_cooldown()
	return true


# ─────────────────────────────── 玩家蓄力操控（SWL ArcherControls PC 翻译）───

## 玩家拉弓起手（SWL DrawBow：按住进入瞄准态）：弓播拉弓保持段（举弓-拉弦-
## 绷住，定格拉满陪按住全程）；其余武器维持旧行为（播攻击动画）。
## 不进冷却、不登记命中结算，冷却与出手都在松手时刻（release_player_shot）判。
## 弹药约束：耗弹武器无弹时不起拉（射空不能射的入口门），给一声拒绝反馈。
func begin_player_draw() -> void:
	if weapon_type != WeaponType.BOW:
		_play_swing()
		return
	if not has_ammo():
		if AudioManager != null:
			AudioManager.play_event("ui_denied")
		return
	_aim_visual_active = true
	_aim_visual_player = true
	_aim_visual_until = 1.0e9  # 玩家按住全程无超时，松手/接管丢失才收弓
	_aim.set_bow_aim_walk_override(true)  # 玩家窗同享持瞄保持行走（移动走 walk_bow_hold）
	_aim.play_via_visual(Anims.ANIM_ATTACK_BOW_HOLD)


## 玩家松手放箭（SWL AimReleased → UserControlledArrowReleased）：
## 手动弹道（aim_dir 由鼠标指向给出，power 由按住时长给出），冷却门在出手时刻判。
## 返回箭矢实例（无出手为 null；箭矢镜头消费）。
func release_player_shot(aim_dir: Vector2, power: float) -> Node2D:
	if not can_attack():
		_aim.end_bow_aim_visual(true)  # 出手被拒也要收弓，别把玩家钉在拉满姿态
		return null
	if not has_ammo():
		# 起手门已拦，这里是兜底（蓄力途中背包被清空等边角）——拒绝且收弓
		_aim.end_bow_aim_visual(true)
		return null
	var arrow: Node2D = _ranged.fire_arrow_manual(aim_dir, power)
	# 松手 = 释放段（绷住→放）；出手被守卫拦下时 _end 已回站姿。
	# 移动中松手不播释放段（同 perform_attack：定腿滑步比无动作更糟）
	_aim.end_bow_aim_visual(false)
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null or owner_entity.velocity.length_squared() <= BOW_MOVE_SQ_THRESHOLD:
		_play_swing()
	_cooldown_after_player_action()
	return arrow


## 玩家蓄力投矛（SWL Spearton.ThrowSpear 的 PC 翻译）：投掷走双倍冷却
## （技能语义，原版掷后接拔剑近战，拔剑未实装前用冷却差模拟节奏差）。
## 掷出播 Spearton-Throw 真数据动画（站定才播，移动投掷保持脚步——同弓
## 释放段口径）；纯表现无结算挂钩，伤害走矛投射物。
func throw_spear_manual(aim_dir: Vector2, power: float) -> bool:
	if not can_attack():
		return false
	_ranged.throw_spear_manual(aim_dir, power)
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity != null and owner_entity.velocity.length_squared() <= BOW_MOVE_SQ_THRESHOLD:
		_aim.play_via_visual(Anims.ANIM_THROW_SPEAR)
	var factor: float = 2.0
	var s := _sim()
	if s != null:
		s.set_cooldown(_sim_sid(), _get_effective_cooldown() * factor)
	else:
		_cooldown_timer = _get_effective_cooldown() * factor
	return true


## 玩家指向施法（SWL Magikill 攻击的 PC 翻译）：落点=鼠标世界坐标，
## 不再自动锁敌；AOE 以落点为心结算（cast_magic_at 实现）。
func cast_magic_at(point: Vector2) -> bool:
	if not can_attack():
		return false
	_ranged.cast_magic_at(get_owner_entity(), point)
	_cooldown_after_player_action()
	return true


## 玩家蓄力出手的冷却登记（出手时刻进冷却，与 AI 攻速语义一致）
func _cooldown_after_player_action() -> void:
	var s := _sim()
	if s != null:
		s.set_cooldown(_sim_sid(), _get_effective_cooldown())
	else:
		_cooldown_timer = _get_effective_cooldown()


## 手动放箭出射点（射手胸口，与 fire_arrow/fire_arrow_manual 同源）
func get_arrow_origin() -> Vector2:
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity == null:
		return global_position
	return _ranged.get_muzzle_pos(owner_entity)


## 蓄力→出手速度映射（SWL ArrowSpeedMinPower/MaxPower：力度决定箭速）
func charge_launch_speed(power: float) -> float:
	return lerpf(ARROW_VX_MIN, ARROW_VX_MAX, clampf(power, 0.0, 1.0))


## 蓄力预览/投射重力（弓=箭重力、矛=矛重力；轨迹预览与实际投射同源）
func get_charge_gravity() -> float:
	if weapon_type == WeaponType.SPEAR:
		return _ranged.SPEAR_GRAVITY
	return ARROW_GRAVITY


## 法术 AOE 半径（杖落点圈预览与结算同源；档案 spell_aoe_radius，缺省 90）
func get_spell_aoe_radius() -> float:
	return float(ScriptBehaviorProfiles.get_profile(int(weapon_type)).get("spell_aoe_radius", 90.0))


# ─────────────────────────────── 弹药约束（AMMO 接线，蓝图 §4.2）────────────────
# 数据开关：武器 def.ammo_id 空 = 恒免弹（近战/杖/投矛现状）。设了 ammo_id 时，
# 出箭从 ammo_source 扣 1 发、无弹不能射——只加资源约束，弹道/手感零改动。
# NPC 无 ammo_source（个体背包 E-4）= 免弹；玩家侧由 InventoryService 注入背包。

## 当前主手武器的弹药 def_id（免弹武器/无映射返回空）
func current_ammo_id() -> StringName:
	var wid: StringName = ItemsAPI.WEAPON_ITEM_BY_TYPE.get(int(weapon_type), &"")
	if wid == &"":
		return &""
	var def: ItemDef = ItemDB.get_def(wid)
	return def.ammo_id if def != null else &""


## 是否还有弹药（免弹武器/无弹药源恒 true——射空不能射的判定源）
func has_ammo() -> bool:
	var aid := current_ammo_id()
	return aid == &"" or ammo_source == null or ammo_source.has_item(aid)


## 扣 1 发弹药（射击瞬间调用）。免弹/无源恒成功；容器无货失败 = 出手中止。
func spend_ammo() -> bool:
	var aid := current_ammo_id()
	if aid == &"" or ammo_source == null:
		return true
	return ammo_source.remove(aid, 1)


# ── 命中帧结算子域（Saga MeleeAttackSystem.Strike；逻辑下沉 weapon_strike.gd，
#    STRIKE_FRAME_RATIO_FALLBACK / STRIKE_ANIM_GRACE 常量随迁）──
## 挥砍状态留本类：can_attack 门禁、_play_swing 变体重置、_physics_tick 轮询
## 与 sim 回调（BattleSim 经 facade 触发）共同消费。
var _pending_strike_target: Node = null
var _pending_strike_owner: Node = null
var _strike_fired: bool = true
## 发起攻击后经过的时间（用于动画起播宽限判定）
var _pending_strike_elapsed: float = 0.0
## 可打断窗口锁存：动画一旦越过可打断点即置位，下次起挥时复位。
## 决策（AI 轮询 can_attack）与执行（perform_attack）之间可能隔帧、动画时间
## 已继续推进——锁存保证"看到窗口开着 → 出手必成"，不因查询时序丢攻击。
var _cancel_window_latched: bool = false


## sim 模式命中帧到点回调（BattleSim._tick_weapon crossing 触发；sim 为时序权威）。
## 结算链在 weapon_strike.gd（AOE/情绪/hitstop/伤害管线零重复）——facade 转发，
## BattleSim 直调本签名，不可变。
func sim_strike_now() -> void:
	_strike.sim_strike_now()


## sim 模式远程到点回调（弓放箭 / 杖施法；延迟计时归 BattleSim）——facade 转发。
func sim_fire_now() -> void:
	_strike.sim_fire_now()


# ─────────────────────────────── BattleSim 接线（D 刀）────────────────────────────────

## 宿主实体的 BattleSim（null = 未注册/未启用/已死——所有 sim 分支的统一入口判定）。
func _sim() -> ScriptBattleSim:
	var e := get_owner_entity()
	if e == null or not is_instance_valid(e):
		return null
	if not e.has_method("get_battle_sim"):
		return null
	var s: ScriptBattleSim = e.get_battle_sim()
	if s == null or e.get_battle_sim_sid() < 0 or e.is_dead():
		return null
	return s


## 宿主实体的 sim 下标（调用前须确认 _sim() 非 null）
func _sim_sid() -> int:
	var e := get_owner_entity()
	return e.get_battle_sim_sid() if e != null else -1


## 每帧递减冷却（也可由外部调用）。散热恢复不在本函数：见 _recover_sustained_fire
## （须两模通吃，挂 _physics_process 的 sim 早退之前）。
func update_cooldown(delta: float) -> void:
	if _cooldown_timer > 0.0:
		_cooldown_timer = maxf(0.0, _cooldown_timer - delta)


## RWR sustained_fire 停火恢复（diminish_rate）：散布热度随时间线性回落。
## 调用位 = _physics_process 的 sim 早退之前（两模通吃；单测直接步进本函数）。
func _recover_sustained_fire(delta: float) -> void:
	_sustained_fire_heat = maxf(0.0, _sustained_fire_heat - SUSTAINED_FIRE_DIMINISH * delta)


## 连射散热记账（放箭时由 weapon_ranged.fire_arrow 调用）：热度增长 + 封顶。
## 增长/恢复两个时间常数的唯一入口（单测步进 add/_recover 一对函数复算节奏）。
func add_sustained_fire_heat() -> void:
	_sustained_fire_heat = minf(_sustained_fire_heat + SUSTAINED_FIRE_GROW, SUSTAINED_FIRE_HEAT_MAX)


## 获取挂在手部的武器实例（null=未挂载）
func get_weapon_node() -> Node2D:
	return _weapon


## 获取副手盾牌实例（null=未装备盾）
func get_shield_node() -> Node2D:
	return _shield


## 持盾格挡判定（被攻击方调用；DamagePipeline 的格挡入口，签名不可变）。
## 判定本体（盾存在/举盾姿态/正面扇区/重置节流/概率掷骰）下沉 weapon_block.gd，
## 状态（_shield/_blocking/_block_reset_timer/BLOCK_*）留本类，此处仅转发。
func is_shield_blocking(incoming_dir: Vector2 = Vector2.ZERO) -> bool:
	return _block.is_shield_blocking(incoming_dir)


## 举盾姿态（原版 IsBlocking()）：true = 该单位正处于防御姿态。
## 由 AI（守备/被压制）或玩家输入切换；无盾单位设了也挡不住。
## 状态变化时通知持有实体（on_blocking_changed → VisualController 换持盾变体，
## 盾姿态分层计划 5）。
func set_blocking(v: bool) -> void:
	if _blocking == v:
		return
	_blocking = v
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity != null and owner_entity.has_method("on_blocking_changed"):
		owner_entity.on_blocking_changed(v)


## 是否处于举盾姿态（受击方选受击动画用：举盾被击走 Hit-Spearton-Block 池）
func is_blocking() -> bool:
	return _blocking


## 是否处于举盾姿态
func get_blocking() -> bool:
	return _blocking


## 标记一次成功格挡（由 DamagePipeline 调用）：启动 blockResetInterval 冷却，
## 防止高攻速单位被同一面盾连续无限吃掉伤害（本体下沉 weapon_block.gd）。
func notify_block_succeeded() -> void:
	_block.notify_block_succeeded()


## 是否可被反伤（原版 Unit.CanReceiveReflectDamage 虚方法，缺省可被反伤）。
## 未来免疫反伤的单位类型（雕像/亡灵等）在此覆写。
func can_receive_reflect_damage() -> bool:
	return true


## 是否正在挥砍（程序化挥砍已移除，挥砍由攻击动画驱动，恒 false）
func is_swinging() -> bool:
	return false


# ─────────────────────────────── 治疗能力（P7 批次 7b：Meric 实体层直译）────────────────────────────────
## 施法本体下沉 weapon_heal.gd（_heal）；治疗状态（_heal_anim_playing/
## _last_heal_time/_last_heal_effect_spawn/healing_animation，被 tests/unit/
## test_meric_heal.gd 直写）与本函数签名留本类，此处仅转发。
## CanCastHeal 直译：冷却满 ∧ 非施法中。dump 无方法体真值，语义推断（待实测校准）。
func can_cast_heal() -> bool:
	return _heal.can_cast_heal()


## CastHeal 直译；签名差异声明：原版无参目标由宿主字段隐含，本项目显式传 target
## 保类型安全，语义等价。dump 无方法体真值，语义推断（待实测校准）。
func cast_heal(target: Node) -> void:
	_heal.cast_heal(target)


## IsCastingHeal 直译：返回施法标志位（比查询 rig 动画名更可测，unit 测试直接置位）。
func is_casting_heal() -> bool:
	return _heal.is_casting_heal()


## 现实秒时钟源（对齐 StatusEffects._now 混源先例）
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


# ─────────────────────────────── 内部 ────────────────────────────────

## 攻击挥砍：剑挂 hand_inner 骨骼，攻击动画（按武器类型选，转译自解包 Spine）
## 驱动手臂挥砍，剑自动跟随，无需程序化 Tween 旋转。
## 由发起攻击这一步直接触发——命中帧按动画时间结算，动画必须先起播。
func _play_swing() -> void:
	# 攻击池变体每次随机抽取且先于命中帧登记换装（visual_controller.play_attack）：
	# 命中帧时刻随变体逐击重解析——"换武器才重解析"的缓存语义只对无池武器成立
	_hit_time_resolved = false
	_hit_event_time = -1.0
	var owner_entity: CharacterBody2D = get_owner_entity()
	if owner_entity != null and owner_entity.has_method("play_attack"):
		owner_entity.play_attack()


## 命中顿帧：短暂冻结时间（打击感核心，参考 Stickman Burst Hit Stop 方案）。
## headless 下禁用（避免拖慢测试计时）。
## 2026-08-31 审计 P0-2 规模节流：全局 Engine.time_scale 冻结是为 1v1 打击感
## 设计的——24+ 单位混战每次近战命中都冻结整个世界，画面反复掉到 5% 速度
## 且多个恢复 timer 互相覆盖。加全局最小触发间隔（0.3s 至多一次）。
static var _hitstop_ctrl := HitstopController.new()

func _hitstop() -> void:
	_hitstop_ctrl.try_trigger(get_owner_entity(), get_tree(), HITSTOP_TIME_SCALE, HITSTOP_DURATION, HITSTOP_MIN_INTERVAL)


## 获取目标实体的 HealthComponent
func _get_health(target: Node) -> Node:
	if target == null:
		return null
	return target.get_node_or_null("HealthComponent")


## 实际冷却（接管攻速乘子 × 装备攻速乘子；speed_mult>1 更快 → 冷却变短）
func _get_effective_cooldown() -> float:
	var base: float = cooldown * _user_controlled_speed_mult()
	# 装备攻速乘子（speed_mult>1 更快 → 冷却变短；缺省 1.0 零回归）
	return base / maxf(0.05, equip_speed_mult)


# ── 命运骰 RNG（单位种子隔离：与全局 randf 断开，P4 回放"每单位可注入种子"前置）──
var _dice_rng := RandomNumberGenerator.new()
var _dice_seeded: bool = false


## 命运骰（命中/暴击掷骰统一出口）：首掷按宿主实体实例 id 派生种子
## （每单位不同；对齐 ai_controller._resolve_jitter_seed 惯例），测试可直接
## 重掷 _dice_rng.seed 复现序列。
func _roll_dice() -> float:
	if not _dice_seeded:
		_dice_seeded = true
		var e := get_owner_entity()
		_dice_rng.seed = int(e.get_instance_id()) if e != null else 20261006
	return _dice_rng.randf()


## 装备后有效伤害（基础值 × 装备乘子；所有出手结算统一走本出口）
func effective_damage() -> float:
	return damage * equip_attack_mult


## 主控攻速倍率（dump Unit 真值 USER_CONTROLLED_ATTACK_SPEED = 1.3：
## 玩家主控出手节奏 ×1.3；非主控 1.0）
func _user_controlled_speed_mult() -> float:
	var e := get_owner_entity()
	if e != null and e.has_method("is_user_controlled") and e.is_user_controlled():
		return 1.3
	return 1.0


## 获取拥有此 WeaponMount 的 StickmanEntity（父节点）。
## 换武器后让持有者立即换持械站姿（visual_controller.refresh_idle_stance）。
func _refresh_owner_stance() -> void:
	var e := get_owner_entity()
	if e != null and e.has_method("refresh_stance"):
		e.refresh_stance()


func get_owner_entity() -> CharacterBody2D:
	var p: Node = get_parent()
	if p is CharacterBody2D:
		return p as CharacterBody2D
	return null
