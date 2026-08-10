extends Node
## 村落地形渲染系统 —— 草地纹理 / 城内遮罩 / 土路视觉。
##
## 职责：
## - 草地纹理应用（Stochastic Tiling Shader + 图片自动加载）
## - 城内/城外地形遮罩（shader city_color 参数）
## - 土路视觉（土黄色 Polygon2D 覆盖土路 cell 范围）
##
## 由 VillageMap._ready 挂载为 TerrainRenderer 子节点并调用 setup(root)，
## 地形类型数据（_terrain_types）由 VillageMap 持有。

## 草地纹理平铺尺寸（世界坐标 px，每 GRASS_TILE_SIZE 像素重复一次纹理）
const GRASS_TILE_SIZE: float = 512.0

var _root: Node2D = null


func setup(root: Node2D) -> void:
	_root = root


# ─────────────────────────────── 草地纹理 ────────────────────────────────
# 使用 assets/environment/grassland.jpeg 作为平铺草地纹理。
# 用 ShaderMaterial 实现 Stochastic Tiling（随机偏移+随机翻转，打破规则网格感）。

const _GRASS_SHADER_CODE: String = """
shader_type canvas_item;

uniform sampler2D tex : repeat_enable, filter_linear_mipmap;
uniform vec2 tile_size = vec2(512.0, 512.0);
uniform float jitter = 0.35;        // 随机偏移强度 (0=无偏移, 0.5=最大偏移)
uniform float color_jitter = 0.15;   // 明暗变化强度
uniform float noise_scale = 0.0006;  // 噪波频率（越小=色块越大）
uniform bool random_flip = true;     // 随机翻转
uniform float seam_blend = 0.2;      // 接缝过渡宽度（占格子比例）

// 阶段 F §5.7.3：城内/城外地形混合
uniform vec4 city_color = vec4(0.45, 0.38, 0.28, 1.0);  // 城内泥土色
uniform float city_left_x = -99999.0;   // 城内左边界（世界坐标）
uniform float city_right_x = -99999.0;  // 城内右边界（世界坐标）
uniform float city_fade = 320.0;        // 过渡带宽度（10 格 = 320px）

// 传递顶点局部坐标（= 世界坐标）到 fragment，避免 fragment 中 VERTEX 是视空间导致贴图不跟随世界
varying vec2 world_pos;

// 2D hash -> [0,1]
float hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

// 2D value noise（平滑连续噪波，覆盖整个地面）
float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f); // smoothstep 插值
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 分形布朗运动（多频叠加，更自然）
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * value_noise(p);
		p *= 2.0;
		a *= 0.5;
	}
	return v;
}

// 格子内到最近边缘的距离 [0, 0.5]
float edge_dist(vec2 local_uv) {
	return min(min(local_uv.x, 1.0 - local_uv.x), min(local_uv.y, 1.0 - local_uv.y));
}

// 计算单个格子的随机采样 UV
vec2 stochastic_uv(vec2 cell, vec2 local_uv, float seed) {
	vec2 offset = vec2(hash21(cell + seed), hash21(cell + seed + 1.0)) * jitter;
	vec2 uv = local_uv;
	if (random_flip) {
		if (hash21(cell + seed + 2.0) > 0.5) uv.x = 1.0 - uv.x;
		if (hash21(cell + seed + 3.0) > 0.5) uv.y = 1.0 - uv.y;
	}
	return fract(uv + offset);
}

void vertex() {
	// MODEL_MATRIX 把局部顶点变换到世界坐标，兼容 Polygon2D 的 position 偏移
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 pos = world_pos / tile_size;

	// Layer 1: 原始网格
	vec2 cell1 = floor(pos);
	vec2 luv1 = fract(pos);
	vec4 c1 = texture(tex, stochastic_uv(cell1, luv1, 0.0));

	// Layer 2: 网格偏移半格，接缝与 Layer 1 错开
	vec2 pos2 = pos + 0.5;
	vec2 cell2 = floor(pos2);
	vec2 luv2 = fract(pos2);
	vec4 c2 = texture(tex, stochastic_uv(cell2, luv2, 10.0));

	// 按到边缘距离加权混合：一层在接缝处时另一层在格子中心
	float w1 = smoothstep(0.0, seam_blend, edge_dist(luv1));
	float w2 = smoothstep(0.0, seam_blend, edge_dist(luv2));
	COLOR = (c1 * w1 + c2 * w2) / (w1 + w2);

	// 连续噪波控制整体明暗（平滑过渡，不按格子）
	float n = fbm(world_pos * noise_scale);
	float tint = 1.0 + (n - 0.5) * 2.0 * color_jitter;
	COLOR.rgb *= tint;

	// 阶段 F §5.7.3：城内/城外地形混合
	float city_factor = smoothstep(city_left_x - city_fade, city_left_x + city_fade, world_pos.x)
		* (1.0 - smoothstep(city_right_x - city_fade, city_right_x + city_fade, world_pos.x));
	COLOR = mix(COLOR, city_color, city_factor * 1.0);
}
"""


