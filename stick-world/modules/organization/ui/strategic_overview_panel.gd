class_name StrategicOverviewPanel
extends StickWindow
## 战略总览面板（StrategicOverviewPanel）—— 全组织报表 + 上报流时间线（UI-W4b · 方案 §3.2.C）。
##
## 定位（docs/设计/UI/组织界面与AI状态接线-总体方案.md §3.2.C 战略视图）：
## 宏观层级 = 密集报表式（01-设计语言.md §1.3）——全组织森林树 + 每组织摘要行
##（人数 直辖/统辖 / 士气均值 / 状态徽标 / 驻地 / 最近上报）+ 上报流时间线。
## 窗口形态：ModalOverlay 大面板（UI.md §10.1「组织架构总览」既有槽位语义），
## 代码建根走 UIKit.full_rect 合规出口（OrgPanel 同款先例）。
##
## 信息架构：
##   ① 报表行（左栏，ScrollContainer 内森林缩进列表；行内士气条/状态徽标走手绘语言）——
##      布局思路复用指挥链沙盘的「固定步距 + 滚动容器」（拥挤即滚动平移，不压缩行宽）；
##   ② 上报流时间线（右栏）——消费 organization api `report_filed`（三型 payload：
##      commander_lost / casualty_threshold / contact）+ EventBus `commander_assigned`，
##      **事件驱动不轮询**；只展示信号带来的真实可见集（上报已由组织侧 autonomy 门控，
##      本面板不做二次门控判定，避免与组织侧规则分叉）。
##
## 过滤：复用 OrgPanel 既有标签过滤语义（TABS 七标签，"" = 全部；非匹配节点不生成行，
## 子代挂靠最近匹配祖先——与 org_panel._insert_org_item 同口径）。常量本地镜像
## OrgPanel 的 TABS/TAG/STATE/MOTIF 表，避免跨脚本常量耦合，语义保持一致。
##
## 核心操作：**跨组织调人（拖拽）**——选中组织行后，成员托盘列出其直属 personnel，
## 拖盘内成员丢到目标组织行即调 `organization api.transfer_stickman`（方案 §五.6 定稿的
## 原子接口：合法性校验一体、失败不改状态）。层级可行性（L1↔L1、L1↔L2…）一律由 api 判定，
## 本面板不做第二套判断：`_can_drop_data` 只认载荷类型，成败与原因只呈现 api 返回值。
## 失败经既有通知通道 EventBus.ui_notification → UIRoot NotificationFeed（先例
## org_report_narrator.gd）；成功刷新面板。
## 选中组织行只在本面板高亮自身，**不新造跨面板状态同步**（OrgPanel 无既有联动口）。
##
## 摘要行士气聚合：用「当前地图在场实体表」索引反查（org_panel.gd 同款口径），
## **不用全局 instance_from_id**（脏 id 会触发 ObjectDB 越界引擎报错——UI-W2-B 教训）。
## 组织数据读取一律解包 api 的 {ok, data}（读包装顶层字段是已修复过的 bug 类型）。
##
## 装配：SystemSetup 阶段表登记，实例挂 UIRoot.ModalOverlay 槽；入口在 OrgPanel 顶部
## 「总览」按钮（group("strategic_overview_panel") 查找，与「指挥链」并排，不硬编码节点路径）。


# ─────────────────────────── 拖拽控件（内联类）───────────────────────────

## 成员托盘内的可拖成员芯片（拖拽源）。`_get_drag_data` 只产载荷 + 置面板拖拽态，
## 不预判源/目标可行性（归 api）。不使用 set_drag_preview：无预览亦不影响拖放，
## 且避免测试直调时的引擎告警（拖拽态由面板横幅 + 目标行描边呈现）。
class TransferMemberChip extends SketchPanel:
	var _panel: Node = null
	var stickman_id: String = ""
	var from_org: String = ""

	func _get_drag_data(_at_position: Vector2) -> Variant:
		if _panel == null or not _panel.has_method("_begin_member_drag"):
			return null
		return _panel.call("_begin_member_drag", from_org, stickman_id)

	## 拖拽结束（含取消）由引擎发 NOTIFICATION_DRAG_END——复位面板拖拽态
	func _notification(what: int) -> void:
		if what == NOTIFICATION_DRAG_END and _panel != null \
				and _panel.has_method("_end_member_drag"):
			_panel.call("_end_member_drag")


## 组织报表行（投放目标）。只认载荷类型，不做层级合法性判断。
class TransferOrgRow extends SketchPanel:
	var _panel: Node = null
	var org_id: String = ""

	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return data is Dictionary and String((data as Dictionary).get("kind", "")) == "stickman_transfer"

	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		if _panel != null and _panel.has_method("_on_member_dropped"):
			_panel.call("_on_member_dropped", data, org_id)


