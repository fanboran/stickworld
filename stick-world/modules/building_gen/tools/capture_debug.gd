extends SceneTree
## 调试场景截图工具（标准运行模式：项目主场景即调试场景）

func _init():
	print("[capture_debug] _init start")
	var root := get_root()

	# 等待场景完全加载并渲染多帧
	for i in range(60):
		await get_tree().process_frame

	print("[capture_debug] waited 60 frames")

	var vp := root.get_viewport() as Viewport
	var tex := vp.get_texture()
	if tex == null:
		push_error("[capture_debug] viewport texture 为 null")
		quit(1)
		return

	var img := tex.get_image()
	if img == null:
		push_error("[capture_debug] 截图失败：img 为 null")
		quit(1)
		return

	# 保存原始分辨率截图
	var path := "res://modules/building_gen/reference/thatch_debug_capture.png"
	var err := img.save_png(path)
	if err != OK:
		push_error("[capture_debug] 保存截图失败: %d" % err)
		quit(1)
		return

	print("[capture_debug] 已保存: %s" % path)
	print("[capture_debug] image size: %dx%d" % [img.get_width(), img.get_height()])
	quit(0)
