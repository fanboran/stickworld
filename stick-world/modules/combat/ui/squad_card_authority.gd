extends RefCounted
## L1 班组卡·权威对比块助手（UI-W4a §3.3①，从 squad_card.gd 下沉）——
## "权威值择班表达"+"权威对比取数"两区整块迁移：本班权威/星级 + 邻近可投奔班对比
## +「N 人有意转投 X 班」提示条的子树渲染与私有取数。
##
## 纪律（与 system_setup 拆分同构）：
## - 状态全部留在宿主，本助手经 _host 回引现读（_squad_id/_formation/_org_api 与
##   AuthCompare 子树的 @onready 节点引用），不另立状态；
## - 单兵探测复用取数助手 static（SquadCardData.ai_of/status_of/is_dead，类调用）；
##   班名/权威值走取数助手实例方法（_data._squad_name/_data._authority）；
## - 常量经 _host 现读宿主语义常量（AUTHORITY_PER_STAR/CANDIDATE_RADIUS/CANDIDATE_ROW_MAX，
##   宿主保留全部语义常量，不复制）；
## - 全部真实查询，任一出口缺失或本班权威不可解 → 整块隐藏（不显示占位噪声）；
## - 各方法与宿主原同名函数逐一对应，行为与拆分前逐行等价。

## 取数助手类（类调用其 static 单兵探测，规避 STATIC_CALLED_ON_INSTANCE 警告）
const SquadCardData: GDScript = preload("res://modules/combat/ui/squad_card_data.gd")

var _host: Node  ## 班组卡宿主（无 class_name，动态回引）
var _data: RefCounted  ## 取数助手（squad_card_data.gd 实例，setup 注入）


func setup(host: Node, data: RefCounted) -> void:
	_host = host
	_data = data


# ─────────────────── 权威对比块渲染（AuthCompare 子树）───────────────────

## 权威对比块：本班权威/星级 + 邻近可投奔班对比 +「N 人有意转投 X 班」提示条。
## 全真实查询；任一出口缺失或本班权威不可解 → 整块隐藏（不显示占位噪声）。
func _refresh_authority_compare(units: Array) -> void:
	if _host._auth_compare == null:
		return
	var current := _data._authority()
	if is_nan(current) or _host._formation == null \
			or not _host._formation.has_method("get_squad_authority") \
			or not _host._formation.has_method("should_switch_squad"):
		_host._auth_compare.visible = false
		return
	var scored := _scored_neighbors()
	if scored.is_empty():
		_host._auth_compare.visible = false
		return
	_host._auth_compare.visible = true
	_clear_rows()
	_add_auth_row("本班·%s" % _data._squad_name(), current, true, 0.0)
	for i in mini(scored.size(), _host.CANDIDATE_ROW_MAX):
		var e: Dictionary = scored[i]
		_add_auth_row(String(e["name"]), float(e["auth"]), false, float(e["auth"]) - current)
	_refresh_defect_hint(current, scored, units)


## 邻近可投奔班评分表（[{id,name,auth}]，权威降序；无班长候选剔除 = 同 A9 口径）
func _scored_neighbors() -> Array:
	var scored: Array = []
	for cid in _candidate_squads():
		if not _is_live_leader(cid):
			continue
		var a: Variant = _authority_of(cid)
		if a == null:
			continue
		scored.append({"id": cid, "name": _name_of(cid), "auth": float(a)})
	scored.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		return float(x["auth"]) > float(y["auth"]))
	return scored


## 提示条：最强邻近班经 should_switch_squad 滞回判定够格时，统计本班有意转投人数。
## N = 通过「不该动的别动」守卫（班长/附身/溃逃找掩体/被压制）且落在候选半径内的成员数。
func _refresh_defect_hint(current: float, scored: Array, units: Array) -> void:
	if scored.is_empty():
		_host._defect_hint.visible = false
		return
	var best: Dictionary = scored[0]
	if not bool(_host._formation.should_switch_squad(current, float(best["auth"]))):
		_host._defect_hint.visible = false
		return
	var n := _switch_intent_count(String(best["id"]), units)
	if n <= 0:
		_host._defect_hint.visible = false
		return
	_host._defect_label.text = "%d 人有意转投 %s（威望 %.1f）" % [n, String(best["name"]), float(best["auth"])]
	_host._defect_hint.visible = true


## 有意转投本班 → best 班的成员数（真实成员表 + 半径/守卫过滤，非戏假）
func _switch_intent_count(best_id: String, units: Array) -> int:
	var best_leader: Node = _leader_of(best_id)
	var self_leader: Node = _leader_of(_host._squad_id)
	var radius := _candidate_radius()
	var count := 0
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_possessed") and bool(u.is_possessed()):
			continue
		if u == self_leader:
			continue  # 班长本人不被抽走（A9 同守卫）
		var ai := SquadCardData.ai_of(u)
		if ai != null and ai.has_method("get_current_behavior") \
				and String(ai.get_current_behavior()) in ["retreat", "seek_cover"]:
			continue
		var se := SquadCardData.status_of(u)
		if se != null and se.has_method("has_suppressed") and bool(se.has_suppressed()):
			continue
		if best_leader != null and u is Node2D and best_leader is Node2D \
				and (u as Node2D).global_position.distance_to(
						(best_leader as Node2D).global_position) > radius:
			continue
		count += 1
	return count