# ─────────────────────── 拖拽协议常量（调人交互）───────────────────────

## 跨组织调人拖拽载荷类型（源/目标两侧共用同一协议串）
const TRANSFER_DRAG_KIND := "stickman_transfer"
## 成员托盘默认提示（拖拽中会被替换为调动提示）
const TRAY_HINT_DEFAULT := "先点选组织行 → 拖盘内成员丢到目标组织行（层级可行性由组织接口判定，UI 不做二次判断）"
## 托盘单次最多列出的成员芯片数（超出折叠计数，防长人员表撑爆面板）
const TRAY_CHIP_MAX := 12


# ─────────────────────────────── 常量 ────────────────────────────────
## 标签栏（"" = 全部；镜像 OrgPanel.TABS，语义一致）
const TABS: Array = [
	{"id": "", "label": "全部"},
	{"id": "MILITARY", "label": "军事"},
	{"id": "RESEARCH", "label": "科研"},
	{"id": "ENGINEERING", "label": "工程"},
	{"id": "ADMINISTRATION", "label": "行政"},
	{"id": "COMMERCE", "label": "商业"},
	{"id": "LABOR", "label": "劳工"},
	{"id": "LOGISTICS", "label": "运输"},
]

## Tag 枚举 int ↔ 中文 / 字符串（镜像 OrgPanel，过滤比较用）
const TAG_INT_TO_ZH := {
	0: "军事", 1: "科研", 2: "工程", 3: "行政", 4: "商业", 5: "劳工", 6: "运输",
}
const TAG_STR_TO_INT := {
	"MILITARY": 0, "RESEARCH": 1, "ENGINEERING": 2, "ADMINISTRATION": 3,
	"COMMERCE": 4, "LABOR": 5, "LOGISTICS": 6,
}

## 组织状态枚举 → 中文 / 图标母题（镜像 OrgPanel.STATE_*，母题名 = 图标库文件名）
const STATE_INT_TO_ZH := {
	0: "组建中", 1: "活跃", 2: "执行中", 3: "休整中", 4: "已解散",
}
const STATE_MOTIF := {
	0: &"帐篷", 1: &"旗帜", 2: &"齿轮", 3: &"篝火", 4: &"木门",
}

## 上报三型 + 任命事件 → 时间线分组名 / 图标母题（全走图标库既有枚，不立项新母题）
const REPORT_KIND_ZH := {
	"commander_lost": "指挥链", "casualty_threshold": "伤亡", "contact": "接触",
	"commander_assigned": "任命",
}
const REPORT_KIND_MOTIF := {
	"commander_lost": &"王冠", "casualty_threshold": &"绷带", "contact": &"望远镜",
	"commander_assigned": &"印章",
}

## 时间线留痕上限（密集报表纪律：旧条目滚出，不无限堆）
const TIMELINE_MAX := 30
## 森林缩进步距（px/层）
const ROW_INDENT := 16.0

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _org_api: Node = null
## 当前标签过滤（"" = 全部）
var _active_tag: String = ""
## 选中组织 id（仅本面板高亮，不做跨面板同步）
var _selected_org: String = ""
## 报表行控件（org_id -> SketchPanel；选中高亮用）
var _rows: Dictionary = {}
## 行的「最近上报」标签句柄（org_id -> Label；上报到达时原地更新，不整表重建）
var _row_report_labels: Dictionary = {}
## 上报流时间线缓存（新条目在队首；[{at,clock,org_id,org_name,tag,kind,text}]）
var _report_cache: Array = []
## 最近上报摘要（org_id -> {kind,text}；报表行「最近上报」列数据源）
var _last_report: Dictionary = {}

# ── 士气聚合缓存（单次建表内复用；口径同 OrgPanel）──
var _people_cache: Dictionary = {}
var _morale_cache: Dictionary = {}
var _unit_index: Dictionary = {}
var _unit_index_built: bool = false

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _tag_bar: TabBar = null
var _row_box: VBoxContainer = null
var _timeline_box: VBoxContainer = null
## 成员托盘（跨组织调人：选中组织后列出其直属成员为可拖芯片）
var _tray_box: HBoxContainer = null
var _tray_hint: Label = null

# ── 拖拽态（拖拽中记录源组织/成员；NOTIFICATION_DRAG_END 或投放后复位）──
var _drag_from_org: String = ""
var _drag_stickman: String = ""


func _ready() -> void:
	super()
	add_to_group("strategic_overview_panel")


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 SystemSetup 调用，注入 GameRoot 引用并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_org_api = game_root.get_organization_api() if game_root != null \
			and game_root.has_method("get_organization_api") else null
	window_size = Vector2(1220, 680)
	window_title = "战略总览"
	behavior = StickWindow.Behavior.FLOATING
	_build_window()
	_connect_signals()
	_refresh_all()


