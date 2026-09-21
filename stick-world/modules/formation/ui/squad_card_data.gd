extends RefCounted
## L1 班组卡·取数助手（从 squad_card.gd 下沉）——"取数（全 duck，缺则降级）"语义整区迁移
## （docs/设计/UI/组织界面与AI状态接线-总体方案.md §2.0/§3.2.A）。
##
## 纪律（与 system_setup 拆分同构）：
## - 状态全部留在宿主（squad_card.gd），本助手经 _host 回引现读宿主状态
##   （_squad_id/_selection/_formation/_org_api），不另立状态；
## - 单兵组件探测（health_of/status_of/ai_of/is_dead/is_routed/morale_of/state_flags/
##   role_zh/signature）不依赖宿主状态，做成 static：宿主与权威对比块助手经
##   const preload 类调用（SquadCardData.xxx(...)），不经实例调用（规避
##   STATIC_CALLED_ON_INSTANCE 警告）；
## - 系统查询（编制/组织/框选解析/号令波及/徽标聚合）为实例方法；
## - 相位计划接线（_current_plan/_capture_plan）留宿主，此处经 _host._current_plan() 取用
##   （含其信号接线副作用，与拆分前直呼语义一致）；
## - 各方法与宿主原同名函数逐一对应，行为与拆分前逐行等价。

## 单兵状态效果类型（static 方法无法经 _host 读宿主常量，本地镜像 squad_card.gd 的
## EFFECT_STUN/EFFECT_HEAL/ROLE_ZH——镜像 StatusEffects.Type：STUN3 HEAL4；
## ROLE_ZH 镜像 fighter/builder/worker 中文口径，改动须与宿主两处同步）
const EFFECT_STUN: int = 3
const EFFECT_HEAL: int = 4
const ROLE_ZH: Dictionary = {"fighter": "战士", "builder": "建造工", "worker": "工人"}

var _host: Node  ## 班组卡宿主（无 class_name，动态回引）


func setup(host: Node) -> void:
	_host = host


# ─────────────────── 单兵组件探测（static；宿主/权威对比块助手共用）───────────────────

static func health_of(u: Node) -> Node:
	if u == null or not is_instance_valid(u) or not u.has_method("get_health"):
		return null
	var h: Node = u.get_health()
	if h == null or not is_instance_valid(h):
		return null
	return h


static func status_of(u: Node) -> Node:
	if u == null or not is_instance_valid(u) or not u.has_method("get_status_effects"):
		return null
	var se: Node = u.get_status_effects()
	if se == null or not is_instance_valid(se):
		return null
	return se


static func ai_of(u: Node) -> Node:
	if u == null or not is_instance_valid(u) or not u.has_method("get_ai_controller"):
		return null
	var ai: Node = u.get_ai_controller()
	if ai == null or not is_instance_valid(ai):
		return null
	return ai


static func is_dead(u: Node) -> bool:
	return u != null and is_instance_valid(u) and u.has_method("is_dead") and bool(u.is_dead())


static func is_routed(u: Node) -> bool:
	var h := health_of(u)
	return h != null and h.has_method("is_routed") and bool(h.is_routed())


## 士气比例（get_health().get_morale_ratio；不可查回 1.0 = 条形满、不误报低压）
static func morale_of(u: Node) -> float:
	var h := health_of(u)
	if h != null and h.has_method("get_morale_ratio"):
		return float(h.get_morale_ratio())
	return 1.0


## 单兵状态事实（事实注入行，行内做文案映射；查询缺口即 false = 不显示角标）
static func state_flags(u: Node) -> Dictionary:
	var flags := {"routed": is_routed(u)}
	var se := status_of(u)
	if se == null:
		return flags
	if se.has_method("has_suppressed"):
		flags["suppressed"] = bool(se.has_suppressed())
	if se.has_method("has_effect"):
		flags["stunned"] = bool(se.has_effect(EFFECT_STUN))
		flags["healing"] = bool(se.has_effect(EFFECT_HEAL))
	return flags


## 职责中文（fighter/builder/worker → 战士/建造工/工人）
static func role_zh(u: Node) -> String:
	if u == null or not is_instance_valid(u) or not u.has_method("get_role"):
		return "火柴人"
	var role := String(u.get_role())
	return String(ROLE_ZH.get(role, "火柴人"))


## 成员集合签名（人数 + instance_id 序列；顺序变化也算变化，行序与快照一致）。
## 带人数前缀：空班签名不为 ""，与"未初始化"哨兵值区分（否则空班不会触发重建，
## 残留上一班的旧行——宿主曾踩此坑）。
static func signature(units: Array) -> String:
	var ids: Array[String] = []
	for u in units:
		ids.append(str(u.get_instance_id()))
	return "n=%d|%s" % [units.size(), ",".join(ids)]


# ─────────────────── 系统查询（实例方法；_host 回引现读宿主状态）───────────────────

## 小队是否仍存在：编制在册（FormationSystem 公开表）或组织册上的 L1 组织
## （后者 = 组织面板直接建的 FORMING 空班，招兵位仍要看，不算消亡）
func _squad_exists() -> bool:
	if _host._formation != null and _host._formation.has_method("get_all_squads") \
			and _host._squad_id in _host._formation.get_all_squads():
		return true
	if _host._org_api != null and _host._org_api.has_method("get_organization"):
		var r: Dictionary = _host._org_api.get_organization(_host._squad_id)
		if not r.get("ok", false):
			return false
		return int((r.get("data", {}) as Dictionary).get("tier", 0)) == 1
	return false


