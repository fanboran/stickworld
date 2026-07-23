// 程序化材质系统 / 石头类材质共享 Shader 原语
// 提供砖块 SDF、工字缝、石头体积色块、划痕、油画边缘等基础函数

#ifndef STONE_LIB_GDSHADERINC
#define STONE_LIB_GDSHADERINC

#include "res://modules/building_gen/shaders/lib/hash.gdshaderinc"

// ── SDF 原语 ──

// 圆角矩形 SDF
float sl_sd_rounded_box(vec2 sl_pos, vec2 sl_half_size, float sl_radius) {
	vec2 sl_d = abs(sl_pos) - sl_half_size + vec2(sl_radius);
	return min(max(sl_d.x, sl_d.y), 0.0) + length(max(sl_d, 0.0)) - sl_radius;
}

// 线段 SDF
float sl_sd_segment(vec2 sl_pos, vec2 sl_a, vec2 sl_b) {
	vec2 sl_pa = sl_pos - sl_a;
	vec2 sl_ba = sl_b - sl_a;
	float sl_h = clamp(dot(sl_pa, sl_ba) / dot(sl_ba, sl_ba), 0.0, 1.0);
	return length(sl_pa - sl_ba * sl_h);
}

// 圆 SDF
float sl_sd_circle(vec2 sl_pos, float sl_radius) {
	return length(sl_pos) - sl_radius;
}

// 四个角可独立圆角的矩形 SDF
// sl_radii: x=左上, y=右上, z=左下, w=右下
float sl_sd_rounded_box_4r(vec2 sl_pos, vec2 sl_half_size, vec4 sl_radii) {
	vec2 sl_r;
	sl_r.x = (sl_pos.x > 0.0) ? sl_radii.y : sl_radii.x;
	sl_r.y = (sl_pos.x > 0.0) ? sl_radii.w : sl_radii.z;
	sl_r.x  = (sl_pos.y > 0.0) ? sl_r.y : sl_r.x;
	vec2 sl_d = abs(sl_pos) - sl_half_size + sl_r.x;
	return min(max(sl_d.x, sl_d.y), 0.0) + length(max(sl_d, 0.0)) - sl_r.x;
}

// 单角切口平面 SDF（用于切掉矩形角落）
// sl_q: 转换后的局部坐标，目标角落在原点，砖块占据第一象限
// sl_cut: 切口深度
float sl_sd_corner_cut_plane(vec2 sl_q, float sl_cut) {
	return sl_q.x + sl_q.y - sl_cut;
}

// 将矩形局部坐标转换到指定角落的第一象限坐标
// sl_pos: 砖块局部坐标（中心为0）
// sl_half_size: 砖块半尺寸
// sl_corner: 0=左上, 1=右上, 2=左下, 3=右下
vec2 sl_corner_local(vec2 sl_pos, vec2 sl_half_size, int sl_corner) {
	if (sl_corner == 0) return vec2(-sl_pos.x - sl_half_size.x, -sl_pos.y - sl_half_size.y);
	if (sl_corner == 1) return vec2( sl_pos.x - sl_half_size.x, -sl_pos.y - sl_half_size.y);
	if (sl_corner == 2) return vec2(-sl_pos.x - sl_half_size.x,  sl_pos.y - sl_half_size.y);
	return vec2(sl_pos.x - sl_half_size.x, sl_pos.y - sl_half_size.y);
}

// 不规则石头轮廓：4 个独立圆角 + 边缘波浪 + 随机切角
// sl_cut_mask: 4 个分量分别控制 4 个角是否切口（0 或 1）
float sl_sd_irregular_stone(
	vec2 sl_pos, vec2 sl_half_size, vec4 sl_radii,
	float sl_edge_wave, vec4 sl_cut_mask, float sl_cut_amount, vec2 sl_seed
) {
	float sl_d = sl_sd_rounded_box_4r(sl_pos, sl_half_size, sl_radii);

	// 边缘波浪：沿轮廓的低频起伏，模拟手绘不规则边缘
	float sl_wave = sin(sl_pos.x * 0.65 + sl_seed.x * 6.2831853)
	              + cos(sl_pos.y * 0.50 + sl_seed.y * 6.2831853) * 0.7;
	sl_d += sl_wave * sl_edge_wave;

	// 随机切角：用平面切掉选中角落
	for (int sl_i = 0; sl_i < 4; sl_i++) {
		if (sl_cut_mask[sl_i] < 0.5) continue;
		vec2 sl_q = sl_corner_local(sl_pos, sl_half_size, sl_i);
		float sl_cut_dist = sl_sd_corner_cut_plane(sl_q, sl_cut_amount);
		sl_d = max(sl_d, sl_cut_dist);
	}

	return sl_d;
}

// ── 砖块与缝隙 ──