## 内容装配（StickWindow 已建无遮罩骨架；内容挂 _body：顶部条 + 标签栏 + 左报表右时间线）
func _build_content() -> void:
	# ── 顶部：标题（账本母题）+ 报表说明 ──
	var top := StickKit.row(_body, 8)
	_add_motif(top, &"账本", 20.0)
	StickKit.label(top, "战略总览", StickKit.LabelKind.SECTION)
	var hint := StickKit.label(top, "全组织报表 + 上报流时间线（上报 = 自主门控后的真实可见集）",
			StickKit.LabelKind.HINT)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# ── 标签栏 = 报表过滤（语义同 OrgPanel）──
	_tag_bar = TabBar.new()
	for t in TABS:
		_tag_bar.add_tab(String(t["label"]))
	_tag_bar.tab_selected.connect(_on_tab_selected)
	_body.add_child(_tag_bar)
	# ── 主体：左报表 + 右时间线 ──
	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(main)
	# 左：报表行滚动区（内容超窗即滚条；行宽不压缩——指挥链沙盘同思路）
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main.add_child(scroll)
	_row_box = VBoxContainer.new()
	_row_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row_box.add_theme_constant_override("separation", 2)
	scroll.add_child(_row_box)
	# 右：上报流时间线（固定宽，事件驱动重排）
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(360, 0)
	right.add_theme_constant_override("separation", 4)
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(right)
	StickKit.label(right, "上报流时间线", StickKit.LabelKind.SECTION)
	StickKit.label(right, "report_filed 三型 + commander_assigned｜事件驱动", StickKit.LabelKind.TINY)
	var tscroll := ScrollContainer.new()
	tscroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(tscroll)
	_timeline_box = VBoxContainer.new()
	_timeline_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline_box.add_theme_constant_override("separation", 4)
	tscroll.add_child(_timeline_box)
	# ── 成员托盘（跨组织调人：选中组织行 → 拖盘内成员丢到目标组织行）──
	var tray_panel := SketchPanel.new()
	tray_panel.tone = SketchPanel.Tone.LIGHT
	tray_panel.compact = true
	_body.add_child(tray_panel)
	var tray_v := VBoxContainer.new()
	tray_v.add_theme_constant_override("separation", 3)
	tray_panel.add_child(tray_v)
	var tray_top := StickKit.row(tray_v, 8)
	_add_motif(tray_top, &"印章", 14.0)
	StickKit.label(tray_top, "成员托盘", StickKit.LabelKind.TINY)
	_tray_hint = StickKit.label(tray_top, TRAY_HINT_DEFAULT, StickKit.LabelKind.TINY)
	_tray_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tray_box = HBoxContainer.new()
	_tray_box.add_theme_constant_override("separation", 6)
	tray_v.add_child(_tray_box)
	# ── 底部纪律提示 ──
	StickKit.label(_body, "选中行仅本面板高亮；调人成败与层级可行性一律以组织接口返回为准",
			StickKit.LabelKind.TINY)


func _connect_signals() -> void:
	if _org_api != null:
		for sig in ["org_created", "org_restructured", "org_disbanded"]:
			if _org_api.has_signal(sig) and not _org_api.is_connected(sig, _on_orgs_changed):
				_org_api.connect(sig, _on_orgs_changed)
		if _org_api.has_signal("report_filed") and not _org_api.is_connected("report_filed", _on_report_filed):
			_org_api.connect("report_filed", _on_report_filed)
	if EventBus != null and EventBus.has_signal("commander_assigned") \
			and not EventBus.commander_assigned.is_connected(_on_commander_assigned):
		EventBus.commander_assigned.connect(_on_commander_assigned)


# ─────────────────────────────── 打开/关闭 ────────────────────────────────

func open() -> void:
	_refresh_all()
	super.open()


## 组织树变动（建表/重组/解散）→ 报表重建 + 选中态复核
func _on_orgs_changed(_org_id: String = "") -> void:
	if visible:
		_refresh_all()


func _refresh_all() -> void:
	_rebuild_rows()
	_refresh_timeline()


# ─────────────────────────────── 报表行 ────────────────────────────────

