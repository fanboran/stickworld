extends Node
## 出城选项框 —— 玩家越过右墙前触发线时弹在玩家头顶的按钮组：
##   ⚔ 征伐 <据点>（动态，expansion api） / 开守城战(Demo) / 出城逛战场 / 去隔壁地区 / 收起
## 选项经 SceneLoader 传送（加载覆盖掩盖城内 1/3 屏地面 ↔ 战场高地面带的比例跳变）；
## 征伐项走 expansion.launch_campaign（状态校验+直达 travel，架构 §三 出征入口）。
## UI 挂 UIRoot HudOverlay 槽（AGENTS 核心指令 5），每帧跟随玩家屏幕坐标。

const SiegeFieldScript := preload("res://modules/world/scripts/map/siege_field.gd")

## 触发线（世界 x；玩家越过弹出，退回 ~120px 收起）
var gate_prompt_x: float = 1600.0

const TITLES_PATH := "res://config/scene_map/map_titles.json"

var _map: Node2D = null
var _map_id: String = ""
var _titles_cache: Dictionary = {}
var _panel: Control = null
var _root: Node = null          # GameRoot（scene_loader）
var _shown: bool = false


func setup(map: Node2D) -> void:
	_map = map
	# GameRoot 沿祖先链找（工具场景实例名不定）
	var n: Node = _map
	while n != null:
		if "scene_loader" in n:
			_root = n
			break
		n = n.get_parent()
	# 守军折损/臣服状态变化（车轮战、占领）→ 面板重建（选项数据 list_targets 现取）
	if EventBus != null and EventBus.has_signal("territory_state_changed"):
		EventBus.territory_state_changed.connect(_on_territory_state_changed)


func _process(_delta: float) -> void:
	var player: Node2D = _find_player()
	if player == null:
		return
	var over_line: bool = player.global_position.x >= gate_prompt_x
	if over_line and not _shown:
		_show(player)
	elif not over_line and player.global_position.x < gate_prompt_x - 120.0 and _shown:
		_hide()
	if _shown and _panel != null:
		_follow(player)


func _find_player() -> Node2D:
	var host: Node2D = _map.get_node_or_null("EntityHost") as Node2D
	if host == null:
		return null
	for u in host.get_children():
		if is_instance_valid(u) and u.has_method("is_possessed") and u.is_possessed():
			return u
	return null


func _show(player: Node2D) -> void:
	_shown = true
	if _panel != null:
		_panel.visible = true
		_follow(player)
		return
	var ui_root: CanvasLayer = _find_ui_root()
	if ui_root == null:
		return
	_panel = _build_panel()
	ui_root.add_to_slot("HudOverlay", _panel)
	_follow(player)


## 沿场景树找 UIRoot（CanvasLayer；工具场景里 GameRoot 实例名不定，不按名字查）
func _find_ui_root() -> CanvasLayer:
	var n: Node = get_tree().root
	if n is CanvasLayer and n.name == "UIRoot":
		return n
	var found := n.find_children("UIRoot", "CanvasLayer", true, false)
	if not found.is_empty():
		return found[0] as CanvasLayer
	return null


func _hide() -> void:
	_shown = false
	if _panel != null:
		_panel.visible = false


## 随所属地图释放时清掉跨图存活的 HUD 面板（切图后不残留选项框）
func _exit_tree() -> void:
	if EventBus != null and EventBus.has_signal("territory_state_changed"):
		EventBus.territory_state_changed.disconnect(_on_territory_state_changed)
	_shown = false
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null


## 守军折损/臣服状态变化 → 弃置面板（可见时立即重建，否则下次触发线 _show 重建）
func _on_territory_state_changed(_territory_id: String, _new_state: int) -> void:
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	_panel = null
	if _shown:
		var player := _find_player()
		if player != null:
			_show(player)


## 选项框跟随玩家头顶（世界 → 屏幕坐标）
func _follow(player: Node2D) -> void:
	var ui_root: CanvasLayer = _find_ui_root()
	if ui_root == null:
		return
	var screen_pos: Vector2 = ui_root.get_viewport().get_canvas_transform() * player.global_position
	_panel.position = screen_pos - Vector2(_panel.size.x * 0.5, 130.0)


