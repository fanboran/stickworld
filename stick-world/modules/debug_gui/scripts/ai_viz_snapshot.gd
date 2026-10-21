extends RefCounted
## AI 决策可视化 · 观测快照层 —— 给 AiVizWindow 取数的纯只读查询库。
##
## 设计纪律（任务口径"纯观测不改行为"）：
##   - 本文件只读：全部经实体/AI 控制器的公开查询口与既有观测面 duck 调用
##     （先例 debug_info_panel._append_ai_info 读 _get_behavior_profile /
##     _squad_phase_plans），**不写任何 AI 状态、不触发决策**；
##   - 切换原因推断在信号到达时点做（ai_viz_window 订阅 EventBus），瞬时态
##     （看门狗推力/附身恢复）过后即逝，轮询侧补推不准——快照层只提供
##     describe_switch_reason 供信号时点调用；
##   - 任一环查询不可用即跳过该字段（调试面板不倒逼战斗侧改结构，同 W1 口径）。
##
## 信息密度对标 LimboAI 调试器：单位列表 → 选中看详情（行为注册表当前态高亮 /
## 目标及选择理由 / 关键阈值余量 / 决策时钟 / 号令 / 特殊态）。

# ─────────────────────────────── 展示字典 ────────────────────────────────

## 兵种中文名（weapon_type → 展示名；对齐 battle_arena 六兵种）
const WEAPON_NAMES: Dictionary = {
	0: "剑士", 1: "矛士", 2: "弓手", 3: "矿工", 4: "法师", 5: "祭司",
}

## 行为中文名（behavior_name → 展示名；语义对齐各 behavior_* 文件头注释）
const BEHAVIOR_NAMES: Dictionary = {
	"idle": "待命", "wander": "闲逛", "work": "建造", "haul": "搬运",
	"harvest": "采集", "follow": "跟随", "move": "移动", "attack": "攻击",
	"seek_cover": "找掩体", "retreat": "避战", "heal": "治疗",
}

## 阵营展示色（1 蓝=攻 / 2 红=守 / 其他中立灰）
const FACTION_COLORS: Dictionary = {
	1: Color(0.55, 0.75, 1.0), 2: Color(1.0, 0.62, 0.55), 0: Color(0.7, 0.7, 0.7),
}

## 撤退安全距离（镜像 behavior_retreat.SAFE_DISTANCE——常量只读复制，
## 观测侧不 import 行为类防依赖倒挂；源常量变更时此处同步）
const RETREAT_SAFE_DISTANCE: float = 320.0


# ─────────────────────────────── 实体枚举 ────────────────────────────────

## 世界宿主解析（带 get_current_map 的节点，即 GameRoot）：
## 常规玩法 game_root 是当前场景 = root 直子；观察场等调试场景嵌套挂载
##（GameRoot 是场景孙子），靠 find_child 名字兜底。调用方缓存宿主（本函数
## 只查不存），解析失败返回 null。
static func resolve_game_host(tree: SceneTree) -> Node:
	var root: Node = tree.root
	# 常规路径：root 直子（先例 debug_info_panel._get_current_map）
	for i in root.get_child_count():
		var child: Node = root.get_child(i)
		if child.has_method("get_current_map"):
			return child
	# 嵌套路径：观察场等（battle_arena 把 GameRoot instantiate 成子节点）
	var nested: Node = root.find_child("GameRoot*", true, false)
	if nested != null and nested.has_method("get_current_map"):
		return nested
	return null


## 当前地图（经世界宿主；宿主未装配/图未加载返回 null）
static func get_current_map(host: Node) -> Node2D:
	if host == null or not is_instance_valid(host) or not host.has_method("get_current_map"):
		return null
	var map: Node2D = host.get_current_map() as Node2D
	if map != null and is_instance_valid(map):
		return map
	return null


## 当前地图全部带 AI 控制器的实体（存活优先；死亡单位不入列——列表看"谁在想"）
static func collect_ai_entities(host: Node) -> Array:
	var map: Node2D = get_current_map(host)
	var out: Array = []
	if map == null or not map.has_method("get_entities"):
		return out
	for e in map.get_entities():
		if e == null or not is_instance_valid(e):
			continue
		if not (e is Node2D):
			continue
		if e.has_method("is_dead") and e.is_dead():
			continue
		if not e.has_method("get_ai_controller"):
			continue
		var ai: Node = e.get_ai_controller()
		if ai == null or not is_instance_valid(ai):
			continue
		out.append(e)
	return out


# ─────────────────────────────── 列表行摘要 ────────────────────────────────

