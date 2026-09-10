extends Node
## 村庄全景验收渲染（批次 6 初始村美化）：完整加载 GameRoot（village_a +
## TownSiege 城墙 + InitialBuildingsList 初始建筑 + 土路/资源点全链路），
## 截两版验收图：
##   1. 入村视角：玩家出生点一屏（相机实际所见，含天空/地形/硬化土路/引路泥带）
##   2. 全景布局：临时相机拉远，覆盖左右城墙（±1900）看主街整体构图
## 运行（非 headless，需要 GPU 出图；GameRoot 每次启动都是新游戏，无读档污染）：
##   godot --path stick-world res://tools/baking/render_village.tscn
## 输出：user://village_render_entry.png / user://village_render_overview.png
## 注意：--script 模式下全局类名解析不可靠，本脚本经 .tscn 入口正常启动（autoload 在场）。

var _game_root: Node


func _ready() -> void:
	_run()


func _run() -> void:
	var packed: PackedScene = load("res://modules/world/scenes/game_root.tscn")
	if packed == null:
		push_error("[render_village] game_root.tscn 加载失败")
		get_tree().quit(1)
		return
	_game_root = packed.instantiate()
	add_child(_game_root)
	# 等地图加载 + 初始建筑/资源点/NPC 生成 + 加载覆盖层淡出（约 2.5s 余量）
	for i in 150:
		await get_tree().process_frame
	# 推到正午并放慢时钟：启动时是深夜，CanvasModulate 会把地表压成剪影，
	# 观感验收须白天版；_night/sky 过渡 lerp 约 2s，多等几帧收敛
	var env: Node = _game_root.get_node_or_null("EnvironmentSystem")
	if env != null:
		if env.has_method("set_seconds_per_day"):
			env.call("set_seconds_per_day", 100000.0)  # 冻结昼夜推进
		if env.has_method("set_time_of_day"):
			env.call("set_time_of_day", 12.0)
	for i in 150:
		await get_tree().process_frame
	_hide_ui_layers()
	# 截图 1：入村视角（CameraRig 已 snap 到出生点玩家，世界原样）
	for i in 10:
		await get_tree().process_frame
	_save_shot("user://village_render_entry.png")
	# 截图 2：全景布局（临时相机拉远覆盖 ±1900 城墙）
	var cam := Camera2D.new()
	cam.name = "OverviewCam"
	cam.zoom = Vector2(0.5, 0.5)
	cam.position = Vector2(0.0, 640.0)
	add_child(cam)
	cam.make_current()
	for i in 10:
		await get_tree().process_frame
	_save_shot("user://village_render_overview.png", Rect2i(0, 140, 1920, 624))
	print("[render_village] done")
	get_tree().quit(0)


## 隐藏 GameRoot 树内全部 CanvasLayer（UI/调试覆盖层），只留世界画面
func _hide_ui_layers() -> void:
	var stack: Array = [_game_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CanvasLayer:
			(n as CanvasLayer).visible = false
			continue  # CanvasLayer 内部不再有世界画面
		for c in n.get_children():
			stack.append(c)


func _save_shot(out_path: String, crop: Rect2i = Rect2i()) -> void:
	var img := get_viewport().get_texture().get_image()
	if crop.size.x > 0 and crop.size.y > 0:
		img = img.get_region(crop)
	img.save_png(out_path)
	print("[render_village] saved: ", ProjectSettings.globalize_path(out_path))
