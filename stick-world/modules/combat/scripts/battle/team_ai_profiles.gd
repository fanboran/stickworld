class_name TeamAiProfiles
extends RefCounted
## 阵营 AI 参数档案 -- TeamAi 姿态机的全部可调参数（RWR 档案制，计划 §七.7）。
##
## 真值声明（§七.9）：legacy dump TeamAi 21 个行为函数均为 IL2CPP 签名级导出、
## **无方法体**，本档案所有数值仅有签名/字段名/枚举序真值，具体数值全部为
## 语义推断初值，**均待实测校准**（先例：UNITS_PER_COLUMN/ROW_GAP）。
##
## A1（设计文档12号 C1/C2）新增：
##   - personality 单一参数档案：配置在 BalanceConfig（res://config/ai/personality.tres，
##     类型路径 ai.personality），难度分档维度已裁决移除（开放问题#3）——机制参数
##     （开局攻击时间/方差/概率）保留、收敛为单一默认档案；load_personality_overlay
##     负责装载，merge 序 = 代码默认 < personality 档案 < setup 显式 overrides。
##   - beat_interval：L4 层基础节拍（C1 收敛红线：每层一个基础节拍，CoH 0.5s 真值），
##     取代旧 stance_decision_interval（分帧相位轮转表达，见 team_ai.tick）。
##   - start_attack_variance：开局攻击时间 ± 掷骰半宽（CoH 9min±4min 同构）。
##   - demand_variance：三游戏统一的方差扰动单旋钮（收敛红线，A4 效用打分消费）。
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

## 姿态枚举（对齐 dump Team.Stance 枚举序：0=GARRISON/1=DEFEND/2=ATTACK；
## 3=ROUT 为本作扩展——敌将撤仗终态，据点战专用，见出征与领地架构 §4.2）
const STANCE_GARRISON: int = 0
const STANCE_DEFEND: int = 1
const STANCE_ATTACK: int = 2
const STANCE_ROUT: int = 3


## 默认参数档案（待实测校准）：
##   beat_interval              L4 基础节拍（s，下限 MIN_BEAT_INTERVAL；C1，CoH 0.5s 真值）
##   attack_enter/attack_exit   ATTACK 进入/退出力量比值阈值（双阈值滞回带）
##   defend_enter/defend_exit   DEFEND 进入/退出力量比值阈值（双阈值滞回带）
##   stance_change_cooldown     全姿态切换统一冷却（s，60s 理论上限 12 次防号令风暴）
##   garrison_cool              驻守维持时长（s，WeRecentlyDecidedToGarrison 语义）
##   seconds_before_attack      开局攻击门禁基准值（s，SecondsBeforeCanLeaveBase 语义近似；
##                              实际门禁 = 本值 ± start_attack_variance 掷骰，A1）
##   start_attack_variance      开局攻击时间 ± 掷骰半宽（s，CoH 9min±4min 同构，A1）
##   demand_variance            方差扰动单旋钮（收敛红线；A4 效用打分消费，A1 先随档案装载）
##   enemy_close_dist           敌军质心距本方锚点近于此值视为"敌近"（px）
##   projectile_window          投射物来袭登记新鲜窗口（s）
##   no_defender_floor          本方防守力量占满编力量比例低于此值视为"无防守者"
##   unit_weights               兵种军事力量权重（PICKAXE=0 非军事单位）
##   anchor_margin              阵营侧锚点距地图边内收（px）
##   manual_order_guard         玩家手动号令保护期（s，姿态号令避让）
##   ratio_empty_enemy_sentinel 敌方力量为 0 时的力量比值哨兵（全歼敌军=绝对优势）
##   type_priority              兵种优先序（CompareUnitTypes 比较器，排序真值来自签名语义）
## （旧 stance_decision_interval 已退役：决策节拍收敛为 beat_interval 基础节拍 +
##   双相位轮转偏移——C1 红线「每层一个基础节拍 + 行为级偏移」，A1）
##   retreat_casualty_rate      撤仗阈值：本方伤亡率超此值判定"这仗不能打了"
##                              （≤0 不启用 = 普通战斗维持全灭判定的注册制闸门）
##   retreat_loss_ratio         撤仗阈值：本方伤亡/敌方伤亡 超此值（打不动对面）
##   retreat_timeout            撤仗阈值：战斗持续秒数超此值（相持不下）
##   三阈值任一 >0 即武装撤仗评估，满足其一即切 ROUT（据点战由 territories.commander 注入）
## ── A2 · C3/C4/C5 任务槽与攻击百分比（CoH 真值见逆向笔记 §3.2/§3.3；语义映射初值待校准）──
##   slot_kernel_enabled        决策内核开关：true=CoH 槽内核（咬合③主路径），
##                              false=SWL 比例条件退化路径（should_attack/should_defend）
##   score_threat               C4 目标评分·威胁权重（CoH 5.0）
##   score_avoid_clumps_at_no_threat  C4 目标评分·无威胁时敌群聚集惩罚权重（CoH 10.0）
##   score_distance_to_squad    C4 目标评分·距小队（本方质心）惩罚权重（CoH 5.0）
##   score_distance_to_base     C4 目标评分·距基地（本方锚点）惩罚权重（CoH 5.0）
##   score_inertia              C4 目标评分·惯性防振荡奖励权重（CoH 1.4）
##   score_threat_radius        威胁因子取数半径（px；语义映射初值）
##   score_clump_radius         聚集因子取数半径（px；语义映射初值）
##   score_distance_norm        距离因子归一化尺度（px）
##   score_inertia_tolerance    惯性判定容差（px，候选距上次目标小于此值视为同一目标）
##   attack_rally_timeout       攻击槽集结超时（s，CoH 3min；到点杀槽由 sync 重建）
##   attack_target_timeout      攻击槽目标超时→重评分重定向（s，CoH 30s）
##   defend_target_timeout      防守槽目标超时→重定位刷数据（s，CoH 2min；不重发号令）
##   defend_rally_timeout       防守槽集结超时（s；CoH 未给真值，取防守目标超时 2 倍）
##   attack_pct_baseline        C5 攻击百分比基调（单一参数曲线，CoH 默认 0.6）
##   attack_pct_growth_per_min  C5 开门禁后每分钟递增（CoH +0.01/min）
##   max_attack_percentage      C5 攻击百分比上限（CoH 0.70）
##   superiority_ratio_floor    C5 军力优势递增起点（归一化优势，CoH 0.4）
##   superiority_gain           C5 超出起点部分→pct 增益系数（语义映射初值）
##   base_threat_threshold      C5 基地威胁封顶触发值（0-100 口径，CoH 5）
##   base_threat_floor          C5 基地威胁封顶下限（%，CoH max(100-threat,5)）
##   vp_rule_enabled            C5 规则一胜利目标危急（开放问题#1：无 VP 等价物，
##                              缺省关闭【提案/待定】；旗/区域控制接入后启用）
const DEFAULTS: Dictionary = {
	"beat_interval": 0.5,
	"attack_enter": 1.30,
	"attack_exit": 1.10,
	"defend_enter": 0.85,
	"defend_exit": 1.00,
	"stance_change_cooldown": 5.0,
	"garrison_cool": 8.0,
	"seconds_before_attack": 10.0,
	"start_attack_variance": 2.0,
	"demand_variance": 0.8,
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
	# 撤仗阈值（C3 敌将撤仗）：默认全负 = 不启用（普通战斗/双开扫参零回归；
	# 据点战 enable_team_ai 时经 overrides 注入 territories.commander.retreat_thresholds）
	"retreat_casualty_rate": -1.0,
	"retreat_loss_ratio": -1.0,
	"retreat_timeout": -1.0,
	# ── A2 · C3/C4/C5（personality global 行镜像值 = 零回归基线；CoH 真值见逆向笔记 §3.2/§3.3）──
	"slot_kernel_enabled": true,
	"score_threat": 5.0,
	"score_avoid_clumps_at_no_threat": 10.0,
	"score_distance_to_squad": 5.0,
	"score_distance_to_base": 5.0,
	"score_inertia": 1.4,
	"score_threat_radius": 260.0,
	"score_clump_radius": 300.0,
	"score_distance_norm": 1200.0,
	"score_inertia_tolerance": 120.0,
	"attack_rally_timeout": 180.0,
	"attack_target_timeout": 30.0,
	"defend_target_timeout": 120.0,
	"defend_rally_timeout": 240.0,
	"attack_pct_baseline": 0.6,
	"attack_pct_growth_per_min": 0.01,
	"max_attack_percentage": 0.70,
	"superiority_ratio_floor": 0.4,
	"superiority_gain": 1.0,
	"base_threat_threshold": 5.0,
	"base_threat_floor": 5.0,
	"vp_rule_enabled": false,
}