## 单位列表行摘要（左栏一行；字段全可选——查询不可用给缺省）
static func unit_row(e: Node) -> Dictionary:
	var ai: Node = e.get_ai_controller() if e.has_method("get_ai_controller") else null
	var behavior: String = str(ai.get_current_behavior()) \
			if ai != null and ai.has_method("get_current_behavior") else "?"
	return {
		"entity": e,
		"iid": e.get_instance_id(),
		"faction": _faction_of(e),
		"unit_label": unit_label(e),
		"behavior": behavior,
		"behavior_zh": BEHAVIOR_NAMES.get(behavior, behavior),
		"hp": hp_pair(e),
		"flags": flag_glyphs(e, ai),
		"target_iid": target_iid(e, behavior),
	}


## 单位短标（兵种#iid尾号——观察场单位无名，iid 尾号即足区分）
static func unit_label(e: Node) -> String:
	var wn: String = ""
	var w: Node = e.get_weapon() if e.has_method("get_weapon") else null
	if w != null and is_instance_valid(w) and "weapon_type" in w:
		wn = str(WEAPON_NAMES.get(int(w.weapon_type), "?"))
	return "%s#%d" % [wn if not wn.is_empty() else "单位", e.get_instance_id() % 1000]


## 特殊态徽标串（列表行内联；详情栏有全量文字版）
static func flag_glyphs(e: Node, ai: Node) -> String:
	var g: String = ""
	if ai != null and ai.has_method("has_order") and ai.has_order():
		g += "令"
	if ai != null and ai.has_method("is_breach_engaged") and ai.is_breach_engaged():
		g += "通"
	if ai != null and ai.has_method("is_disengaging") and ai.is_disengaging():
		g += "避"
	if e.has_method("is_in_hit_stun") and e.is_in_hit_stun():
		g += "晕"
	if e.has_method("is_possessed") and e.is_possessed():
		g += "附"
	return g


# ─────────────────────────────── 选中详情 ────────────────────────────────

## 选中单位详情快照（右栏一次取全；字段见各 _detail 段）
static func unit_detail(e: Node) -> Dictionary:
	var ai: Node = e.get_ai_controller() if e.has_method("get_ai_controller") else null
	var d: Dictionary = {
		"label": unit_label(e),
		"faction": _faction_of(e),
		"faction_color": FACTION_COLORS.get(_faction_of(e), Color(0.7, 0.7, 0.7)),
		"pos": e.global_position if e is Node2D else Vector2.ZERO,
		"facing": int(e.get_facing()) if e.has_method("get_facing") else 0,
		"speed": e.velocity.length() if "velocity" in e else 0.0,
		"possessed": bool(e.is_possessed()) if e.has_method("is_possessed") else false,
		"hit_stun": bool(e.is_in_hit_stun()) if e.has_method("is_in_hit_stun") else false,
		"hp": hp_pair(e),
	}
	# 行为状态机段（LimboAI 树语义：注册表全列 + 当前高亮 + 完成态）
	_fill_behavior_detail(d, e, ai)
	# 目标段（目标/距离/射程余量/选择理由/驻留）
	_fill_target_detail(d, e, ai)
	# 阈值余量段（撤退线/冷却/出手门/持瞄/决策时钟）
	_fill_margin_detail(d, e, ai)
	# 号令段
	_fill_order_detail(d, e, ai)
	return d


## 行为状态机段：注册的全部行为（当前 ▶ + 中文名）+ 当前行为是否已 finish
##（ LimboAI 行为树视图的扁平等价：树节点着色 → 注册表当前项高亮）
static func _fill_behavior_detail(d: Dictionary, e: Node, ai: Node) -> void:
	d["current"] = ""
	d["finished"] = true
	d["registry"] = []  # [{name, zh, current}]
	if ai == null or not ai.has_method("get_state_machine"):
		return
	var sm: Node = ai.get_state_machine()
	if sm == null or not is_instance_valid(sm):
		return
	var cur: String = str(sm.get_current_behavior_name()) \
			if sm.has_method("get_current_behavior_name") else ""
	d["current"] = cur
	d["current_zh"] = str(BEHAVIOR_NAMES.get(cur, cur))
	d["finished"] = bool(sm.is_current_finished()) if sm.has_method("is_current_finished") else true
	var reg: Array = []
	var behaviors: Dictionary = sm.get("_behaviors") if "_behaviors" in sm else {}
	for bname in behaviors.keys():
		reg.append({
			"name": str(bname),
			"zh": str(BEHAVIOR_NAMES.get(str(bname), str(bname))),
			"current": str(bname) == cur,
		})
	reg.sort_custom(func(a, b) -> bool: return str(a["name"]) < str(b["name"]))
	d["registry"] = reg