## 应用草地纹理到 GroundPolygon（Stochastic Tiling ShaderMaterial）。
func apply_grass_texture() -> void:
	if _root.terrain_layer == null:
		push_warning("[VillageMap] terrain_layer 为空，跳过草地材质")
		return
	var gp: Polygon2D = _root.terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null:
		push_warning("[VillageMap] GroundPolygon 不存在，跳过草地材质")
		return
	# 自动查找 assets/environment/ 下以 grassland 开头的图片文件
	var img_path := _find_grass_texture()
	if img_path.is_empty():
		push_warning("[VillageMap] 未找到草地纹理文件")
		return
	# 按文件头检测真实格式加载（避免扩展名与实际格式不匹配）
	var img := _load_image_auto(img_path)
	if img == null:
		push_warning("[VillageMap] 草地图片加载失败: " + img_path)
		return
	var tex := ImageTexture.create_from_image(img)
	gp.texture = tex
	# 重置设计时可能存在的 position 偏移，确保 shader 世界坐标与地面边界一致
	gp.position = Vector2.ZERO
	# 用 ShaderMaterial 的 repeat_enable 强制平铺，shader 内用世界坐标计算 UV
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = _GRASS_SHADER_CODE
	mat.set_shader_parameter("tex", tex)
	mat.set_shader_parameter("tile_size", Vector2(GRASS_TILE_SIZE, GRASS_TILE_SIZE))
	gp.material = mat
	# 土路颜色（city_color）：土黄色，覆盖草地显示硬化路面
	mat.set_shader_parameter("city_color", Color(0.62, 0.50, 0.32, 1.0))
	# 土路硬边界（1px 过渡避免 smoothstep 退化）
	mat.set_shader_parameter("city_fade", 1.0)
	# 纹理颜色不需要 color 调色，设为白色避免叠加
	gp.color = Color.WHITE


## 阶段 F §5.7.3：设置城内范围（世界坐标），更新地形遮罩 Shader 参数。
## 城墙建造时调用此方法标记城内区域。
func set_city_bounds(left_x: float, right_x: float) -> void:
	if _root.terrain_layer == null:
		return
	var gp: Polygon2D = _root.terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null or gp.material == null:
		return
	gp.material.set_shader_parameter("city_left_x", left_x)
	gp.material.set_shader_parameter("city_right_x", right_x)


## 阶段 F：根据城墙建筑列表自动计算城内范围并更新地形遮罩。
## city_walls: Array of {cell_x, width}，取最左和最右城墙作为城内边界。
func update_terrain_mask_from_walls(city_walls: Array) -> void:
	if city_walls.is_empty():
		return
	var min_x: float = INF
	var max_x: float = -INF
	for wall in city_walls:
		if wall is Dictionary:
			var cx: int = wall.get("cell_x", 0)
			var w: int = wall.get("width", 1)
			var left_x: float = cx * PlacementGrid.CELL_SIZE
			var right_x: float = (cx + w) * PlacementGrid.CELL_SIZE
			min_x = min(min_x, left_x)
			max_x = max(max_x, right_x)
	if min_x != INF and max_x != -INF:
		set_city_bounds(min_x, max_x)


