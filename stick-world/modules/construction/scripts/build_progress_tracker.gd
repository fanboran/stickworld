class_name BuildProgressTracker
extends RefCounted
## 建造进度条跟踪器 —— 阶段 E 双进度条（材料进度 / 建造进度）。
##
## 职责：
##   1. 项目开工/读档恢复时，在 map.BuildMaskLayer 创建双进度条指示器
##   2. 监听项目 progress_changed，实时刷新对应进度条
##   3. 项目完工/取消时移除进度条；读档/换图前清空全部
##
## 由 ConstructionManager 持有（一个 Manager 对应一个 Tracker）；
## 地图引用经 set_map 注入（与 manager.set_map 同步），本组件不反向依赖 manager。
## 指示器节点本体见 build_progress_indicator.gd。

const ScriptBuildProgressIndicator := preload("res://modules/construction/scripts/build_progress_indicator.gd")
const ScriptConstructionProject := preload("res://modules/construction/scripts/construction_project.gd")

# ─────────────────────────────── 字段 ────────────────────────────────

## 当前地图引用（由 ConstructionManager.set_map 注入）
var _map: Node2D = null
## 建造项目 → 进度条指示器映射 {project_id → BuildProgressIndicator}
var _indicators: Dictionary = {}


# ─────────────────────────────── 注入 ────────────────────────────────

## 由 ConstructionManager.set_map 同步注入当前地图引用。
func set_map(map: Node2D) -> void:
	_map = map


# ─────────────────────────────── 进度条生命周期 ────────────────────────────────

## 项目开工/读档恢复：创建双进度条指示器 + 监听进度变化。
func track(project: ScriptConstructionProject) -> void:
	_create_indicator(project)
	if not project.progress_changed.is_connected(_on_project_progress):
		project.progress_changed.connect(_on_project_progress)


## 项目完工/取消：移除进度条。
func untrack(project_id: String) -> void:
	var indicator: Node2D = _indicators.get(project_id)
	if indicator != null and is_instance_valid(indicator):
		indicator.queue_free()
	_indicators.erase(project_id)


## 清空全部进度条（读档/换图前调用）。
func clear_all() -> void:
	for indicator in _indicators.values():
		if is_instance_valid(indicator):
			(indicator as Node).queue_free()
	_indicators.clear()


# ─────────────────────────────── 内部实现 ────────────────────────────────

## 为项目创建双进度条指示器，挂到 map.BuildMaskLayer
func _create_indicator(project: ScriptConstructionProject) -> void:
	if _map == null:
		return
	var mask_layer: Node2D = _map.get("build_mask_layer") if "build_mask_layer" in _map else null
	if mask_layer == null:
		mask_layer = _map.get_node_or_null("BuildMaskLayer")
	if mask_layer == null:
		return
	var indicator: Node2D = ScriptBuildProgressIndicator.new()
	indicator.setup(project.cell_x, project.width, float(_map.get("ground_y") if "ground_y" in _map else 810.0))
	mask_layer.add_child(indicator)
	_indicators[project.project_id] = indicator
	indicator.update_progress(project.get_material_progress(), project.get_progress())


## 项目进度变化回调：更新进度条
func _on_project_progress(project: ScriptConstructionProject, _progress: float) -> void:
	var indicator: Node2D = _indicators.get(project.project_id)
	if indicator != null and is_instance_valid(indicator):
		indicator.update_progress(project.get_material_progress(), project.get_progress())
