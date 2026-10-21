class_name AiVizWindow
extends StickWindow
## AI 决策观察窗 —— 实时看每个单位的 AI 在想什么（LimboAI 调试器信息密度对齐）。
##
## 弹窗行为模板：StickWindow FLOATING（可拖标题栏、无遮罩、ESC 自关、面板外
## 鼠标穿透到游戏）——拖动/关闭/安全矩形夹紧均由基类提供。
##
## 纯观测（零行为改动）：
##   - 列表/详情每 0.25s 只读轮询（ai_viz_snapshot 快照层，全 duck 调用）；
##   - 状态切换日志订阅 EventBus.ai_behavior_switched（BehaviorStateMachine.travel
##     唯一入口埋点），**原因推断在信号到达时点做**（看门狗推力/接管恢复是瞬时态）；
##   - 本窗口只在挂载它的调试场景（观察场等）活跃，无全局常驻成本。
##
## 信息密度布局（对标 LimboAI 调试器：树视图→本作注册表扁平等价物）：
##   左栏  单位列表（阵营/兵种/当前行为/特殊态徽标/HP），点击行选中
##   右栏  选中详情：行为注册表（当前 ▶ 高亮+完成态）/ 目标及选择理由 /
##         阈值余量（撤退线/武器冷却/出手门/持瞄）/ 决策时钟 / 号令 /
##         切换日志（该单位最近 10 条：时刻 from→to 原因）

const ScriptSnapshot := preload("res://modules/debug_gui/scripts/ai_viz_snapshot.gd")

## 刷新节流（s；对齐 debug_tools_panel.AUTO_REFRESH_INTERVAL 档）
const REFRESH_INTERVAL: float = 0.25
## 每单位切换日志上限（环形）
const LOG_CAP: int = 10
## 初始落位：右上（避让观察场左上战况板与底部控制面板；标题栏可拖）
const _INITIAL_POS := Vector2(930.0, 96.0)

enum Filter { ALL, BLUE, RED, COMBAT }

## 过滤按钮文案（下标对齐 Filter）
const FILTER_NAMES: Array[String] = ["全部", "蓝方", "红方", "接战中"]

# ─────────────────────────────── 状态 ────────────────────────────────
## 当前过滤档
var _filter: int = Filter.ALL
## 选中单位 iid（-1 = 未选中，自动选首个可见）
var _selected_iid: int = -1
## 行控件表（iid -> Button；增量更新不整列重建，96 行 0.25s 刷新不掉帧）
var _rows: Dictionary = {}
## 每单位行为切换日志（iid -> [{t, from, to, reason}]，环形 LOG_CAP）
var _logs: Dictionary = {}
## 每单位当前行为起始时刻（iid -> 物理帧钟 s；驻留时长展示用）
var _behavior_since: Dictionary = {}
## 刷新计时
var _refresh_accum: float = 0.0
## 世界宿主缓存（GameRoot；观察场为场景嵌套挂载，解析一次反复用，失效重解析）
var _host: Node = null

# ─────────────────────────────── 控件 ────────────────────────────────
var _stats_label: Label = null
var _rows_box: VBoxContainer = null
var _filter_buttons: Array = []
var _detail_text: RichTextLabel = null
var _log_text: RichTextLabel = null


func _ready() -> void:
	visible = false
	behavior = Behavior.FLOATING
	window_title = "AI 决策观察（纯只读 · V 键开关）"
	window_size = Vector2(1020, 620)
	_build_window()
	_panel.position = _INITIAL_POS
	_build_columns()
	# 切换日志订阅：发射方 BehaviorStateMachine.travel（唯一入口埋点）；
	# 场景卸载窗口释放时连接自动断开
	EventBus.ai_behavior_switched.connect(_on_behavior_switched)


func _exit_tree() -> void:
	if EventBus.ai_behavior_switched.is_connected(_on_behavior_switched):
		EventBus.ai_behavior_switched.disconnect(_on_behavior_switched)


## 物理帧钟（s）——与 AI 决策时钟同源（暂停/hitstop 同步冻结，回放确定）
static func _phys_now() -> float:
	return float(Engine.get_physics_frames()) / float(Engine.physics_ticks_per_second)


# ─────────────────────────────── 切换日志（信号时点）────────────────────────────────

