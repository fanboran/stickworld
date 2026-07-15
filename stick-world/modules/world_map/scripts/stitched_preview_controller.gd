extends Node
class_name StitchedPreviewController
## 拼接预览模式控制器 —— 跨地区作战时多包拼接显示
##
## 详见 docs/技术/架构/战略图架构.md §五 地图拼接预览模式
##
## 渲染层级：
##   远邻包（矢量描边层）：仅多边形轮廓 + 政治色填充
##   相邻包（简化预览层）：降采样底图 + 边界 + 简化聚落图标
##   中心包（完整渲染层）：全分辨率底图 + 全部叠加层 + 动态聚落建筑群
##
## 阶段：P2 实现（P0/P1 不涉及）

## 关联的数据容器
@export var data: StrategicMapData

## 关联的渲染器
@export var renderer: MapRenderer

## 关联的相机
@export var camera: MapCamera

## 是否启用拼接预览
var _enabled: bool = false

## 中心包 ID
var _center_id: String = ""

## 相邻包 ID 列表（最多 8 个）
var _neighbor_ids: Array[String] = []

## 同时加载的包数量上限
const MAX_NEIGHBORS: int = 8


## 启用拼接预览
func enable() -> void:
	# TODO: P2 实现
	# 1. _enabled = true
	# 2. 确定中心包（当前 focused_parent_id）
	# 3. 加载相邻包（最多 MAX_NEIGHBORS 个）
	# 4. 通知 renderer 切换到拼接渲染模式
	_enabled = true


## 关闭拼接预览
func disable() -> void:
	# TODO: P2 实现
	# 1. 卸载相邻包
	# 2. 通知 renderer 回到普通渲染模式
	# 3. _enabled = false
	_enabled = false


## 拼接预览是否启用
func is_enabled() -> bool:
	return _enabled


## 切换中心包（玩家点击相邻包时）
func switch_center(new_center_id: String) -> void:
	# TODO: P2 实现
	# 1. 旧中心降级为相邻包
	# 2. 新中心完整渲染
	# 3. 更新 _neighbor_ids（新中心的邻居）
	_center_id = new_center_id


## 获取当前中心包 ID
func get_center_id() -> String:
	return _center_id


## 获取相邻包 ID 列表
func get_neighbor_ids() -> Array[String]:
	return _neighbor_ids


## 渲染拼接预览（由 renderer 调用）
## 返回三层渲染数据：远邻/相邻/中心
func get_render_layers() -> Dictionary:
	# TODO: P2 实现
	# 返回 {
	#   "far_neighbors": [{id, polygon, owner_color}, ...],  # 矢量描边
	#   "near_neighbors": [{id, texture, boundary, settlement_icons}, ...],  # 简化预览
	#   "center": {id, texture, boundary, settlements, roads, resources}  # 完整渲染
	# }
	return {
		"far_neighbors": [],
		"near_neighbors": [],
		"center": {},
	}
