extends RefCounted
## 放置度量常量库 —— construction 模块内占地/落位口径的唯一出口。
##
## 为什么存在：占地条带宽、落位基线回退值等数字曾以裸字面量散在 manager/project/
## indicator/tracker/ghost/build_menu 六处（各写一份"换轨时两处同步"注释，靠人肉
## 对齐）；本档把它们收编成模块内单一真相源，改口径只动这里。
##
## 跨模块边界（勿越）：真正的权威在 world 模块 L3——
##   - 条带宽权威 = PlacementGrid.CELL_SIZE（modules/world/scripts/placement/）
##   - 基线偏移权威 = Hd2dMapBase.building_baseline_offset
## construction 是 L2，禁止反向 preload world；两端口径靠本文件注释锚定同步
##（换轨时改这里 + world 侧各一行）。

## 占地条带宽（px）：锚定 PlacementGrid.CELL_SIZE（24px 换轨，旧 32；1 格显示
## 24 设计像素@zoom1）。同 build_menu/placement_ghost/behavior_work 口径。
const CELL_PX: float = 24.0

## 旧图 duck 回退：地图无 ground_y 字段时的地面基线（px，画布域）。
## 真值源 = 地图自身的 ground_y；此值只兜旧 2D 图/桩地图。
const GROUND_Y_FALLBACK: float = 810.0

## 旧图 duck 回退：地图无 building_baseline_offset 字段时的建筑基线偏移（px）。
## 真值源 = Hd2dMapBase.building_baseline_offset = 96.0（建筑随基线上移一层楼带）。
const BASELINE_OFFSET_FALLBACK: float = 96.0

## 建筑体纵深（px，放置阻挡判定用）：实体脚部落在 [baseline - BODY_DEPTH, baseline]
## 带内即挡放置（防放置后玩家被罩在建筑内）。约数——与 PassageBarrier 手摆
## 碰撞的视觉口径对齐（各楼场景各异，取方阵通用纵深）；不含脚下空地。
const BLOCK_BODY_DEPTH: float = 390.0

## 放置阻挡判定的 X 向余量（px）：条带范围左右各放宽此值再判实体脚部 X。
const BLOCK_X_MARGIN: float = 20.0


## 落位基线（px，画布域）：地图支持逐格墙脚线（HD-2D，get_building_baseline_at）
## 则按格子范围取邻居楼线；否则 ground_y + building_baseline_offset（旧图回退）。
## baseline_y > 0 时直接采用（存档/指定深度优先）。
## manager/_baseline_at、project/_baseline_at、build_menu/indicator 的同构回退
## 全部收敛在此。
static func baseline_at(map: Node2D, cell_x: int, width: int, baseline_y: float = -1.0) -> float:
	if baseline_y > 0.0:
		return baseline_y
	if map != null and map.has_method("get_building_baseline_at"):
		return float(map.call("get_building_baseline_at", cell_x, width))
	return ground_y_of(map) + baseline_offset_of(map)


## 地面基线取值（带回退）：地图缺 ground_y 字段时回退 GROUND_Y_FALLBACK。
static func ground_y_of(map: Node2D) -> float:
	return float(map.get("ground_y") if map != null and "ground_y" in map else GROUND_Y_FALLBACK)


## 建筑基线偏移取值（带回退）：地图缺 building_baseline_offset 字段时回退
## BASELINE_OFFSET_FALLBACK。进度条挂点等只需偏移量的消费方用此口。
static func baseline_offset_of(map: Node2D) -> float:
	return float(map.get("building_baseline_offset") if map != null and "building_baseline_offset" in map else BASELINE_OFFSET_FALLBACK)
