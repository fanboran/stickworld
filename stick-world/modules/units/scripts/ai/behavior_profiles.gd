class_name BehaviorProfiles
extends RefCounted
## 兵种行为档案库 -- RWR 式"基线 + 兵种覆盖"参数分层（审计 §5.2 / P2-2 蓝本）。
##
## 参考：RunningWithRifles `media/packages/vanilla/default.ai`（约 120 参数的人性基线）
##   → 职业文件只写差异（`elite.ai` 全文 2 行）→ 行为物种 = 同一引擎 + 参数差。
## 本项目落地：behavior_attack 的硬编码常量抽成档案字典——
##   基线所有兵种共享，兵种档案**只写差异项**（缺省回落基线），
##   兵种个性（冲脸/持阵/风筝）从"另写行为类"降级成"改几个参数"。
##
## 用法（behavior_attack.enter 内）：
##   _profile = BehaviorProfiles.get_profile(weapon_type)
##   var push_prob: float = _profile.get("aggressive_push_prob", 0.05)

# 武器类型（对齐 WeaponMount.WeaponType 枚举序：本地常量避免跨类依赖）
const SWORD: int = 0
const SPEAR: int = 1
const BOW: int = 2
const PICKAXE: int = 3
const STAFF: int = 4
const MERIC: int = 5