## 基础节拍硬下限（对齐旧 MIN_DECISION_INTERVAL：覆盖注入不得低于此值，防号令风暴）
const MIN_BEAT_INTERVAL: float = 0.5

## setup 未显式给 random_seed 时的默认随机种子（确定性：单测可锁、battle_sim 可复现；
## 需要每局差异的调用方显式传 seed，A1）
const DEFAULT_RANDOM_SEED: int = 20260911

## 覆盖缓存（overrides 序列化键 -> 合并后档案；供 battle_sim 扫参复用）
static var _cache: Dictionary = {}


## 获取阵营 AI 参数档案：默认值 + personality 单一档案/overrides 浅合并（仅 setup 期消费一次）。
## overrides 只覆盖标量键；unit_weights/type_priority 等容器键整键替换。
## 基础节拍钳制到 MIN_BEAT_INTERVAL 下限。
static func get_profile(overrides: Dictionary = {}) -> Dictionary:
	var merged: Dictionary = DEFAULTS.duplicate(true)
	for k in overrides.keys():
		if merged.has(k):
			merged[k] = overrides[k]
	var beat: float = float(merged["beat_interval"])
	merged["beat_interval"] = maxf(beat, MIN_BEAT_INTERVAL)
	return merged


## 装载 personality 单一档案覆盖层（A1 · C2，难度分档已裁决移除·开放问题#3）：
## 只读 global 行（节拍/开局门禁/方差/攻击百分比/撤退掷骰等机制参数）。
## BalanceConfig 缺载/路径缺失时返回空字典（get_profile 侧代码默认兜底）。
static func load_personality_overlay() -> Dictionary:
	var overlay: Dictionary = {}
	var cfg: Node = _balance_config()
	if cfg == null:
		return overlay
	var global_v: Variant = cfg.get_value("ai.personality.global")
	if global_v is Dictionary:
		overlay.merge(global_v)
	return overlay


## BalanceConfig autoload 稳健解析（static 上下文不直引 autoload 标识符；
## 主循环未就绪/非 SceneTree 返回 null，调用方空档案例外兜底）
static func _balance_config() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null("BalanceConfig")


## 兵种军事力量权重查询（未知类别权重 0，非军事单位不贡献力量值）
static func get_unit_weight(profile: Dictionary, weapon_type: int) -> float:
	var weights: Dictionary = profile.get("unit_weights", {})
	return float(weights.get(weapon_type, 0.0))