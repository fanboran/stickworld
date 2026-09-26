extends Node
## 验证探针：HD-2D 地图建筑宿主装配（ROOT-1）。
##   godot --path stick-world res://tests/dev/verify_hd2d_building_host.tscn
## 流程：GameRoot 完整链启动直连主街 → 断言宿主装配（placement_grid/blocked/
## 基线/BuildMaskLayer）→ construction 直放一栋草棚 → 断言注册/占用/落位带/
## 交互区 → 同址二次放置被拒（占用闭环）→ 截图退出。
## 建造走 spawn_operational_building（不扣资源、不查解锁——不经经济链）。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _fails: int = 0
var _gr: Node = null
var _map: Node2D = null


func _ready() -> void:
	_gr = GameRootScene.instantiate()
	add_child(_gr)
	await _wait(6.0)
	var sl: Node = _gr.get("scene_loader")
	_map = sl.get_current_map() if sl != null and sl.has_method("get_current_map") else null
	_check(_map != null, "主街地图已加载")
	if _map == null:
		_finish()
		return
	_check_hosting()
	await _check_spawn()
	_finish()


## 宿主装配断言：网格存在（duck 属性 + F3 子节点名双契约）、负 cell 覆盖、
## 街景/城墙 blocked、基线推导、建造过程层。
func _check_hosting() -> void:
	var grid: Node = _map.get("placement_grid")
	_check(grid != null, "placement_grid 属性非空（construction duck 契约）")
	_check(_map.get_node_or_null("PlacementGrid") != null,
			"PlacementGrid 子节点存在（F3 调试网格按 WorldAPI 路径定位）")
	if grid == null:
		return
	_check(grid.get_min_cell() < 0, "网格覆盖负 cell（主街以街中心 x=0 对称）")
	# 街景前排带封锁：取首条建筑占位中心 cell
	var rects: Array = _map.get_building_rects() if _map.has_method("get_building_rects") else []
	if not rects.is_empty():
		var mid_c: int = floori((float(rects[0][0]) + float(rects[0][1])) * 0.5)
		_check(grid.is_blocked(mid_c), "街景前排占位条带已封锁（cell %d）" % mid_c)
	else:
		_check(true, "本图无前排占位（封锁为零）")
	# 城墙带封锁（±墙线中心；战场图无墙会得 0 跳过）
	var wall_c: int = int(_map.get_wall_px() / 24.0) if _map.has_method("get_wall_px") else 0
	if wall_c > 1:
		_check(grid.is_blocked(wall_c) and grid.is_blocked(-wall_c),
				"城墙条带已封锁（cell ±%d）" % wall_c)
	_check(_map.get_node_or_null("BuildMaskLayer") != null, "建造过程层 BuildMaskLayer 存在")
	var off: float = float(_map.get("building_baseline_offset"))
	_check(off > 0.0, "建筑落位基线偏移已推导（%.1f，落前排墙脚线 walk_back_y=%.0f）" % [off, 516.0])


## 直放建筑断言：选址 → 注册 → 占用 → 落位带 → 交互区 → 占用闭环。
func _check_spawn() -> void:
	var api: Node = _gr.get_construction_api() if _gr.has_method("get_construction_api") else null
	_check(api != null, "construction api 可用（map_flow 已自动 set_map）")
	if api == null:
		return
	var grid: Node = _map.get("placement_grid")
	if grid == null:
		return
	var wall_c: int = int(_map.get_wall_px() / 24.0) if _map.has_method("get_wall_px") else 90
	# 找空 cell：优先城内（|c| < 墙线-4），找不到放宽墙外野地带；实体挡位
	# （玩家/NPC 站选址带）跳过继续试
	var placed_at: int = -999
	for span: Array in [[wall_c - 4, 4], [grid.get_max_cell() - 8, grid.get_min_cell() + 8]]:
		var c: int = int(span[0])
		while c >= int(span[1]):
			if grid.can_place(c, 2):
				var r: Dictionary = api.spawn_operational_building("placeholder", c, 2)
				if r.get("ok", false):
					placed_at = c
					break
			c -= 1
		if placed_at != -999:
			break
	_check(placed_at != -999, "直放建筑成功（cell %d，草棚 placeholder）" % placed_at)
	if placed_at == -999:
		return
	var host: Node2D = _map.get("building_host")
	_check(host != null and host.get_child_count() >= 1, "建筑实例已挂 BuildingHost")
	var b: Node2D = host.get_child(host.get_child_count() - 1) as Node2D
	_check(b != null and b is Building, "BuildingHost 末子节点为 Building")
	if b == null:
		return
	_check(grid.is_occupied(placed_at), "网格占用已登记（cell %d）" % placed_at)
	_check(absf(b.global_position.x - float(placed_at) * 24.0) < 1.0,
			"落位 x 对齐条带左缘（实得 %.1f，期望 %.1f）" % [b.global_position.x, float(placed_at) * 24.0])
	# 落位脚线（root y + collision_bottom）应与逐格基线一致（HD-2D = 邻居楼卡
	# 墙脚线 530~574 带或楼排中位；旧图 = ground_y+offset）
	var foot: float = b.global_position.y + float(b.call("get_collision_bottom_local"))
	var expect_foot: float = float(_map.call("get_building_baseline_at", placed_at, 2))
	_check(absf(foot - expect_foot) < 1.0,
			"落位脚线与逐格基线一致（实得 %.1f，基线 %.1f，楼排带 530~574）" % [foot, expect_foot])
	_check(b.get_node_or_null("InteractionZone") != null, "InteractionZone 存在（交互链挂点）")
	# 占用闭环：同址再放被拒
	var again: Dictionary = api.spawn_operational_building("placeholder", placed_at, 2)
	_check(not bool(again.get("ok", true)), "同址二次放置被拒（占用生效）")


func _finish() -> void:
	print("[verify_building_host] 断言完成：%d 失败" % _fails)
	await _shot()
	await _wait(0.5)
	get_tree().quit(0 if _fails == 0 else 1)


func _check(cond: bool, what: String) -> void:
	if cond:
		print("[verify_building_host] OK  " + what)
	else:
		_fails += 1
		push_error("[verify_building_host] FAIL  " + what)


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot() -> void:
	# headless 哑渲染不产帧，frame_post_draw 永不触发（实测探针挂死在截图）——跳过
	if DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/proto_hd2d"))
	img.save_png("res://temp/proto_hd2d/verify_hd2d_building_host.png")
	print("[verify_building_host] shot -> temp/proto_hd2d/verify_hd2d_building_host.png")
