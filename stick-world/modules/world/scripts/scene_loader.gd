class_name SceneLoader
extends Node
## 场景加载器 —— 地图与 Chunk 流式加载。
##
## 详见 docs/技术/架构/场景与战斗架构.md §三。
## 当前 P0 阶段实现：地图整体加载/卸载（Chunk 流式留到阶段 0.8）。

const WorldAPI := preload("res://modules/world/api.gd")

# ─────────────────────────────── 信号 ────────────────────────────────
## 地图加载完成
signal map_loaded(map_id: String, map_type: int)
## 地图卸载完成
signal map_unloaded(map_id: String)
## 旅行开始
signal travel_started(from_id: String, to_id: String, mode: int)
## 旅行完成
signal travel_completed(to_id: String)

# ─────────────────────────────── 状态 ────────────────────────────────
## 已注册地图：map_id -> PackedScene
var _registered_maps: Dictionary = {}
## 当前地图 ID
var current_map_id: String = ""
## 当前地图实例
var current_map: Node2D = null
## 当前地图类型
var current_map_type: int = WorldAPI.MapType.VILLAGE

## WorldChunkHost 引用（地图挂载点）
var _chunk_host: Node2D = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	# 延迟一帧获取 GameRoot 下的 WorldChunkHost 引用
	call_deferred("_resolve_chunk_host")


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


# ─────────────────────────────── 加载/卸载 ────────────────────────────────

## 加载地图。如果当前有地图，先卸载。
## 返回加载的地图实例，失败返回 null。
func load_map(map_id: String) -> Node2D:
	if not _registered_maps.has(map_id):
		push_error("[SceneLoader] 未注册的地图: %s" % map_id)
		return null

	if _chunk_host == null:
		_resolve_chunk_host()
	if _chunk_host == null:
		push_error("[SceneLoader] WorldChunkHost 未就绪")
		return null

	var old_id := current_map_id
	# 旅行开始
	travel_started.emit(old_id, map_id, WorldAPI.TravelMode.WALK)

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

	map_loaded.emit(map_id, current_map_type)
	travel_completed.emit(map_id)
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


# ─────────────────────────────── 查询 ────────────────────────────────

func get_current_map_id() -> String:
	return current_map_id


func get_current_map() -> Node2D:
	return current_map


func get_current_map_type() -> int:
	return current_map_type


func is_map_loaded() -> bool:
	return current_map != null and is_instance_valid(current_map)


# ─────────────────────────────── 旅行 ────────────────────────────────

## 快速旅行（仅切换地图，时间消耗由调用方处理）
func fast_travel(target_map_id: String) -> Node2D:
	return load_map(target_map_id)
