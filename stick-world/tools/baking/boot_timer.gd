extends Node
## 启动计时：GameRoot 装配到地图就绪各阶段耗时（定位灰屏 20 秒）

const GAME_ROOT_SCENE: PackedScene = preload("res://modules/world/scenes/game_root.tscn")

var _t0: int = 0


func _ready() -> void:
	_t0 = Time.get_ticks_msec()
	# 阶段1：instantiate（场景+依赖资源已由 const preload 加载）
	var game_root: Node = GAME_ROOT_SCENE.instantiate()
	print("[%.2fs] instantiate 完成（未 add_child）" % _sec())
	# 阶段2：add_child（触发 GameRoot._ready + 子模块 _ready 链）
	add_child(game_root)
	print("[%.2fs] add_child 完成（_ready 链结束）" % _sec())
	_start_wait(game_root)


func _start_wait(game_root: Node) -> void:
	var map: Node = null
	for i in 400:  # 最多 20s
		await get_tree().process_frame
		if game_root != null and is_instance_valid(game_root) \
				and game_root.has_method("get_current_map"):
			map = game_root.get_current_map()
			if map != null:
				break
		if i % 200 == 199:
			print("[%.2fs] 等待地图... (i=%d)" % [_sec(), i])
	await get_tree().process_frame
	print("[%.2fs] 地图就绪: %s" % [_sec(), map])
	if map != null:
		var ents: Array = map.get_entities() if map.has_method("get_entities") else []
		print("[%.2fs] 实体数: %d" % [_sec(), ents.size()])
	# 再等实体生成完成
	for i in 300:
		await get_tree().process_frame
		if map != null and is_instance_valid(map) and map.has_method("get_entities") and map.get_entities().size() >= 2:
			break
	print("[%.2fs] 实体 >=2 达成（玩家+NPC）" % _sec())

	# 验证 L3 懒加载装配（M 键首次打开路径）
	var t1 := Time.get_ticks_msec()
	var ss: Node = game_root.get_node_or_null("SystemSetup")
	if ss != null and ss.has_method("_toggle_l3_strategic_map"):
		ss.call("_toggle_l3_strategic_map")
		print("[%.2fs] L3 懒加载装配完成（M 键路径），耗时 %.2fs" % [_sec(), float(Time.get_ticks_msec()-t1)/1000.0])
		var l3: Node = game_root.get("_strategic_map_l3")
		print("[%.2fs] L3 节点: %s" % [_sec(), l3])
		# 关闭（ESC 路径）
		ss.call("_toggle_l3_strategic_map")
		print("[%.2fs] L3 已关闭" % _sec())
	else:
		print("SystemSetup 未找到，跳过 L3 验证")

	print("启动计时完成")
	get_tree().quit(0)


func _sec() -> float:
	return float(Time.get_ticks_msec() - _t0) / 1000.0