func _rebuild_rows() -> void:
	if _row_box == null:
		return
	# 建表前清聚合缓存（人员/士气随组织与实体状态变化，缓存只在单次建表内有效）
	_people_cache.clear()
	_morale_cache.clear()
	_unit_index_built = false
	for child in _row_box.get_children():
		_row_box.remove_child(child)
		child.queue_free()
	_rows.clear()
	_row_report_labels.clear()
	# 选中组织可能已被解散/重组：失效则清高亮
	if not _selected_org.is_empty() and _org_api != null \
			and not bool(_org_api.get_organization(_selected_org).get("ok", false)):
		_selected_org = ""
	# 成员托盘随选中组织同步重建（报表重建后人员表也可能已变）
	_refresh_member_tray()
	if _org_api == null or not _org_api.has_method("list_root_orgs"):
		_add_row_hint("组织系统未装配")
		return
	var any := false
	for org_id in _org_api.list_root_orgs():
		any = _insert_rows(String(org_id), 0) or any
	if not any:
		_add_row_hint("当前过滤下无组织（在组织管理面板从预设创建）")


func _add_row_hint(text: String) -> void:
	var l := StickKit.label(_row_box, text, StickKit.LabelKind.HINT)
	l.modulate = StickTokens.TEXT_FAINT


## 递归插入报表行；非匹配节点不生成行，子代挂靠最近匹配祖先（过滤透传，同 OrgPanel）
func _insert_rows(org_id: String, visible_depth: int) -> bool:
	var r: Dictionary = _org_api.get_organization(org_id)
	if not r.get("ok", false):
		return false
	var d: Dictionary = r.data
	var matched: bool = _active_tag.is_empty() \
			or int(d.tag) == int(TAG_STR_TO_INT.get(_active_tag, -1))
	var any := false
	if matched:
		_make_row(org_id, d, visible_depth)
		any = true
		for child_id in d.child_orgs:
			any = _insert_rows(String(child_id), visible_depth + 1) or any
	else:
		for child_id in d.child_orgs:
			any = _insert_rows(String(child_id), visible_depth) or any
	return any


## 单行摘要（报表式密集排布；行内士气条/状态徽标走手绘语言）。
## 列：缩进 + 层级 + 状态图标 + 名 + 标签 + 状态 + 人数（直辖/统辖）+ 士气条 + 驻地 + 最近上报。
func _make_row(org_id: String, d: Dictionary, depth: int) -> void:
	var people := _org_people(org_id)
	var morale := _people_morale(people)
	var panel := TransferOrgRow.new()
	panel._panel = self
	panel.org_id = org_id
	panel.tone = SketchPanel.Tone.LIGHT
	panel.compact = true
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.tooltip_text = _row_tooltip(d, people, morale)
	panel.gui_input.connect(_on_row_input.bind(org_id))
	_row_box.add_child(panel)
	_rows[org_id] = panel
	if org_id == _selected_org:
		panel.outline_override = StickTokens.ACCENT
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)
	_ignore(hb)
	panel.add_child(hb)
	# 缩进 + 层级字形（森林缩进列表）
	var indent := Control.new()
	indent.custom_minimum_size = Vector2(depth * ROW_INDENT, 0)
	_ignore(indent)
	hb.add_child(indent)
	_small_label(hb, "◆" if depth == 0 else "└", 12.0, StickTokens.TEXT_FAINT,
			StickKit.LabelKind.TINY)
	# 状态图标（母题与 OrgPanel 同源）
	var icon := TextureRect.new()
	icon.texture = StickIcons.tex(StringName(STATE_MOTIF.get(int(d.state), &"旗帜")))
	icon.custom_minimum_size = Vector2(18, 18)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_ignore(icon)
	hb.add_child(icon)
	# 名（[L%d] 名）
	var leaderless := int(d.tier) > 1 and String(d.commander_id).is_empty()
	var name_l := _small_label(hb, "[L%d] %s" % [int(d.tier), String(d.name)], 140.0,
			StickTokens.DANGER if leaderless else StickTokens.TEXT, StickKit.LabelKind.HINT)
	name_l.tooltip_text = "群龙无首：命令将停驻此层" if leaderless else ""
	# 标签
	_small_label(hb, String(TAG_INT_TO_ZH.get(int(d.tag), "?")), 36.0, StickTokens.TEXT_DIM,
			StickKit.LabelKind.TINY)
	# 统一人数（直辖/统辖）
	_small_label(hb, "直辖 %d · 统辖 %d" % [(d.personnel as Array).size(), people.size()],
			104.0, StickTokens.TEXT_DIM, StickKit.LabelKind.TINY)
	# 状态徽标（中文 + 状态色）
	_small_label(hb, String(STATE_INT_TO_ZH.get(int(d.state), "?")), 48.0,
			_state_color(int(d.state)), StickKit.LabelKind.TINY)
	# 士气均值条（取不到则不显示条形，标 ——— 不误报）
	if morale >= 0.0:
		var bar := SketchProgress.new()
		bar.max_value = 1.0
		bar.value = morale
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(84, 12)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_ignore(bar)
		hb.add_child(bar)
		_small_label(hb, "%d%%" % int(round(morale * 100.0)), 34.0, _morale_color(morale),
				StickKit.LabelKind.TINY)
	else:
		_small_label(hb, "士气 —", 62.0, StickTokens.TEXT_FAINT, StickKit.LabelKind.TINY)
	# 驻地
	var loc := String(d.location)
	_small_label(hb, "驻地 %s" % (loc if not loc.is_empty() else "—"), 78.0,
			StickTokens.TEXT_DIM, StickKit.LabelKind.TINY)
	# 最近上报（列尾自适应；信号到达时原地更新句柄）
	var rep: Dictionary = _last_report.get(org_id, {})
	var rep_l := _small_label(hb, _row_report_text(rep), 0.0, _row_report_color(rep),
			StickKit.LabelKind.TINY)
	rep_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row_report_labels[org_id] = rep_l


