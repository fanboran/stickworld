extends Node
## 验证探针：HD-2D 图 F3 覆盖层对齐契约（屏幕映射 §四 的实机断言 + 出图）。
##   godot --path stick-world res://tests/dev/verify_hd2d_f3.tscn
## 流程：GameRoot 完整装配 → 数值断言锚线契约（rig 下边界 = WALK_FRONT_Y）→
## 开 F3 覆盖层（含宽度辅助线抽屉）→ 两档缩放各截一张 → 退出。
## 截图产物：temp/proto_hd2d/f3_hd2d_default.png / f3_hd2d_zoom.png（创始人验收用）。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

const SHOT_DIR := "res://temp/proto_hd2d"

var _fails: int = 0


func _ready() -> void:
	var gr: Node = GameRootScene.instantiate()
	# 直接挂 root（与实机同构）——DebugDrawControl._get_camera 只扫 root 直接
	# 子节点的 CameraRig，嵌套一层会"面板开、线条全无"
	get_tree().root.add_child.call_deferred(gr)
	await _wait(6.0)
	var sl: Node = gr.get("scene_loader")
	var map: Node2D = sl.get_current_map() if sl != null else null
	_check(map != null, "地图实例存在")
	if map == null:
		get_tree().quit(1)
		return
	print("[verify_f3] 地图=%s" % map.name)

	# ── 锚线契约（HD-2D街景系统.md §4.3）：rig 视野下边界必须 = WALK_FRONT_Y ──
	var walk_front: float = float(map.get("WALK_FRONT_Y")) if map.get("WALK_FRONT_Y") != null else 1294.0
	var derived_bottom: float = float(map.ground_y) + 1080.0 * float(map.ground_ratio)
	_check(absf(derived_bottom - walk_front) < 0.5,
			"锚线契约：ground_y+1080×ground_ratio=%.1f ≈ WALK_FRONT_Y=%.1f" % [derived_bottom, walk_front])
	var rig: Camera2D = _find_rig()
	if rig != null:
		var vp_h: float = get_viewport().get_visible_rect().size.y
		var view_bottom: float = rig.global_position.y + vp_h / (2.0 * rig.zoom.x)
		_check(absf(view_bottom - walk_front) < 0.5,
				"rig 实际视野下边界=%.1f ≈ %.1f（差值即 F3/特效整体错位量）" % [view_bottom, walk_front])
		# 默认缩放档（创始人 2026-09-15：0.75）→ 前后景分界线压屏幕下 1/4
		_check(absf(rig.user_zoom - 0.75) < 0.001,
				"默认 user_zoom=0.75（实得 %.2f）" % rig.user_zoom)
		var boundary: float = float(map.get_fg_bg_boundary_y()) if map.has_method("get_fg_bg_boundary_y") else 472.6
		var k: float = float(map.get_ground_squash()) if map.has_method("get_ground_squash") else 0.4384
		var offset_px: float = (walk_front - boundary) * k * rig.zoom.x
		_check(absf(offset_px - vp_h * 0.25) < 3.0,
				"前后景分界线压屏幕下 1/4（offset=%.1fpx，期望 %.1f）" % [offset_px, vp_h * 0.25])
	else:
		_check(false, "找不到 CameraRig")

	# ── remap 语义：锚点恒等、纵深向上压缩 ──
	if map.has_method("remap_fx_pos"):
		var r_front: float = (map.remap_fx_pos(Vector2(0.0, walk_front)) as Vector2).y
		var r_back: float = (map.remap_fx_pos(Vector2(0.0, 688.0)) as Vector2).y
		_check(absf(r_front - walk_front) < 0.01, "remap 锚点恒等（1294 → %.1f）" % r_front)
		_check(r_back > 688.0 and r_back < walk_front,
				"remap 纵深压向前沿（688 → %.1f，越深越贴近锚线）" % r_back)
	else:
		_check(false, "地图缺 remap_fx_pos（HD-2D 契约前提）")

	# ── 宽度辅助线数据口：建筑占地带非空、x 跨度与 y 带合理 ──
	if map.has_method("get_building_rects"):
		var rects: Array = map.get_building_rects()
		_check(rects.size() >= 5, "建筑占地带数据口（实得 %d 栋）" % rects.size())
		if not rects.is_empty():
			var r: Array = rects[0]
			_check(float(r[1]) - float(r[0]) >= 2.0 and float(r[3]) > float(r[2]),
					"占地带有序且格宽合理（样例 %s，x 为格）" % str(r))
			_check(r.size() >= 6 and float(r[5]) > 50.0,
					"占地带含基线+卡可见高（基线 %.0f / 高 %.0f px）" % [float(r[4]), float(r[5])])
		# HD2DSolids 前N形状应带建筑 meta（F3 直立包楼框的跳过标记）
		var solids: Node = map.get_node_or_null("HD2DSolids")
		if solids != null:
			var tagged: int = 0
			for s: Node in solids.get_children():
				if s.has_meta("hd2d_building"):
					tagged += 1
			_check(tagged == rects.size(),
					"建筑碰撞形状 meta 打标（%d/%d）" % [tagged, rects.size()])
	else:
		_check(false, "地图缺 get_building_rects（F3 宽度辅助线数据口）")

	# ── 开 F3 覆盖层 + 两档缩放出图 ──
	if DebugApi != null:
		DebugApi.set_drawer_enabled("grid_drawer", true)
		DebugApi.set_drawer_enabled("building_drawer", true)
		DebugApi.set_drawer_enabled("barrier_drawer", true)
		DebugApi.set_drawer_enabled("ground_line_drawer", true)
		DebugApi.set_drawer_enabled("entity_collider_drawer", true)
		DebugApi.set_drawer_enabled("world_ruler", true)
		DebugApi.set_drawer_enabled("resource_nodes", true)
		DebugApi.set_overlay_visible(true)
	await _wait(1.0)
	await _shot("f3_hd2d_default.png")
	if rig != null and rig.has_method("set_user_zoom"):
		rig.set_user_zoom(1.5)
		await _wait(1.0)
		await _shot("f3_hd2d_zoom.png")

	print("[verify_f3] 断言完成：%d 失败" % _fails)
	print("[verify_f3] DONE")
	await _wait(0.5)
	get_tree().quit(0 if _fails == 0 else 1)


func _find_rig() -> Camera2D:
	# 探针里 GameRoot 挂在本节点下（比实机多一层），按当前相机取最稳
	return get_viewport().get_camera_2d()


func _check(cond: bool, what: String) -> void:
	if cond:
		print("[verify_f3] OK  " + what)
	else:
		_fails += 1
		push_error("[verify_f3] FAIL  " + what)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(fname: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SHOT_DIR))
	img.save_png(SHOT_DIR + "/" + fname)
	print("[verify_f3] shot -> " + SHOT_DIR + "/" + fname)
