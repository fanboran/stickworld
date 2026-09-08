// 地面分带材质 —— 城镇生成管线批次 3（tools/worldgen/l1 产物 tscn 消费）。
//
// 四个风格共用一套踩踏/噪波语言（与 terrain_renderer.gd 的草地 shader 同族，
// 保证城内硬地皮→分带过渡的视觉一致性）：
//   style 0 = 草皮带（城内其余地面：双绿 fbm 斑块 + 草叶碎光）
//   style 1 = 土路带（主街踩踏带：裸土 + 石子 + 车辙 + 路缘残草）
//   style 2 = 石板广场（市场周边：错缝石板 + 板间明暗 + 磨损/填土板）
//   style 3 = 农田带（profile 开关：横向垄沟 + 垄上作物碎点，AI 提案·待定）
//
// 世界坐标驱动（MODEL_MATRIX），任意相机缩放/偏移下纹理钉在世界上。
// 矩形边缘按 edge_soft 羽化出参差边界（草从带边长回来）。
shader_type canvas_item;

uniform int style = 0; // 0=草皮 1=土路 2=石板 3=农田
uniform vec4 base_color : source_color = vec4(0.33, 0.44, 0.21, 1.0);
uniform vec4 alt_color : source_color = vec4(0.27, 0.38, 0.18, 1.0);
uniform vec4 seam_color : source_color = vec4(0.43, 0.39, 0.32, 1.0);  // 浅缝（明度差小=铺装非砌块）
uniform float seed_off = 0.0;
uniform float rect_l = -99999.0; // 分带矩形（世界坐标，边缘羽化窗）
uniform float rect_t = -99999.0;
uniform float rect_r = 99999.0;
uniform float rect_b = 99999.0;
uniform float edge_soft = 34.0;

varying vec2 world_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(443.897, 441.423));
	p += dot(p, p.yx + 19.19);
	return fract((p.x + p.y) * p.x);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

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

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

vec3 turf_col(vec2 p) {
	float n = fbm(p * 0.013 + seed_off);
	vec3 c = mix(base_color.rgb, alt_color.rgb, smoothstep(0.25, 0.85, n));
	float fleck = hash21(floor(p * 0.9) + seed_off);
	c += vec3(0.05, 0.07, 0.02) * step(0.93, fleck);
	c *= 0.90 + fbm(p * 0.002 + seed_off * 2.0) * 0.25;
	return c;
}

vec3 road_col(vec2 p) {
	float tread = fbm(p * vec2(0.012, 0.024) + seed_off);
	vec3 c = base_color.rgb * (0.86 + tread * 0.22);
	float pebble = hash21(floor(p * 0.55) + seed_off);
	c *= 1.0 + (pebble - 0.5) * 0.20 * step(0.68, pebble);
	float mid = (rect_t + rect_b) * 0.5;
	float span = max(rect_b - rect_t, 1.0);
	float ry1 = mid - span * 0.16 + sin(p.x * 0.004 + seed_off) * 12.0;
	float ry2 = mid + span * 0.16 + sin(p.x * 0.004 + 2.1) * 12.0;
	float ruts = (1.0 - smoothstep(6.0, 20.0, abs(p.y - ry1)))
		+ (1.0 - smoothstep(6.0, 20.0, abs(p.y - ry2)));
	c *= 1.0 - clamp(ruts, 0.0, 1.0) * 0.16;
	float ey = min(p.y - rect_t, rect_b - p.y);
	c = mix(c, vec3(0.30, 0.42, 0.20), (1.0 - smoothstep(0.0, 26.0, ey)) * 0.5);
	return c;
}

vec3 stone_col(vec2 p) {
	float slab_w = 34.0;  // 细板（大块砖读感偏"砌块墙"）
	float slab_h = 17.0;
	float row = floor(p.y / slab_h);
	float sx = (p.x + mod(row, 2.0) * slab_w * 0.5) / slab_w;
	vec2 cell = vec2(floor(sx), row);
	vec2 f = vec2(fract(sx), fract(p.y / slab_h));
	vec3 c = mix(base_color.rgb, alt_color.rgb, hash21(cell + seed_off));
	c *= 0.94 + hash21(cell * 1.7 + seed_off + 3.0) * 0.10;
	float bd = min(min(f.x, 1.0 - f.x) * slab_w, min(f.y, 1.0 - f.y) * slab_h);
	c = mix(c, seam_color.rgb, (1.0 - smoothstep(1.0, 2.4, bd)) * 0.38);
	c *= 0.92 + fbm(p * 0.008 + seed_off) * 0.16;
	float dirt_slab = step(0.94, hash21(cell + seed_off + 7.0));
	c = mix(c, vec3(0.45, 0.38, 0.28), dirt_slab * 0.45);
	return c;
}

vec3 farmland_col(vec2 p) {
	float row_w = 17.0;
	float wob = (fbm(vec2(p.x * 0.01, p.y * 0.03) + seed_off) - 0.5) * 6.0;
	float u = (p.y + wob) / row_w;
	float ridge = abs(fract(u) - 0.5) * 2.0;
	vec3 soil = base_color.rgb * (0.90 + hash21(vec2(floor(p.x * 0.2), floor(u))) * 0.20);
	vec3 crop = alt_color.rgb * (0.90 + hash21(floor(p * 0.8) + seed_off) * 0.30);
	vec3 c = mix(soil, crop, smoothstep(0.45, 0.8, ridge) * 0.85);
	float sp = hash21(floor(p * 1.1) + seed_off + 5.0);
	c += vec3(0.04, 0.08, 0.02) * step(0.9, sp) * smoothstep(0.4, 0.8, ridge);
	return c;
}

void fragment() {
	vec3 col;
	if (style == 2) {
		col = stone_col(world_pos);
	} else if (style == 1) {
		col = road_col(world_pos);
	} else if (style == 3) {
		col = farmland_col(world_pos);
	} else {
		col = turf_col(world_pos);
	}
	float a = 1.0;
	if (edge_soft > 0.5) {
		float ex = min(world_pos.x - rect_l, rect_r - world_pos.x);
		float ey = min(world_pos.y - rect_t, rect_b - world_pos.y);
		a = smoothstep(0.0, edge_soft, ex) * smoothstep(0.0, edge_soft, ey);
	}
	COLOR = vec4(col, a);
}