## 更新土路视觉：用土黄色 Polygon2D 覆盖土路 cell 范围的地面区域。
func update_dirt_road_visual() -> void:
	if _root.terrain_layer == null:
		return
	var min_cell: int = -1
	var max_cell: int = -1
	for cx: int in _root._terrain_types.keys():
		if _root._terrain_types[cx] == _root.TERRAIN_DIRT_ROAD:
			if min_cell < 0 or cx < min_cell:
				min_cell = cx
			if cx > max_cell:
				max_cell = cx
	if min_cell < 0:
		return  # 无土路
	if _root._dirt_road_poly == null:
		_root._dirt_road_poly = Polygon2D.new()
		_root._dirt_road_poly.color = Color(0.62, 0.50, 0.32, 1.0)  # 土黄色
		# z=1（decoration 层）：低于建筑（BuildingHost z=2），否则路面盖住建筑画面
		_root._dirt_road_poly.z_index = 1
		_root.add_child(_root._dirt_road_poly)
	var x0: float = float(min_cell) * PlacementGrid.CELL_SIZE
	var x1: float = float(max_cell + 1) * PlacementGrid.CELL_SIZE
	_root._dirt_road_poly.polygon = PackedVector2Array([
		Vector2(x0, _root.ground_y), Vector2(x1, _root.ground_y),
		Vector2(x1, _root.ground_bottom), Vector2(x0, _root.ground_bottom),
	])


## 获取城内左边界（从 Shader 参数读）
func get_city_left_x() -> float:
	if _root.terrain_layer == null:
		return -99999.0
	var gp: Polygon2D = _root.terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null or gp.material == null:
		return -99999.0
	var v = gp.material.get_shader_parameter("city_left_x")
	if v == null:
		return -99999.0
	return float(v)


## 获取城内右边界
func get_city_right_x() -> float:
	if _root.terrain_layer == null:
		return -99999.0
	var gp: Polygon2D = _root.terrain_layer.get_node_or_null("GroundPolygon")
	if gp == null or gp.material == null:
		return -99999.0
	var v = gp.material.get_shader_parameter("city_right_x")
	if v == null:
		return -99999.0
	return float(v)


# ─────────────────────────────── 纹理文件查找与加载 ────────────────────────────────

## 在 assets/environment/ 目录下查找 grassland 开头的图片文件，返回绝对路径
func _find_grass_texture() -> String:
	var dir_path := "res://assets/environment"
	var abs_dir := ProjectSettings.globalize_path(dir_path)
	var dir := DirAccess.open(abs_dir)
	if dir == null:
		return ""
	var exts := [".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga"]
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir():
			var lower := file_name.to_lower()
			if lower.begins_with("grassland"):
				for ext in exts:
					if lower.ends_with(ext):
						return abs_dir + "/" + file_name
		file_name = dir.get_next()
	dir.list_dir_end()
	return ""


## 按文件头检测真实图片格式并加载（不依赖文件扩展名）
func _load_image_auto(path: String) -> Image:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var buf := file.get_buffer(file.get_length())
	file.close()
	if buf.size() < 4:
		return null
	var img := Image.new()
	var err: int = ERR_FILE_UNRECOGNIZED
	# JPEG: FF D8 FF
	if buf[0] == 0xFF and buf[1] == 0xD8 and buf[2] == 0xFF:
		err = img.load_jpg_from_buffer(buf)
	# PNG: 89 50 4E 47
	elif buf[0] == 0x89 and buf[1] == 0x50 and buf[2] == 0x4E and buf[3] == 0x47:
		err = img.load_png_from_buffer(buf)
	# WebP: 52 49 46 46
	elif buf.size() >= 12 and buf[0] == 0x52 and buf[1] == 0x49 and buf[2] == 0x46 and buf[3] == 0x46:
		err = img.load_webp_from_buffer(buf)
	if err == OK:
		return img
	return null
