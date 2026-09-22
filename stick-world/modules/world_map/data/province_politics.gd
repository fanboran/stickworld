class_name ProvincePolitics
extends RefCounted
## 老 L1 省份政治面侧表（69 省 → 主导政权 + 全局质心）
##
## 数据源：`config/strategic_map/l1_province_politics.json`（worldgen 侧表，由
## `tools/worldgen/l1/export_province_politics.py` 从 l3_l1.json 多边形 ×
## l3_political_id_8192.png 众数采样产出）。**静态快照**：世界生成期的主导政权，
## 不随运行时占领变动（领土归属真值在 `WorldState.territories`，见出征与领地架构 §9.1）。
##
## 消费点（都在 L1 视图的"邻省上下文层"）：
##   1) 政治模式邻省色块按各自主导政权色**暗一阶**上色（地形照常透出），不再一律平灰；
##   2) 切省箭头环按邻省**全局质心**判方位——用全局几何而不是 context 裁切后的局部
##      多边形，避免方位被裁切偏心带歪（局部多边形只用于画形状）；
##   3) HUD「地区 L2」按钮的 L1→L2 反查（region 字段 = L3 地区 label，region_of）。
##
## 侧表缺失（文件不在/解析失败）一律返回空结果，调用方各自回退旧口径
## （邻省回退灰底、箭头隐藏），不锁死视图。

const DATA_PATH := "res://config/strategic_map/l1_province_politics.json"

## label(int) -> {state_id:String, name:String, lut_index:int, color:Color,
##                centroid:Vector2, area_px:int, region:int}
var provinces: Dictionary = {}

static var _shared: ProvincePolitics = null
## 加载失败记忆（避免每帧重试读盘）
static var _load_failed: bool = false


## 取共享实例（懒加载一次；文件缺失/解析失败返回 null 并记忆失败）
static func load_shared() -> ProvincePolitics:
	if _shared != null:
		return _shared
	if _load_failed:
		return null
	var f := FileAccess.open(DATA_PATH, FileAccess.READ)
	if f == null:
		_load_failed = true
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("provinces"):
		_load_failed = true
		return null
	var inst := ProvincePolitics.new()
	for key in (parsed as Dictionary)["provinces"]:
		var raw: Dictionary = (parsed as Dictionary)["provinces"][key]
		var label := int(String(key))
		var col: Array = raw.get("color", [110, 110, 110])
		var cen: Array = raw.get("centroid", [0.0, 0.0])
		inst.provinces[label] = {
			"state_id": str(raw.get("state_id", "")),
			"name": str(raw.get("name", "")),
			"lut_index": int(raw.get("lut_index", 0)),
			"color": Color(
				float(col[0]) / 255.0, float(col[1]) / 255.0, float(col[2]) / 255.0),
			"centroid": Vector2(float(cen[0]), float(cen[1])),
			"area_px": int(raw.get("area_px", 0)),
			"region": int(raw.get("region", 0)),
		}
	_shared = inst
	return _shared


## 测试/工具用：清掉共享缓存（换数据后强制重读）
static func reset_shared() -> void:
	_shared = null
	_load_failed = false


func has_label(label: int) -> bool:
	return provinces.has(label)


## 该省主导政权色（未知 label / 无政权返回透明黑——调用方按 a<=0 判"无"）
func color_of(label: int) -> Color:
	var info: Dictionary = provinces.get(label, {})
	return info.get("color", Color(0, 0, 0, 0))


## 该省主导政权名（未知/自由城邦返回空串）
func state_name_of(label: int) -> String:
	var info: Dictionary = provinces.get(label, {})
	return str(info.get("name", ""))


## 该省全局质心（8192 世界坐标；未知 label 返回 Vector2.INF）
func centroid_of(label: int) -> Vector2:
	var info: Dictionary = provinces.get(label, {})
	return info.get("centroid", Vector2.INF)


## 该省所属 L3 地区 label（1..13；未知/无地区返回 0）。
## 消费点：HUD「地区 L2」按钮的 L1→L2 反查（地区视图 id = region_%03d % region）。
func region_of(label: int) -> int:
	var info: Dictionary = provinces.get(label, {})
	return int(info.get("region", 0))
