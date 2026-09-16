extends Node
## 主街城门选项框 —— 玩家走近 ±城门触发线时弹在头顶的按钮组（2D 村图同款
## "靠近城门蹦出弹窗"口径，创始人 2026-09-15：城墙即传送门指的是弹窗确认，
## 不是静默瞬移）。选项：资源图直达（出口表）+ 附近村庄（战略图出生 L1 直连
## 邻村，暂时直接传送——创始人）/ 收起；弹出时同步在城外上空展开城外舆图
## （hd2d_sky_region_map.gd，Tab 战略图同源数据），悬浮村庄项 → 舆图对应
## 地块高亮。
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


# ──────────────────────────── 战略图 Api 对接（附近村庄）────────────────────────

## 战略图 Api（GameRoot 常驻装配 _strategic_map/Content/Api；未装配/未初始化返回 null）
func _strategic_api() -> Node:
	if _root == null:
		return null
	var sm: Node = _root.get("_strategic_map")
	if sm == null or not is_instance_valid(sm):
		return null
	var content: Node = sm.get_node_or_null("Content")
	var api: Node = content.get_node_or_null("Api") if content != null else null
	if api != null and api.has_method("is_initialized") and api.is_initialized():
		return api
	return null


## 玩家当前锚聚落（api 维护：开局在战略图外场景时保持出生聚落）
func _anchor_settlement_id(api: Node) -> String:
	if api != null and api.has_method("get_player_settlement"):
		var sid := String(api.get_player_settlement())
		if not sid.is_empty():
			return sid
	return ""


## 附近村庄 = 锚聚落的路网直连邻村（TravelPlanner 邻接表），按路程升序。
## 项：{ref: SettlementRef, length: float, open: bool(map_id 已开放)}
func _nearby_villages(api: Node, anchor: String) -> Array:
	var out: Array = []
	if api == null or anchor.is_empty():
		return out
	var planner = api.get_travel_planner() if api.has_method("get_travel_planner") else null   # TravelPlanner(RefCounted)
	if planner == null or not planner.has_method("neighbors"):
		return out
	var nb: Dictionary = planner.neighbors(anchor)
	for sid: String in nb.keys():
		var ref: Resource = api.get_settlement_ref(sid) if api.has_method("get_settlement_ref") else null
		if ref == null:
			continue
		out.append({
			"ref": ref,
			"length": float(nb[sid]),
			"open": not str(ref.get("map_id")).is_empty(),
		})
	out.sort_custom(func(a, b): return float(a["length"]) < float(b["length"]))
	return out


# ──────────────────────────── 城外舆图（天空悬浮图）────────────────────────────

## 弹窗时在对应城外上空展开舆图：数据 = 战略图 Api 的出生 L1 世界（Tab 同源）；
## 数据未就绪（工具裸场景）时藏图只留菜单
func _show_sky_map() -> void:
	var api := _strategic_api()
	if api == null:
		if _sky_map != null and is_instance_valid(_sky_map):
			_sky_map.visible = false
		return
	if _sky_map == null or not is_instance_valid(_sky_map):
		var ui_root: CanvasLayer = _find_ui_root()
		if ui_root == null:
			return
		_sky_map = _SkyRegionMapScript.new()
		_sky_map.name = "Hd2dSkyRegionMap"
		_sky_map.visible = false
		ui_root.add_to_slot("HudOverlay", _sky_map)
	_sky_map.set_data(api.get_data(), _anchor_settlement_id(api))
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


## 目的地悬浮 → 舆图对应地块高亮（村庄传 settlement_id，资源图无舆图地块不亮）
func _on_dest_hover(dest_id: String) -> void:
	if _sky_map != null and is_instance_valid(_sky_map):
		_sky_map.set_highlight(dest_id)


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
	# 动态项：本方向出口表的资源图直达（§5.5.5 一方向多条可选）；道路目标
	# 跳过——「去附近村庄」改走战略图数据（村间道路入口撤下，创始人）
	if _map_id.is_empty():
		_map_id = _owner_map_id()
	var sl: Node = _root.scene_loader if _root != null else null
	if sl != null and sl.has_method("get_map_exits"):
		var side_key := WorldAPI.EntrySide.LEFT if side < 0 else WorldAPI.EntrySide.RIGHT
		for exit_info: Dictionary in sl.get_map_exits(_map_id, side_key):
			var target := String(exit_info["target"])
			if target.begins_with("road"):
				continue
			var entry := int(exit_info.get("entry", WorldAPI.EntrySide.LEFT))
			var btn := Button.new()
			btn.text = "去 %s（传送）" % _title_or_id(target)
			btn.pressed.connect(_on_choice.bind("travel:%d:%s" % [entry, target]))
			col.add_child(btn)
	# 动态项：附近村庄（战略图出生 L1 路网的直连邻村，按路程升序）——
	# 暂时直接传送（创始人）；悬浮项 → 舆图对应地块高亮
	var api := _strategic_api()
	var villages := _nearby_villages(api, _anchor_settlement_id(api))
	if not villages.is_empty():
		var cap := Label.new()
		cap.text = "—— 附近村庄 ——"
		cap.add_theme_font_size_override("font_size", 12)
		cap.add_theme_color_override("font_color", Color(0.75, 0.70, 0.60, 0.9))
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(cap)
	for v: Dictionary in villages:
		var ref: Resource = v["ref"]
		var sid := str(ref.get("settlement_id"))
		var vname := str(ref.get("name"))
		if vname.is_empty():
			vname = sid
		var vbtn := Button.new()
		if bool(v["open"]):
			vbtn.text = "去 %s（传送）" % vname
			vbtn.pressed.connect(_on_choice.bind("village:" + sid))
		else:
			vbtn.text = "去 %s（未开放）" % vname
			vbtn.disabled = true
		vbtn.mouse_entered.connect(_on_dest_hover.bind(sid))
		vbtn.mouse_exited.connect(_on_dest_hover.bind(""))
		col.add_child(vbtn)
	var btn_last := Button.new()
	btn_last.text = "收起"
	btn_last.pressed.connect(_on_choice.bind("dismiss"))
	col.add_child(btn_last)
	return box


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
	if act.begins_with("village:"):
		_enter_village(act.trim_prefix("village:"))
		return
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


## 村庄直达（创始人：暂时直接传送）：走战略图 api.enter_settlement 统一入口
## （发射 travel_requested + 关战略图），TELEPORT 与城门传送同语义
func _enter_village(settlement_id: String) -> void:
	_hide_panel()
	var api := _strategic_api()
	if api != null and api.has_method("enter_settlement"):
		api.enter_settlement(settlement_id, WorldAPI.TravelMode.TELEPORT)