## 行「最近上报」文案（无上报显示占位，不撒谎）
func _row_report_text(rep: Dictionary) -> String:
	if rep.is_empty():
		return "最近 —"
	return "最近 %s：%s" % [String(rep.get("kind", "")), String(rep.get("text", ""))]


func _row_report_color(rep: Dictionary) -> Color:
	if rep.is_empty():
		return StickTokens.TEXT_FAINT
	return _kind_color(String(rep.get("kind", "")))


## 行点击选中 → 仅本面板高亮（不新造跨面板状态同步）
func _on_row_input(event: InputEvent, org_id: String) -> void:
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_selected_org = org_id
		_apply_selection_visuals()
		_refresh_member_tray()
		var panel: Control = _rows.get(org_id, null)
		if panel != null and is_instance_valid(panel):
			panel.accept_event()


func _apply_selection_visuals() -> void:
	for id in _rows:
		var panel: Control = _rows[id]
		if panel != null and is_instance_valid(panel):
			panel.outline_override = StickTokens.ACCENT if id == _selected_org else Color.TRANSPARENT


# ─────────────────────── 跨组织调人（拖拽 → api 原子接口）───────────────────────

## 拖拽源回调：置拖拽态 + 产载荷。返回 nil = 无法拖（面板未接线时安全降级）。
## **不在此处做任何可行性预判**——层级/成员归属合法性一律由 api.transfer_stickman 判定。
func _begin_member_drag(from_org: String, stickman_id: String) -> Variant:
	if from_org.is_empty() or stickman_id.is_empty():
		return null
	_drag_from_org = from_org
	_drag_stickman = stickman_id
	if _tray_hint != null:
		_tray_hint.text = "调动中 ▲#%s：「%s」→ 丢到目标组织行" % [stickman_id, _org_name(from_org)]
		_tray_hint.modulate = StickTokens.ACCENT
	_apply_drag_targets(true)
	return {"kind": TRANSFER_DRAG_KIND, "stickman_id": stickman_id, "from_org": from_org}


## 拖拽结束（引擎 NOTIFICATION_DRAG_END，含取消）或投放后复位拖拽态
func _end_member_drag() -> void:
	if _drag_from_org.is_empty() and _drag_stickman.is_empty():
		return
	_drag_from_org = ""
	_drag_stickman = ""
	if _tray_hint != null:
		_tray_hint.text = TRAY_HINT_DEFAULT
		_tray_hint.modulate = StickTokens.TEXT_DIM
	_apply_drag_targets(false)


## 拖拽中提示可投放行（非源组织行加描边）——纯视觉提示，不代表合法性通过
func _apply_drag_targets(active: bool) -> void:
	if not active:
		_apply_selection_visuals()
		return
	for id in _rows:
		var panel: Control = _rows[id]
		if panel != null and is_instance_valid(panel):
			panel.outline_override = StickTokens.ACCENT if id == _selected_org else StickTokens.BORDER_STRONG


## 投放回调：调 api 原子接口。成败/原因只呈现 api 返回值，UI 不预判、不二次判定。
## 失败（api 保证不改动状态）→ 既有通知通道报错；成功 → 刷新报表与托盘。
func _on_member_dropped(data: Variant, to_org: String) -> void:
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	var stickman_id := String(d.get("stickman_id", ""))
	var from_org := String(d.get("from_org", ""))
	_end_member_drag()
	if _org_api == null or not _org_api.has_method("transfer_stickman"):
		_notify("调人失败：组织模块未提供 transfer_stickman", "error")
		return
	var r: Dictionary = _org_api.transfer_stickman(stickman_id, from_org, to_org)
	if r.get("ok", false):
		_notify("已调动 ▲#%s：「%s」→「%s」" % [stickman_id, _org_name(from_org), _org_name(to_org)], "info")
		_refresh_all()
		_refresh_member_tray()
	else:
		_notify("调动失败：%s" % String(r.get("error", "未知原因")), "warn")