## 目标段：当前目标（attack 的锁定 / heal 的治疗对象）、距离、射程余量、
## 选择理由（前向最近/全域回退/打通强制/锁定驻留）、目标血量。
## 无目标时保持空字典（调用方按 is_empty 分支——字段一律不落 null，
## 防窗口侧类型化赋值炸）
static func _fill_target_detail(d: Dictionary, e: Node, ai: Node) -> void:
	d["target"] = {}  # {label, iid, dist, range_margin, reason, dwell, hp}
	var cur: String = str(d.get("current", ""))
	var tgt: Node = null
	var source_behavior: Node = _current_behavior_node(ai)
	if cur == "attack" and source_behavior != null and source_behavior.has_method("get_target"):
		tgt = source_behavior.get_target()
	elif cur == "heal" and source_behavior != null and "_heal_target" in source_behavior:
		var ht: Variant = source_behavior.get("_heal_target")
		if ht is Node and is_instance_valid(ht):
			tgt = ht
	if tgt == null or not is_instance_valid(tgt):
		return
	var dist: float = e.global_position.distance_to(tgt.global_position) \
			if tgt is Node2D else -1.0
	var t: Dictionary = {
		"label": unit_label(tgt),
		"iid": tgt.get_instance_id(),
		"dist": dist,
		"hp": hp_pair(tgt),
		"dwell": -1.0,
		"range_margin": NAN,
		"reason": target_reason(e, tgt, source_behavior),
	}
	# 锁定驻留时长（target_acquire.get_dwell 观测面）
	if source_behavior != null and "_acq" in source_behavior:
		var acq: Variant = source_behavior.get("_acq")
		if acq != null and is_instance_valid(acq) and acq.has_method("get_dwell"):
			t["dwell"] = float(acq.get_dwell())
	# 射程余量（>0 = 目标在射程外还差多少 px；≤0 = 已进入射程）
	var w: Node = e.get_weapon() if e.has_method("get_weapon") else null
	if w != null and is_instance_valid(w) and "attack_range" in w and dist >= 0.0:
		t["range_margin"] = dist - float(w.attack_range)
	d["target"] = t


## 目标选择理由（纯观测推断，SWL 锁定口径 target_acquire.gd）：
## 打通强制 > 前向最近 > 全域回退；附锁定驻留时长
static func target_reason(e: Node, tgt: Node, behavior: Node) -> String:
	if behavior != null and "_acq" in behavior:
		var acq: Variant = behavior.get("_acq")
		if acq != null and is_instance_valid(acq):
			# 强制目标（打通态拦路者）最高优先
			var forced: Variant = acq.get("_forced_target") if "_forced_target" in acq else null
			if forced is Node and is_instance_valid(forced) and forced == tgt:
				return "打通态强制锁定（拦路者）"
			# 锁定到死语义：驻留 > 0 说明非本拍新选
			var dwell: float = float(acq.get_dwell()) if acq.has_method("get_dwell") else 0.0
			var forward: bool = (tgt.global_position.x - e.global_position.x) * _facing_sign(e) > 0.0
			var how: String = "前向最近敌" if forward else "全域回退（身前无敌）"
			if dwell > 0.1:
				return "%s · 锁定驻留 %.1fs（锁定到死）" % [how, dwell]
			return how + "（新选）"
	return "—"


