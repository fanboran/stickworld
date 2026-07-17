class_name SceneLoader
extends Node
## 场景加载器 -- 地图与 Chunk 流式加载。
##
## 详见 docs/技术/架构/场景与战斗架构.md §三 / §六。
## 阶段 0.8：支持地图间过渡（步行/快速旅行/传送）+ EventBus 信号转发。

# WorldAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 信号 ────────────────────────────────
## 地图加载完成
signal map_loaded(map_id: String, map_type: int)
## 地图卸载完成
signal map_unloaded(map_id: String)
## 旅行开始
signal travel_started(from_id: String, to_id: String, mode: int)
## 旅行完成
signal travel_completed(to_id: String)
## Chunk 加载完成
signal chunk_loaded(chunk_idx: int)
## Chunk 卸载完成
signal chunk_unloaded(chunk_idx: int)

# ─────────────────────────────── 状态 ────────────────────────────────
## 已注册地图：map_id -> {scene, type}
var _registered_maps: Dictionary = {}
## 当前地图 ID
var current_map_id: String = ""
## 当前地图实例
var current_map: Node2D = null
## 当前地图类型
var current_map_type: int = WorldAPI.MapType.VILLAGE

## WorldChunkHost 引用（地图挂载点）
var _chunk_host: Node2D = null

## 地图出口配置：map_id -> {left: {target, entry}, right: {target, entry}}
var _map_exits: Dictionary = {}

## 上次旅行方式（供 GameRoot 查询）
var last_travel_mode: int = WorldAPI.TravelMode.WALK
## 上次进入方向（供 GameRoot 决定玩家 spawn 位置）
var last_entry_side: int = WorldAPI.EntrySide.LEFT


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 延迟一帧获取 GameRoot 下的 WorldChunkHost 引用
	call_deferred("_resolve_chunk_host")
	# 订阅 EventBus 旅行请求（战略图 -> 场景图）
	if EventBus:
		EventBus.travel_requested.connect(_on_travel_requested)


func _resolve_chunk_host() -> void:
	var root := get_parent()
	if root and root.has_node(WorldAPI.PATH_WORLD_CHUNK_HOST):
		_chunk_host = root.get_node(WorldAPI.PATH_WORLD_CHUNK_HOST)


# ─────────────────────────────── 地图注册 ────────────────────────────────

## 注册地图场景
func register_map(map_id: String, packed_scene: PackedScene, map_type: int = WorldAPI.MapType.VILLAGE) -> void:
	if packed_scene == null:
		push_warning("[SceneLoader] 注册空场景: %s" % map_id)
		return
	_registered_maps[map_id] = {
		"scene": packed_scene,
		"type": map_type,
	}


## 是否已注册
func has_map(map_id: String) -> bool:
	return _registered_maps.has(map_id)


## 注册地图出口（步行衔接相邻地图）
## map_id: 当前地图
## exit_side: WorldAPI.EntrySide.LEFT / RIGHT（从当前地图哪侧出去）
## target_map_id: 目标地图 ID
## target_entry_side: 进入目标地图的方向
func register_map_exit(map_id: String, exit_side: int, target_map_id: String, target_entry_side: int) -> void:
	var key := "left" if exit_side == WorldAPI.EntrySide.LEFT else "right"
	if not _map_exits.has(map_id):
		_map_exits[map_id] = {}
	_map_exits[map_id][key] = {
		"target": target_map_id,
		"entry": target_entry_side,
	}


## 查询地图出口
func get_map_exit(map_id: String, exit_side: int) -> Dictionary:
	var key := "left" if exit_side == WorldAPI.EntrySide.LEFT else "right"
	if not _map_exits.has(map_id):
		return {}
	return _map_exits[map_id].get(key, {})


# ─────────────────────────────── 加载/卸载 ────────────────────────────────

## 加载地图。如果当前有地图，先卸载。
## 返回加载的地图实例，失败返回 null。
func load_map(map_id: String) -> Node2D:
	return travel_to_map(map_id, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)