## 成员托盘重建：选中组织的直属 personnel → 可拖芯片（超上限折叠计数；无选中/无成员给提示）
func _refresh_member_tray() -> void:
	if _tray_box == null:
		return
	for child in _tray_box.get_children():
		_tray_box.remove_child(child)
		child.queue_free()
	# 拖拽中不覆盖调动提示
	if _drag_stickman.is_empty() and _tray_hint != null:
		_tray_hint.text = TRAY_HINT_DEFAULT
		_tray_hint.modulate = StickTokens.TEXT_DIM
	if _selected_org.is_empty():
		var none_l := StickKit.label(_tray_box, "（未选中组织）", StickKit.LabelKind.TINY)
		none_l.modulate = StickTokens.TEXT_FAINT
		return
	var d: Dictionary = _org_data(_selected_org)
	var members: Array = d.get("personnel", []) if not d.is_empty() else []
	if members.is_empty():
		var empty_l := StickKit.label(_tray_box, "「%s」无直属成员可调" % _org_name(_selected_org),
				StickKit.LabelKind.TINY)
		empty_l.modulate = StickTokens.TEXT_FAINT
		return
	var n := 0
	for raw in members:
		if n >= TRAY_CHIP_MAX:
			var more_l := StickKit.label(_tray_box, "…+%d" % (members.size() - TRAY_CHIP_MAX),
					StickKit.LabelKind.TINY)
			more_l.modulate = StickTokens.TEXT_FAINT
			break
		_make_member_chip(String(raw))
		n += 1


## 单个成员芯片（拖拽源；mouse_filter STOP 才可起拖）
func _make_member_chip(stickman_id: String) -> void:
	var chip := TransferMemberChip.new()
	chip._panel = self
	chip.stickman_id = stickman_id
	chip.from_org = _selected_org
	chip.tone = SketchPanel.Tone.LIGHT
	chip.compact = true
	chip.mouse_filter = Control.MOUSE_FILTER_STOP
	chip.tooltip_text = "拖动 ▲#%s 到目标组织行（跨组织调人）" % stickman_id
	_tray_box.add_child(chip)
	var l := StickKit.label(chip, "▲#%s" % stickman_id, StickKit.LabelKind.TINY)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.modulate = StickTokens.TEXT


func _notify(msg: String, kind: String = "info") -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("战略总览", msg, kind)


# ─────────────────────────────── 上报流时间线 ────────────────────────────────

## 上报落档（三型分发；可见集已由组织侧门控决定，本面板只做呈现，不二次判定）
func _on_report_filed(org_id: String, report: Dictionary) -> void:
	var type := String(report.get("type", ""))
	var raw: Variant = report.get("payload", {})
	var payload: Dictionary = raw if raw is Dictionary else {}
	match type:
		"commander_lost":
			_push_entry(org_id, type, _text_commander_lost(payload))
		"casualty_threshold":
			_push_entry(org_id, type, _text_casualty(payload))
		"contact":
			_push_entry(org_id, type, _text_contact(payload))
		_:
			pass  # 未知类型不进时间线（schema 槽位留给后续各域上报，不猜文案）


## 补位/任命事件（双方皆发：玩家手任命与补位链均落时间线，构成指挥变更留痕）
func _on_commander_assigned(org_id: String, unit_id: int) -> void:
	if unit_id <= 0:
		return
	_push_entry(org_id, "commander_assigned", "任命 ▲#%d" % unit_id)


func _push_entry(org_id: String, type: String, text: String) -> void:
	var kind := String(REPORT_KIND_ZH.get(type, type))
	var entry := {
		"at": Time.get_ticks_msec(),
		"clock": Time.get_time_string_from_system(),
		"org_id": org_id,
		"org_name": _org_name(org_id),
		"tag": _org_tag_of(org_id),
		"type": type,
		"kind": kind,
		"text": text,
	}
	_report_cache.push_front(entry)
	if _report_cache.size() > TIMELINE_MAX:
		_report_cache.resize(TIMELINE_MAX)
	_last_report[org_id] = {"kind": kind, "text": text}
	# 行尾「最近上报」原地更新（不整表重建）；时间线仅可见时重排（隐藏时只积攒）
	var rep_l: Label = _row_report_labels.get(org_id, null)
	if rep_l != null and is_instance_valid(rep_l):
		rep_l.text = _row_report_text(_last_report[org_id])
		rep_l.modulate = _row_report_color(_last_report[org_id])
	if visible:
		_refresh_timeline()