## 行为切换入账（EventBus.ai_behavior_switched）：
## 原因推断必须在**此刻**做（瞬时态过后不可考），驻留时钟此刻归零。
func _on_behavior_switched(entity, from_b: String, to_b: String, params: Dictionary) -> void:
	if entity == null or not is_instance_valid(entity):
		return
	var iid: int = entity.get_instance_id()
	var ai: Node = entity.get_ai_controller() if entity.has_method("get_ai_controller") else null
	var reason: String = ScriptSnapshot.describe_switch_reason(entity, ai, to_b, params)
	var now: float = _phys_now()
	_behavior_since[iid] = now
	var log: Array = _logs.get(iid, [])
	log.append({"t": now, "from": from_b, "to": to_b, "reason": reason})
	while log.size() > LOG_CAP:
		log.pop_front()
	_logs[iid] = log


# ─────────────────────────────── 布局 ────────────────────────────────

## 双栏内容（StickWindow._body 内）：统计行 + 左列表/右详情
func _build_columns() -> void:
	# 顶部统计行（行为分布直方：LimboAI agent 计数条语义）
	_stats_label = Label.new()
	_stats_label.text = "—"
	_stats_label.add_theme_font_size_override("font_size", 13)
	_body.add_child(_stats_label)
	var columns := HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_theme_constant_override("separation", 10)
	_body.add_child(columns)
	# 左栏：过滤行 + 单位列表
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(400, 0)
	left.add_theme_constant_override("separation", 6)
	columns.add_child(left)
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override("separation", 6)
	left.add_child(filter_row)
	for fi in FILTER_NAMES.size():
		var fb: Button = StickKit.sketch_button(filter_row, FILTER_NAMES[fi],
				_set_filter.bind(fi), StickKit.ButtonKind.NORMAL, 28.0)
		fb.toggle_mode = true
		_filter_buttons.append(fb)
	_refresh_filter_buttons()
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 2)
	scroll.add_child(_rows_box)
	# 右栏：详情（上）+ 切换日志（下）
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	columns.add_child(right)
	_detail_text = RichTextLabel.new()
	_detail_text.bbcode_enabled = true
	_detail_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_text.add_theme_font_size_override("normal_font_size", 13)
	_detail_text.add_theme_font_size_override("bold_font_size", 13)
	right.add_child(_detail_text)
	var log_head := Label.new()
	log_head.text = "── 切换日志（最近 %d 条 · 原因记录于切换时点）──" % LOG_CAP
	log_head.add_theme_font_size_override("font_size", 12)
	right.add_child(log_head)
	_log_text = RichTextLabel.new()
	_log_text.bbcode_enabled = true
	_log_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_text.add_theme_font_size_override("normal_font_size", 12)
	_log_text.custom_minimum_size = Vector2(0, 150)
	right.add_child(_log_text)


## 过滤切换（点按立即生效，选中态高亮）
func _set_filter(fi: int) -> void:
	_filter = fi
	_refresh_filter_buttons()


func _refresh_filter_buttons() -> void:
	for fi in _filter_buttons.size():
		var b: Button = _filter_buttons[fi]
		b.set_pressed_no_signal(fi == _filter)


# ─────────────────────────────── 刷新 ────────────────────────────────

func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_accum += delta
	if _refresh_accum < REFRESH_INTERVAL:
		return
	_refresh_accum = 0.0
	var entities: Array = ScriptSnapshot.collect_ai_entities(_resolve_host())
	_refresh_stats(entities)
	_refresh_rows(entities)
	_refresh_detail(entities)


## 世界宿主解析（缓存 + 失效重解析；逻辑在 ai_viz_snapshot.resolve_game_host）
func _resolve_host() -> Node:
	if _host != null and is_instance_valid(_host) and _host.has_method("get_current_map"):
		return _host
	_host = ScriptSnapshot.resolve_game_host(get_tree())
	return _host