// 将全局 UV 转换为砖块坐标系
// sl_b_size: 单块砖在 UV 空间的尺寸
// sl_g_size: 缝隙在 UV 空间的尺寸
// 返回：局部坐标（中心为 0，砖块边界处约 ±sl_b_size/2）；id = 砖块行列号
vec2 sl_brick_local_and_id(vec2 sl_uv, vec2 sl_b_size, vec2 sl_g_size, out ivec2 sl_id) {
	vec2 sl_cell_size = sl_b_size + sl_g_size;
	sl_id.y = int(floor(sl_uv.y / sl_cell_size.y));
	float sl_row_phase = float(sl_id.y % 2) * sl_cell_size.x * 0.5;
	sl_id.x = int(floor((sl_uv.x + sl_row_phase) / sl_cell_size.x));
	vec2 sl_local;
	sl_local.x = sl_uv.x - float(sl_id.x) * sl_cell_size.x + sl_row_phase;
	sl_local.y = sl_uv.y - float(sl_id.y) * sl_cell_size.y;
	sl_local -= sl_b_size * 0.5;
	return sl_local;
}

// 从 UV 计算砖块 ID
ivec2 sl_brick_id(vec2 sl_uv, vec2 sl_b_size, vec2 sl_g_size) {
	vec2 sl_cell_size = sl_b_size + sl_g_size;
	int sl_row = int(floor(sl_uv.y / sl_cell_size.y));
	float sl_row_phase = float(sl_row % 2) * sl_cell_size.x * 0.5;
	int sl_col = int(floor((sl_uv.x + sl_row_phase) / sl_cell_size.x));
	return ivec2(sl_col, sl_row);
}

// 工字缝（running bond）行偏移系数
float sl_running_bond_phase(int sl_row) {
	return float(sl_row % 2) * 0.5;
}

// ── 颜色与体积 ──

// 单块石头的亮/中/暗三色分布
vec3 sl_stone_color_blocks(vec2 sl_local, vec3 sl_light, vec3 sl_mid, vec3 sl_dark, vec2 sl_lit_dir, float sl_blend) {
	float sl_lit = dot(normalize(sl_local), normalize(sl_lit_dir));
	sl_lit = smoothstep(-1.0, 1.0, sl_lit);
	vec3 sl_base = mix(sl_dark, sl_light, sl_lit);
	float sl_mid_weight = 1.0 - abs(sl_lit - 0.5) * 2.0 * (1.0 - sl_blend);
	sl_mid_weight = clamp(sl_mid_weight, 0.0, 1.0);
	return mix(sl_base, sl_mid, sl_mid_weight);
}

// 给颜色添加手绘风格的随机扰动
vec3 sl_painterly_color_shift(vec3 sl_base_col, vec2 sl_pos, float sl_shift_amount, vec2 sl_noise_seed) {
	float sl_n = hash21(sl_pos * 50.0 + sl_noise_seed);
	vec3 sl_shift = vec3((sl_n - 0.5) * sl_shift_amount);
	return clamp(sl_base_col + sl_shift, 0.0, 1.0);
}

// ── 边缘与划痕 ──

// 油画笔触边缘粗糙化
float sl_painterly_edge(vec2 sl_pos, float sl_d, float sl_roughness, float sl_noise_scale, vec2 sl_noise_seed) {
	float sl_n1 = hash21(sl_pos * sl_noise_scale + sl_noise_seed);
	float sl_n2 = hash21(sl_pos * sl_noise_scale * 2.3 + sl_noise_seed + 31.0);
	float sl_noise = sl_n1 * 0.7 + sl_n2 * 0.3;
	return sl_d + (sl_noise - 0.5) * sl_roughness;
}

// 单条划痕（细线）
float sl_scratch_line(vec2 sl_pos, vec2 sl_a, vec2 sl_b, float sl_width) {
	float sl_d = sl_sd_segment(sl_pos, sl_a, sl_b);
	return 1.0 - smoothstep(sl_width * 0.2, sl_width, sl_d);
}

// 短裂纹：折线
float sl_crack_line(vec2 sl_pos, vec2 sl_a, vec2 sl_b, vec2 sl_c, float sl_width) {
	float sl_d1 = sl_sd_segment(sl_pos, sl_a, sl_b);
	float sl_d2 = sl_sd_segment(sl_pos, sl_b, sl_c);
	float sl_d = min(sl_d1, sl_d2);
	return 1.0 - smoothstep(sl_width * 0.2, sl_width, sl_d);
}

// ── 噪声 ──

// 2D 值噪声（低频，用于污渍/风化）
float sl_value_noise(vec2 sl_pos) {
	vec2 sl_i = floor(sl_pos);
	vec2 sl_f = fract(sl_pos);
	sl_f = sl_f * sl_f * (3.0 - 2.0 * sl_f);
	float sl_a = hash21(sl_i);
	float sl_b = hash21(sl_i + vec2(1.0, 0.0));
	float sl_c = hash21(sl_i + vec2(0.0, 1.0));
	float sl_d = hash21(sl_i + vec2(1.0, 1.0));
	return mix(mix(sl_a, sl_b, sl_f.x), mix(sl_c, sl_d, sl_f.x), sl_f.y);
}

#endif