func _refresh_timeline() -> void:
	if _timeline_box == null:
		return
	for child in _timeline_box.get_children():
		_timeline_box.remove_child(child)
		child.queue_free()
	var active_int: int = int(TAG_STR_TO_INT.get(_active_tag, -1))
	var shown := 0
	for e in _report_cache:
		var d: Dictionary = e
		# 过滤：未知 tag（组织已解散）不因无法判定而被误滤
		var tag := int(d.get("tag", -1))
		if not _active_tag.is_empty() and tag != active_int and tag != -1:
			continue
		_make_timeline_row(d)
		shown += 1
	if shown == 0:
		var l := StickKit.label(_timeline_box, "暂无上报（组织侧门控后的真实可见集）",
				StickKit.LabelKind.TINY)
		l.modulate = StickTokens.TEXT_FAINT


func _make_timeline_row(e: Dictionary) -> void:
	var kind := String(e.get("kind", ""))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_ignore(row)
	_timeline_box.add_child(row)
	var icon := TextureRect.new()
	icon.texture = StickIcons.tex(StringName(REPORT_KIND_MOTIF.get(String(e.get("type", "")), &"印章")))
	icon.custom_minimum_size = Vector2(14, 14)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_slim_v(icon)
	row.add_child(icon)
	var l := StickKit.label(row, "[%s] %s · %s\n%s" % [
			String(e.get("clock", "")), String(e.get("org_name", "")), kind,
			String(e.get("text", ""))], StickKit.LabelKind.TINY, _kind_color(kind))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.tooltip_text = "组织 %s" % String(e.get("org_id", ""))


# ─────────────────────────────── 三型文案 ────────────────────────────────

func _text_commander_lost(payload: Dictionary) -> String:
	var filled := bool(payload.get("filled", false))
	var prev := String(payload.get("prev_commander_id", ""))
	var succ := String(payload.get("successor_id", ""))
	var line := "指挥官阵亡"
	if not prev.is_empty():
		line = "指挥官 ▲#%s 阵亡" % prev
	if filled and not succ.is_empty():
		return "%s → ▲#%s 接任" % [line, succ]
	return "%s（无人补位·群龙无首）" % line


func _text_casualty(payload: Dictionary) -> String:
	var alive := int(payload.get("alive", 0))
	var total := int(payload.get("total", 0))
	var loss_rate := float(payload.get("loss_rate", 0.0))
	if loss_rate <= 0.0 and total > 0:
		loss_rate = 1.0 - float(alive) / float(total)
	return "剩 %d/%d（损失 %d%%）" % [alive, total, int(round(loss_rate * 100.0))]


func _text_contact(payload: Dictionary) -> String:
	return "遭遇敌军 %d 人" % int(payload.get("enemy_count", 0))


# ─────────────────────────────── 过滤 / 回调 ────────────────────────────────

func _on_tab_selected(tab: int) -> void:
	_active_tag = String(TABS[tab]["id"]) if tab >= 0 and tab < TABS.size() else ""
	_rebuild_rows()
	_refresh_timeline()


# ─────────────── 组织「活」取数（只读 duck；查询不到即不显示该项）───────────────

func _org_name(org_id: String) -> String:
	var d := _org_data(org_id)
	return String(d.get("name", org_id)) if not d.is_empty() else (org_id if not org_id.is_empty() else "玩家")
	# 注：空 id = 玩家源，与指挥链口径一致


func _org_data(org_id: String) -> Dictionary:
	if _org_api == null or not _org_api.has_method("get_organization"):
		return {}
	var r: Dictionary = _org_api.get_organization(org_id)
	return r.get("data", {}) if r.get("ok", false) else {}


## 组织 tag（未知/已解散返回 -1——过滤时不过度裁剪）
func _org_tag_of(org_id: String) -> int:
	var d := _org_data(org_id)
	return int(d.get("tag", -1)) if not d.is_empty() else -1


## 子树人员集合（本组织成员 ∪ 指挥官 ∪ 各级子组织递归；去重 + 单次建表内缓存）
func _org_people(org_id: String) -> Array[String]:
	if _people_cache.has(org_id):
		return _people_cache[org_id]
	var out: Array[String] = []
	_collect_people(org_id, out, {})
	_people_cache[org_id] = out
	return out


func _collect_people(org_id: String, out: Array[String], seen: Dictionary) -> void:
	if _org_api == null:
		return
	var r: Dictionary = _org_api.get_organization(org_id)
	if not r.get("ok", false):
		return
	var d: Dictionary = r.data
	for raw in [String(d.commander_id)] + (d.personnel as Array):
		var pid := String(raw)
		if pid.is_empty() or seen.has(pid):
			continue
		seen[pid] = true
		out.append(pid)
	for child_id in d.child_orgs:
		_collect_people(String(child_id), out, seen)