## 顶部统计：总数 + 行为分布（attack 12 · idle 8 · …，按数量降序）
func _refresh_stats(entities: Array) -> void:
	var dist: Dictionary = {}
	for e in entities:
		var row: Dictionary = ScriptSnapshot.unit_row(e)
		var b: String = str(row["behavior"])
		dist[b] = int(dist.get(b, 0)) + 1
	var parts: Array[String] = []
	var keys: Array = dist.keys()
	keys.sort_custom(func(a, b) -> bool: return int(dist[a]) > int(dist[b]))
	for k in keys:
		parts.append("%s %d" % [ScriptSnapshot.BEHAVIOR_NAMES.get(str(k), str(k)), dist[k]])
	_stats_label.text = "AI 单位 %d   %s" % [entities.size(), " · ".join(parts)]


## 左栏行增量刷新：新增/更新/移除（行控件复用，不整列重建）
func _refresh_rows(entities: Array) -> void:
	var seen: Dictionary = {}
	for e in entities:
		var row: Dictionary = ScriptSnapshot.unit_row(e)
		var iid: int = int(row["iid"])
		if not _pass_filter(row):
			continue
		seen[iid] = true
		var btn: Button = _rows.get(iid)
		if btn == null or not is_instance_valid(btn):
			btn = _make_row(iid)
		_update_row(btn, row)
	# 移除已死/被过滤的行（死亡单位下次过滤不通过即清）
	for iid in _rows.keys():
		if not seen.has(iid):
			var stale: Button = _rows[iid]
			if is_instance_valid(stale):
				stale.queue_free()
			_rows.erase(iid)
	# 选中失效（死亡/移除）→ 自动落到首个可见行
	if _selected_iid != -1 and not seen.has(_selected_iid):
		_selected_iid = -1
	if _selected_iid == -1 and not _rows.is_empty():
		var first: Button = null
		for child in _rows_box.get_children():
			if child is Button and is_instance_valid(child):
				first = child
				break
		if first != null:
			_selected_iid = int(first.get_meta("iid"))
	_recolor_rows()


## 过滤档判定
func _pass_filter(row: Dictionary) -> bool:
	match _filter:
		Filter.BLUE:
			return int(row["faction"]) == 1
		Filter.RED:
			return int(row["faction"]) == 2
		Filter.COMBAT:
			return str(row["behavior"]) == "attack"
		_:
			return true


## 新建一行（Button 承载整行文本，左对齐；iid 存 meta 供选中回查）
func _make_row(iid: int) -> Button:
	var btn: Button = StickKit.sketch_button(_rows_box, "", _select_iid.bind(iid),
			StickKit.ButtonKind.NORMAL, 26.0)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.set_meta("iid", iid)
	btn.font_size = 13
	_rows[iid] = btn
	# 新行排到末尾（列表序 = 枚举序；不追求稳定排序，观察场够用）
	_rows_box.move_child(btn, _rows_box.get_child_count() - 1)
	return btn


## 行文本/颜色更新：阵营色字 + 特殊态徽标 + HP
func _update_row(btn: Button, row: Dictionary) -> void:
	var hp: Vector2 = row["hp"]
	var hp_txt: String = " %d/%d" % [int(hp.x), int(hp.y)] if hp.x >= 0.0 else ""
	var flags: String = str(row["flags"])
	var flag_txt: String = " [%s]" % flags if not flags.is_empty() else ""
	btn.text = "%s %s ▸%s%s%s" % [_faction_zh(int(row["faction"])),
			str(row["unit_label"]), str(row["behavior_zh"]), flag_txt, hp_txt]
	btn.set_meta("faction", int(row["faction"]))


## 阵营中文字（列表行前缀）
static func _faction_zh(f: int) -> String:
	return "蓝" if f == 1 else ("红" if f == 2 else "中")


## 选中/未选中着色（选中 = 琥珀高亮，未选中 = 阵营色）
func _recolor_rows() -> void:
	for iid in _rows.keys():
		var btn: Button = _rows[iid]
		if not is_instance_valid(btn):
			continue
		var faction: int = int(btn.get_meta("faction"))
		if int(iid) == _selected_iid:
			btn.kind = SketchButton.Kind.ACCENT
		else:
			btn.kind = SketchButton.Kind.DARK
			btn.add_theme_color_override("font_color",
					ScriptSnapshot.FACTION_COLORS.get(faction, Color(0.7, 0.7, 0.7)))


