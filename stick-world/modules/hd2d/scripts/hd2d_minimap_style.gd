class_name Hd2dMinimapStyle
extends RefCounted
## HD-2D 建筑卡 def → 小地图语义表（功能类型 + 近似世界材质色）。
##
## 为什么需要近似色：街景建筑是**烘进贴图的 3D 卡片**（cards.json 只有
## `card`/`def`/`cells` 等几何字段，无材质字段），运行期拿不到逐栋的真实采样色。
## 小地图要"按世界实际颜色缩略"只能按 def 归档给近似色——口径与
## `BuildingPalette`（2D 程序化建筑那套材质色）同族，但与本管线无实体耦合，
## 故独立成表，避免小地图侧反向依赖另一条建筑管线。
##
## 功能类型（`type`）是 UI 层「类型着色+图例」的键：颜色归 UI（StickTokens），
## 本表只回答"这栋楼是干什么用的"（数据归地图侧）。
##
## 消费方：hd2d_world.get_minimap_layout() → 小地图/放大版窗口。

## 功能类型键
const TYPE_RESIDENTIAL := "residential"   ## 居住
const TYPE_PRODUCTION := "production"     ## 生产
const TYPE_COMMERCIAL := "commercial"     ## 商业
const TYPE_CIVIC := "civic"               ## 市政/宗教
const TYPE_MILITARY := "military"         ## 军事
const TYPE_MISC := "misc"                 ## 其他

## 近似世界材质色（木构暖褐 / 深木 / 灰石 / 深石 / 青灰瓦 / 市集赭 / 砖）
const C_WOOD_WARM := Color(0.62, 0.45, 0.28)
const C_WOOD_DARK := Color(0.45, 0.33, 0.22)
const C_STONE := Color(0.63, 0.61, 0.56)
const C_STONE_DARK := Color(0.47, 0.46, 0.43)
const C_SLATE := Color(0.42, 0.44, 0.48)
const C_OCHRE := Color(0.70, 0.56, 0.32)
const C_BRICK := Color(0.60, 0.42, 0.35)
const C_GREEN := Color(0.45, 0.58, 0.36)
const C_WATER := Color(0.36, 0.50, 0.62)

