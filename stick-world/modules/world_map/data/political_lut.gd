class_name PoliticalLut
extends RefCounted
## 政权色 LUT（R7/R9 过渡态裁决：政权色运行时上色，零烘焙）。
##
## 生成端把 CONTENT_PALETTE 派生的 80 国色写进 political_data.json（states[].color
## + states[].lut_index），并产政权 ID mask（L3 一张 8192 单通道 PNG / L2 每地区
## 一张窗口裁切，像素值 = lut_index）。本类在运行时把 states 表构建成 256x1 LUT
## 纹理，供 political_mask_colorize.gdshader 逐像素查表上色——
## **改 LUT 数组（set_state_color）→ 所有引用本纹理的政治图层即时换色，零重烘**
## （R9 验收硬指标；shader 每帧采样该纹理，无缓存失效问题）。
##
## ID mask 保留码（与生成端 state_expand_lite.py 同源）：
##   0 = 海洋（mask 外真水域，shader 侧输出 empty_color）；253 = 自由城邦
##   （无归属陆地，feedback2 D 陆地洞修复）；254 = 湖泊；255 = 邻区灰底（仅 L2 mask）。

## mask 保留码：自由城邦（无归属陆地，L3/L2 mask 通用）
const CODE_FREE_CITY := 253
## L2 mask 保留码：湖泊（色值同 L2MapRenderer.LAKE_COLOR）
const CODE_LAKE := 254
## L2 mask 保留码：邻区灰底（色值同 L2MapRenderer.NEIGHBOR_COLOR 0.45 灰）
const CODE_NEIGHBOR := 255

## 自由城邦中性灰（feedback2 D 定值 [110,110,110]；与生成端预览 LUT 同值）
const FREE_CITY_COLOR := Color(110.0 / 255.0, 110.0 / 255.0, 110.0 / 255.0)
const LAKE_COLOR := Color(72.0 / 255.0, 116.0 / 255.0, 158.0 / 255.0)
## 0.45 灰的 8bit 精确表示（LUT 图像是 RGBA8，取 115/255 才能精确回读）
const NEIGHBOR_COLOR := Color(115.0 / 255.0, 115.0 / 255.0, 115.0 / 255.0)

## 查表上色 shader（L2/L3 政治模式共用）
const COLORIZE_SHADER := preload("res://modules/world_map/shaders/political_mask_colorize.gdshader")

## 数据源：l3_city.json（bin 优先）顶层 states（state_expand_lite 注入，与
## political_data.json 同表）
const STATES_DATA_PATH := "res://config/strategic_map/l3_city.json"

static var _shared: PoliticalLut = null

## 政权表（state_id -> info：name/culture/culture_label/color/lut_index/is_city_state/n_cities...）
var states: Dictionary = {}
## state_id -> lut_index（1..80）
var index_of: Dictionary = {}
## 256x1 RGBA8 色表图像（x = lut_index；0 透明；253/254/255 保留码）
var image: Image = null
## LUT 纹理（shader 采样；set_state_color 就地 update → 全图即时换色）
var texture: ImageTexture = null


## 取共享实例（首调时用给定 states 构建一次；后续调用忽略参数返回同一实例）。
## L2/L3 渲染器与 L1 图例都走这里，保证全游戏一份 LUT、改色全局生效。
## states 为空（数据缺失）返回 null 且不污染缓存，调用方回退旧口径。
static func shared_from_states(st: Dictionary) -> PoliticalLut:
	if _shared != null:
		return _shared
	if st.is_empty():
		return null
	_shared = PoliticalLut.new()
	_shared._build(st)
	return _shared


## 自行从 l3_city.json/bin 装载并构建共享实例（图例等无现成 states 的调用方用）。
## 数据缺失返回 null（调用方回退旧口径）。
static func load_shared() -> PoliticalLut:
	if _shared != null:
		return _shared
	var data := _read_data_dict(STATES_DATA_PATH)
	var st: Dictionary = data.get("states", {}) if data is Dictionary else {}
	if st.is_empty():
		return null
	return shared_from_states(st)


func _build(st: Dictionary) -> void:
	image = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	for sid in st:
		var info: Dictionary = st[sid]
		var idx := int(info.get("lut_index", 0))
		if idx <= 0 or idx >= 256:
			continue
		states[sid] = info
		index_of[sid] = idx
		var col: Array = info.get("color", [255, 0, 255])
		image.set_pixel(idx, 0, Color(
			float(col[0]) / 255.0, float(col[1]) / 255.0, float(col[2]) / 255.0, 1.0))
	# mask 保留码（自由城邦灰/湖泊/邻区灰底）
	image.set_pixel(CODE_FREE_CITY, 0, FREE_CITY_COLOR)
	image.set_pixel(CODE_LAKE, 0, LAKE_COLOR)
	image.set_pixel(CODE_NEIGHBOR, 0, NEIGHBOR_COLOR)
	texture = ImageTexture.create_from_image(image)


## 政权当前色（未知 sid 返回透明黑）
func color_of(sid: String) -> Color:
	var idx := int(index_of.get(sid, 0))
	if idx <= 0:
		return Color(0, 0, 0, 0)
	return image.get_pixel(idx, 0)


func state_info(sid: String) -> Dictionary:
	return states.get(sid, {})


## 运行时改色：更新 LUT 图像 + 就地刷纹理 → 所有政治图层（L2/L3/L1 图例色源）
## 即时换色，不重烘任何贴图（R9 验收硬指标的运行时链路）。
func set_state_color(sid: String, col: Color) -> void:
	var idx := int(index_of.get(sid, 0))
	if idx <= 0:
		return
	image.set_pixel(idx, 0, col)
	var info: Dictionary = states.get(sid, {})
	if info.has("color"):
		info["color"] = [int(round(col.r * 255.0)), int(round(col.g * 255.0)),
				int(round(col.b * 255.0))]
	if texture != null:
		texture.update(image)


## 读取 l*_city 数据：优先同名紧凑 bin（LWDB + var_to_bytes，与 L3WorldData 同机制），
## bin 缺失回退 JSON。只读顶层字段，不做 polygon 紧凑化。
static func _read_data_dict(json_path: String) -> Dictionary:
	var bin_path := json_path.get_basename() + ".bin"
	if FileAccess.file_exists(bin_path):
		var f := FileAccess.open(bin_path, FileAccess.READ)
		if f != null:
			var magic := f.get_buffer(4).get_string_from_ascii()
			if magic == "LWDB":
				f.get_16()  # ver
				var got: Variant = bytes_to_var(f.get_buffer(f.get_length()))
				if got is Dictionary:
					return got
	var jt := FileAccess.get_file_as_string(json_path)
	if jt.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(jt)
	return parsed if parsed is Dictionary else {}
