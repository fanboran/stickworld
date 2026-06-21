extends Node
class_name MapModeManager
## 地图模式管理器 —— 管理多种地图模式的切换和数据

## 支持的地图模式枚举（与 WorldMapData.get_region_color 中的 mode 值对应）
enum MapMode {
	POLITICAL = 0,  ## 政治模式：按势力归属着色
	TERRAIN = 1,    ## 地形模式：按地块类型着色
	RESOURCE = 2,   ## 资源模式：按资源类型着色
	STICKMAN = 3,   ## 火柴人模式：按火柴人种类着色
	BATTLEFRONT = 4 ## 战线模式：交战地块高亮
}

## 关联的渲染器
@export var map_renderer: MapRenderer

## 模式切换信号
signal mode_switched(mode: int, mode_name: String)

## 当前地图模式
var current_mode: MapMode = MapMode.POLITICAL

## 模式名称映射
const MODE_NAMES: Dictionary = {
	MapMode.POLITICAL: "势力地图",
	MapMode.TERRAIN: "地形地图",
	MapMode.RESOURCE: "资源地图",
	MapMode.STICKMAN: "人口地图",
	MapMode.BATTLEFRONT: "战线地图"
}


func _ready():
	if map_renderer == null:
		map_renderer = _find_map_renderer()
	_set_mode(MapMode.POLITICAL)

func _find_map_renderer() -> MapRenderer:
	var parent := get_parent()
	if parent:
		for child in parent.get_children():
			if child is MapRenderer:
				return child
	return null

## 切换地图模式
func switch_mode(mode: MapMode):
	if current_mode == mode:
		return
	_set_mode(mode)

func _set_mode(mode: MapMode):
	current_mode = mode
	if map_renderer:
		map_renderer.set_map_mode(int(mode))
	# 发出模式切换信号（外部模块可通过 API 或直接连接此信号响应）
	mode_switched.emit(int(mode), get_mode_name(mode))

## 获取模式名称
func get_mode_name(mode: int = -1) -> String:
	if mode == -1:
		mode = current_mode
	return MODE_NAMES.get(mode, "未知模式")

## 获取所有可用模式
func get_available_modes() -> Array:
	return [MapMode.POLITICAL, MapMode.TERRAIN, MapMode.RESOURCE, MapMode.STICKMAN, MapMode.BATTLEFRONT]

## 循环切换模式
func cycle_mode():
	var modes: Array = get_available_modes()
	var current_idx: int = modes.find(current_mode)
	var next_idx: int = (current_idx + 1) % modes.size()
	switch_mode(modes[next_idx])
