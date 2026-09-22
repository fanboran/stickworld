extends Node
## L1 战略图整屏验收捕图器 —— 真实场景（strategic_map.tscn）+ 真实 api 装配，
## 把「邻省政权色暗一阶 + 左右切省箭头 + 水面回贴」放进一张可点开的图里。
##
## 用法（需真实渲染，不能 headless）：
##   godot --path stick-world res://tests/dev/capture_l1_view_ui.tscn
## 产物（gitignored）：stick-world/temp/l1_view_ui/{political_full.png, terrain_full.png,
##                    political_zoom.png, after_switch.png}
##
## 与 capture_l1_map_probe 的分工：那个用裸渲染器做像素级取样（观感收敛过程用），
## 本捕图器跑真实视图链路（箭头 UI / 名牌 / 图例 / 相机都在位），给创始人验收用。

const SM_BASE := "res://config/strategic_map"
const L1_JSON := SM_BASE + "/l1_world.json"
const SCENE: PackedScene = preload("res://modules/world_map/scenes/strategic_map.tscn")
const OUT_DIR := "res://temp/l1_view_ui"
## 邻省切换验收目标（出生省 #69 的左邻，由侧表方位算出；写死仅为产物可复现）
const SWITCH_PROBE := 67

var _scene: Node
var _content: Node
var _api: Node
var _renderer: MapRenderer
var _cam: MapCamera
var _vp_size: Vector2


func _ready() -> void:
	_vp_size = get_viewport().get_visible_rect().size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_scene = SCENE.instantiate()
	add_child(_scene)
	_content = _scene.get_node_or_null("Content")
	_api = _content.get_node_or_null("Api") if _content != null else null
	_renderer = _content.get_node_or_null("MapRenderer") as MapRenderer if _content != null else null
	_cam = _content.get_node_or_null("MapCamera") as MapCamera if _content != null else null
	if _api == null or _renderer == null or _cam == null:
		print("UI_CAPTURE_FAIL 装配缺失")
		get_tree().quit(1)
		return
	_api.initialize(L1_JSON, SM_BASE)
	_content.visible = true
	_content.call("open")
	await _wait_frames(6)

	# 地形模式（对照：邻省地形原样）
	MapModeManager.set_mode(MapModeManager.Mode.TERRAIN)
	await _settle_mode(MapModeManager.Mode.TERRAIN)
	await _capture("terrain_full")

	# 政治模式：邻省政权色暗一阶 + 本省政权色 + 水面回贴 + 左右箭头
	MapModeManager.set_mode(MapModeManager.Mode.POLITICAL)
	await _settle_mode(MapModeManager.Mode.POLITICAL)
	var guard := 0
	while _renderer._water_tex == null and not _renderer._water_failed and guard < 600:
		guard += 1
		await get_tree().process_frame
	print("WATER_RESTORE ready=", _renderer._water_tex != null, " failed=", _renderer._water_failed)
	await _capture("political_full")

	# 放大看三岔口/海岸（同机位判「色块严丝合缝」）
	var data: L1WorldData = _api.get_data()
	var ctx := float(maxi(data.context_size.y, data.size))
	_focus(Vector2(ctx * 0.42, ctx * 0.78), 2.6)
	await _wait_frames(4)
	await _capture("political_zoom")

	# 切省（左箭头同一入口）：整屏复拍，看邻省上下文与名牌/指示器跟随
	_focus(Vector2(ctx, ctx) * 0.5, _vp_size.y * 0.85 / ctx)
	var switched: bool = _content.call("switch_province", SWITCH_PROBE)
	print("SWITCH to #", SWITCH_PROBE, " -> ", switched,
			"  current=", _api.get_current_l1_label())
	await _wait_frames(8)
	await _capture("after_switch")

	print("UI_CAPTURE_DONE")
	get_tree().quit()


## 等模式静态底图就位（渲染器异步线程）
func _settle_mode(mode: int) -> void:
	var guard := 0
	while not _renderer._mode_textures.has(mode) and guard < 900:
		guard += 1
		await get_tree().process_frame
	await _wait_frames(6)


func _focus(center: Vector2, zoom: float) -> void:
	_cam.set_zoom(zoom)
	_cam.set_offset(_vp_size * 0.5 - center * _cam.get_zoom())
	_renderer.queue_redraw()


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _capture(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("%s/%s.png" % [OUT_DIR, shot_name])
	img.save_png(path)
	print("SHOT ", shot_name, " -> ", path)
