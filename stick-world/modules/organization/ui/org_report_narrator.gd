class_name OrgReportNarrator
extends Node
## 组织上报叙事器 —— 把 report_filed 三型上报与补位事件接成玩家可见的 toast。
##
## 定位（docs/设计/UI/组织界面与AI状态接线-总体方案.md §3.2.C 上报流 / §3.3② 补位叙事）：
## 组织侧只透传上报，玩家侧此前零消费方；本类补上「上报流消费 + 补位仪式感」的玩家可见面。
##
## 通知通道：一律 EventBus.ui_notification → UIRoot 左下 NotificationFeed（既有唯一通道）。
##   队列规则（上限 5 条 / 停留 3s 淡出 / info-warn-error 三级着色）归 feed，本类不新造组件、
##   不自管队列——别绕过 test_notification_feed 覆盖的那套。
##
## 门控不绕过：report_filed 只在组织侧门控之后才发——combat 挂点一律先
##   evaluate_report_gate 通过再 file_report（§4.4 三档表）；commander_lost 是必报型
##   （补位引擎直发）。因此「消费 report_filed」≡「只看得到门控放出来的可见集」，
##   本类不做二次门控判定（重复判定会与组织侧规则分叉）。
##
## 叙事口径（§3.3②）：commander_lost 的 payload 是唯一权威——filled=true 才说「自动接任」，
##   filled=false 说「群龙无首」（与 OrgPanel 空缺标记同一套语义，不美化）。
##   EventBus.commander_assigned 只作接任者 id 的兜底来源（payload 缺 successor_id 时用留痕补），
##   不参与真假判定——避免信号时序影响玩家可见语义。

## 补位任命留痕时限（毫秒）：同一 manager 流程里 commander_assigned 先于 commander_lost 发，
## 用留痕核对这次任命确实是补位链产物（而非玩家手任命），超窗残留不认。
const ASSIGN_TRACE_TTL_MSEC := 3000

## 军事层级 → 指挥者称谓（tier 见 presets.tres：L1排/L2连/L3营/L4团/L5师）
const MILITARY_RANK := {1: "排长", 2: "连长", 3: "营长", 4: "团长", 5: "师长"}

var _org_api: Node = null
## org_id -> {"unit_id": int, "at": int}：commander_assigned 留痕（核对补位链）
var _assign_trace: Dictionary = {}


## SystemSetup 装配注入 organization api（树根 GameRoot 常驻子节点）
func setup(org_api: Node) -> void:
	_org_api = org_api
	if _org_api == null:
		return
	if _org_api.has_signal("report_filed") and not _org_api.is_connected("report_filed", _on_report_filed):
		_org_api.connect("report_filed", _on_report_filed)
	if EventBus != null and EventBus.has_signal("commander_assigned") \
			and not EventBus.commander_assigned.is_connected(_on_commander_assigned):
		EventBus.commander_assigned.connect(_on_commander_assigned)


# ─────────────────────────────── 信号消费 ────────────────────────────────

## 补位/任命留痕：只用于核对 commander_lost 的 filled=true 有对应任命信号，
## 不参与文案真假判定（权威值仍是 payload.filled）
func _on_commander_assigned(org_id: String, unit_id: int) -> void:
	_assign_trace[org_id] = {"unit_id": unit_id, "at": Time.get_ticks_msec()}


## 上报落档（三型分发）。上报可见集已由组织侧门控决定，此处只做呈现。
func _on_report_filed(org_id: String, report: Dictionary) -> void:
	var type := String(report.get("type", ""))
	var raw: Variant = report.get("payload", {})
	var payload: Dictionary = raw if raw is Dictionary else {}
	match type:
		"commander_lost":
			_narrate_commander_lost(org_id, payload)
		"casualty_threshold":
			_narrate_casualty(org_id, payload)
		"contact":
			_narrate_contact(org_id, payload)
		_:
			pass  # 未知类型不透传（schema 槽位留给后续各域上报，不猜文案）


# ─────────────────────────────── 三类叙事 ────────────────────────────────

