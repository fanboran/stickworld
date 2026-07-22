extends Node
## 标准运行模式下的自动截图工具
##
## 用法：把本脚本挂到调试场景的任意节点上，用命令行正常运行项目：
##   godot --path <project> --position 10000,10000
## 运行后会等待若干帧确保 Shader 已编译并渲染完成，保存 viewport 截图并退出。

## 截图保存路径（res:// 路径）
@export var output_path: String = "res://modules/building_gen/materials/thatch/reference/thatch_debug_capture.png"

## 启动后等待的帧数，给 Shader 编译和窗口初始化留足时间
@export var settle_frames: int = 5


func _ready() -> void:
	# 让场景先稳定几帧，避免捕获到灰底或 Shader 未编译完成的画面
	for i in range(settle_frames):
		await RenderingServer.frame_post_draw

	var vp := get_viewport()
	if vp == null:
		push_error("[capture_in_game] viewport 为 null")
		get_tree().quit(1)
		return

	var tex := vp.get_texture()
	if tex == null:
		push_error("[capture_in_game] viewport texture 为 null")
		get_tree().quit(1)
		return

	var img := tex.get_image()
	if img == null:
		push_error("[capture_in_game] 截图失败：img 为 null")
		get_tree().quit(1)
		return

	var err := img.save_png(output_path)
	if err != OK:
		push_error("[capture_in_game] 保存截图失败: %d" % err)
		get_tree().quit(1)
		return

	print("[capture_in_game] 已保存: %s (%dx%d)" % [output_path, img.get_width(), img.get_height()])
	get_tree().quit(0)
