extends Node
## 主街城门选项框 —— 玩家走近 ±城门触发线时弹在头顶的按钮组（2D 村图同款
## "靠近城门蹦出弹窗"口径，创始人 2026-09-15：城墙即传送门指的是弹窗确认，
## 不是静默瞬移）。选项：出城（跨墙传送到墙外野地）/ 收起。
## UI 挂 UIRoot HudOverlay 槽（AGENTS 核心指令 5），每帧跟随玩家屏幕坐标；
## 村民不经过本组件——采集 AI 走静默传送带（gate_router 协议）。

## 触发语义：玩家进入墙内 ~120px 触发带弹出；退回 120px 以上收起（滞回防抖）。

var _map: Node2D = null
var _panel: Control = null
var _shown_side: int = 0        # 当前弹出侧（-1 西 / +1 东 / 0 无）
var _suppress_side: int = 0     # 收起后抑制同侧再弹（直到退出触发带）

## 触发带（px）：墙内沿往城内 24~132
const TRIGGER_NEAR := 24.0
const TRIGGER_FAR := 132.0
const HYSTERESIS := 120.0


func setup(map: Node2D) -> void:
	_map = map


func _process(_delta: float) -> void:
	if _map == null or not is_instance_valid(_map):
		return
	var player: Node2D = _find_player()
	if player == null:
		_hide_panel()
		return
	var side := _side_at(player.global_position)
	if side != 0:
		if side != _shown_side and side != _suppress_side:
			_show(player, side)
		elif _panel != null and _shown_side == side:
			_follow(player)
	elif _shown_side != 0:
		# 退出触发带：收起并允许下次再弹
		_suppress_side = 0
		_hide_panel()


## 玩家在哪侧城门触发带内（0 = 都不在）
func _side_at(pos: Vector2) -> int:
	var wall_px: float = _wall_px()
	if wall_px <= 0.0:
		return 0
	var ax: float = absf(pos.x)
	# 已越过墙线（理论上传送即刻发生，不会停留）不算
	if ax < wall_px - TRIGGER_FAR or ax > wall_px - TRIGGER_NEAR:
		return 0
	return -1 if pos.x < 0.0 else 1


func _wall_px() -> float:
	if _map.has_method("get_wall_px"):
		return float(_map.get_wall_px())
	return 0.0


func _find_player() -> Node2D:
	var host: Node2D = _map.get_node_or_null("EntityHost") as Node2D
	if host == null:
		return null
	for u in host.get_children():
		if is_instance_valid(u) and u.has_method("is_possessed") and u.is_possessed():
			return u
	return null


func _show(player: Node2D, side: int) -> void:
	_shown_side = side
	if _panel != null:
		_panel.visible = true
		_follow(player)
		return
	var ui_root: CanvasLayer = _find_ui_root()
	if ui_root == null:
		return
	_panel = _build_panel(side)
	ui_root.add_to_slot("HudOverlay", _panel)
	_follow(player)


## 沿场景树找 UIRoot（CanvasLayer）
func _find_ui_root() -> CanvasLayer:
	var n: Node = get_tree().root
	if n is CanvasLayer and n.name == "UIRoot":
		return n
	var found := n.find_children("UIRoot", "CanvasLayer", true, false)
	if not found.is_empty():
		return found[0] as CanvasLayer
	return null


func _hide_panel() -> void:
	_shown_side = 0
	if _panel != null and is_instance_valid(_panel):
		_panel.visible = false


## 选项框跟随玩家头顶（世界 → 屏幕坐标）
func _follow(player: Node2D) -> void:
	var ui_root: CanvasLayer = _find_ui_root()
	if ui_root == null:
		return
	var screen_pos: Vector2 = ui_root.get_viewport().get_canvas_transform() * player.global_position
	_panel.position = screen_pos - Vector2(_panel.size.x * 0.5, 130.0)


func _build_panel(side: int) -> Control:
	var box := PanelContainer.new()
	box.name = "Hd2dGatePromptBox"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.09, 0.07, 0.92)
	style.border_color = Color(0.85, 0.82, 0.75, 0.8)
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	box.add_theme_stylebox_override("panel", style)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	box.add_child(col)
	var title := Label.new()
	title.text = "西城门" if side < 0 else "东城门"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85))
	col.add_child(title)
	for entry: Dictionary in [
		{"text": "出城（传送到墙外野地）", "act": "out"},
		{"text": "收起", "act": "dismiss"},
	]:
		var btn := Button.new()
		btn.text = str(entry["text"])
		btn.pressed.connect(_on_choice.bind(str(entry["act"])))
		col.add_child(btn)
	return box


func _on_choice(act: String) -> void:
	match act:
		"out":
			var player: Node2D = _find_player()
			if player != null and _map.has_method("gate_teleport_player"):
				_map.gate_teleport_player(player)
			_hide_panel()
		"dismiss":
			# 收起：抑制同侧再弹，直到玩家退出触发带
			_suppress_side = _shown_side
			_hide_panel()


func _exit_tree() -> void:
	_shown_side = 0
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