## 旅行到目标地图（统一入口，支持步行/快速旅行/传送）
## map_id: 目标地图 ID
## mode: WorldAPI.TravelMode.WALK / FAST_TRAVEL / TELEPORT
## entry_side: WorldAPI.EntrySide.LEFT / RIGHT（进入新地图的方向）
func travel_to_map(map_id: String, mode: int = WorldAPI.TravelMode.WALK, entry_side: int = WorldAPI.EntrySide.LEFT) -> Node2D:
	if not _registered_maps.has(map_id):
		push_error("[SceneLoader] 未注册的地图: %s" % map_id)
		return null

	if _chunk_host == null:
		_resolve_chunk_host()
	if _chunk_host == null:
		push_error("[SceneLoader] WorldChunkHost 未就绪")
		return null

	var old_id := current_map_id
	last_travel_mode = mode
	last_entry_side = entry_side

	# 旅行开始（本地 + EventBus）
	travel_started.emit(old_id, map_id, mode)
	_emit_event_bus("travel_started", [old_id, map_id, mode])

	# 卸载旧地图
	if current_map != null and is_instance_valid(current_map):
		unload_current_map()

	# 实例化新地图
	var entry: Dictionary = _registered_maps[map_id]
	var packed: PackedScene = entry["scene"]
	var new_map: Node2D = packed.instantiate() as Node2D
	if new_map == null:
		push_error("[SceneLoader] 地图场景实例化失败: %s" % map_id)
		return null

	_chunk_host.add_child(new_map)
	current_map = new_map
	current_map_id = map_id
	current_map_type = entry["type"]

	# 地图加载完成（本地 + EventBus）
	map_loaded.emit(map_id, current_map_type)
	_emit_event_bus("map_loaded", [map_id, current_map_type])

	# 旅行完成（本地 + EventBus）
	travel_completed.emit(map_id)
	_emit_event_bus("travel_completed", [map_id])
	return new_map


## 卸载当前地图
func unload_current_map() -> void:
	if current_map == null or not is_instance_valid(current_map):
		current_map = null
		current_map_id = ""
		return
	var old_id := current_map_id
	current_map.queue_free()
	current_map = null
	current_map_id = ""
	map_unloaded.emit(old_id)
	_emit_event_bus("map_unloaded", [old_id])


# ─────────────────────────────── EventBus 转发 ────────────────────────────────

func _emit_event_bus(signal_name: String, args: Array) -> void:
	if EventBus == null:
		return
	if not EventBus.has_signal(signal_name):
		return
	match args.size():
		0:
			EventBus.emit_signal(signal_name)
		1:
			EventBus.emit_signal(signal_name, args[0])
		2:
			EventBus.emit_signal(signal_name, args[0], args[1])
		3:
			EventBus.emit_signal(signal_name, args[0], args[1], args[2])


## EventBus.travel_requested 信号处理（战略图 -> 场景图）
func _on_travel_requested(map_id: String) -> void:
	travel_to_map(map_id, WorldAPI.TravelMode.FAST_TRAVEL, WorldAPI.EntrySide.LEFT)


# ─────────────────────────────── 查询 ────────────────────────────────

func get_current_map_id() -> String:
	return current_map_id


func get_current_map() -> Node2D:
	return current_map


func get_current_map_type() -> int:
	return current_map_type


func is_map_loaded() -> bool:
	return current_map != null and is_instance_valid(current_map)


func get_last_travel_mode() -> int:
	return last_travel_mode


func get_last_entry_side() -> int:
	return last_entry_side


# ─────────────────────────────── 旅行 ────────────────────────────────

## 快速旅行（仅切换地图，时间消耗由调用方处理）
func fast_travel(target_map_id: String) -> Node2D:
	return travel_to_map(target_map_id, WorldAPI.TravelMode.FAST_TRAVEL, WorldAPI.EntrySide.LEFT)


# ─────────────────────────────── Chunk 流式加载（§3.2）────────────────────────────────
# P0 阶段：地图整体加载，Chunk 流式为基础接口预留。
# 后续可将地图拆分为多个 Chunk，按玩家位置流式加载/卸载。

## 预加载 Chunk（不阻塞，后台加载）
func preload_chunk(chunk_idx: int) -> void:
	# TODO: 实现后台 Chunk 预加载
	chunk_loaded.emit(chunk_idx)
	_emit_event_bus("chunk_loaded", [chunk_idx])


## 卸载 Chunk
func unload_chunk(chunk_idx: int) -> void:
	# TODO: 实现 Chunk 卸载
	chunk_unloaded.emit(chunk_idx)
	_emit_event_bus("chunk_unloaded", [chunk_idx])
