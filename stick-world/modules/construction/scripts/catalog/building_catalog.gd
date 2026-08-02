extends Node
## 建筑目录系统 —— 建筑场景模板注册表 + 建筑定义数据加载。
##
## 职责：
## - 注册建筑场景模板（def_id → PackedScene）
## - 默认注册（占位建筑 / 城墙城门 / 兵营 / 仓库）
## - 从 buildings.tres 加载建筑定义（width / 建造成本 / interior_mode 等）
##
## 由 ConstructionManager._ready 挂载为 BuildingCatalog 子节点并调用 setup(root)，
## 注册表数据（_building_scene_registry / _building_defs_cache）由 ConstructionManager 持有。

var _root: Node = null


func setup(root: Node) -> void:
	_root = root


# ─────────────────────────────── 建筑场景注册 ────────────────────────────────

## 注册建筑场景模板（def_id → PackedScene）
func register_scene(def_id: String, scene: PackedScene) -> void:
	if def_id.is_empty() or scene == null:
		return
	_root._building_scene_registry[def_id] = scene


## P0 默认注册：bld_placeholder（占位建筑） + 城墙/城门（阶段 F）
func register_defaults() -> void:
	var placeholder_scene := load("res://modules/building_gen/buildings/bld_placeholder.tscn") as PackedScene
	if placeholder_scene != null:
		register_scene("bld_placeholder", placeholder_scene)
	else:
		push_warning("[ConstructionManager] 无法加载 bld_placeholder.tscn")
	# 阶段 F：城墙/城门场景注册
	var wall_scenes := {
		"bld_wall_tier1": "res://modules/building_gen/buildings/bld_wall_tier1.tscn",
		"bld_wall_tier2": "res://modules/building_gen/buildings/bld_wall_tier2.tscn",
		"bld_wall_tier3": "res://modules/building_gen/buildings/bld_wall_tier3.tscn",
		"bld_wall_gate": "res://modules/building_gen/buildings/bld_wall_gate.tscn",
	}
	for def_id: String in wall_scenes.keys():
		var scene := load(wall_scenes[def_id]) as PackedScene
		if scene != null:
			register_scene(def_id, scene)
		else:
			push_warning("[ConstructionManager] 无法加载 %s.tscn" % def_id)
	# 阶段 E：兵营场景注册（复制自铁匠铺，红色调区分）
	var barracks_scene := load("res://modules/building_gen/buildings/bld_barracks.tscn") as PackedScene
	if barracks_scene != null:
		register_scene("bld_barracks", barracks_scene)
	else:
		push_warning("[ConstructionManager] 无法加载 bld_barracks.tscn")
	# 仓库场景注册（搬运系统取货点，复制自兵营改棕黄色调）
	var warehouse_scene := load("res://modules/building_gen/buildings/bld_warehouse.tscn") as PackedScene
	if warehouse_scene != null:
		register_scene("bld_warehouse", warehouse_scene)
	else:
		push_warning("[ConstructionManager] 无法加载 bld_warehouse.tscn")


# ─────────────────────────────── 建筑定义数据驱动（P0-6）────────────────────────────────

## 从 buildings.tres 预加载建筑定义
func load_defs() -> void:
	var res_path := "res://config/buildings/buildings.tres"
	if not ResourceLoader.exists(res_path):
		push_warning("[ConstructionManager] 建筑定义表不存在: %s" % res_path)
		return
	var res: Resource = load(res_path)
	if res == null or not (res.get("variables") is Dictionary):
		return
	var data: Array = res.variables.get("data", [])
	for entry in data:
		if entry is Dictionary and entry.has("id"):
			_root._building_defs_cache[entry["id"]] = entry


## 查询建筑定义
func get_def(def_id: String) -> Dictionary:
	return _root._building_defs_cache.get(def_id, {})


## 建筑类型是否已注册场景（可建造）
func is_registered(def_id: String) -> bool:
	return _root._building_scene_registry.has(def_id)


## 获取建筑场景模板（未注册返回 null）
func get_scene(def_id: String) -> PackedScene:
	return _root._building_scene_registry.get(def_id, null)


## 返回所有已注册场景的建筑 def_id（即可建造的建筑类型）
func get_registered_def_ids() -> Array:
	return _root._building_scene_registry.keys()
