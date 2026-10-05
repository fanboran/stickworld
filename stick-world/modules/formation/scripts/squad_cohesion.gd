extends RefCounted
## 班内一次性归队状态机（SWL 跟随直译：FormationPositionIsStable 到位滞回
## + lastFollowUpdate 重算节流）——static 函数库（无实例状态）。
##
## 模型（创始人裁决：跟随 =「和队长拉开一定距离后才生效一次」）：
##   - 距班锚点 > JOIN_DIST → 进入归队态，此后持续给出指向锚点的移动建议；
##     距锚点 < SETTLE_DIST → 落定退出，回到之前的任务。
##   - 非归队态零施力：不打扰正在执行任务的单位（站桩不拉、行军不扰、
##     接战不吸）——不是持续弹簧拉扯，旧 Boids 回拉/对齐就此退役。
##   - JOIN > SETTLE 滞回带防边界振荡（SWL FormationPositionIsStable 同构）。
##   - 触发判定低频节流 COHESION_RECHECK_MS（SWL lastFollowUpdate 语义：
##     跟随重算不是每帧）；归队态下的移动建议逐帧刷新（锚点实时读），
##     移动执行本身不受节流影响。落定即时退出（到位即站定不抖）。
##   - 战斗优先（生效前持续完成手头任务）：接战（attack）不触发归队；
##     避战（retreat/seek_cover）豁免同理；已处归队态遇战斗则挂起施力，
##     状态保留——战毕若仍超 SETTLE_DIST 继续归队。
##
## 锚点 = 班长实时位置；班长亡/缺 = 班质心（400ms 节流缓存 refresh_cache）。
## 归队状态挂宿主 squad["catchup_state"]（iid -> {"catching": bool, "at": ms}；
## 单位死亡后残留条目无害——iid 不参与判定，班解散随字典整体丢弃）。
##
## 输出 = 指向锚点的单位方向向量（消费方 entity_motion 归一混入移动意图，
## 不直改位置）。数值全部【提案/待定·待实测校准】，单一真相源在 api.gd
## （本库经 api 读，api 不回引本库，无环）。

const _Api := preload("res://modules/formation/api.gd")

## 避战态行为名（不触发归队、归队中挂起；口径见 ai_controller 行为注册）
const AVOID_BEHAVIORS: Array = ["retreat", "seek_cover"]
## 接战态行为名（战斗优先：不触发、归队中挂起）
const ENGAGED_BEHAVIOR: String = "attack"
## 状态字典初始时戳（久远过去 → 首次判定必跑，不受节流窗挡；
## 纯数值字面量——GDScript const 不认 `-1 << 30` 这类负数移位表达式）
const _STATE_AT_NEVER: int = -1073741824


## 质心缓存（班长亡/缺时的兜底锚点）：400ms 节流，缓存留宿主 squad["cohesion_cache"]。
## 班不存在/无存活成员返回 {}。
static func refresh_cache(host, squad_id: String) -> Dictionary:
	if not host._squads.has(squad_id):
		return {}
	var squad: Dictionary = host._squads[squad_id]
	var now: int = Time.get_ticks_msec()
	var cache: Dictionary = squad.get("cohesion_cache", {})
	if not cache.is_empty() and now - int(cache.get("at", -10000)) < _Api.COHESION_CACHE_TTL_MS:
		return cache
	var centroid := Vector2.ZERO
	var members: Array = []
	for u in squad["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			centroid += u.global_position
			members.append(u)
	var n: int = members.size()
	if n == 0:
		return {}
	centroid /= float(n)
	cache = {
		"centroid": centroid,
		"members": n,
		"at": now,
	}
	squad["cohesion_cache"] = cache
	return cache


## 取（惰性建）单位的归队状态条目（挂宿主 squad 字典）。
static func _catchup_state(squad: Dictionary, unit: Node) -> Dictionary:
	var states: Dictionary = squad.get("catchup_state", {})
	var iid: int = unit.get_instance_id()
	if not states.has(iid):
		states[iid] = {"catching": false, "at": _STATE_AT_NEVER}
	squad["catchup_state"] = states
	return states[iid]


## 解析归队锚点：班长在场 = 班长实时位置；否则班质心（缓存）。无锚返回 {}。
static func _resolve_anchor(host, squad_id: String, squad: Dictionary) -> Dictionary:
	var leader: Node = squad.get("leader", null)
	if leader != null and is_instance_valid(leader) \
			and not (leader.has_method("is_dead") and leader.is_dead()):
		return {"anchor": (leader as Node2D).global_position}
	var cache := refresh_cache(host, squad_id)
	if cache.is_empty():
		return {}
	return {"anchor": cache["centroid"]}


## 单位归队转向建议：Vector2.ZERO = 非归队态/战斗挂起/无锚（无施力）；
## 归队态 = 指向锚点的单位方向向量。
static func squad_steer(host, squad_id: String, unit: Node) -> Vector2:
	if unit == null or not is_instance_valid(unit):
		return Vector2.ZERO
	if not host._squads.has(squad_id):
		return Vector2.ZERO
	var squad: Dictionary = host._squads[squad_id]
	var state: Dictionary = _catchup_state(squad, unit)
	# 行为门控：接战/避战 = 战斗优先（生效前持续完成手头任务）
	var behavior := ""
	if unit.has_method("get_current_behavior"):
		behavior = String(unit.get_current_behavior())
	var combat_busy: bool = behavior == ENGAGED_BEHAVIOR or behavior in AVOID_BEHAVIORS

	# ── 归队态：持续给出归队建议（执行不受节流影响），落定即时退出 ──
	if bool(state["catching"]):
		if combat_busy:
			return Vector2.ZERO  # 战斗挂起，状态保留：战毕若仍超距继续归队
		var r := _resolve_anchor(host, squad_id, squad)
		if r.is_empty():
			return Vector2.ZERO
		var to_anchor: Vector2 = r["anchor"] - unit.global_position
		if to_anchor.length() < _Api.COHESION_SETTLE_DIST:
			state["catching"] = false  # 到位即站定（不等节流，防过冲折返）
			return Vector2.ZERO
		return to_anchor.normalized()

	# ── 非归队态：触发判定低频重估（SWL lastFollowUpdate：跟随重算不是每帧）──
	var now: int = Time.get_ticks_msec()
	if now - int(state["at"]) < _Api.COHESION_RECHECK_MS:
		return Vector2.ZERO
	state["at"] = now
	if combat_busy:
		return Vector2.ZERO  # 接战/避战中不触发自动归队
	var r2 := _resolve_anchor(host, squad_id, squad)
	if r2.is_empty():
		return Vector2.ZERO
	var to2: Vector2 = r2["anchor"] - unit.global_position
	if to2.length() > _Api.COHESION_JOIN_DIST:
		state["catching"] = true  # 一次性触发：超距才归队，落定前不重判
		return to2.normalized()
	return Vector2.ZERO


## 归队态查询（is_unit_catching_up 出口的内核）：超距触发后、落定/挂起前为 true。
static func is_catching_up(host, squad_id: String, unit: Node) -> bool:
	if unit == null or not is_instance_valid(host) or not host._squads.has(squad_id):
		return false
	var states: Dictionary = host._squads[squad_id].get("catchup_state", {})
	var entry: Variant = states.get(unit.get_instance_id())
	return entry != null and bool(entry.get("catching", false))