## 阈值余量段（LimboAI 黑板观测的等价物：决策相关数值逐项给余量）。
## 各子项无数据时保持空字典（不落 null，同 _fill_target_detail 口径）
static func _fill_margin_detail(d: Dictionary, e: Node, ai: Node) -> void:
	# 武器冷却（装填/散热）：剩余 / 总长 + can_attack 态
	d["cooldown"] = {}
	var w: Node = e.get_weapon() if e.has_method("get_weapon") else null
	if w != null and is_instance_valid(w):
		var total: float = float(w.cooldown) if "cooldown" in w else 0.0
		var rem: float = float(w.get_cooldown_remaining()) \
				if w.has_method("get_cooldown_remaining") else 0.0
		if total > 0.0:
			d["cooldown"] = {
				"remaining": rem, "total": total,
				"ready": bool(w.can_attack()) if w.has_method("can_attack") else (rem <= 0.0),
			}
	# 撤退安全线余量：距最近敌 vs SAFE_DISTANCE（避战/撤退行为判定真值）
	d["retreat_margin"] = {}
	var bi: Node = e.get_battle_instance() if e.has_method("get_battle_instance") else null
	if bi != null and is_instance_valid(bi) and bi.has_method("get_nearest_enemy"):
		var enemy: Node = bi.get_nearest_enemy(e)
		if enemy != null and is_instance_valid(enemy) and enemy is Node2D:
			var dist: float = e.global_position.distance_to(enemy.global_position)
			d["retreat_margin"] = {
				"nearest_dist": dist,
				"safe_distance": RETREAT_SAFE_DISTANCE,
				"margin": dist - RETREAT_SAFE_DISTANCE,  # >0 = 已拉开到安全距离外
			}
	# 持瞄进度（弓/杖 aim_hold 节奏，behavior_attack 私有观测面）
	d["aim"] = {}
	var behavior: Node = _current_behavior_node(ai)
	if behavior != null and "_aiming" in behavior and "_aim_timer" in behavior:
		var hold: Variant = behavior.get("_profile").get("aim_hold", Vector2.ZERO) \
				if "_profile" in behavior else Vector2.ZERO
		if hold is Vector2 and (hold as Vector2).y > 0.0:
			var hv: Vector2 = hold
			d["aim"] = {
				"aiming": bool(behavior.get("_aiming")),
				"remain": float(behavior.get("_aim_timer")),
				"hold": hv,
			}
	# 决策时钟（AIController.get_decision_timing_state 既有导出面）
	d["clock"] = {}
	d["cooling_domains"] = []
	if ai != null and ai.has_method("get_decision_timing_state"):
		var ts: Dictionary = ai.get_decision_timing_state()
		var dec: Dictionary = ts.get("decision", {}) if ts.has("decision") else {}
		if dec.has("next_at"):
			var now: float = float(ts.get("now", 0.0))
			d["clock"] = {
				"due_in": float(dec["next_at"]) - now,  # 下次决策倒计时（s）
				"interval": float(dec.get("interval", 0.0)),
				"beats": int(dec.get("beats", 0)),
			}
			# 域级探测冷却（combat/job 失败冷却窗，默认关 = 恒到期）
			var dom: Dictionary = ts.get("domains", {}) if ts.has("domains") else {}
			var cooling: Array[String] = []
			for ch in dom.keys():
				var cd: Dictionary = dom[ch]
				if bool(cd.get("cooling_down", false)):
					cooling.append("%s(剩%.1fs)" % [str(ch), maxf(0.0, float(cd.get("next_at", 0.0)) - now)])
			d["cooling_domains"] = cooling
	# 特殊行为态
	d["disengaging"] = bool(ai.is_disengaging()) if ai != null and ai.has_method("is_disengaging") else false
	d["breach"] = bool(ai.is_breach_engaged()) if ai != null and ai.has_method("is_breach_engaged") else false
	d["under_threat"] = bool(ai.is_under_threat()) if ai != null and ai.has_method("is_under_threat") else false


## 号令段（命令覆盖 §8.3：号令优先于自主决策）
static func _fill_order_detail(d: Dictionary, e: Node, ai: Node) -> void:
	d["order"] = {}
	if ai == null or not ai.has_method("get_ordered_behavior"):
		return
	var ob: String = str(ai.get_ordered_behavior())
	if ob.is_empty():
		return
	var params: Dictionary = ai.get_ordered_params() if ai.has_method("get_ordered_params") else {}
	var brief: String = _order_params_brief(params)
	d["order"] = {
		"behavior": ob,
		"behavior_zh": str(BEHAVIOR_NAMES.get(ob, ob)),
		"params_brief": brief,
	}


## 号令参数摘要（观测侧可读的最短诊断串）
static func _order_params_brief(params: Dictionary) -> String:
	var parts: Array[String] = []
	if params.has("target"):
		var t: Variant = params["target"]
		if t is Node2D and is_instance_valid(t):
			parts.append("目标点(%d,%d)" % [int(t.global_position.x), int(t.global_position.y)])
		else:
			parts.append("目标=%s" % str(t))
	if params.has("target_position"):
		parts.append("目标点%s" % str(params["target_position"]))
	if bool(params.get("evacuate", false)):
		parts.append("战役撤离")
	if params.has("retreat_mode"):
		parts.append("档=%s" % str(params["retreat_mode"]))
	if bool(params.get("follow_order", false)):
		parts.append("编队跟随")
	return " ".join(parts)


# ─────────────────────────────── 切换原因推断 ────────────────────────────────

