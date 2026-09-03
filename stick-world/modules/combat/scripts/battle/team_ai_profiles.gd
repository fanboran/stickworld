class_name TeamAiProfiles
extends RefCounted
## 阵营 AI 参数档案 -- TeamAi 姿态机的全部可调参数（RWR 档案制，计划 §七.7）。
##
## 真值声明（§七.9）：legacy dump TeamAi 21 个行为函数均为 IL2CPP 签名级导出、
## **无方法体**，本档案所有数值仅有签名/字段名/枚举序真值，具体数值全部为
## 语义推断初值，**均待实测校准**（先例：UNITS_PER_COLUMN/ROW_GAP）。
##
## 落位说明：放 combat 模块而非 units 的 BehaviorProfiles——TeamAi 消费端在
## combat，若 preload units 档案将与既有 units→combat preload
## （behavior_attack.gd TargetFinder）形成模块依赖环（P6 design §1.1.2）。
##
## 用法（team_ai.gd）：
##   var p: Dictionary = TeamAiProfiles.get_profile(overrides)
##   var ratio: float = p["attack_enter"]

## 武器/兵种类别（对齐 WeaponMount.WeaponType 枚举序 + BehaviorProfiles 本地常量；
## GIANT 为 P8 巨人批次占位类别，当前无对应 WeaponType，TeamHasAGiant 判定恒假属预期）
const SWORD: int = 0
const SPEAR: int = 1
const BOW: int = 2
const PICKAXE: int = 3
const STAFF: int = 4
const MERIC: int = 5  ## P7 批次 7b 祭司（本地常量，不跨模块引用 BehaviorProfiles）
const GIANT: int = 9  ## 占位类别（P8 前不出现）

## 姿态枚举（对齐 dump Team.Stance 枚举序：0=GARRISON/1=DEFEND/2=ATTACK）
const STANCE_GARRISON: int = 0
const STANCE_DEFEND: int = 1
const STANCE_ATTACK: int = 2


## 默认参数档案（待实测校准）：
##   stance_decision_interval   决策周期（s，下限 0.5，spec §4.1.1）
##   attack_enter/attack_exit   ATTACK 进入/退出力量比值阈值（双阈值滞回带）
##   defend_enter/defend_exit   DEFEND 进入/退出力量比值阈值（双阈值滞回带）
##   stance_change_cooldown     全姿态切换统一冷却（s，60s 理论上限 12 次防号令风暴）
##   garrison_cool              驻守维持时长（s，WeRecentlyDecidedToGarrison 语义）
##   seconds_before_attack      开局攻击门禁（s，SecondsBeforeCanLeaveBase 语义近似）
##   enemy_close_dist           敌军质心距本方锚点近于此值视为"敌近"（px）
##   projectile_window          投射物来袭登记新鲜窗口（s）
##   no_defender_floor          本方防守力量占满编力量比例低于此值视为"无防守者"
##   unit_weights               兵种军事力量权重（PICKAXE=0 非军事单位）
##   anchor_margin              阵营侧锚点距地图边内收（px）
##   manual_order_guard         玩家手动号令保护期（s，姿态号令避让）
##   ratio_empty_enemy_sentinel 敌方力量为 0 时的力量比值哨兵（全歼敌军=绝对优势）
##   type_priority              兵种优先序（CompareUnitTypes 比较器，排序真值来自签名语义）
const DEFAULTS: Dictionary = {
	"stance_decision_interval": 1.0,
	"attack_enter": 1.30,
	"attack_exit": 1.10,
	"defend_enter": 0.85,
	"defend_exit": 1.00,
	"stance_change_cooldown": 5.0,
	"garrison_cool": 8.0,
	"seconds_before_attack": 10.0,
	"enemy_close_dist": 900.0,
	"projectile_window": 3.0,
	"no_defender_floor": 0.35,
	"unit_weights": {
		SWORD: 1.0,
		SPEAR: 2.0,
		BOW: 1.5,
		STAFF: 3.0,
		MERIC: 1.0,  ## P7 祭司：脆皮辅助 < 法师 3.0（待实测校准）
		GIANT: 10.0,
		PICKAXE: 0.0,
	},
	"anchor_margin": 260.0,
	"manual_order_guard": 8.0,
	"ratio_empty_enemy_sentinel": 10.0,
	"type_priority": [GIANT, STAFF, SPEAR, BOW, MERIC, SWORD],  ## P7 祭司插 BOW 与 SWORD 之间（待实测校准）
}

## 决策周期硬下限（spec §4.1.1：覆盖注入不得低于此值，防号令风暴）
const MIN_DECISION_INTERVAL: float = 0.5

## 覆盖缓存（overrides 序列化键 -> 合并后档案；供 battle_sim 扫参复用）
static var _cache: Dictionary = {}


## 获取阵营 AI 参数档案：默认值 + overrides 浅合并（仅 setup 期消费一次）。
## overrides 只覆盖标量键；unit_weights/type_priority 等容器键整键替换。
## 决策周期钳制到 MIN_DECISION_INTERVAL 下限。
static func get_profile(overrides: Dictionary = {}) -> Dictionary:
	var merged: Dictionary = DEFAULTS.duplicate(true)
	for k in overrides.keys():
		if merged.has(k):
			merged[k] = overrides[k]
	var interval: float = float(merged["stance_decision_interval"])
	merged["stance_decision_interval"] = maxf(interval, MIN_DECISION_INTERVAL)
	return merged


## 兵种军事力量权重查询（未知类别权重 0，非军事单位不贡献力量值）
static func get_unit_weight(profile: Dictionary, weapon_type: int) -> float:
	var weights: Dictionary = profile.get("unit_weights", {})
	return float(weights.get(weapon_type, 0.0))