## 成员士气均值（0~1，仅存活且可解析成员；无一可解析 → -1 = 不显示该项）
func _people_morale(people: Array[String]) -> float:
	var sum := 0.0
	var n := 0
	for pid in people:
		var ratio := _unit_morale(pid)
		if ratio < 0.0:
			continue
		sum += ratio
		n += 1
	return sum / float(n) if n > 0 else -1.0


func _unit_morale(stickman_id: String) -> float:
	if _morale_cache.has(stickman_id):
		return _morale_cache[stickman_id]
	var value := _probe_unit_morale(stickman_id)
	_morale_cache[stickman_id] = value
	return value


func _probe_unit_morale(stickman_id: String) -> float:
	var node := _resolve_unit(stickman_id)
	if node == null:
		return -1.0
	if node.has_method("is_dead") and bool(node.call("is_dead")):
		return -1.0
	var health: Node = node.call("get_health") if node.has_method("get_health") else null
	if health == null or not health.has_method("get_morale_ratio"):
		return -1.0
	return clampf(float(health.call("get_morale_ratio")), 0.0, 1.0)


## 当前地图实体索引（instance_id -> 在场实体），懒建 + 单次建表内复用。
## 不用全局 instance_from_id：脏档/测试桩数据会触发 ObjectDB 越界引擎报错；
## 「地图在场实体表」口径也更诚实——取不到（未出场/他图）就不显示士气。
func _ensure_unit_index() -> void:
	if _unit_index_built:
		return
	_unit_index_built = true
	_unit_index.clear()
	if _game_root == null or not _game_root.has_method("get_current_map"):
		return
	var map: Node = _game_root.get_current_map()
	if map == null or not map.has_method("get_entities"):
		return
	for e in map.get_entities():
		if e != null and is_instance_valid(e) and e.has_method("get_health"):
			_unit_index[int(e.get_instance_id())] = e


func _resolve_unit(stickman_id: String) -> Node:
	if not stickman_id.is_valid_int():
		return null
	_ensure_unit_index()
	return _unit_index.get(stickman_id.to_int(), null)


func _row_tooltip(d: Dictionary, people: Array[String], morale: float) -> String:
	var lines: Array[String] = []
	lines.append("%s · L%d · %s · %s" % [String(d.name), int(d.tier),
			String(TAG_INT_TO_ZH.get(int(d.tag), "?")), String(STATE_INT_TO_ZH.get(int(d.state), "?"))])
	var cmd := String(d.commander_id)
	lines.append("指挥官：%s" % ("▲#%s" % cmd if not cmd.is_empty() else "（空缺）"))
	lines.append("直属 %d 人 · 统辖 %d 人" % [(d.personnel as Array).size(), people.size()])
	if morale >= 0.0:
		lines.append("士气均值：%d%%" % int(round(morale * 100.0)))
	if int(d.tier) > 1 and cmd.is_empty():
		lines.append("群龙无首：命令将停驻此层")
	var rep: Dictionary = _last_report.get(String(d.id), {})
	if not rep.is_empty():
		lines.append("最近上报：%s %s" % [String(rep.get("kind", "")), String(rep.get("text", ""))])
	return "\n".join(lines)


# ─────────────────────────────── 样式 / 小工具 ────────────────────────────────

func _state_color(state: int) -> Color:
	match state:
		0:
			return StickTokens.INFO
		1:
			return StickTokens.SUCCESS
		2:
			return StickTokens.ACCENT
		3:
			return StickTokens.TEXT_DIM
		_:
			return StickTokens.TEXT_FAINT


## 时间线分组配色（数值之外的颜色冗余）
func _kind_color(kind: String) -> Color:
	match kind:
		"指挥链":
			return StickTokens.DANGER
		"伤亡":
			return StickTokens.WARN
		"接触":
			return StickTokens.INFO
		"任命":
			return StickTokens.ACCENT
		_:
			return StickTokens.TEXT_DIM


func _morale_color(ratio: float) -> Color:
	if ratio < 0.35:
		return StickTokens.DANGER
	if ratio < 0.60:
		return StickTokens.WARN
	return StickTokens.SUCCESS


## 顶部母题图标（账本等既有枚；缺失静默跳过）
func _add_motif(parent: Control, motif: StringName, size: float) -> void:
	var t := StickIcons.tex(motif)
	if t == null:
		return
	var icon := TextureRect.new()
	icon.texture = t
	icon.custom_minimum_size = Vector2(size, size)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_ignore(icon)
	parent.add_child(icon)


## 小号定宽标签（报表列；超宽裁切——树列不换行纪律）
func _small_label(parent: Control, text: String, min_w: float, color: Color,
		kind: StickKit.LabelKind) -> Label:
	var l := StickKit.label(parent, text, kind, color)
	if min_w > 0.0:
		l.custom_minimum_size = Vector2(min_w, 0)
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _ignore(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _slim_v(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