## 邻近可投奔班半径（px）：优先 duck 消费 formation 只读参数出口
## get_authority_switch_state().candidate_radius（档案实值，与 A9 跳槽同源）；
## 出口缺失 / 非字典 / 无该键（旧版 formation）→ 回落缺省常量 CANDIDATE_RADIUS。
## 注意：test_squad_card.gd 直呼宿主 _candidate_radius，宿主留委托壳转发到这里。
func _candidate_radius() -> float:
	if _host._formation != null and _host._formation.has_method("get_authority_switch_state"):
		var st: Variant = _host._formation.get_authority_switch_state()
		if st is Dictionary and (st as Dictionary).has("candidate_radius"):
			return float((st as Dictionary)["candidate_radius"])
	return _host.CANDIDATE_RADIUS


## 邻近可投奔班 id：组织相邻口径（同父组织 L1 兄弟班）；散兵/无父级退化为编队全部战斗班
func _candidate_squads() -> Array:
	var out: Array = []
	var parent := _parent_org()
	if not parent.is_empty() and _host._org_api != null and _host._org_api.has_method("get_organization"):
		var pr: Dictionary = _host._org_api.get_organization(parent)
		if pr.get("ok", false):
			for c in (pr.get("data", {}) as Dictionary).get("child_orgs", []):
				var cid := String(c)
				if cid.is_empty() or cid == _host._squad_id:
					continue
				if _tier_of(cid) != 1:
					continue
				out.append(cid)
	if not out.is_empty():
		return out
	if _host._formation != null and _host._formation.has_method("get_all_squads"):
		for sid in _host._formation.get_all_squads():
			var s := String(sid)
			if s.is_empty() or s == _host._squad_id:
				continue
			if _host._formation.has_method("is_combat_squad") and not _host._formation.is_combat_squad(s):
				continue
			out.append(s)
	return out


## 权威对比行（星级 + 名称 + 威望；本班行高亮，候选行标注差值方向）
func _add_auth_row(label_text: String, authority: float, is_current: bool, delta: float) -> void:
	var level := clampi(int(round(authority / _host.AUTHORITY_PER_STAR)), 0, 5)
	var stars := "—" if level <= 0 else "★".repeat(level)
	var delta_text := ""
	if not is_current:
		delta_text = "（%+.1f）" % delta
	var l := StickKit.label(_host._auth_rows, "%s %s  威望 %.1f%s" % [stars, label_text, authority, delta_text],
			StickKit.LabelKind.TINY)
	l.clip_text = true
	if is_current:
		l.modulate = StickTokens.ACCENT
	elif delta > 0.0:
		l.modulate = StickTokens.WARN
	else:
		l.modulate = StickTokens.TEXT_DIM


func _clear_rows() -> void:
	for child in _host._auth_rows.get_children():
		_host._auth_rows.remove_child(child)
		child.queue_free()


# ─────────────────── 权威对比取数（duck；缺则整块降级）───────────────────

## 某班权威值（不可解返回 null；-INF = 不在编队册）
func _authority_of(squad_id: String) -> Variant:
	if _host._formation == null or not _host._formation.has_method("get_squad_authority"):
		return null
	var v: Variant = _host._formation.get_squad_authority(squad_id)
	if not (v is float) or not is_finite(v):
		return null
	return float(v)


func _leader_of(squad_id: String) -> Node:
	if _host._formation == null or not _host._formation.has_method("get_squad_leader"):
		return null
	var leader: Node = _host._formation.get_squad_leader(squad_id)
	if leader == null or not is_instance_valid(leader) or SquadCardData.is_dead(leader):
		return null
	return leader


func _is_live_leader(squad_id: String) -> bool:
	return _leader_of(squad_id) != null


func _name_of(squad_id: String) -> String:
	if _host._formation != null and _host._formation.has_method("get_squad_name"):
		var n := String(_host._formation.get_squad_name(squad_id))
		if not n.is_empty():
			return n
	return squad_id


func _parent_org() -> String:
	if _host._org_api == null or not _host._org_api.has_method("get_organization"):
		return ""
	var r: Dictionary = _host._org_api.get_organization(_host._squad_id)
	if not r.get("ok", false):
		return ""
	return String((r.get("data", {}) as Dictionary).get("parent_org", ""))


func _tier_of(org_id: String) -> int:
	if _host._org_api == null or not _host._org_api.has_method("get_organization"):
		return -1
	var r: Dictionary = _host._org_api.get_organization(org_id)
	if not r.get("ok", false):
		return -1
	return int((r.get("data", {}) as Dictionary).get("tier", -1))
