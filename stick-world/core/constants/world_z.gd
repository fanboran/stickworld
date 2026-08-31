class_name WorldZ
extends RefCounted
## 世界空间 z 序统一常量 —— 一处定义、处处引用（对标 UI 侧 LayerOrder）。
##
## 适用范围：地图场景内 Node2D 层序 + 世界内浮动指示物（血条/进度条/交互提示）。
## 与 UI CanvasLayer 的 LayerOrder 分属两套坐标系，互不冲突。
##
## 替换记录（2026-08-22）：village_a/village_b/battlefield/forest_zone/road_a_b/
## mega_interior 场景文件的 z_index 硬编码已移除，改由 MapBase._ready 统一应用。

# ─────────────────────────────── 地图场景层 ────────────────────────────────

## 地面/土路（TerrainRenderer 路面多边形）
const GROUND := 0
## 装饰层（DecorationLayer：草丛/资源点装饰）
const DECORATION := 1
## 建筑层（BuildingHost / TerrainBuildings，容器内部用 y-sort 细分）
const BUILDING := 2
## 单位层（EntityHost，y-sort）
const ENTITY := 3
## 前景遮挡层（ForegroundLayer：火柴人经过被遮挡的近景物）
const FOREGROUND := 10

# ─────────────────────────────── 世界内浮动指示物 ────────────────────────────────

## 交互提示 / 建造幽灵（悬于单位之上、前景之下）
const OVERLAY_HINT := 20
## 建造/动作进度条
const OVERLAY_PROGRESS := 25
## 血条（最高浮层）
const OVERLAY_HEALTHBAR := 50


## 把常量应用到地图根的具名子层（由 MapBase._ready 调用；
## 场景文件不再保存 z_index，本方法为唯一真相源的应用点）。
static func apply(map: Node2D) -> void:
	if map == null:
		return
	for entry in [
		["DecorationLayer", DECORATION],
		["BuildingHost", BUILDING],
		["TerrainBuildings", BUILDING],
		["EntityHost", ENTITY],
		["ForegroundLayer", FOREGROUND],
	]:
		var node := map.get_node_or_null(NodePath(entry[0])) as Node2D
		if node != null:
			node.z_index = entry[1]
