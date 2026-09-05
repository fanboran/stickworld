extends Node
## Demo 视觉快照（dev 层）——带渲染跑游戏并截图，验证后处理 shader 实际渲染。
##
## 用法（不要 --headless，需要真渲染）：
##   godot --path stick-world res://tests/dev/snapshot_demo.tscn -- --out F:/tmp/demo_shot.png
##
## 截两个时刻：T+2s（开局村庄，白天后处理满强度）。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null


func _ready() -> void:
	var out := "res://tests/dev/snapshot_out.png"
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--out="):
			out = str(a).trim_prefix("--out=")
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	await get_tree().create_timer(2.5).timeout
	# 取景诊断（与实际渲染同源）：相机 + 池塘屏幕位置
	var cam: Camera2D = _game_root.get_node_or_null("CameraRig")
	if cam != null:
		print("[SNAP-DIAG] cam center=%s zoom=%s" % [cam.get_screen_center_position(), cam.zoom])
	var map: Node = _game_root.get_current_map()
	var pond: Node2D = map.get_node_or_null("SeaLeft") if map != null else null
	if pond != null:
		var vp := get_viewport()
		var sp: Vector2 = vp.get_canvas_transform() * pond.global_position
		print("[SNAP-DIAG] pond world=%s screen=(%.0f,%.0f) uv_y=%.3f vp=%s" % [
			pond.global_position, sp.x, sp.y, sp.y / vp.get_visible_rect().size.y, vp.get_visible_rect().size])
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("[SNAPSHOT] saved: ", out)
	get_tree().quit(0)
