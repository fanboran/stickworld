class_name CommandChainView
extends StickWindow
## 指挥链视图（CommandChainView）—— 「命令沿层级逐跳跑秒」的独立沙盘窗口。
##
## 定位（docs/设计/UI/组织界面与AI状态接线-总体方案.md §3.2.B ★ 本项目独有特色）：
## 命令不是瞬发魔法而是物理旅程——把旅程画出来（逐层指挥链 + 传输层物理传播）。
## 窗口形态：独立 StickWindow FLOATING（开放问题 §五.2 提案：动画层需常驻、不被 CRUD 打断）；
## 渲染层：UI 层示意动画（§五.3 提案：不做世界层光点）。
##
## 信息架构三块（中密度，字段收进节点牌 tooltip）：
##   ① 层级树 = 兵棋沙盘（CommandChainBoard）：兵牌 = 指挥官 + 统辖规模 + 补位候选前三
##      + 群龙无首墨渍标记，按 tag 走 CONTENT_PALETTE 染色；
##   ② 命令传播动画层（同 board）：relay_started 逐跳点亮连线 + 每跳 eta 实时秒数；
##      relay_arrived 的 delivered(tier<=1) 兵牌脉冲、dropped_leaderless 亮「命令停驻」；
##   ③ 在途清单 / 抵达留痕（右栏）：get_relays_in_flight() + get_relay_history(8)。
##
## 信号路由（方案 §五.5 提案口径）：org UI 消费战斗域接力信号——command_chain.gd 发射处
## 镜像转发到 EventBus（relay_started/relay_arrived），本视图只订阅 EventBus，不做跨模块取节点；
## 在途清单走 organization api 同域的 command_chain 只读查询（get_relays_in_flight/history）。
##
## 核心操作「对任意层节点下令」（方案 §3.2.B，UI-W4a）：点兵牌选中 → 号令条按钮 →
## `TacticalOrders.issue_to_org(选中 org_id, 号令类型)`——选层即对该层子树下令，语义与
## OrgPanel/战斗面板一致（逐层接力，relay 动画随之点亮，既有机制不新造）。
## TacticalOrders 实例经 **GameRoot duck getter `get_tactical_orders()`** 取（battle_panel
## 同款既有出口，不新增 combat 侧接口、不 preload 宿主脚本）；取不到即整条号令条禁用降级。
##
## 装配：SystemSetup 登记「指挥链视图」项，实例化 command_chain_view.tscn（场景=布局真相源）
## 挂 UIRoot.ModalOverlay 槽；入口在 OrgPanel 顶部「指挥链」按钮（group 查找，不硬编码节点路径）。
## 本批不开任何 .tres 开关、不改配置值。

# ─────────────────────────────── 常量 ────────────────────────────────
## 号令中文名（镜像 TacticalOrders.OrderType：ADVANCE_ALL0 SPRINT1 HOLD2 RETREAT3
## TAKE_COVER4 RALLY5——与 squad_card 同惯例，按战斗域本地常量，不 preload 宿主脚本）
const ORDER_NAMES := {0: "前进", 1: "冲刺", 2: "坚守", 3: "后撤", 4: "找掩体", 5: "集结"}

## 号令条按钮集（§3.2.B 核心操作「挑常用的 3~4 个」）：
## 类型 int + 文案 + 是否需目标点（需要者无目标点时禁用）
const ORDER_BUTTONS: Array = [
	[0, "前进", true],   # ADVANCE_ALL
	[1, "冲刺", true],   # SPRINT
	[2, "坚守", false],  # HOLD_POSITION
	[5, "集结", true],   # RALLY
]
## 前进/冲刺目标点前推偏移（px；battle_panel ADVANCE_OFFSET_X 同语义的本地镜像）
const FORWARD_OFFSET_X := 320.0

## 在途清单倒计时刷新节拍（s）：清单成员集仍由接力信号驱动，此处只让「剩余秒数」
## 数字走起来（squad_card/team_ai_hud 缓变值低频节拍同惯例）；动画层本身零轮询。
const POLL_INTERVAL := 0.25

