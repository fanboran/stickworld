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
	"move_mult": 1.0,                       ## 移速倍率（SWL 兵种机动性：Swordwrath 轻快、Spearton 沉稳）
	"block_after_attack": 0.0,              ## 攻击后举盾时长（s，SWL Ai.cooldownAfterAttackForBlock；0=关）
	"formation_block": false,               ## 行军/待命举盾（SWL UpdateBlockWhenInFormation：盾兵行军盾不放下）
	"push_apart": 0.0,                      ## 站桩输出时与友军保持的间距（px，SWL PushApartTolerance；0=关）
	"summon_count": 0,                      ## 召唤护卫数量（SWL MagikillAi.ShouldCastSummon；0=无召唤）
	"summon_cooldown": 12.0,                ## 召唤冷却（s）
	"summon_hp": 40.0,                      ## 护卫 HP（minidon 脆皮）
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
		"summon_cooldown": 12.0,
		"summon_hp": 40.0,
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