## 指挥层损失 + 补位（仪式感：这一瞬间是补位链戏剧性的高光）
## filled=true：损者称谓 + 接任者称谓（从子组织指挥官位阶反推）分两行，像一封战报；
## filled=false：明白说空缺，与「群龙无首」标记同一语义。
func _narrate_commander_lost(org_id: String, payload: Dictionary) -> void:
	var filled := bool(payload.get("filled", false))
	var successor := String(payload.get("successor_id", ""))
	# 兜底：payload 缺 successor_id（旧档/schema 漂移）时取 commander_assigned 留痕
	if filled and successor.is_empty():
		successor = _recent_assignment(org_id)
	var org_name := _org_name(org_id)
	var lost_rank := _rank_label(_org_tier(org_id), _org_tag(org_id))
	var line1 := "「%s」%s阵亡" % [org_name, lost_rank]
	# filled 是唯一权威：true 才说「自动接任」，false 直说空缺（与树标记同一套语义）
	if filled and not successor.is_empty():
		_notify("指挥链", "%s\n%s ▲#%s 自动接任" % [
				line1, _successor_rank(org_id, successor), successor], "warn")
	else:
		_notify("指挥链", "%s\n补位无人——群龙无首，命令停驻" % line1, "error")
	_assign_trace.erase(org_id)


## 近期 commander_assigned 留痕（窗口内）→ 接任者 id；超窗/无留痕 → ""
func _recent_assignment(org_id: String) -> String:
	var trace: Dictionary = _assign_trace.get(org_id, {})
	if trace.is_empty():
		return ""
	if Time.get_ticks_msec() - int(trace.get("at", 0)) > ASSIGN_TRACE_TTL_MSEC:
		return ""
	var unit_id := int(trace.get("unit_id", 0))
	return str(unit_id) if unit_id > 0 else ""


## 伤亡达阈值（组织侧门控放行才可见：HIGH 档不报 / MEDIUM 存活比跌破阈值 / LOW 全量）
func _narrate_casualty(org_id: String, payload: Dictionary) -> void:
	var alive := int(payload.get("alive", 0))
	var total := int(payload.get("total", 0))
	var loss_rate := float(payload.get("loss_rate", 0.0))
	if loss_rate <= 0.0 and total > 0:
		loss_rate = 1.0 - float(alive) / float(total)
	var pct := int(round(loss_rate * 100.0))
	_notify("伤亡", "「%s」剩 %d/%d 人（损失 %d%%）" % [_org_name(org_id), alive, total, pct], "warn")


## 接触 / 遭遇（小队首次获得敌方目标）
func _narrate_contact(org_id: String, payload: Dictionary) -> void:
	var enemy := int(payload.get("enemy_count", 0))
	_notify("接触", "「%s」遭遇敌军 %d 人" % [_org_name(org_id), enemy], "info")


# ─────────────────────────────── 查询与文案工具 ────────────────────────────────

func _notify(title: String, body: String, kind: String) -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit(title, body, kind)


func _org_data(org_id: String) -> Dictionary:
	if _org_api == null or not _org_api.has_method("get_organization"):
		return {}
	var r: Dictionary = _org_api.get_organization(org_id)
	return r.get("data", {}) if r.get("ok", false) else {}


func _org_name(org_id: String) -> String:
	var d := _org_data(org_id)
	return String(d.get("name", org_id)) if not d.is_empty() else org_id


func _org_tier(org_id: String) -> int:
	return int(_org_data(org_id).get("tier", 0))


func _org_tag(org_id: String) -> int:
	return int(_org_data(org_id).get("tag", -1))


## tier + 标签 → 指挥者称谓（仅军事套军阶；其余标签统称「指挥官」——不发明军衔）
func _rank_label(tier: int, tag_int: int) -> String:
	if tag_int == 0:  # OrganizationState.Tag.MILITARY
		return String(MILITARY_RANK.get(tier, "指挥官"))
	return "指挥官"


## 接任者出身：候选池 = 本组织成员 ∪ 直接下级指挥官（§4.3.1），
## 命中下级指挥官位则用其层级称谓（排长顶上连长位），否则统称「部下」
func _successor_rank(org_id: String, successor_id: String) -> String:
	var d := _org_data(org_id)
	for child_id in d.get("child_orgs", []):
		var cd := _org_data(String(child_id))
		if String(cd.get("commander_id", "")) == successor_id:
			return _rank_label(int(cd.get("tier", 0)), int(cd.get("tag", _org_tag(org_id))))
	return "部下"