## 切换原因推断（**须在 ai_behavior_switched 信号到达时点调用**——看门狗推力/
## 附身恢复是瞬时态，事后补推不准）。只读 AIController 公开面 + 两个私有观测
## 字段（_wd_nudge_until/_was_possessed，调试读先例 _squad_phase_plans）。
## 返回短句（详情日志行用）。
static func describe_switch_reason(e: Node, ai: Node, to: String, params: Dictionary) -> String:
	if e == null or not is_instance_valid(e):
		return "单位失效"
	if ai == null or not is_instance_valid(ai):
		return "—"
	# 1. 卡死看门狗（_stuck_break 内 travel attack + 刚置分离推力 → 窗口内可判）
	if "_wd_nudge_until" in ai and "_world_time" in ai:
		var until: float = float(ai.get("_wd_nudge_until"))
		var now: float = float(ai.get("_world_time"))
		if until > 0.0 and now <= until and until - now < 0.3:
			return "卡死看门狗：有意图无位移，换目标+分离推力"
	# 2. 打通态（遇阻接战插叙）
	if ai.has_method("is_breach_engaged") and ai.is_breach_engaged():
		if params.has("forced_target"):
			return "打通态：接战拦路者（号令插叙）"
		return "打通态维护"
	# 3. 命令覆盖（号令执行/续行）
	if ai.has_method("has_order") and ai.has_order():
		var ob: String = str(ai.get_ordered_behavior())
		if to == ob:
			var brief: String = _order_params_brief(
					ai.get_ordered_params() if ai.has_method("get_ordered_params") else {})
			return "号令%s%s" % [str(BEHAVIOR_NAMES.get(ob, ob)),
					"" if brief.is_empty() else "（%s）" % brief]
	# 4. 行为语义表（决策层各分支的落点语义）
	match to:
		"attack":
			if params.has("forced_target"):
				return "打通态重入（锁拦路者）"
			return "参战接敌：选到最近敌（锁定到死）"
		"heal":
			return "祭司治疗路由（Meric 兵种）"
		"seek_cover":
			return "劣势找掩体"
		"retreat":
			if bool(params.get("evacuate", false)):
				return "战役撤离（TeamAi ROUT）"
			if str(params.get("retreat_mode", "")) == "withdraw":
				return "撤退：回己方锚点（命令档）"
			return "避战脱离（C6 掷骰/号令）"
		"idle":
			return "行为完成回收，原地待命"
		"wander":
			return "村民空闲闲逛（锚定聚落中心）"
		"work":
			return "接建造派工"
		"haul":
			return "搬运材料（工地需料）"
		"harvest":
			return "职业劳作（无派工时自主生产）"
		"follow":
			return "小队跟随玩家"
		"move":
			return "号令行军"
		_:
			pass
	# 未识别路径（附身恢复等非常规切换无独立真值面，不硬猜）
	return "—"


# ─────────────────────────────── 小工具 ────────────────────────────────

## 当前行为节点（state_machine._behaviors[current]——私有字典 duck 读，
## 调试观测先例 _squad_phase_plans）
static func _current_behavior_node(ai: Node) -> Node:
	if ai == null or not is_instance_valid(ai) or not ai.has_method("get_state_machine"):
		return null
	var sm: Node = ai.get_state_machine()
	if sm == null or not is_instance_valid(sm):
		return null
	var cur: String = str(sm.get_current_behavior_name()) \
			if sm.has_method("get_current_behavior_name") else ""
	if cur.is_empty() or not "_behaviors" in sm:
		return null
	var behaviors: Dictionary = sm.get("_behaviors")
	var b: Variant = behaviors.get(cur, null)
	return b if b is Node and is_instance_valid(b) else null


## HP 对（hp/max_hp；查询不可用给 -1）
static func hp_pair(e: Node) -> Vector2:
	var hc: Node = e.get_health() if e.has_method("get_health") else null
	if hc == null or not is_instance_valid(hc) or not ("hp" in hc and "max_hp" in hc):
		return Vector2(-1, -1)
	return Vector2(float(hc.get("hp")), float(hc.get("max_hp")))


## 阵营号（查询不可用 = 0 中立）
static func _faction_of(e: Node) -> int:
	return int(e.get_faction()) if e.has_method("get_faction") else 0


## 面向符号（±1；查询不可用 = 0 使前向判定恒 false → 全域回退文案）
static func _facing_sign(e: Node) -> float:
	return float(e.get_facing()) if e.has_method("get_facing") else 0.0


## 目标 iid（列表行"打谁"简列；非战斗行为无目标 → -1）
static func target_iid(e: Node, behavior: String) -> int:
	if behavior != "attack":
		return -1
	var ai: Node = e.get_ai_controller() if e.has_method("get_ai_controller") else null
	var b: Node = _current_behavior_node(ai)
	if b == null or not b.has_method("get_target"):
		return -1
	var t: Node = b.get_target()
	return t.get_instance_id() % 1000 if t != null and is_instance_valid(t) else -1