func _build_panel() -> Control:
	var box := PanelContainer.new()
	box.name = "GatePromptBox"
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
	title.text = "城门"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.95, 0.92, 0.85))
	col.add_child(title)
	# 固定项：守城 Demo / 出城逛战场（同一张城郊战场图的两种模式）
	for entry: Dictionary in [
		{"text": "⚔ 开守城战（Demo）", "act": "siege"},
		{"text": "出城逛战场", "act": "field"},
	]:
		var btn := Button.new()
		btn.text = entry["text"]
		btn.pressed.connect(_on_choice.bind(entry["act"]))
		col.add_child(btn)
	# 动态项：本方向注册的全部道路出口（一方向多条道路可选，地图与场景图 §5.5.5），
	# 文案写真实目的地村名（道路图追到对侧村庄）
	if _map_id.is_empty():
		_map_id = _owner_map_id()
	var sl: Node = _root.scene_loader if _root != null else null
	if sl != null and sl.has_method("get_map_exits"):
		for exit_info: Dictionary in sl.get_map_exits(_map_id, WorldAPI.EntrySide.RIGHT):
			var btn2 := Button.new()
			btn2.text = _dest_label(sl, String(exit_info["target"]))
			btn2.pressed.connect(_on_choice.bind("travel:" + String(exit_info["target"])))
			col.add_child(btn2)
	# 动态项：可征伐据点（expansion api.list_targets，架构 §三 出征入口）——
	# 「⚔ 征伐 黑石营地（守军 3）」；已臣服项禁用占位（据点已友化，不可再战）
	var expansion: Node = _root.get("_expansion_api") if _root != null else null
	if expansion != null and expansion.has_method("list_targets"):
		for target: Dictionary in expansion.list_targets():
			var tid := String(target.get("id", ""))
			var btn4 := Button.new()
			if bool(target.get("captured", false)):
				btn4.text = "⚔ 征伐 %s（已臣服）" % String(target.get("name_zh", tid))
				btn4.disabled = true
			else:
				btn4.text = "⚔ 征伐 %s（守军 %d）" % [String(target.get("name_zh", tid)),
						int(target.get("garrison_count", 0))]
				btn4.pressed.connect(_on_choice.bind("campaign:" + tid))
			col.add_child(btn4)
	var btn3 := Button.new()
	btn3.text = "收起"
	btn3.pressed.connect(_on_choice.bind("close"))
	col.add_child(btn3)
	return box


## 目的地显示名：地区报幕表（config/scene_map/map_titles.json）优先；
## 道路图查它对侧出口接的村庄——"沿村间道路去 村落B"
func _dest_label(sl: Node, map_id: String) -> String:
	var title := _title_of(map_id)
	# 道路图：目的地是路对面的村庄——文案写村庄名（“沿村间道路去 村落B”）
	if map_id.begins_with("road") and sl.has_method("get_map_exits"):
		for far: Dictionary in sl.get_map_exits(map_id, WorldAPI.EntrySide.LEFT):
			if String(far["target"]) == _map_id:
				continue   # 路的另一头接的是出发点自己，跳过
			var far_title := _title_of(String(far["target"]))
			if not far_title.is_empty():
				return "沿%s去 %s" % [title if not title.is_empty() else "道路", far_title]
		for far: Dictionary in sl.get_map_exits(map_id, WorldAPI.EntrySide.RIGHT):
			if String(far["target"]) == _map_id:
				continue
			var far_title := _title_of(String(far["target"]))
			if not far_title.is_empty():
				return "沿%s去 %s" % [title if not title.is_empty() else "道路", far_title]
	if title.is_empty():
		return "去 " + map_id
	return "去 " + title


## 地区名（map_titles.json title；未配置回退 map_id）
func _title_of(map_id: String) -> String:
	if _titles_cache.is_empty() and ResourceLoader.exists(TITLES_PATH):
		var f := FileAccess.open(TITLES_PATH, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				_titles_cache = parsed
	if _titles_cache.has(map_id) and _titles_cache[map_id] is Dictionary:
		return String(_titles_cache[map_id].get("title", ""))
	return ""


func _owner_map_id() -> String:
	var sl: Node = _root.scene_loader if _root != null else null
	if sl != null and "current_map_id" in sl:
		return String(sl.current_map_id)
	return ""


func _on_choice(act: String) -> void:
	if act.begins_with("travel:"):
		_travel(act.trim_prefix("travel:"))
		return
	if act.begins_with("campaign:"):
		_launch_campaign(act.trim_prefix("campaign:"))
		return
	match act:
		"siege":
			SiegeFieldScript.pending_siege_mode = true
			_travel("siege_battlefield")
		"field":
			SiegeFieldScript.pending_siege_mode = false
			_travel("siege_battlefield")
		"close":
			_hide()


## 征伐：交 expansion 流程编排（状态校验 + 直达 travel，架构 §三；
## 已臣服/装配缺失由 launch_campaign 侧拒绝并告警）
func _launch_campaign(territory_id: String) -> void:
	_hide()
	var expansion: Node = _root.get("_expansion_api") if _root != null else null
	if expansion != null and expansion.has_method("launch_campaign"):
		expansion.launch_campaign(territory_id)


func _travel(map_id: String) -> void:
	_hide()
	if _root == null or _root.scene_loader == null:
		return
	_root.scene_loader.travel_to_map(map_id, WorldAPI.TravelMode.TELEPORT,
			WorldAPI.EntrySide.LEFT)
