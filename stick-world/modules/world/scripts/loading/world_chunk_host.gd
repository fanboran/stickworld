class_name WorldChunkHost
extends Node2D
## 地图实例挂载点。
##
## GameRoot 的子节点，SceneLoader 把地图实例 add_child 到这里。
## 当前 P0 阶段仅作为容器，后续 Chunk 流式加载逻辑会在此扩展。
##
## 详见 docs/技术/架构/场景与战斗架构.md §三.4。

# ─────────────────────────────── 占位接口 ────────────────────────────────

## 当前挂载的地图实例（首个子节点）
func get_current_map() -> Node2D:
	if get_child_count() == 0:
		return null
	return get_child(0) as Node2D


## 是否有地图挂载
func has_map() -> bool:
	return get_child_count() > 0
