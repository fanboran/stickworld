extends Node
## 主街城门选项框 —— 玩家走近 ±城门触发线时弹在头顶的按钮组（2D 村图同款
## "靠近城门蹦出弹窗"口径，创始人 2026-09-15：城墙即传送门指的是弹窗确认，
## 不是静默瞬移）。选项：本方向出口表全部目的地（西/东郊资源图直达 + 沿村间
## 道路去对岸村庄）/ 收起；弹出时同步在城外上空展开城外舆图
## （hd2d_sky_region_map.gd），悬浮某目的地项 → 舆图对应地块高亮。
## UI 挂 UIRoot HudOverlay 槽（AGENTS 核心指令 5），每帧跟随玩家屏幕坐标；
## 村民不经过本组件——采集 AI 走静默传送带（gate_router 协议）。

## 触发语义：玩家进入墙内 ~120px 触发带弹出；退回 120px 以上收起（滞回防抖）。

const _SkyRegionMapScript := preload("res://modules/world/scripts/map/hd2d_sky_region_map.gd")
const TITLES_PATH := "res://config/scene_map/map_titles.json"

var _map: Node2D = null
var _map_id: String = ""
var _titles_cache: Dictionary = {}
var _panel: Control = null
var _sky_map: Control = null
var _shown_side: int = 0        # 当前弹出侧（-1 西 / +1 东 / 0 无）
var _suppress_side: int = 0     # 收起后抑制同侧再弹（直到退出触发带）

## 触发带（px）：墙内沿往城内 24~132
const TRIGGER_NEAR := 24.0
const TRIGGER_FAR := 132.0
const HYSTERESIS := 120.0

## 舆图锚：对应墙线外 ~11 格（墙外野地上空），随玩家视口投影横向跟随
const SKY_ANCHOR_OFF_PX := 360.0
const SKY_TOP_Y := 108.0


var _root: Node = null   # GameRoot（scene_loader 旅行用，同 SiegeGatePrompt 口径）

func setup(map: Node2D) -> void:
	_map = map
	var n: Node = _map
	while n != null:
		if "scene_loader" in n:
			_root = n
			break
		n = n.get_parent()


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
			_follow_sky()
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
	if _panel == null:
		var ui_root: CanvasLayer = _find_ui_root()
		if ui_root == null:
			return
		_panel = _build_panel(side)
		ui_root.add_to_slot("HudOverlay", _panel)
	else:
		_refresh_panel(side)
	if _panel == null:
		return
	_panel.visible = true
	_show_sky_map()
	_follow(player)
	_follow_sky()


## 同一选项框复用时按当前侧重刷目的地项（西/东出口表不同）
func _refresh_panel(side: int) -> void:
	# 整框重建：项数随侧变化，局部增删比重建更绕
	_panel.queue_free()
	var ui_root: CanvasLayer = _find_ui_root()
	if ui_root == null:
		_panel = null
		return
	_panel = _build_panel(side)
	ui_root.add_to_slot("HudOverlay", _panel)


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
	if _sky_map != null and is_instance_valid(_sky_map):
		_sky_map.visible = false
		_sky_map.set_highlight("")


func _exit_tree() -> void:
	_shown_side = 0
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
	if _sky_map != null and is_instance_valid(_sky_map):
		_sky_map.queue_free()
	_panel = null
	_sky_map = null


# ──────────────────────────── 城外舆图（天空悬浮图）────────────────────────────

## 弹窗时在对应城外上空展开舆图：数据 = 出口表 BFS（直达一程 + 道路对岸）
func _show_sky_map() -> void:
	if _sky_map == null or not is_instance_valid(_sky_map):
		var ui_root: CanvasLayer = _find_ui_root()
		if ui_root == null:
			return
		_sky_map = _SkyRegionMapScript.new()
		_sky_map.name = "Hd2dSkyRegionMap"
		_sky_map.visible = false
		ui_root.add_to_slot("HudOverlay", _sky_map)
	_sky_map.set_region(_build_region())
	_sky_map.set_highlight("")
	_sky_map.visible = true
	_sky_map.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_sky_map, "modulate:a", 1.0, 0.18)


## 锚 = 对应墙线外 SKY_ANCHOR_OFF_PX 的地面点投影 x；纵向钉在天空带上沿
func _follow_sky() -> void:
	if _sky_map == null or not is_instance_valid(_sky_map) or not _sky_map.visible:
		return
	if _shown_side == 0:
		return
	var ui_root: CanvasLayer = _find_ui_root()
	if ui_root == null:
		return
	var anchor := Vector2(signf(_shown_side) * (_wall_px() + SKY_ANCHOR_OFF_PX), 688.0)
	var sx: Vector2 = ui_root.get_viewport().get_canvas_transform() * anchor
	var vp := ui_root.get_viewport().get_visible_rect().size
	var x := clampf(sx.x - _sky_map.size.x * 0.5, 8.0, vp.x - _sky_map.size.x - 8.0)
	_sky_map.position = Vector2(x, SKY_TOP_Y)


