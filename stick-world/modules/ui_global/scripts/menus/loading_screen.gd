extends Control
## 载入屏 —— 主菜单 → 游戏 的跳板（本屏不再自带视觉）。
##
## 职责：把常驻加载层（WorldLoadingOverlay）挂到**场景树根**——它不随本场景
## 释放，切到 game_root 期间持续在屏；game_root 启动后经 group 认领同一块层，
## 继续驱动分段进度到世界就绪。点「继续游戏」到进世界是**同一块加载屏**，
## 交接零缝隙（旧两屏方案：各自挂场景内，切换时旧的销毁、新的没首帧，必卡缝）。
## 直启 game_root（编辑器 F5/测试）没有跳板，game_root 自建兜底。

const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
const _OverlayScript: GDScript = preload("res://modules/ui_global/scripts/overlays/world_loading_overlay.gd")
## 跳板停留时间（给常驻层首帧渲染 + 提示可读的最低保障）
const LOAD_SECONDS := 0.5


func _ready() -> void:
	_install_root_overlay()
	await get_tree().create_timer(LOAD_SECONDS).timeout
	get_tree().change_scene_to_file(GAME_ROOT_SCENE)


## 挂常驻加载层到场景树根（已存在则复用——回主菜单再进游戏的第二轮）。
## root.add_child 需 deferred：菜单 _ready 处于场景装配期，同步挂会撞
## "Parent is busy setting up children"（SketchTextures.ensure_driver 同坑）。
func _install_root_overlay() -> void:
	var root := get_tree().root
	if root.get_node_or_null("BootLoadingLayer") != null:
		return
	var layer := CanvasLayer.new()
	layer.name = "BootLoadingLayer"
	layer.layer = 100  # 压过一切场景内 UI（含 game_root 的 WorldLoadingLayer）
	root.add_child.call_deferred(layer)
	await get_tree().process_frame
	if not is_instance_valid(layer):
		return
	var ov: Control = _OverlayScript.new()
	ov.name = "WorldLoadingOverlay"
	ov.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(ov)
	if ov.has_method("show_loading"):
		ov.show_loading("正在进入世界…", 0.0)
