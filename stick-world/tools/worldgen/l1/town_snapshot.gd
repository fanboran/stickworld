extends Node
## 开发期验收工具：L1 八城截图（全景 + 城门近景 + 地面特写），供视觉验收（城镇生成管线批次 2/3/4 复用）。
##
## 用法（会弹一个游戏窗口约 3 分钟，跑完自动退出）：
##   godot --path stick-world res://tools/worldgen/l1/town_snapshot.tscn
## 输出：<仓库>/.../.tmp_shots/<map_id>_pan.png（全景布局）、<map_id>_gate.png（城门近景）、
##       <map_id>_ground.png（地面分带/装饰特写）
##
## 走真实加载链路（game_root + SceneLoader + 初始建筑 spawn），所见即玩家进城所见。
## 去干扰：全领地预置已臣服（据点城不刷守军不开战）+ 截图帧隐藏全部 CanvasLayer
## （去 HUD/新手引导弹窗）。相机自管（make_current 覆盖游戏相机），并让 SkyDecor
## 视差层跟随截图相机（否则背景带只盖游戏相机附近，全景里出现山体硬切边假象）。

const MAP_IDS := [
	"l1_settlement_00", "l1_settlement_01", "l1_settlement_02", "l1_settlement_03",
	"l1_settlement_04", "l1_settlement_05", "l1_settlement_06", "l1_settlement_07",
]
## 近景缩放：1280 宽视野下约 2100px 世界宽，能看清城门两侧地标形态
const GATE_ZOOM := 0.6
## 地面特写缩放：约 1160px 世界宽，可辨分带边界/石板/路灯绿植杂物
const GROUND_ZOOM := 1.1
## tone → 截图时刻（时）。天空/昼夜是全局时间系统（EnvironmentSystem 驱动、不逐城锁），
## 验收画面按每城 tone 对齐时刻=该城氛围的真实表达；截图窗口内暂停时钟防漂移。
const TONE_HOUR := {"dawn": 6.0, "noon": 12.0, "gold": 16.5, "dusk": 19.0, "overcast": 12.0}
## tone 配置来源（生成器配置层，仓库级文件不在 res:// 内）
const PROFILES_PATH := "res://../tools/worldgen/l1/city_profiles.json"

var _game_root: Node = null
var _env: Node = null
var _tones: Dictionary = {}


func _ready() -> void:
	get_window().size = Vector2i(1280, 720)  # 降渲染负担（核显弹窗模式帧率低）
	_load_tones()
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
	TimeManager.resume()  # 解除上一城截图窗口的时钟暂停（含中途失败的兜底）
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
	_align_clock(mid)  # 按城 tone 对齐游戏时刻并暂停时钟（截图窗口防漂移）
	var width: float = map.map_right - map.map_left
	var vp := get_viewport().get_visible_rect().size
	var cam := Camera2D.new()
	add_child(cam)
	cam.make_current()
	# SkyDecor 默认追 GameRoot.CameraRig；改跟截图相机，背景带才铺满全景画幅
	var sky: Node = map.get_node_or_null("SkyDecor")
	if sky != null and sky.has_method("set_camera_override"):
		sky.set_camera_override(cam)
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
	# 地面特写：看分带边界/石板广场/路灯绿植杂物落位
	cam.zoom = Vector2(GROUND_ZOOM, GROUND_ZOOM)
	cam.position = Vector2(_ground_focus_x(map, gate_x), 940)
	await RenderingServer.frame_post_draw
	await _snap(out_dir.path_join(mid + "_ground.png"))
	cam.queue_free()
	await get_tree().process_frame
	return 0


## 读生成器配置层拿每城 tone（缺失城按 noon）
func _load_tones() -> void:
	var f := FileAccess.open(PROFILES_PATH, FileAccess.READ)
	if f == null:
		push_warning("[town_snapshot] 读不到 profiles，全部按 noon 拍")
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary and data.get("cities") is Dictionary:
		for mid in MAP_IDS:
			var c: Dictionary = data["cities"].get(mid, {})
			_tones[mid] = String(c.get("tone", "noon"))


## 对齐游戏时刻并暂停时钟：天空色/光照/极光都由 EnvironmentSystem 按 time_of_day 驱动
func _align_clock(mid: String) -> void:
	if _env == null or not is_instance_valid(_env):
		_env = _find_env(get_tree().root)
	if _env == null:
		push_warning("[town_snapshot] 找不到 EnvironmentSystem，按当前时刻拍")
		return
	_env.call("set_time_of_day", float(TONE_HOUR.get(_tones.get(mid, "noon"), 12.0)))
	TimeManager.pause()
	for i in 3:
		await get_tree().process_frame  # CanvasModulate/天空色刷新一拍


func _find_env(node: Node) -> Node:
	if node.has_method("set_time_of_day") and node.has_method("get_time_of_day"):
		return node
	for c in node.get_children():
		var found := _find_env(c)
		if found != null:
			return found
	return null


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


## 地面特写落点：优先市场广场（placeholder 宽幅地标），退而求其次仓库，最后城门
func _ground_focus_x(map: Node2D, gate_x: float) -> float:
	var ibl: Node = map.get_node_or_null("InitialBuildingsList")
	if ibl == null:
		return gate_x
	var warehouse_x := -1.0
	for d in ibl.building_defs:
		var def := String(d.get("def_id", ""))
		var w := int(d.get("width", 0))
		if def == "placeholder" and w >= 8:  # 市场地标（民居宽 4、铁匠铺区宽 6）
			return float(d.get("cell_x", -1)) * 32.0
		if def == "warehouse":
			warehouse_x = float(d.get("cell_x", -1)) * 32.0
	if warehouse_x > 0.0:
		return warehouse_x
	return gate_x