## 舆图数据：出口表有向 BFS——当前城直达一程（col ±1）+ 村间道路对岸
## （col ±2，道路本身画成连线不画瓦片）。空出口表（工具裸场景）给空图。
func _build_region() -> Dictionary:
	var region := {"current_id": _map_id, "nodes": [], "links": []}
	var sl: Node = _root.scene_loader if _root != null else null
	if _map_id.is_empty() or sl == null or not sl.has_method("get_map_exits"):
		return region
	var nodes: Array = region["nodes"]
	var links: Array = region["links"]
	var seen := {_map_id: true}
	nodes.append({"id": _map_id, "name": _title_or_id(_map_id), "col": 0, "current": true})
	for dir: int in [WorldAPI.EntrySide.LEFT, WorldAPI.EntrySide.RIGHT]:
		var col := -1 if dir == WorldAPI.EntrySide.LEFT else 1
		for exit_info: Dictionary in sl.get_map_exits(_map_id, dir):
			var target := String(exit_info["target"])
			if seen.has(target):
				continue
			seen[target] = true
			if target.begins_with("road"):
				# 村间道路：不画瓦片，画成当前城→对岸目的地的连线（一方向多路各一条）
				for far: Dictionary in sl.get_map_exits(target, WorldAPI.EntrySide.LEFT):
					_add_far_node(far, target, col, nodes, links, seen)
				for far: Dictionary in sl.get_map_exits(target, WorldAPI.EntrySide.RIGHT):
					_add_far_node(far, target, col, nodes, links, seen)
			else:
				nodes.append({"id": target, "name": _title_or_id(target),
						"col": col, "current": false})
				links.append({"a": _map_id, "b": target, "road": false, "label": ""})
	return region


## 道路对岸节点（跳过接回出发点的路头），label = 道路名
func _add_far_node(far: Dictionary, road_id: String, col: int,
		nodes: Array, links: Array, seen: Dictionary) -> void:
	var fid := String(far["target"])
	if fid == _map_id or seen.has(fid):
		return
	seen[fid] = true
	nodes.append({"id": fid, "name": _title_or_id(fid), "col": col * 2, "current": false})
	links.append({"a": _map_id, "b": fid, "road": true, "label": _title_or_id(road_id)})


## 目的地悬浮 → 舆图对应地块高亮
func _on_dest_hover(map_id: String) -> void:
	if _sky_map != null and is_instance_valid(_sky_map):
		_sky_map.set_highlight(map_id)


# ─────────────────────────────── 选项框 UI ────────────────────────────────

## 选项框跟随玩家头顶（世界 → 屏幕坐标）
func _follow(player: Node2D) -> void:
	var ui_root: CanvasLayer = _find_ui_root()
	if ui_root == null:
		return
	# 地面锚经视觉域协议 remap（HD-2D 图 = 视觉脚线，origin 直绘会浮在角色
	# 上方 (1−k)×纵深处）；上提 130px 是身体纵向偏移，按协议铁律不参与压缩
	var anchor: Vector2 = player.global_position
	var remapper: Node = get_tree().get_first_node_in_group("fx_pos_remapper")
	if remapper != null and remapper.has_method("remap_fx_pos"):
		anchor = remapper.remap_fx_pos(anchor)
	var screen_pos: Vector2 = ui_root.get_viewport().get_canvas_transform() * anchor
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
	# 动态项：本方向出口表全部目的地（§5.5.5 一方向多条道路可选）——
	# 村间道路项文案写对岸村名（"沿村间道路去 村落B"），悬浮点亮舆图地块
	if _map_id.is_empty():
		_map_id = _owner_map_id()
	var sl: Node = _root.scene_loader if _root != null else null
	if sl != null and sl.has_method("get_map_exits"):
		var side_key := WorldAPI.EntrySide.LEFT if side < 0 else WorldAPI.EntrySide.RIGHT
		for exit_info: Dictionary in sl.get_map_exits(_map_id, side_key):
			var target := String(exit_info["target"])
			var entry := int(exit_info.get("entry", WorldAPI.EntrySide.LEFT))
			var btn := Button.new()
			btn.text = _dest_label(sl, target)
			btn.pressed.connect(_on_choice.bind("travel:%d:%s" % [entry, target]))
			btn.mouse_entered.connect(_on_dest_hover.bind(target))
			btn.mouse_exited.connect(_on_dest_hover.bind(""))
			col.add_child(btn)
	var btn_last := Button.new()
	btn_last.text = "收起"
	btn_last.pressed.connect(_on_choice.bind("dismiss"))
	col.add_child(btn_last)
	return box


## 目的地显示名：地区报幕表（config/scene_map/map_titles.json）优先；
## 道路图查它对侧出口接的村庄——"沿村间道路去 村落B"
func _dest_label(sl: Node, map_id: String) -> String:
	var title := _title_of(map_id)
	if map_id.begins_with("road") and sl.has_method("get_map_exits"):
		for side: int in [WorldAPI.EntrySide.LEFT, WorldAPI.EntrySide.RIGHT]:
			for far: Dictionary in sl.get_map_exits(map_id, side):
				if String(far["target"]) == _map_id:
					continue   # 路的另一头接的是出发点自己，跳过
				var far_title := _title_of(String(far["target"]))
				if not far_title.is_empty():
					return "沿%s去 %s" % [title if not title.is_empty() else "道路", far_title]
	if title.is_empty():
		return "去 %s（传送）" % map_id
	return "去 %s（传送）" % title


## 舆图瓦片名：报幕表 title，未配置回退 map_id
func _title_or_id(map_id: String) -> String:
	var t := _title_of(map_id)
	return t if not t.is_empty() else map_id


## 地区名（map_titles.json title；未配置回退空串）
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
		# "travel:<entry_side>:<map_id>"——入缘侧来自出口表登记
		var spec := act.trim_prefix("travel:").split(":", false, 2)
		if spec.size() == 2:
			_travel(String(spec[1]), int(spec[0]))
		return
	match act:
		"dismiss":
			# 收起：抑制同侧再弹，直到玩家退出触发带
			_suppress_side = _shown_side
			_hide_panel()


func _travel(map_id: String, entry_side: int = WorldAPI.EntrySide.LEFT) -> void:
	_hide_panel()
	if _root == null or _root.scene_loader == null:
		return
	_root.scene_loader.travel_to_map(map_id, WorldAPI.TravelMode.TELEPORT, entry_side)
