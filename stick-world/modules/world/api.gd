class_name WorldAPI
extends RefCounted
## World 模块公共接口契约
##
## 本模块是游戏世界的常驻容器，负责：
## - GameRoot 主场景控制
## - CameraRig 相机跟随/缩放/震屏
## - SceneLoader 地图与 Chunk 流式加载
## - WorldChunkHost 当前激活地图实例的挂载点
##
## 外部模块通过本模块的常量、枚举与节点路径约定交互。
## 修改 GameRoot 节点结构需同步更新本文件。

# ─────────────────────────────── 节点路径 ────────────────────────────────
## GameRoot 下各常驻子节点的相对路径
const PATH_ENVIRONMENT := "EnvironmentSystem"
const PATH_CAMERA_RIG := "CameraRig"
const PATH_SCENE_LOADER := "SceneLoader"
const PATH_INPUT_DISPATCHER := "InputDispatcher"
const PATH_WORLD_CHUNK_HOST := "WorldChunkHost"
const PATH_UI_ROOT := "UIRoot"
const PATH_BATTLE_DIRECTOR := "BattleDirector"

# ─────────────────────────────── MapInstance 节点路径 ────────────────────────────────
## MapInstance（村落/战场/道路/室内）下各子节点的相对路径
## 详见 docs/技术/架构/场景与战斗架构.md §3.4
const PATH_MAP_PLACEMENT_GRID := "PlacementGrid"
const PATH_MAP_TERRAIN_LAYER := "TerrainLayer"
const PATH_MAP_DECORATION_LAYER := "DecorationLayer"
const PATH_MAP_BUILDING_HOST := "BuildingHost"
const PATH_MAP_ENTITY_HOST := "EntityHost"
const PATH_MAP_CHUNK_TRIGGERS := "ChunkTriggers"
const PATH_MAP_BATTLE_ANCHOR := "BattleAnchor"

# ─────────────────────────────── 地图类型 ────────────────────────────────
enum MapType {
	VILLAGE,        ## 村落地图
	BATTLEFIELD,    ## 战场地图
	ROAD,           ## 道路地图
	INDOOR,         ## 室内地图（小建筑）
	MEGA_INTERIOR,  ## 大建筑内部（传送）
}

# ─────────────────────────────── 旅行方式 ────────────────────────────────
enum TravelMode {
	WALK,           ## 步行（走 RoadMap）
	FAST_TRAVEL,    ## 快速旅行（世界地图）
	TELEPORT,       ## 传送（大建筑内部）
}

# ─────────────────────────────── 信号契约 ────────────────────────────────
## GameRoot 发射的信号（通过 EventBus 转发或本地信号）：
##   - map_loaded(map_id: String, map_type: int)
##   - map_unloaded(map_id: String)
##   - travel_started(from_id: String, to_id: String, mode: int)
##   - travel_completed(to_id: String)
##
## 本模块订阅的信号：
##   - EventBus.game_paused / game_resumed
##   - InputDispatcher.mode_changed