## def → [类型, 近似色]。键同时收两类建筑标识：管线烘卡 def（CityGen 卡名去
## `_wN`，如 cottage/smithy2——3D 街景排楼）与运行时建筑 def_id（config/
## buildings/buildings.tres，如 timber_cottage/wall_tier1——玩家自建与 plan
## 物化件）。两者同名的（warehouse/barracks/academy）恰好同义，无需分表。
## 未收录 def 走 FALLBACK。
const STYLE: Dictionary = {

	# ── 居住（木构暖褐，屋顶茅草/木瓦）──
	"cottage": [TYPE_RESIDENTIAL, C_WOOD_WARM],
	"house": [TYPE_RESIDENTIAL, C_WOOD_WARM],
	"rowhouse": [TYPE_RESIDENTIAL, C_WOOD_WARM],
	"townhouse": [TYPE_RESIDENTIAL, C_WOOD_WARM],
	"shelter": [TYPE_RESIDENTIAL, C_WOOD_DARK],
	"hayloft": [TYPE_RESIDENTIAL, C_WOOD_DARK],
	"placeholder": [TYPE_RESIDENTIAL, C_WOOD_WARM],
	"timber_cottage": [TYPE_RESIDENTIAL, C_WOOD_WARM],
	"manor": [TYPE_RESIDENTIAL, C_WOOD_WARM],
	# ── 生产（深木/灰石：作坊烟熏、谷仓原木、风车石基）──
	"smithy1": [TYPE_PRODUCTION, C_WOOD_DARK],
	"smithy2": [TYPE_PRODUCTION, C_WOOD_DARK],
	"smithy3": [TYPE_PRODUCTION, C_WOOD_DARK],
	"smithy4": [TYPE_PRODUCTION, C_WOOD_DARK],
	"bakery": [TYPE_PRODUCTION, C_WOOD_DARK],
	"alchemy": [TYPE_PRODUCTION, C_WOOD_DARK],
	"stable": [TYPE_PRODUCTION, C_WOOD_WARM],
	"barn": [TYPE_PRODUCTION, C_WOOD_DARK],
	"warehouse": [TYPE_PRODUCTION, C_STONE_DARK],
	"windmill": [TYPE_PRODUCTION, C_STONE],
	"mint": [TYPE_PRODUCTION, C_STONE],
	"farm": [TYPE_PRODUCTION, C_GREEN],
	"smithy_lv1": [TYPE_PRODUCTION, C_WOOD_DARK],
	"smithy_lv2": [TYPE_PRODUCTION, C_WOOD_DARK],
	"smithy_lv3": [TYPE_PRODUCTION, C_WOOD_DARK],
	"smithy_lv4": [TYPE_PRODUCTION, C_WOOD_DARK],
	"stone_warehouse": [TYPE_PRODUCTION, C_STONE_DARK],
	# ── 商业（暖赭：市集/酒馆/旅店）──
	"shop": [TYPE_COMMERCIAL, C_OCHRE],
	"market": [TYPE_COMMERCIAL, C_OCHRE],
	"tavern": [TYPE_COMMERCIAL, C_OCHRE],
	"inn_post": [TYPE_COMMERCIAL, C_OCHRE],
	"waystation": [TYPE_COMMERCIAL, C_OCHRE],
	"coach_house": [TYPE_COMMERCIAL, C_OCHRE],
	"gambling_den": [TYPE_COMMERCIAL, C_BRICK],
	"grand_casino": [TYPE_COMMERCIAL, C_BRICK],
	"flower_shop": [TYPE_COMMERCIAL, C_GREEN],
	# ── 市政/宗教（灰石 → 宫殿深石）──
	"guildhall": [TYPE_CIVIC, C_STONE],
	"council_hall": [TYPE_CIVIC, C_STONE],
	"town_hall": [TYPE_CIVIC, C_STONE],
	"governor_palace": [TYPE_CIVIC, C_STONE_DARK],
	"imperial_palace": [TYPE_CIVIC, C_STONE_DARK],
	"library": [TYPE_CIVIC, C_STONE],
	"academy": [TYPE_CIVIC, C_STONE],
	"observatory": [TYPE_CIVIC, C_STONE],
	"abbey": [TYPE_CIVIC, C_STONE],
	"cathedral": [TYPE_CIVIC, C_STONE_DARK],
	"belfry": [TYPE_CIVIC, C_STONE],
	"gatehouse": [TYPE_CIVIC, C_STONE_DARK],
	"grand_hall": [TYPE_CIVIC, C_STONE],
	# ── 军事（青灰瓦/石）──
	"barracks": [TYPE_MILITARY, C_SLATE],
	"tower": [TYPE_MILITARY, C_SLATE],
	"mage_tower": [TYPE_MILITARY, C_SLATE],
	"wall_tier1": [TYPE_MILITARY, C_SLATE],
	"wall_tier2": [TYPE_MILITARY, C_SLATE],
	"wall_tier3": [TYPE_MILITARY, C_SLATE],
	"wall_gate": [TYPE_MILITARY, C_SLATE],
	# ── 其他（护城河水面）──
	"moat": [TYPE_MISC, C_WATER],
}

## 未收录 def 的兜底（新增卡片未登记时不至于丢点）
const FALLBACK: Array = [TYPE_MISC, C_STONE]


## 功能类型键（未收录 → TYPE_MISC）
static func type_for(def: String) -> String:
	var row: Array = STYLE.get(def, FALLBACK)
	return String(row[0])


## 近似世界材质色（未收录 → 兜底色）
static func color_for(def: String) -> Color:
	var row: Array = STYLE.get(def, FALLBACK)
	return row[1]
