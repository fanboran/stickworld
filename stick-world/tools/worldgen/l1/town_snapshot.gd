extends Node
## 开发期验收工具：L1 八城截图（全景 + 城门近景），供视觉验收（城镇生成管线批次 2/3/4 复用）。
##
## 用法（会弹一个游戏窗口约 2 分钟，跑完自动退出）：
##   godot --path stick-world res://tools/worldgen/l1/town_snapshot.tscn
## 输出：<仓库>/.../.tmp_shots/<map_id>_pan.png（全景布局）、<map_id>_gate.png（城门近景）
##
## 走真实加载链路（game_root + SceneLoader + 初始建筑 spawn），所见即玩家进城所见。
## 去干扰：全领地预置已臣服（据点城不刷守军不开战）+ 截图帧隐藏全部 CanvasLayer
## （去 HUD/新手引导弹窗）。相机自管（make_current 覆盖游戏相机）。

const MAP_IDS := [
	"l1_settlement_00", "l1_settlement_01", "l1_settlement_02", "l1_settlement_03",
	"l1_settlement_04", "l1_settlement_05", "l1_settlement_06", "l1_settlement_07",
]
## 近景缩放：1280 宽视野下约 2100px 世界宽，能看清城门两侧地标形态
const GATE_ZOOM := 0.6

var _game_root: Node = null


func _ready() -> void:
	get_window().size = Vector2i(1280, 720)  # 降渲染负担（核显弹窗模式帧率低）
	_game_root = (load("res://modules/world/scenes/game_root.tscn") as PackedScene).instantiate()
	add_child(_game_root)
	for i in 5:
		await get_tree().process_frame
	var out_dir := ProjectSettings.globalize_path("res://").path_join("../.tmp_shots")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var failed := 0
	for mid in MAP_IDS:
		failed += await _shot_map(mid, out_dir)
	print("[town_snapshot] 完成：%d 城，输出 %s（失败 %d）" % [MAP_IDS.size(), out_dir, failed])
	get_tree().quit(1 if failed > 0 else 0)


func _shot_map(mid: String, out_dir: String) -> int:
	_preset_captured()  # game_root 启动链（start_new_run）会清 WorldState.territories，逐城重预置
	var sl: Node = _game_root.get("scene_loader")
	sl.travel_to_map(mid, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
	# 弹窗模式帧率可能低至个位数，按真实秒轮询而非数帧
	var waited := 0.0
	while _game_root.get_current_map() == null and waited < 15.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		push_error("[town_snapshot] 进图失败: " + mid)
		return 1
	await get_tree().create_timer(2.0).timeout  # 建筑实例化/deferred 收尾
	var width: float = map.map_right - map.map_left
	var vp := get_viewport().get_visible_rect().size
	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()
	# 全景：横向塞满视口（空天偏多属预期，看的是布局骨架）
	var z: float = vp.x / maxf(width, 1.0)
	cam.zoom = Vector2(z, z)
	cam.position = Vector2(map.map_left + width * 0.5, 700)
	await RenderingServer.frame_post_draw
	await _snap(out_dir.path_join(mid + "_pan.png"))
	# 城门近景：看地标形态与净空
	var gate_x := _gate_x(map)
	if gate_x > 0.0:
		cam.zoom = Vector2(GATE_ZOOM, GATE_ZOOM)
		cam.position = Vector2(gate_x, 760)
		await RenderingServer.frame_post_draw
		await _snap(out_dir.path_join(mid + "_gate.png"))
	cam.queue_free()
	await get_tree().process_frame
	return 0


## 全领地预置已臣服：进据点城时 ConquestManager 短路不刷守军不开战，画面干净
func _preset_captured() -> void:
	var reg := TerritoryRegistry.new()
	reg.load_config()
	for t in reg.get_all():
		var st: Dictionary = TerritoryRegistry.initial_state()
		st["state"] = TerritoryRegistry.State.CAPTURED
		WorldState.territories[t["id"]] = st


## 截图帧隐藏全部 CanvasLayer（HUD/引导弹窗/小地图不进验收画面）；递归整棵树。
## 藏 UI 发生在上次绘制之后，须再等一帧绘制完成才取图，否则取到带 UI 的旧帧。
func _snap(path: String) -> void:
	var hidden: Array[CanvasLayer] = []
	_collect_layers(get_tree().root, hidden)
	for l in hidden:
		l.visible = false
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[town_snapshot] ", path)
	for l in hidden:
		l.visible = true


func _collect_layers(node: Node, out: Array[CanvasLayer]) -> void:
	if node is CanvasLayer and node.visible:
		out.append(node)
	for c in node.get_children():
		_collect_layers(c, out)


func _gate_x(map: Node2D) -> float:
	var ibl: Node = map.get_node_or_null("InitialBuildingsList")
	if ibl == null:
		return -1.0
	for d in ibl.building_defs:
		if String(d.get("def_id", "")) == "wall_gate":
			return float(d.get("cell_x", -1)) * 32.0
	return -1.0