# ─────────────────────────────── 基线（人性基线，RWR default.ai 思路）────────────────────────────────
## 所有兵种共享的默认行为参数。字段说明：
##   acquire_interval     目标扫视轮询间隔（s）——感知节奏，RWR 1s 扫视、本作决策 0.3s
##   hesitate_prob        犹豫概率（每次检查）——反应迟疑，RWR 反应延迟 0.3~1.1s 随机
##   hesitate_time        犹豫时长范围 Vector2(min, max)（s）
##   aggressive_push_prob 擅自冲锋概率（每次接近时）
##   leash_mult           追击放弃倍数（目标超出射程 × 此值即"追丢了"）
##   kite_range           保距射击距离（px，>0 时敌人近于此距离边打边撤）
##   kite_run             后撤时是否奔跑
const BASELINE: Dictionary = {
	"acquire_interval": 0.5,
	"hesitate_prob": 0.03,
	"hesitate_time": Vector2(0.3, 0.8),
	"aggressive_push_prob": 0.05,
	"leash_mult": 4.0,
	"kite_range": 0.0,
	"kite_run": false,
	"aim_hold": Vector2.ZERO,               ## 拉弓瞄准保持区间（s），ZERO=关闭（SWL ArcherAi.ShouldAim/isAiming 节奏）
	"aim_scatter": 0.0,                     ## 放箭方向高斯散布 σ（rad，SWL NextGaussian/currentShotBodyRandomness）
	"prefer_large": 0.0,                    ## 大目标偏好权重，0=关（SWL ArcherAi.AttackLargeTarget）
	"arrow_threat_block": false,            ## 被箭瞄准即举盾（SWL SpeartonAi.IsAnyArrowThreat）
	"arrow_block_hold": 0.8,                ## 威胁记忆窗口（s，_lastArrowThreatTime 对齐）
	"y_drift_band": 30.0,                   ## y 纵深个性漂移半径（px，SWL personalityControlledY）
	"y_drift_interval": Vector2(0.5, 1.2),  ## 漂移目标重掷区间（s，DIRECTION_CHANGE_FREQUENCY=0.5 对齐）
	"y_align_x_range": 300.0,               ## 调 y 门槛：|Δx| 小于此才对齐目标 y（SWL IsCloseEnoughToAdjustYTowardsTarget；无 dump 真值，待实测校准）
	"y_align_early": false,                 ## 提前对齐（SWL adjustYEarly 参数：远程兵种接敌全程调 y，近战只在近处）
	"y_align_strength": 0.22,               ## y 对齐走位分量强度（0~1 叠加到移动方向）
	"y_aim_tolerance": 0.0,                 ## 9p：射程内 |Δy| 超此值先 y 走位不出手（px；0=关。SWL ShouldAim/CanAttack 的 y 门槛近似，待实测校准）
	"missing_arrows_tolerance": 0.0,        ## 11d 弓手脱靶容忍（dump ArcherAi.MissingArrowsTolerance）：目标在飞箭伤害估计超出"击杀所需+此值"即不出手（HP 点；0=关）
	"move_mult": 1.0,                       ## 移速倍率（SWL 兵种机动性：Swordwrath 轻快、Spearton 沉稳）
	"block_after_attack": 0.0,              ## 攻击后举盾时长（s，SWL Ai.cooldownAfterAttackForBlock；0=关）
	"formation_block": false,               ## 行军/待命举盾（SWL UpdateBlockWhenInFormation：盾兵行军盾不放下）
	"push_apart": 0.0,                      ## 站桩输出时与友军保持的间距（px，SWL PushApartTolerance；0=关）
	"summon_count": 0,                      ## 召唤护卫数量（SWL MagikillAi.ShouldCastSummon；0=无召唤）
	"summon_cooldown": 12.0,                ## 召唤冷却（s）
	"summon_hp": 40.0,                      ## 护卫 HP（minidon 脆皮）
	"summon_body_scale": 0.65,              ## 护卫体型倍率（SWL minidon 比常规兵种小一圈）
	"spell_aoe_radius": 0.0,                ## 法术命中点爆炸半径（px，SWL CastStun/StunOpponents 放倒一片；0=关）
	"block_walk_anim": "",                  ## 持盾行军动画（盾姿态分层，计划 5；空=无持盾变体）
	"block_idle_anim": "",                  ## 持盾待命动画（空=无）
	"block_attack_pool": [],                ## 持盾攻击动画池（举盾时随机抽取，如三连刺）
	"block_move_mult": 1.0,                 ## 持盾移速倍率（举盾行军更沉稳）
	"attack_pool": [],                      ## 攻击动画池（9f：非举盾攻击随机抽取；空=只用武器基础攻击动画。动画名对齐 stickman_anims）
	"stand_pool": [],                       ## 站姿变体池（9r：进待机随机抽取；空=武器默认站姿。动画名对齐 stickman_anims）
	# ── 9i+ 溃逃保真五项增强（P6 批次 7c：能力开关，默认全关 = 零回归）──
	# 消费函数与降级路径：开关关 / 姿态查询不可用（未注册阵营 AI）→ 既有行为。
	# 全部只改走位/决策取向，不触碰选目标、出手、伤害管线。数值均待实测校准。
	"rout_reengage_enabled": false,         ## 逃开后再战（ai_controller._try_combat 脱战低士气分支）
	"re_engage_morale": 0.15,               ## 再战所需士气比例（0~1；需 < 低士气阈值 0.25 才在脱战分支内触发，待实测校准）
	"retreat_keep_block": false,            ## 保持招架（behavior_retreat：持盾兵种撤退全程举盾）
	"rout_strafe_enabled": false,           ## 垂直位游走（behavior_retreat：撤退叠加垂直横向分量）
	"rout_strafe_strength": 0.35,           ## 横向分量强度（0~1 叠加到撤退方向）
	"test_engage_enabled": false,           ## 前排怯战试探接敌（ai_controller：脱战低士气脉冲接敌）
	"test_pulse_on": 2.0,                   ## 试探接敌脉冲开启时长（s）
	"test_pulse_off": 3.0,                  ## 试探接敌脉冲关闭时长（s）
	"test_engage_range": 480.0,             ## 试探接敌触发距离（px，射程边缘近似）
	"flank_enabled": true,                 ## 包抄走位（behavior_attack：侧翼单位接近叠加侧向分量）
	"flank_y_offset": 120.0,                ## 侧翼判定：相对本方质心 y 偏移绝对值阈值（px）
	"flank_side_strength": 0.40,            ## 包抄侧向分量强度（0~1）
	# ── P7 批次 7b 治疗档案族（祭司 Meric；全部默认"关闭/零"，非祭司无消费路径 = 零回归）──
	# dump MericAi 全部 3 行为函数与 Meric 实体层治疗方法（CastHeal/CanCastHeal/IsCastingHeal）
	# 均无方法体：healAmount/healCooldown 字段名真值存在，数值全部语义推断（待实测校准）。
	"heal_enabled": false,                  ## 治疗能力开关（MericAi 直译消费端 behavior_heal）
	"heal_amount": 0.0,                     ## 单次治疗总量（HP 点，dump healAmount 字段名真值；HOT 均分到 tick）
	"heal_cooldown": 0.0,                   ## 治疗冷却（s，dump healCooldown 字段名真值；MERIC 档须 ≥ 施法动画时长，9d 同款校验）
	"heal_range": 0.0,                      ## 治疗射程（px，语义推断待实测校准）
	"heal_duration": 0.0,                   ## HOT 持续时长（s，总量均分 per_tick）
	"heal_scan_interval": 0.5,              ## 治疗目标扫视周期（s，MericAi.UpdateTarget 节流推断）
	"rear_line": false,                     ## 后排站位（FormationSystem 尾列取向；duck 查询不跨模块 preload）
}

