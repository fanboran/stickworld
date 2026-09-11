class_name RoadMapGenerator
extends RefCounted
## 道路场景生成器（F6/E4，总体设计 §5.10）—— 路长 → 横向卷轴 RoadMap 场景。
##
## 输入：步行队列的一段 leg（WorldState.walk_legs 条目）：
##   {road_id, road: {pts, tier, length_px, biomes}, from_map_id, to_map_id}
## 输出：PackedScene（RoadMap 根，结构对齐手工模板 road_a_b.tscn）：
##   RoadMap
##   ├── TerrainLayer
##   │   ├── BiomeBand0..N        ← 沿线群系色带（biomes 预采样，生成端 road_biome_export.py）
##   │   └── RoadStrip            ← 道路本体带（tier 决定色：土路土黄 / 官道灰白）
##   ├── GroundLine (Marker2D)
##   ├── EntityHost (Node2D)
##   ├── DecorationLayer          ← 路边装饰（seed 确定性，密度按 tier）
##   └── ChunkTriggers
##       ├── ExitLeft / ExitRight ← ChunkTrigger，target_map_id 留空 →
##                                  走 SceneLoader 出口配置（GameRoot 按队列状态刷新）
##
## 确定性：road_id 作种子，同一条路每次生成一致；生成结果由 SceneLoader 注册缓存
## （会话内复用，不落盘）。宽度 = length_px × 比例系数（官道更短——「大路好走」）。

# WorldAPI 是全局 class_name，无需 preload

const RoadMapScript := preload("res://modules/world/scripts/map/road_map.gd")
const ChunkTriggerScript := preload("res://modules/world/scripts/loading/chunk_trigger.gd")

## 场景宽度比例系数（1 地图 px = N 场景 px，§5.10 系数表；手感定标）：
## 土路绕、官道直且「好走」——同一路长官道场景更短
const SCALE_BY_TIER := {
	"DIRT": 24.0,
	"PAVED": 16.0,
}
const MIN_WIDTH := 2500.0
const MAX_WIDTH := 40000.0

## 地面纵向布局（对齐 VillageMap/road_a_b 模板默认值）
const GROUND_Y := 810.0
const GROUND_BOTTOM := 1080.0
const GROUND_RATIO := 0.25

## 道路本体带高度与色（tier 分级；P0 纯色，后续可换纹理）
const ROAD_STRIP_H := 72.0
const ROAD_COLOR_DIRT := Color(0.62, 0.52, 0.36)
const ROAD_COLOR_PAVED := Color(0.66, 0.64, 0.58)

## 沿线群系色带（索引 = biome 标签 0..6；1..6 与 map_renderer.gd BIOME_LEGEND 同源，
## 标签 0 海洋不在图例——贴海岸路段给沙岸色）
const BIOME_BAND_COLORS := [
	Color(0.76, 0.71, 0.55),  # 0 海洋→沙岸
	Color(0.51, 0.67, 0.35),  # 1 平原
	Color(0.27, 0.47, 0.24),  # 2 森林
	Color(0.82, 0.71, 0.48),  # 3 荒漠
	Color(0.89, 0.91, 0.93),  # 4 冰原
	Color(0.37, 0.63, 0.76),  # 5 源流
	Color(0.46, 0.24, 0.21),  # 6 火山
]
## biomes 缺失时的兜底单色（按 tier——旧包无预采样数据）
const FALLBACK_COLORS := {
	"DIRT": Color(0.51, 0.67, 0.35),
	"PAVED": Color(0.51, 0.67, 0.35),
}

## 装饰参数（seed 确定性；土路荒野感装饰更密）
const DECOR_SPACING_BY_TIER := {"DIRT": 220.0, "PAVED": 420.0}


## 道路场景 id 由 world_map api.walk_to 组装队列时生成（`road_<edge_key>` 形式，
## 两端聚落排序拼接保证 a-b 与 b-a 同路同 id）——本生成器只消费 leg["road_id"]，
## 不重复维护 id 规则（单一真相源）。


## 场景宽度（长度 × tier 系数，clamp 上下限）
static func scene_width(length_px: float, tier: String) -> float:
	var k: float = float(SCALE_BY_TIER.get(tier, SCALE_BY_TIER["DIRT"]))
	return clampf(length_px * k, MIN_WIDTH, MAX_WIDTH)


## 由步行队列段构建道路场景 PackedScene（seed = road_id 哈希，确定性）
static func build(leg: Dictionary) -> PackedScene:
	var road: Dictionary = leg.get("road", {})
	var rid := str(leg.get("road_id", "road_unknown"))
	var tier := str(road.get("tier", "DIRT"))
	var width := scene_width(float(road.get("length_px", 0.0)), tier)

	var root := Node2D.new()
	root.name = "RoadMap"
	root.set_script(RoadMapScript)
	root.map_id = rid
	root.ground_y = GROUND_Y
	root.ground_ratio = GROUND_RATIO
	root.map_left = 0.0
	root.map_right = width
	root.ground_bottom = GROUND_BOTTOM

	var terrain := Node2D.new()
	terrain.name = "TerrainLayer"
	root.add_child(terrain)
	_build_biome_bands(terrain, road, width, tier)
	_build_road_strip(terrain, width, tier)

	var ground_line := Marker2D.new()
	ground_line.name = "GroundLine"
	ground_line.position = Vector2(0, GROUND_Y)
	root.add_child(ground_line)

	var entity_host := Node2D.new()
	entity_host.name = "EntityHost"
	root.add_child(entity_host)

	var decor := Node2D.new()
	decor.name = "DecorationLayer"
	root.add_child(decor)
	_build_decorations(decor, width, tier, rid.hash())

	var triggers := Node2D.new()
	triggers.name = "ChunkTriggers"
	root.add_child(triggers)
	_build_exit_trigger(triggers, "ExitLeft", WorldAPI.EntrySide.LEFT, width)
	_build_exit_trigger(triggers, "ExitRight", WorldAPI.EntrySide.RIGHT, width)

	# pack() 只序列化 owner==root 的子树——运行时 add_child 的节点 owner 为空，
	# 不补设则产物仅剩根节点（地形/装饰/出口触发器全丢，road 场景进图即空壳）
	_propagate_owner(root, root)

	var packed := PackedScene.new()
	packed.pack(root)
	return packed