const BoardScript := preload("res://modules/organization/ui/command_chain_board.gd")

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _org_api: Node = null
var _chain: Node = null
## TacticalOrders（GameRoot duck getter；缺省 = 无战斗侧，号令条整体降级禁用）
var _tactical: Node = null

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _board: Control = null
var _inflight_box: VBoxContainer = null
var _history_box: VBoxContainer = null
var _summary_label: Label = null
## 下令目标文案（「下令目标 —（点选兵牌）」/「下令目标 第一连 · L2」）
var _target_label: Label = null
## 号令按钮（order_type -> Button）
var _order_buttons: Dictionary = {}
## 缩放滑杆与百分比标签
var _zoom_slider: HSlider = null
var _zoom_label: Label = null
## 在途清单倒计时节拍累积器
var _poll_acc: float = 0.0


func _process(delta: float) -> void:
	if not visible:
		return
	_poll_acc += delta
	if _poll_acc < POLL_INTERVAL:
		return
	_poll_acc = 0.0
	# 只在有在途命令时重刷清单（成员集归信号，这里只让剩余秒数走字）
	if _chain != null and _chain.has_method("get_relays_in_flight") \
			and not (_chain.get_relays_in_flight() as Array).is_empty():
		_refresh_inflight()


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 SystemSetup 调用，注入 GameRoot 引用并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_org_api = game_root.get_organization_api() if game_root != null and game_root.has_method("get_organization_api") else null
	_chain = game_root.get_command_chain() if game_root != null and game_root.has_method("get_command_chain") else null
	_tactical = game_root.get_tactical_orders() if game_root != null and game_root.has_method("get_tactical_orders") else null
	window_size = Vector2(1120, 760)
	window_title = "指挥链"
	behavior = StickWindow.Behavior.FLOATING
	_build_window()
	_connect_signals()
	_refresh_all()


func _ready() -> void:
	super()
	add_to_group("command_chain_view")


## 内容装配（StickWindow 已建无遮罩骨架；内容挂 _body：工具条 + 号令条 + 左沙盘右清单）
func _build_content() -> void:
	_build_toolbar()
	_build_order_bar()
	# ── 主区：左沙盘 + 右清单 ──
	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(main)
	# 左：兵棋沙盘（自绘连线 + 兵牌子控件；位置由 board 自算，容器只管体量）。
	# 沙盘外套 ScrollContainer（拥挤治理 UI-W4a）：内容超窗即出滚动条（平移），
	# 兵牌不再为塞进一屏而互叠；缩放由滑杆改步距（board.set_zoom）。
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(680, 480)
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(scroll)
	_board = UIKit.widget(BoardScript, "Board")
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	if _board.has_signal("node_selected"):
		_board.connect("node_selected", _on_node_selected)
	scroll.add_child(_board)
	# 右：在途清单 + 抵达留痕
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(300, 0)
	right.add_theme_constant_override("separation", 4)
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(right)
	StickKit.label(right, "在途命令", StickKit.LabelKind.SECTION)
	_summary_label = StickKit.label(right, "在途 0 跳", StickKit.LabelKind.HINT)
	var iscroll := ScrollContainer.new()
	iscroll.custom_minimum_size = Vector2(0, 190)
	iscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	iscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(iscroll)
	_inflight_box = VBoxContainer.new()
	_inflight_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inflight_box.add_theme_constant_override("separation", 2)
	iscroll.add_child(_inflight_box)
	StickKit.label(right, "抵达留痕（最近 8）", StickKit.LabelKind.SECTION)
	_history_box = VBoxContainer.new()
	_history_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_box.add_theme_constant_override("separation", 2)
	right.add_child(_history_box)
	# ── 底部纪律提示 ──
	StickKit.label(_body, "「命令停驻」= 中间层指挥官空缺，命令不续传（空缺期下令由下令方重发）",
			StickKit.LabelKind.TINY)