## 行点击选中（立即换详情，不等下个刷新拍——交互手感）
func _select_iid(iid: int) -> void:
	_selected_iid = iid
	_recolor_rows()
	_refresh_detail(ScriptSnapshot.collect_ai_entities(_resolve_host()))


## 右栏详情：选中单位全量快照 → bbcode；下半该单位切换日志
func _refresh_detail(entities: Array) -> void:
	if _detail_text == null:
		return
	var entity: Node = _entity_by_iid(_selected_iid, entities)
	if entity == null:
		_detail_text.text = "[color=#999]点击左侧单位查看决策详情[/color]"
		_log_text.text = ""
		return
	var d: Dictionary = ScriptSnapshot.unit_detail(entity)
	_detail_text.text = _detail_bbcode(d)
	_log_text.text = _log_bbcode(int(entity.get_instance_id()))


## iid → 实体（行 meta 回查，复用本拍采集结果；失效返回 null）
func _entity_by_iid(iid: int, entities: Array) -> Node:
	if iid == -1:
		return null
	for e in entities:
		if e.get_instance_id() == iid:
			return e
	return null


# ─────────────────────────────── bbcode 组装 ────────────────────────────────

## 详情 bbcode（信息密度优先：一屏读完"在想什么/为什么/余量多少"）
func _detail_bbcode(d: Dictionary) -> String:
	var color: Color = d.get("faction_color", Color(0.8, 0.8, 0.8))
	var lines: Array[String] = []
	# 头部：身份 + 生命 + 姿态
	var hp: Vector2 = d.get("hp", Vector2(-1, -1))
	var hp_txt: String = "%d/%d" % [int(hp.x), int(hp.y)] if hp.x >= 0.0 else "—"
	var pos: Vector2 = d.get("pos", Vector2.ZERO)
	lines.append("[b][color=#%s]%s[/color][/b]   HP %s   位置(%d, %d)   速度 %.0f   朝向%s" % [
		color.to_html(false), str(d.get("label", "?")), hp_txt,
		int(pos.x), int(pos.y), float(d.get("speed", 0.0)),
		_scene_facing_zh(int(d.get("facing", 0)))])
	# 行为段（LimboAI 树语义：注册表全列，当前 ▶ 高亮 + 完成态 + 驻留时长）
	var cur: String = str(d.get("current", ""))
	var since: float = float(_behavior_since.get(_selected_iid, _phys_now()))
	var dwell: float = maxf(0.0, _phys_now() - since)
	var fin: bool = bool(d.get("finished", true))
	lines.append("当前行为: [b][color=#ffd27f]%s[/color][/b]（%s · 驻留 %.1fs）" % [
		str(d.get("current_zh", cur)),
		"已表态完成，待决策回收" if fin else "执行中", dwell])
	var reg: Array = d.get("registry", [])
	if not reg.is_empty():
		var names: Array[String] = []
		for r in reg:
			var nm: String = "%s·%s" % [str(r["name"]), str(r["zh"])]
			names.append("[color=#ffd27f]▶ %s[/color]" % nm if bool(r["current"]) else nm)
		lines.append("注册行为: %s" % "  ".join(names))
	# 目标段
	var t: Dictionary = d.get("target", {}) if d.has("target") else {}
	if not t.is_empty():
		var tgt_line: String = "目标: [b]%s[/b]  距离 %.0f px" % [str(t.get("label", "?")), float(t.get("dist", 0.0))]
		var margin: float = float(t.get("range_margin", NAN))
		if not is_nan(margin):
			tgt_line += "（%s，余量 %+.0f px）" % ["射程内" if margin <= 0.0 else "射程外", -margin]
		tgt_line += "  目标HP %s" % _hp_zh(t.get("hp", Vector2(-1, -1)))
		lines.append(tgt_line)
		lines.append("选择理由: %s" % str(t.get("reason", "—")))
		if float(t.get("dwell", -1.0)) >= 0.0:
			lines.append("锁定驻留: %.1f s（锁定到死：目标死亡/失效才重选）" % float(t["dwell"]))
	else:
		lines.append("目标: 无（非战斗/未锁定）")
	# 号令段
	var order: Dictionary = d.get("order", {}) if d.has("order") else {}
	if not order.is_empty():
		lines.append("号令: [b]%s[/b] %s（号令优先于自主决策，完成前 AI 不接管）" % [
			str(order.get("behavior_zh", "?")), str(order.get("params_brief", ""))])
	else:
		lines.append("号令: 无——自主决策")
	# 阈值余量段
	var margins: Array[String] = []
	var rm: Dictionary = d.get("retreat_margin", {}) if d.has("retreat_margin") else {}
	if not rm.is_empty():
		var m: float = float(rm.get("margin", 0.0))
		margins.append("距最近敌 %.0f / 撤退安全线 %.0f（%s %+.0f px）" % [
			float(rm.get("nearest_dist", 0.0)), float(rm.get("safe_distance", 0.0)),
			"已达安全线" if m > 0.0 else "未达安全线", m])
	var cd: Dictionary = d.get("cooldown", {}) if d.has("cooldown") else {}
	if not cd.is_empty():
		margins.append("武器冷却 %.2f / %.2f s（%s）" % [
			float(cd.get("remaining", 0.0)), float(cd.get("total", 0.0)),
			"就绪" if bool(cd.get("ready", false)) else "装填中"])
	var aim: Dictionary = d.get("aim", {}) if d.has("aim") else {}
	if not aim.is_empty():
		margins.append("持瞄 %s 余 %.2f s（节奏窗 %s）" % [
			"瞄准中" if bool(aim.get("aiming", false)) else "待启动",
			float(aim.get("remain", 0.0)), str(aim.get("hold", ""))])
	var clock: Dictionary = d.get("clock", {}) if d.has("clock") else {}
	if not clock.is_empty():
		margins.append("下次决策 %.2f s 后（间隔 %.2f s · 已 %d 拍）" % [
			maxf(0.0, float(clock.get("due_in", 0.0))), float(clock.get("interval", 0.0)),
			int(clock.get("beats", 0))])
	if margins.is_empty():
		margins.append("（非战斗单位无战斗阈值）")
	lines.append("阈值余量: %s" % "  ·  ".join(margins))
	var cooling: Array = d.get("cooling_domains", [])
	if not (cooling as Array).is_empty():
		lines.append("探测冷却: %s（域级失败冷却窗，默认关）" % " ".join(cooling))
	# 特殊态行
	var states: Array[String] = []
	if bool(d.get("breach", false)):
		states.append("打通接战（号令插叙）")
	if bool(d.get("disengaging", false)):
		states.append("避战中")
	if bool(d.get("under_threat", false)):
		states.append("近身被威胁")
	if bool(d.get("hit_stun", false)):
		states.append("受击硬直")
	if bool(d.get("user_controlled", false)):
		states.append("玩家接管（AI 暂停）")
	if not states.is_empty():
		lines.append("特殊态: %s" % " · ".join(states))
	return "\n".join(lines)