## 存活成员（小队快照 + 有效性/阵亡过滤；小队不存在返回空）
func _alive_units() -> Array:
	var alive: Array = []
	if _host._formation == null or not _host._formation.has_method("get_squad_units"):
		return alive
	for u in _host._formation.get_squad_units(_host._squad_id):
		if u == null or not is_instance_valid(u):
			continue
		if is_dead(u):
			continue
		alive.append(u)
	return alive


func _squad_name() -> String:
	if _host._formation != null and _host._formation.has_method("get_squad_name"):
		var n := String(_host._formation.get_squad_name(_host._squad_id))
		if not n.is_empty():
			return n
	if _host._org_api != null and _host._org_api.has_method("get_organization"):
		var r: Dictionary = _host._org_api.get_organization(_host._squad_id)
		if r.get("ok", false):
			var n2 := String((r.get("data", {}) as Dictionary).get("name", ""))
			if not n2.is_empty():
				return n2
	return _host._squad_id


## 组织态（OrganizationState.State int；不可查返回 -1）
func _org_state() -> int:
	if _host._org_api == null or not _host._org_api.has_method("get_organization"):
		return -1
	var r: Dictionary = _host._org_api.get_organization(_host._squad_id)
	if not r.get("ok", false):
		return -1
	var data: Dictionary = r.get("data", {})
	if not data.has("state"):
		return -1
	return int(data["state"])


## 权威值（get_squad_authority；小队不存在/查询缺返回 NAN = 不显示）
func _authority() -> float:
	if _host._formation == null or not _host._formation.has_method("get_squad_authority"):
		return NAN
	var v: Variant = _host._formation.get_squad_authority(_host._squad_id)
	if not (v is float) or not is_finite(v):
		return NAN
	return float(v)


## 角色表（iid -> ROLE_*；计划缺失返回空字典 = 角标降级为"—"）
func _roles_of_plan() -> Dictionary:
	var plan: Variant = _host._current_plan()
	if plan == null or not plan.has_method("get_roles"):
		return {}
	var roles: Variant = plan.get_roles()
	return roles if roles is Dictionary else {}


func _role_of(u: Node) -> String:
	var plan: Variant = _host._current_plan()
	if plan == null or not plan.has_method("get_role_of"):
		return ""
	return str(plan.get_role_of(u))


# ─────────────────── 框选解析 / 号令波及 / 徽标聚合 ───────────────────

## 框选解析：取选中单位里第一个能解析出所属编制的小队（多小队混选时以首个为准）
func _squad_from_selection() -> String:
	if _host._selection == null or not _host._selection.has_method("get_selected_units"):
		return ""
	if _host._formation == null or not _host._formation.has_method("get_unit_squad"):
		return ""
	for u in _host._selection.get_selected_units():
		if u == null or not is_instance_valid(u):
			continue
		var sid := String(_host._formation.get_unit_squad(u))
		if not sid.is_empty():
			return sid
	return ""


## 号令是否波及本班：直接点名，或点名其上级组织（逐层接力终会送达本班）
func _order_reaches(target_id: String) -> bool:
	if target_id.is_empty():
		return false
	if target_id == _host._squad_id:
		return true
	if _host._org_api == null or not _host._org_api.has_method("get_organization"):
		return false
	var cur: String = _host._squad_id
	for _i in 8:
		var r: Dictionary = _host._org_api.get_organization(cur)
		if not r.get("ok", false):
			return false
		var parent := String((r.get("data", {}) as Dictionary).get("parent_org", ""))
		if parent.is_empty():
			return false
		if parent == target_id:
			return true
		cur = parent
	return false


## 状态徽标聚合（org state × 成员行为）：撤退中 > 接战 > 活跃 / 组建中。
## 组织态 State 目前在册值恒为 FORMING（组织模块只写初值，无 ACTIVE 迁移实现），
## 满员班组贴「组建中」是谎报——故组建中只在空班（尚未编入成员 = 真招兵态）成立，
## 其余按成员行为聚合；组织查询不可用且无成员可查则不显示徽标。
## 常量经 _host 现读宿主语义常量（宿主保留全部语义常量，不复制）。
func _status_badge(units: Array) -> String:
	var state := _org_state()
	if state == _host.ORG_STATE_DISBANDED:
		return ""
	if state == _host.ORG_STATE_FORMING and units.is_empty():
		return _host.STATUS_FORMING
	var retreating := false
	var contact := false
	for u in units:
		var ai := ai_of(u)
		var beh := ""
		if ai != null and ai.has_method("get_current_behavior"):
			beh = String(ai.get_current_behavior())
		if beh == "retreat" or is_routed(u):
			retreating = true
		elif beh == "attack":
			contact = true
	if retreating:
		return _host.STATUS_RETREAT
	if contact:
		return _host.STATUS_CONTACT
	if not units.is_empty() or state >= 0:
		return _host.STATUS_ACTIVE
	return ""