## 工具条：标题 + 连线/流光图例 + 缩放滑杆 + 重新布局
func _build_toolbar() -> void:
	var bar := StickKit.row(_body, 8)
	StickKit.label(bar, "指挥链沙盘", StickKit.LabelKind.SECTION)
	var hint := StickKit.label(bar, "连线 = 指挥关系；流光 = 在途命令（每跳标 eta 实时秒数）",
			StickKit.LabelKind.HINT)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	StickKit.label(bar, "缩放", StickKit.LabelKind.TINY)
	_zoom_slider = SketchHSlider.new()
	_zoom_slider.custom_minimum_size = Vector2(180, StickTokens.BTN_H_SM)
	_zoom_slider.min_value = BoardScript.ZOOM_MIN
	_zoom_slider.max_value = BoardScript.ZOOM_MAX
	_zoom_slider.step = CommandChainBoard.ZOOM_STEP
	_zoom_slider.value = 1.0
	_zoom_slider.value_changed.connect(_on_zoom_changed)
	bar.add_child(_zoom_slider)
	_zoom_label = StickKit.label(bar, "100%", StickKit.LabelKind.TINY)
	_zoom_label.custom_minimum_size = Vector2(42, 0)
	var relayout := StickKit.sketch_button(bar, "重新布局", _on_relayout_pressed,
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	relayout.tooltip_text = "按当前组织树重排兵棋沙盘"


## 号令条：选中兵牌后对该层子树下令（§3.2.B 核心操作）。
## 无 TacticalOrders（无战斗侧）时整条降级禁用；需目标点的号令在目标不可解时禁用。
func _build_order_bar() -> void:
	var bar := StickKit.row(_body, 6)
	StickKit.label(bar, "下令", StickKit.LabelKind.SECTION)
	_target_label = StickKit.label(bar, "下令目标 —（点选兵牌）", StickKit.LabelKind.HINT)
	_target_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for entry in ORDER_BUTTONS:
		var otype := int(entry[0])
		var btn := StickKit.sketch_button(bar, String(entry[1]),
				_on_order_pressed.bind(otype), StickKit.ButtonKind.ACCENT, StickTokens.BTN_H_SM)
		btn.disabled = true
		_order_buttons[otype] = btn
	if _tactical == null:
		for otype in _order_buttons:
			(_order_buttons[otype] as Button).tooltip_text = "战斗侧未装配：指挥链号令不可用（该层子树无需小队）"
	else:
		for entry in ORDER_BUTTONS:
			var otype2 := int(entry[0])
			(_order_buttons[otype2] as Button).tooltip_text = \
					"对选中兵牌所在层及其整棵子树下达「%s」号令（逐层接力，语义同组织面板）" \
					% String(entry[1])


func _connect_signals() -> void:
	if EventBus != null:
		if EventBus.has_signal("relay_started") and not EventBus.relay_started.is_connected(_on_relay_started):
			EventBus.relay_started.connect(_on_relay_started)
		if EventBus.has_signal("relay_arrived") and not EventBus.relay_arrived.is_connected(_on_relay_arrived):
			EventBus.relay_arrived.connect(_on_relay_arrived)
	if _org_api != null:
		for sig in ["org_created", "org_restructured", "org_disbanded"]:
			if _org_api.has_signal(sig) and not _org_api.is_connected(sig, _on_orgs_changed):
				_org_api.connect(sig, _on_orgs_changed)


func _refresh_all() -> void:
	_rebuild_tree()
	_refresh_inflight()
	_refresh_history()


## 组织树变动（建树/重组/解散）→ 沙盘重排（在途流光随之复位）
func _on_orgs_changed(_org_id: String = "") -> void:
	_rebuild_tree()


# ─────────────────────────────── 打开/关闭 ────────────────────────────────

func open() -> void:
	_refresh_all()
	super.open()


# ─────────────────────────────── 接力信号消费（EventBus 镜像）────────────────────────────────

func _on_relay_started(relay_id: String, order_type: int, from_org: String, to_org: String,
		hop_index: int, eta: float) -> void:
	if _board != null and _board.has_method("notify_relay_started"):
		_board.notify_relay_started(relay_id, order_type, from_org, to_org, hop_index, eta)
	_refresh_inflight()


func _on_relay_arrived(relay_id: String, order_type: int, from_org: String, to_org: String,
		hop_index: int, outcome: String) -> void:
	if _board != null and _board.has_method("notify_relay_arrived"):
		_board.notify_relay_arrived(relay_id, order_type, from_org, to_org, hop_index, outcome)
	_refresh_inflight()
	_refresh_history()


func _on_relayout_pressed() -> void:
	_rebuild_tree()


# ─────────────────────────────── 沙盘 ────────────────────────────────

func _rebuild_tree() -> void:
	if _board != null and _board.has_method("build_tree"):
		_board.build_tree(_org_api)
	# 重建即清选中（board._clear_scene），下令条同步回占位/禁用
	_refresh_order_bar(get_selected_org())


# ─────────────────────────────── 缩放 / 节点下令（UI-W4a）────────────────────────────────

func _on_zoom_changed(value: float) -> void:
	if _board != null and _board.has_method("set_zoom"):
		_board.set_zoom(value)
	if _zoom_label != null:
		_zoom_label.text = "%d%%" % int(round(value * 100.0))


## 兵牌选中 → 刷新下令条（目标文案 + 按钮可用性）；无选中即回占位
func _on_node_selected(org_id: String) -> void:
	_refresh_order_bar(org_id)


## 程序化选中（测试/外部跳转；校验交给 board）
func select_node(org_id: String) -> void:
	if _board != null and _board.has_method("select_node"):
		_board.select_node(org_id)


func get_selected_org() -> String:
	if _board != null and _board.has_method("get_selected_id"):
		return String(_board.get_selected_id())
	return ""


func get_order_target_label() -> String:
	return _target_label.text if _target_label != null else ""


## 当前可用号令类型集（下令条按钮启用口径；测试断言）
func get_available_orders() -> Array:
	var out: Array = []
	for otype in _order_buttons:
		if not (_order_buttons[otype] as Button).disabled:
			out.append(int(otype))
	return out


## 对选中层下令（按钮回调与测试共用入口）。返回是否受理。
## target_pos 仅推进/集结类消费；无目标点时该按钮已禁用，此处再兜底一次。
func issue_order_to_selected(order_type: int) -> bool:
	if not _has_board_selection():
		_push_toast("请先在沙盘点选一个指挥节点")
		return false
	var org_id := get_selected_org()
	if org_id.is_empty():
		_push_toast("「玩家·下令方」是链路起点不是组织层，请选一个组织兵牌")
		return false
	if _tactical == null or not _tactical.has_method("issue_to_org"):
		_push_toast("战斗侧未装配，无法下达指挥链号令")
		return false
	var target: Variant = _order_target(org_id, order_type)
	if target == null:
		_push_toast("目标点不可解（该层暂无场上单位），无法下达「%s」"
				% String(ORDER_NAMES.get(order_type, "号令")))
		return false
	var ok: bool = bool(_tactical.issue_to_org(org_id, order_type, target))
	if ok:
		_push_toast("已对 %s 下令：%s" % [_selected_org_label(), String(ORDER_NAMES.get(order_type, "号令"))])
	return ok


func _on_order_pressed(order_type: int) -> void:
	issue_order_to_selected(order_type)


## 下令条刷新：目标文案 + 「需目标点且目标不可解」的按钮禁用
func _refresh_order_bar(org_id: String) -> void:
	var selected: bool = _has_board_selection()
	if _target_label != null:
		if not selected:
			_target_label.text = "下令目标 —（点选兵牌）"
		elif org_id.is_empty():
			_target_label.text = "下令目标 玩家·下令方（链路起点，不可下令）"
		else:
			_target_label.text = "下令目标 %s（对该层子树下令）" % _selected_org_label()
	var has_tactical: bool = _tactical != null and _tactical.has_method("issue_to_org")
	for entry in ORDER_BUTTONS:
		var otype := int(entry[0])
		var btn: Button = _order_buttons.get(otype)
		if btn == null:
			continue
		if not has_tactical or not selected or org_id.is_empty():
			btn.disabled = true
			continue
		var needs_target := bool(entry[2])
		btn.disabled = needs_target and _order_target(org_id, otype) == null


## 选中层显示名（玩家源节点 = 下令方；查询不到退回 id）
func _selected_org_label() -> String:
	var org_id := get_selected_org()
	if org_id.is_empty():
		return "玩家·下令方"
	var r: Dictionary = _org_api.get_organization(org_id) if _org_api != null \
			and _org_api.has_method("get_organization") else {}
	if r.get("ok", false):
		return "%s · L%d" % [String((r.get("data", {}) as Dictionary).get("name", org_id)),
				int((r.get("data", {}) as Dictionary).get("tier", 0))]
	return org_id


## 沙盘是否有选中（board 侧区分「选中玩家源节点」与「未选中」）
func _has_board_selection() -> bool:
	return _board != null and _board.has_method("has_selection") and bool(_board.has_selection())


## 号令目标点（号令类型相关；不可解返回 null = 该按钮禁用）：
##   坚守类不吃目标点 → Vector2.ZERO 恒可解；
##   推进/冲刺 → 目标层子树质心 + 前推偏移；集结 → 子树质心本身；
##   玩家有框选单位时优先用框选质心（RTS 惯例：玩家标记即意图）。
func _order_target(org_id: String, order_type: int) -> Variant:
	if order_type == 2:  # HOLD_POSITION：行为 idle，无目标点
		return Vector2.ZERO
	var base: Variant = _selection_centroid()
	if base == null:
		base = _subtree_centroid(org_id)
	if base == null:
		return null
	var p: Vector2 = base
	if order_type == 0 or order_type == 1:  # ADVANCE_ALL / SPRINT
		return p + Vector2(FORWARD_OFFSET_X, 0.0)
	return p


## 玩家框选单位质心（无框选/SelectionSystem 缺失返回 null）
func _selection_centroid() -> Variant:
	if _game_root == null or not _game_root.has_method("get_selection_system"):
		return null
	var sel: Node = _game_root.get_selection_system()
	if sel == null or not sel.has_method("get_selected_units"):
		return null
	return _centroid_of(sel.get_selected_units())


## 目标层子树质心：沿组织树收集 L1 小队 → 经编队系统取成员位置（查询缺口返回 null）
func _subtree_centroid(org_id: String) -> Variant:
	return _centroid_of(_subtree_units(org_id))


## 子树内全部存活单位（L1 叶经 FormationSystem 取成员；无编队/无组织即空）
func _subtree_units(org_id: String) -> Array:
	var out: Array = []
	if _game_root == null or not _game_root.has_method("get_formation_system"):
		return out
	var fs: Node = _game_root.get_formation_system()
	if fs == null or not fs.has_method("get_squad_units"):
		return out
	for sid in _subtree_squad_ids(org_id):
		for u in fs.get_squad_units(sid):
			if u != null and is_instance_valid(u) and not _is_dead(u):
				out.append(u)
	return out


## 子树内 L1 小队 id 集（org_id 本身即 L1 时含自身；组织查询缺口返回空）
func _subtree_squad_ids(org_id: String) -> Array:
	var out: Array = []
	if _org_api == null or not _org_api.has_method("get_organization"):
		return out
	var stack: Array = [org_id]
	var guard: int = 0
	while not stack.is_empty() and guard < 256:
		guard += 1
		var cid := String(stack.pop_back())
		if cid.is_empty():
			continue
		var r: Dictionary = _org_api.get_organization(cid)
		if not r.get("ok", false):
			continue
		var d: Dictionary = r.get("data", {})
		var kids: Array = d.get("child_orgs", [])
		if kids.is_empty():
			out.append(cid)  # 叶 = L1 小队
			continue
		for c in kids:
			stack.append(String(c))
	return out


func _centroid_of(units: Array) -> Variant:
	var sum := Vector2.ZERO
	var n := 0
	for u in units:
		if u is Node2D and is_instance_valid(u):
			sum += (u as Node2D).global_position
			n += 1
	if n == 0:
		return null
	return sum / float(n)


func _is_dead(u: Node) -> bool:
	return u.has_method("is_dead") and bool(u.is_dead())


func _push_toast(msg: String) -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("指挥链", msg, "info")


# ─────────────────────────────── 清单刷新 ────────────────────────────────

## 在途清单 = command_chain 只读查询（接力信号触发重查；另有 POLL_INTERVAL 低频节拍
## 只为「剩余秒数」走字，见 _process——不属于动画层的逐帧轮询）
func _refresh_inflight() -> void:
	if _inflight_box == null:
		return
	for child in _inflight_box.get_children():
		_inflight_box.remove_child(child)
		child.queue_free()
	var rows: Array = []
	if _chain != null and _chain.has_method("get_relays_in_flight"):
		rows = _chain.get_relays_in_flight()
	if _summary_label != null:
		_summary_label.text = "在途 %d 跳" % rows.size()
	if rows.is_empty():
		StickKit.label(_inflight_box, "当前无在途命令" if _chain != null else "指挥链未装配",
				StickKit.LabelKind.TINY)
		return
	for e in rows:
		var d: Dictionary = e
		var remaining := _remaining_of(d)
		var text := "%s %s  %s → %s · %.1fs" % [
			_short_id(String(d.get("relay_id", ""))),
			String(ORDER_NAMES.get(int(d.get("order_type", -1)), "号令")),
			_org_label(String(d.get("from_org", ""))), _org_label(String(d.get("to_org", ""))),
			remaining]
		var l := StickKit.label(_inflight_box, text, StickKit.LabelKind.TINY, StickTokens.ACCENT)
		l.tooltip_text = "跳序位 %d ｜ eta 传输层真值 %.2fs" % [int(d.get("hop_index", 0)), float(d.get("eta", 0.0))]


## 抵达留痕（最近 8 条；outcome 着色——送达/透传绿、停驻/拒收红）
func _refresh_history() -> void:
	if _history_box == null:
		return
	for child in _history_box.get_children():
		_history_box.remove_child(child)
		child.queue_free()
	var rows: Array = []
	if _chain != null and _chain.has_method("get_relay_history"):
		rows = _chain.get_relay_history(8)
	if rows.is_empty():
		StickKit.label(_history_box, "暂无留痕", StickKit.LabelKind.TINY)
		return
	for e in rows:
		var d: Dictionary = e
		var outcome := String(d.get("outcome", d.get("state", "")))
		var text := "%s %s → %s · %s" % [
			_short_id(String(d.get("relay_id", ""))),
			_org_label(String(d.get("from_org", ""))), _org_label(String(d.get("to_org", ""))),
			String(CommandChainBoard.OUTCOME_ZH.get(outcome, outcome))]
		StickKit.label(_history_box, text, StickKit.LabelKind.TINY, _outcome_color(outcome))


## 剩余秒数（在途登记带 started_at_ms；无则退回 eta 本值）
func _remaining_of(e: Dictionary) -> float:
	var eta := float(e.get("eta", 0.0))
	if e.has("started_at_ms"):
		var elapsed := (Time.get_ticks_msec() - int(e["started_at_ms"])) / 1000.0
		return maxf(0.0, eta - elapsed)
	return eta


func _short_id(relay_id: String) -> String:
	return relay_id.replace("relay_", "#") if not relay_id.is_empty() else "#?"


func _outcome_color(outcome: String) -> Color:
	match outcome:
		"delivered", "relayed":
			return StickTokens.SUCCESS
		"dropped_leaderless", "dropped_invalid", "dropped_no_squad", "dropped_no_formation":
			return StickTokens.DANGER
		"rejected_noncombat":
			return StickTokens.WARN
		_:
			return StickTokens.TEXT_DIM


## 组织名（空 id = 玩家源；查询不到退回 id 本身）
func _org_label(org_id: String) -> String:
	if org_id.is_empty():
		return "玩家"
	if _org_api != null and _org_api.has_method("get_organization"):
		var r: Dictionary = _org_api.get_organization(org_id)
		if r.get("ok", false):
			var n := String((r.get("data", {}) as Dictionary).get("name", ""))
			if not n.is_empty():
				return n
	return org_id
