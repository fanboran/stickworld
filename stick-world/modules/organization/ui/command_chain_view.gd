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
## 装配：SystemSetup 登记「指挥链视图」项，实例化 command_chain_view.tscn（场景=布局真相源）
## 挂 UIRoot.ModalOverlay 槽；入口在 OrgPanel 顶部「指挥链」按钮（group 查找，不硬编码节点路径）。
## 本批不开任何 .tres 开关、不改配置值。

# ─────────────────────────────── 常量 ────────────────────────────────
## 号令中文名（镜像 TacticalOrders.OrderType：ADVANCE_ALL0 SPRINT1 HOLD2 RETREAT3
## TAKE_COVER4 RALLY5——与 squad_card 同惯例，按战斗域本地常量，不 preload 宿主脚本）
const ORDER_NAMES := {0: "前进", 1: "冲刺", 2: "坚守", 3: "后撤", 4: "找掩体", 5: "集结"}

## 在途清单倒计时刷新节拍（s）：清单成员集仍由接力信号驱动，此处只让「剩余秒数」
## 数字走起来（squad_card/team_ai_hud 缓变值低频节拍同惯例）；动画层本身零轮询。
const POLL_INTERVAL := 0.25

const BoardScript := preload("res://modules/organization/ui/command_chain_board.gd")

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _org_api: Node = null
var _chain: Node = null

# ─────────────────────────────── UI 元素 ────────────────────────────────
var _board: Control = null
var _inflight_box: VBoxContainer = null
var _history_box: VBoxContainer = null
var _summary_label: Label = null
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
	window_size = Vector2(1120, 760)
	window_title = "指挥链"
	behavior = StickWindow.Behavior.FLOATING
	_build_window()
	_connect_signals()
	_refresh_all()


func _ready() -> void:
	super()
	add_to_group("command_chain_view")


## 内容装配（StickWindow 已建无遮罩骨架；内容挂 _body：工具条 + 左沙盘右清单）
func _build_content() -> void:
	# ── 工具条 ──
	var bar := StickKit.row(_body, 8)
	StickKit.label(bar, "指挥链沙盘", StickKit.LabelKind.SECTION)
	var hint := StickKit.label(bar, "连线 = 指挥关系；流光 = 在途命令（每跳标 eta 实时秒数）",
			StickKit.LabelKind.HINT)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var relayout := StickKit.sketch_button(bar, "重新布局", _on_relayout_pressed,
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	relayout.tooltip_text = "按当前组织树重排兵棋沙盘"
	# ── 主区：左沙盘 + 右清单 ──
	var main := HBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(main)
	# 左：兵棋沙盘（自绘连线 + 兵牌子控件；位置由 board 自算，容器只管体量）
	_board = UIKit.widget(BoardScript, "Board")
	_board.custom_minimum_size = Vector2(680, 480)
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(_board)
	# 右：在途清单 + 抵达留痕
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(300, 0)
	right.add_theme_constant_override("separation", 4)
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(right)
	StickKit.label(right, "在途命令", StickKit.LabelKind.SECTION)
	_summary_label = StickKit.label(right, "在途 0 跳", StickKit.LabelKind.HINT)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 190)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	_inflight_box = VBoxContainer.new()
	_inflight_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inflight_box.add_theme_constant_override("separation", 2)
	scroll.add_child(_inflight_box)
	StickKit.label(right, "抵达留痕（最近 8）", StickKit.LabelKind.SECTION)
	_history_box = VBoxContainer.new()
	_history_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_box.add_theme_constant_override("separation", 2)
	right.add_child(_history_box)
	# ── 底部纪律提示 ──
	StickKit.label(_body, "「命令停驻」= 中间层指挥官空缺，命令不续传（空缺期下令由下令方重发）",
			StickKit.LabelKind.TINY)


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