# ─────────────────────────────── 兵种差异（RWR 职业文件：只写不同项）────────────────────────────────
## 对照 legacy 逐兵种 Ai 个性（审计 §四）：
##   剑士 = SwordwrathAi 冲脸：高冲锋、几乎不犹豫、追得远、**轻量移速快**（1.3×）
##   矛兵 = SpeartonAi 持阵：绝不擅自脱线、守位（LEASH 收紧防脱阵）、**移速慢盾长**（0.85×）
##   弓手 = ArcherAi 保持距离：被近身就后撤（风筝），站桩输出节奏稳
##   镐  = MinerAi 避敌：胆小犹豫（战斗中罕见，多为工人）
##   杖  = MagikillAi 脆皮法师：保持距离 + 施法前摇长（犹豫=吟唱节奏）
const CLASS_PROFILES: Dictionary = {
	SWORD: {
		"aggressive_push_prob": 0.25,
		"hesitate_prob": 0.01,
		"leash_mult": 6.0,
		"acquire_interval": 0.4,
		"y_drift_band": 40.0,
		"move_mult": 1.3,
	},
	SPEAR: {
		"aggressive_push_prob": 0.0,
		"hesitate_prob": 0.0,
		"leash_mult": 3.0,
		"arrow_threat_block": true,
		"y_drift_band": 15.0,
		"move_mult": 0.85,
		"block_after_attack": 0.7,
		"formation_block": true,
		# 盾姿态分层（计划 5，SWL Spearton 持盾形态）：端盾行军/待命/三连刺
		"block_walk_anim": "block_walk",
		"block_idle_anim": "block_crouch",
		"block_attack_pool": ["block_attack_1", "block_attack_2", "block_attack_3"],
		"block_move_mult": 0.8,
		# 9f：戳刺攻击池（Attack1 横扫观感 + Attack2/3 戳刺，随机混出对比）
		"attack_pool": ["attack_spear", "attack_spear_2", "attack_spear_3"],
		# 9r：站姿候选池（Into-Stand1/2"落定成站姿"，与静态 Stand1 对比验收）
		"stand_pool": ["idle_spear_v2", "idle_spear_v3"],
	},
	BOW: {
		"kite_range": 500.0,
		"aggressive_push_prob": 0.0,
		"hesitate_prob": 0.02,
		"leash_mult": 5.0,
		"acquire_interval": 0.4,
		"aim_hold": Vector2(0.25, 0.9),
		"aim_scatter": 0.035,
		"prefer_large": 1.0,
		"push_apart": 56.0,
		# y 对齐（SWL ArcherAi.IsCloseEnoughToAdjustYTowardsTarget override：收紧调 y 门槛
		# + adjustYEarly 提前对齐；9p 首个消费者：|Δy| 超容忍先走位不出手。阈值待实测校准）
		"y_align_early": true,
		"y_align_x_range": 240.0,
		"y_aim_tolerance": 48.0,
		# 11d 弓手脱靶容忍（MissingArrowsTolerance 直译：对将死目标浪费箭的阈值）。
		# 半箭伤害（基础 10 的 1 倍）起步，无 dump 真值 → 待实测校准
		"missing_arrows_tolerance": 10.0,
	},
	PICKAXE: {
		"hesitate_prob": 0.08,
	},
	STAFF: {
		"kite_range": 0.0,
		"hesitate_prob": 0.06,
		"hesitate_time": Vector2(0.5, 1.1),
		"leash_mult": 5.0,
		"y_drift_band": 15.0,
		"move_mult": 0.9,
		"summon_count": 2,
		# 召唤冷却校准（P5 批次 2）：SWL wiki 法师召唤冷却 ~5s（原 12s 为近似值）
		"summon_cooldown": 5.0,
		"summon_hp": 40.0,
		# 法术爆炸（SWL CastStun/StunOpponents 放倒一片：命中点范围伤害+击晕）
		"spell_aoe_radius": 90.0,
	},
	MERIC: {
		# P7 批次 7b 祭司（SWL Meric）：本地无 wiki 真值，全推断初值待实测校准（决策点 7）
		"heal_enabled": true,
		"heal_amount": 30.0,          ## 单次治疗总量（HP 点，待实测校准）
		"heal_cooldown": 3.0,         ## 治疗冷却 ≥ 施法动画时长（heal_meric_* 全长实测后校准，9d 同款硬约束）
		"heal_range": 400.0,          ## 治疗射程（px，语义推断待实测校准）
		"heal_duration": 3.0,         ## HOT 持续（s，总量均分 per_tick = amount × TICK / duration）
		"heal_scan_interval": 0.5,    ## 目标扫视周期（s）
		"kite_range": 260.0,          ## 被近身保距撤离（决策点 4：撤而不打；置 0 无损切换为站定）
		"kite_run": true,             ## 撤离奔跑
		"rear_line": true,            ## 后排站位（FormationSystem 尾列取向）
		"move_mult": 0.7,             ## 脆皮辅助移速（< 法师 0.9，待实测校准）
		"hesitate_prob": 0.05,        ## 犹豫概率（辅助个性）
		"y_drift_band": 15.0,         ## y 纵深漂移半径（同法师）
	},
}

## 档案缓存（weapon_type -> 合并后 Dictionary）
static var _cache: Dictionary = {}


## 获取兵种行为档案：基线 + 兵种覆盖合并（覆盖项浅合并，未覆盖项回落基线）。
## 未知类型返回基线副本。
static func get_profile(weapon_type: int) -> Dictionary:
	if _cache.has(weapon_type):
		return _cache[weapon_type]
	var merged: Dictionary = BASELINE.duplicate()
	var override: Dictionary = CLASS_PROFILES.get(weapon_type, {})
	for k in override.keys():
		merged[k] = override[k]
	_cache[weapon_type] = merged
	return merged
