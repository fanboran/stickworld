extends Hd2dMapBase
class_name Hd2dStreetMap
## HD-2D 城邦布局图 —— 主街（手摆/算法布局）、村B、L1 聚落壳的宿主。
##
## HD-2D 公共机制（3D 世界挂载/相机镜像/角色 billboard 同步/昼夜/行走带/
## 深度视觉/碰撞墙/城门传送/资源点生成/旅行出口）全部在 Hd2dMapBase；
## 本类只做**布局图特化**：
##   - 共享参数壳：布局驱动图共用 hd2d_layout_map.tscn，实例差异只剩参数，
##     _apply_map_params 钩子按 SceneLoader 注入的 map_id 推导
##     layout_name / city_tier，_apply_hd_layout 钩子生成 CityGen plan 注入
##     3D 场景（新增城邦 = 新增注册条目，零新场景文件）。
##   - 村民闲逛锚 town_center_world_x（街中心 = 出生点）。
##
## 资源图/战场图（Hd2dResourceMap/Hd2dBattlefieldMap）直接继承 Hd2dMapBase
## 侧的公共机制，仅覆写密度/行走带/出口等参数——不经本类。

## 初始城市档（CityGen 八档链键名）：默认 townlet（主街/村B 同口径——创始人
## "东西稍全、工区两三栋"）。八城薄实例按 city_profiles.json 的 size 各自设定；
## 城市规模只是建筑数量问题——扩建=换档重生成
@export var city_tier: String = "townlet"

## 布局驱动模式（city_layout 算法村）：非空时 3D 场景按
## tex/hd2d_layouts/<名>.json 摆街；空 = 手摆主街。村B 等算法村用。
@export var layout_name: String = ""

## 村民闲逛锚（ai_controller.wander 用；街中心 = 出生点）
var town_center_world_x: float = 0.0

## ── map_id → 参数解析（共享壳收敛）───────────────────────────────────
## 布局驱动图（主街/村B/L1 聚落）共用一张参数壳场景（hd2d_layout_map.tscn），
## 实例差异只剩参数：SceneLoader 实例化时写入 META_MAP_ID，_ready 在搭 3D
## 街景前按下面两条规则推导 layout_name / city_tier。新增城邦 = 新增注册
## 条目（map_id），零新场景文件。
##   规则一：l1_settlement_<整数>（聚落模式）→ layout_name = map_id
##     （兼作 CityGen 确定性种子），city_tier 查 SETTLEMENT_TIERS。
##   规则二：DIRECT_LAYOUT_MAP_IDS（手摆/算法布局图）→ layout_name = map_id。
##   其余 map_id（战场等特化子类图）不匹配 → 不写参数，保留 tscn 自带值。
## 聚落档位表。数据源 tools/worldgen/l1/city_profiles.json 的
## cities.<map_id>.size（T2 镇 00/06，其余 city；该文件在仓库根 tools/，
## res:// 之外运行时不可读，故落为代码常量——改档两处须同步）。
const SETTLEMENT_TIERS := {
	"l1_settlement_00": "town",
	"l1_settlement_01": "city",
	"l1_settlement_02": "city",
	"l1_settlement_03": "city",
	"l1_settlement_04": "city",
	"l1_settlement_05": "city",
	"l1_settlement_06": "town",
	"l1_settlement_07": "city",
}
## 聚落查表缺失时的安全默认档（镇级；CityGen 内部对未知档兜底 townlet，
## 本表缺失意味着新城邦还没登记 profile，给中间小档比给大城安全）
const DEFAULT_SETTLEMENT_TIER := "town"
## 直接以 map_id 作布局名的非聚落布局图（主街手摆布局 / 村B 算法布局）
const DIRECT_LAYOUT_MAP_IDS: PackedStringArray = ["hd2d_street", "village_b"]
const _SETTLEMENT_PREFIX := "l1_settlement_"


## 按注入的 map_id 解析壳参数（基类 _ready 开头经 _apply_map_params 钩子
## 调用，先于 3D 场景搭建）。
## 无 meta（未经 SceneLoader 的直接实例化，如编辑器预览）不动参数。
func _apply_params_from_map_id() -> void:
	if not has_meta(WorldAPI.META_MAP_ID):
		return
	var mid: String = str(get_meta(WorldAPI.META_MAP_ID))
	var is_settlement: bool = mid.begins_with(_SETTLEMENT_PREFIX) \
			and mid.substr(_SETTLEMENT_PREFIX.length()).is_valid_int()
	if is_settlement:
		layout_name = mid
		city_tier = str(SETTLEMENT_TIERS.get(mid, DEFAULT_SETTLEMENT_TIER))
	elif mid in DIRECT_LAYOUT_MAP_IDS:
		layout_name = mid


func _apply_map_params() -> void:
	_apply_params_from_map_id()


func _apply_hd_layout(hd: Node3D) -> void:
	if layout_name.is_empty():
		return
	hd.set("layout_name", layout_name)
	# 城市生成时机（创始人 2026-09-15：第一次进入该城市生成）——确定性
	# 种子（城名哈希）→ 多局尽量一致；同存档每次进图同城。城市扩建 =
	# 换档重生成（城墙自动前移，野地资源窗随之露出）
	var plan: Dictionary = CityGen.generate(city_tier, hash("city:" + layout_name), CityGen.prop_names())
	hd.set("layout_data", plan)


## 布局驱动模式：按布局街宽收地图边界（±半宽 + 8 格余量），覆盖 tscn 默认值。
func _apply_hd_bounds() -> void:
	if layout_name.is_empty() or _hd == null or not _hd.has_method("get_layout_width"):
		return
	var w: float = _hd.get_layout_width()
	if w <= 0.0:
		return
	# 墙外只留半屏（≈30 格）野地带——创始人口径：可以走出城墙，但墙外就
	# 半屏距离；地图边界随布局宽度推导（城市扩建 → 墙前移 → 野地窗跟着挪）
	var half_px: float = (w * 0.5 + 30.0) * CELL_PX
	map_left = -half_px
	map_right = half_px
