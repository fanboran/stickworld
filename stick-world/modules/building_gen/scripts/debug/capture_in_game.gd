extends Node
## 标准运行模式下的自动截图工具
##
## 用法：把本脚本挂到调试场景的任意节点上，用命令行正常运行项目：
##   godot --path <project> --position 10000,10000
## 运行后会等待若干帧确保 Shader 已编译并渲染完成，保存 viewport 截图并退出。

## 截图保存路径（res:// 路径）
@export var output_path: String = "res://modules/building_gen/materials/thatch/reference/thatch_debug_capture.png"

## 要精确截图的节点路径。留空则截取整个 viewport。
## 目前支持 Sprite2D；指定后输出的图片尺寸等于该节点在屏幕上的显示尺寸，避免四周灰边。
@export var target_node_path: NodePath = ""

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

	if not target_node_path.is_empty():
		img = _crop_to_node(img, vp)
		if img == null:
			push_error("[capture_in_game] 按节点裁剪失败")
			get_tree().quit(1)
			return

	var err := img.save_png(output_path)
	if err != OK:
		push_error("[capture_in_game] 保存截图失败: %d" % err)
		get_tree().quit(1)
		return

	print("[capture_in_game] 已保存: %s (%dx%d)" % [output_path, img.get_width(), img.get_height()])
	get_tree().quit(0)


func _crop_to_node(img: Image, vp: Viewport) -> Image:
	var target := get_node_or_null(target_node_path)
	if target == null:
		push_error("[capture_in_game] 找不到目标节点: %s" % target_node_path)
		return null

	var world_pos: Vector2
	var world_size: Vector2

	if target is Sprite2D:
		var sprite := target as Sprite2D
		world_pos = sprite.global_position
		world_size = sprite.texture.get_size() * sprite.scale
	else:
		push_error("[capture_in_game] 不支持的节点类型: %s" % target.get_class())
		return null

	var viewport_size := vp.get_visible_rect().size
	var cam := vp.get_camera_2d()

	var screen_top_left: Vector2
	var screen_size: Vector2

	if cam != null:
		# Camera2D 下：世界坐标 -> 屏幕坐标
		var top_left := world_pos - world_size * 0.5
		screen_top_left = (top_left - cam.global_position) * cam.zoom + viewport_size * 0.5
		screen_size = world_size * cam.zoom
	else:
		screen_top_left = world_pos - world_size * 0.5
		screen_size = world_size

	var rect := Rect2i(
		int(screen_top_left.x),
		int(screen_top_left.y),
		int(screen_size.x),
		int(screen_size.y)
	)

	# 边界保护
	if rect.position.x < 0:
		rect.position.x = 0
	if rect.position.y < 0:
		rect.position.y = 0
	if rect.end.x > img.get_width():
		rect.size.x = img.get_width() - rect.position.x
	if rect.end.y > img.get_height():
		rect.size.y = img.get_height() - rect.position.y

	if rect.size.x <= 0 or rect.size.y <= 0:
		push_error("[capture_in_game] 计算出的截图区域无效: %s" % rect)
		return null

	return img.get_region(rect)