## 切换日志 bbcode（新在上；from→to 中文名 + 原因）
func _log_bbcode(iid: int) -> String:
	var log: Array = _logs.get(iid, [])
	if log.is_empty():
		return "[color=#999]（本窗口开启后尚无切换记录）[/color]"
	var lines: Array[String] = []
	var entries: Array = log.duplicate()
	entries.reverse()
	for e in entries:
		var from_txt: String = _b_zh(str(e["from"]))
		var to_txt: String = _b_zh(str(e["to"]))
		var reason: String = str(e["reason"])
		var reason_txt: String = reason if not reason.is_empty() else "—"
		lines.append("[color=#888]t=%.1f[/color]  %s → [b]%s[/b]   %s" % [
			float(e["t"]),
			"[color=#999]∅[/color]" if from_txt.is_empty() else from_txt,
			to_txt, reason_txt])
	return "\n".join(lines)


## 行为短名（日志行：有中文名用中文，空 = 初始）
static func _b_zh(b: String) -> String:
	if b.is_empty():
		return ""
	return str(ScriptSnapshot.BEHAVIOR_NAMES.get(b, b))


## 朝向文案（±1 → 左/右）
static func _scene_facing_zh(f: int) -> String:
	return "→右" if f > 0 else ("←左" if f < 0 else "—")


## HP 短文案
static func _hp_zh(hp: Vector2) -> String:
	if hp.x < 0.0:
		return "—"
	return "%d/%d" % [int(hp.x), int(hp.y)]
