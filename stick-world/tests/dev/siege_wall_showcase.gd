extends Node2D
## 城墙双形态观察场（dev）——并排摆 TOWN / FIELD 两形态 + 模拟地面带，
## 打开即看：城内 8 格矮门段 vs 战场垂直巨墙（垛口线=地平线上 5 格）。
## 用法：godot --path stick-world res://tests/dev/siege_wall_showcase.tscn

const SiegeWallScript := preload("res://modules/world/scripts/map/siege_wall.gd")


func _ready() -> void:
	# 左：模拟城内地面带（810..1080，占屏 1/3 的家）
	_draw_ground_band(Rect2(-900, 810, 1800, 270), Color(0.45, 0.55, 0.32))
	var town: SiegeWall = SiegeWallScript.new()
	town.form = SiegeWall.Form.TOWN
	town.position = Vector2(-450, 650.0)
	town.top_y = 650.0
	town.foot_y = 1040.0
	add_child(town)
	# 右：模拟战场地面带（432..1674，垂直范围高）
	_draw_ground_band(Rect2(200, 432, 1800, 1242), Color(0.38, 0.45, 0.28))
	var field: SiegeWall = SiegeWallScript.new()
	field.form = SiegeWall.Form.FIELD
	field.position = Vector2(700, 272.0)
	field.top_y = 272.0
	field.foot_y = 1674.0
	add_child(field)
	# 地平线参考线
	_queue_redraw()
	# --shot=<path>：截图退出（验证用）
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--shot="):
			await _shot(str(a).trim_prefix("--shot="))


func _shot(path: String) -> void:
	await get_tree().create_timer(0.5).timeout
	# 相机看两墙之间
	var cam := Camera2D.new()
	cam.position = Vector2(120.0, 950.0)
	cam.zoom = Vector2(0.85, 0.85)
	add_child(cam)
	cam.make_current()
	await get_tree().create_timer(0.3).timeout
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("[SHOWCASE] saved: ", path)
	get_tree().quit(0)


func _draw_ground_band(rect: Rect2, color: Color) -> void:
	var poly := Polygon2D.new()
	poly.polygon = PackedVector2Array([
		Vector2(rect.position.x, rect.position.y),
		Vector2(rect.position.x + rect.size.x, rect.position.y),
		Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y),
		Vector2(rect.position.x, rect.position.y + rect.size.y),
	])
	poly.color = color
	add_child(poly)


func _queue_redraw() -> void:
	var line := Line2D.new()
	line.points = PackedVector2Array([Vector2(-1000, 810), Vector2(2100, 810)])
	line.width = 2.0
	line.default_color = Color(1, 1, 1, 0.35)
	add_child(line)
