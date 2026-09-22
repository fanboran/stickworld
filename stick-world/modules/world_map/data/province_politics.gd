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
##   2) 左右切省箭头按邻省**全局质心**判方位——用全局几何而不是 context 裁切后的局部
##      多边形，避免方位被裁切偏心带歪（局部多边形只用于画形状）。
##
## 侧表缺失（文件不在/解析失败）一律返回空结果，调用方各自回退旧口径
## （邻省回退灰底、箭头隐藏），不锁死视图。

const DATA_PATH := "res://config/strategic_map/l1_province_politics.json"

## 方位（pick_by_side 的 side 参数）
const SIDE_LEFT := -1
const SIDE_RIGHT := 1

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


## 方位选邻（纯函数，单测友好）：
## dirs = [[label:int, dir:Vector2], ...]（dir = 邻省相对本省的向量，尺度无关）
## side = SIDE_LEFT / SIDE_RIGHT：取**最朝该侧**的候选（评分 = 归一化 dir.x × side）。
## 同分取更近者；若全部候选都在另一侧，取"最不偏"的那个（箭头不留死位）。
## 无有效候选返回 0。
static func pick_by_side(dirs: Array, side: int) -> int:
	var best_label := 0
	var best_score := -INF
	var best_dist := INF
	for item in dirs:
		var pair := item as Array
		if pair == null or pair.size() < 2:
			continue
		var label := int(pair[0])
		var dir: Vector2 = pair[1]
		var dist := dir.length()
		if dist <= 0.0001:
			continue
		var score := (dir.x / dist) * float(side)
		var better := score > best_score + 0.0001
		if not better and absf(score - best_score) <= 0.0001:
			better = dist < best_dist
		if better:
			best_label = label
			best_score = score
			best_dist = dist
	return best_label