## 递归补设 owner（静态生成节点统一归属根，PackedScene.pack 的序列化前提）
static func _propagate_owner(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_propagate_owner(c, owner)


## 沿线群系色带：biomes 均分横向分段（逐段 Polygon2D）；无数据按 tier 单色兜底
static func _build_biome_bands(terrain: Node2D, road: Dictionary, width: float, tier: String) -> void:
	var biomes: PackedInt32Array = road.get("biomes", PackedInt32Array())
	if biomes.size() < 2:
		var band := Polygon2D.new()
		band.name = "BiomeBand0"
		band.color = FALLBACK_COLORS.get(tier, FALLBACK_COLORS["DIRT"])
		band.polygon = PackedVector2Array([
			Vector2(0, GROUND_Y), Vector2(width, GROUND_Y),
			Vector2(width, GROUND_BOTTOM), Vector2(0, GROUND_BOTTOM),
		])
		terrain.add_child(band)
		return
	var seg_w := width / float(biomes.size())
	for i in biomes.size():
		var label := int(biomes[i])
		var band := Polygon2D.new()
		band.name = "BiomeBand%d" % i
		band.color = BIOME_BAND_COLORS[label] if label >= 0 and label < BIOME_BAND_COLORS.size() else FALLBACK_COLORS["DIRT"]
		var x0 := i * seg_w
		band.polygon = PackedVector2Array([
			Vector2(x0, GROUND_Y), Vector2(x0 + seg_w, GROUND_Y),
			Vector2(x0 + seg_w, GROUND_BOTTOM), Vector2(x0, GROUND_BOTTOM),
		])
		terrain.add_child(band)


## 道路本体带（横贯全宽，tier 决定色）
static func _build_road_strip(terrain: Node2D, width: float, tier: String) -> void:
	var strip := Polygon2D.new()
	strip.name = "RoadStrip"
	strip.color = ROAD_COLOR_PAVED if tier == "PAVED" else ROAD_COLOR_DIRT
	var y0 := GROUND_Y + (GROUND_BOTTOM - GROUND_Y) * 0.5 - ROAD_STRIP_H * 0.5
	strip.polygon = PackedVector2Array([
		Vector2(0, y0), Vector2(width, y0),
		Vector2(width, y0 + ROAD_STRIP_H), Vector2(0, y0 + ROAD_STRIP_H),
	])
	terrain.add_child(strip)


## 路边装饰：石头/灌木多边形，间距按 tier，RandomNumberGenerator(seed) 确定性
static func _build_decorations(decor: Node2D, width: float, tier: String, seed: int) -> void:
	var spacing: float = float(DECOR_SPACING_BY_TIER.get(tier, DECOR_SPACING_BY_TIER["DIRT"]))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var x := 120.0
	var idx := 0
	while x < width - 120.0:
		var is_stone := rng.randf() < 0.45
		var d := Polygon2D.new()
		d.name = "Decor%d" % idx
		d.color = Color(0.42, 0.40, 0.38) if is_stone else Color(0.30, 0.52, 0.26)
		var cy := GROUND_Y + rng.randf_range(4.0, GROUND_BOTTOM - GROUND_Y - 24.0)
		# 道路本体内侧不放（让路可走）
		if absf(cy - (GROUND_Y + GROUND_BOTTOM) * 0.5) < ROAD_STRIP_H * 0.5 + 20.0:
			cy = GROUND_Y + 12.0 if rng.randf() < 0.5 else GROUND_BOTTOM - 24.0
		var s := rng.randf_range(6.0, 16.0)
		var poly := PackedVector2Array()
		for k in 6:
			var ang := TAU * float(k) / 6.0
			poly.append(Vector2(x, cy) + Vector2(cos(ang), sin(ang)) * s * rng.randf_range(0.7, 1.3))
		d.polygon = poly
		decor.add_child(d)
		x += spacing * rng.randf_range(0.7, 1.4)
		idx += 1


## 端点出口触发器（对齐 road_a_b.tscn：64×270 矩形，target 留空走出口配置）
static func _build_exit_trigger(triggers: Node2D, trig_name: String, side: int, width: float) -> void:
	var area := Area2D.new()
	area.name = trig_name
	area.set_script(ChunkTriggerScript)
	area.exit_side = side
	area.target_map_id = ""    # 出口目标由 GameRoot 按步行队列状态刷新（register_map_exit）
	area.target_entry_side = WorldAPI.EntrySide.LEFT
	area.trigger_width = 64.0
	var shape := CollisionShape2D.new()
	var rect := RectangleShape2D.new()
	rect.size = Vector2(64, GROUND_BOTTOM - GROUND_Y)
	shape.shape = rect
	shape.position = Vector2(32 if side == WorldAPI.EntrySide.LEFT else width - 32, (GROUND_Y + GROUND_BOTTOM) * 0.5)
	area.add_child(shape)
	triggers.add_child(area)
