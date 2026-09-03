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


## P0 默认注册：占位建筑 + 城墙/城门（阶段 F）+ 兵营 + 仓库。
## 场景模板归属 building_gen 模块，运行时经其 api 加载（不用编译期 preload，
## 以免与 code_scanner 独立 reload 各脚本产生资源路径冲突），本模块不硬编码内部路径。
func register_defaults() -> void:
	var api: GDScript = load("res://modules/building_gen/api.gd")
	if api == null:
		push_warning("[ConstructionManager] 无法加载 building_gen 接口")
		return
	for def_id: String in api.get_default_building_def_ids():
		var scene: PackedScene = api.load_building_scene(def_id)
		if scene != null:
			register_scene(def_id, scene)
		else:
			push_warning("[ConstructionManager] 无法加载建筑场景: %s" % def_id)


# ─────────────────────────────── 建筑定义数据驱动（P0-6）────────────────────────────────

## 从 buildings.tres 预加载建筑定义
func load_defs() -> void:
	var res_path := "res://config/buildings/buildings.tres"
	if not ResourceLoader.exists(res_path):
		push_warning("[ConstructionManager] 建筑定义表不存在: %s" % res_path)
		return
	var res: Resource = load(res_path)
	if res == null or not (res.get("variables") is Dictionary):
		push_warning("[ConstructionManager] 建筑定义表加载失败或格式异常: %s" % res_path)
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
