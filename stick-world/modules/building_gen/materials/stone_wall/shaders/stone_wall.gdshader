shader_type canvas_item;

// 石墙材质配方：从规整砖块开始，逐步加入变化、体积、划痕、缝隙细节

// ── 全局分辨率 ──
uniform vec2 resolution = vec2(512.0, 512.0);

// ── 砖块基础尺寸（像素） ──
uniform vec2 brick_size = vec2(100.0, 70.0);
// 缝隙尺寸（像素）
uniform vec2 gap_size = vec2(4.0, 4.0);

// ── 砖块变化 ──
// 长度随机范围（相对 brick_size.x 的比例）
uniform float length_var = 0.18;
// 高度随机范围（相对 brick_size.y 的比例）
uniform float height_var = 0.12;
// 位置抖动（像素）
uniform vec2 position_jitter = vec2(2.0, 2.0);
// 行高整体波动
uniform float row_height_var = 0.06;

// ── 形状 ──
// 圆角半径（像素）
uniform float corner_radius = 5.0;
// 四个角圆角差异（相对 corner_radius 的比例）
uniform float corner_radius_var = 0.4;
// 边缘波浪幅度（像素），让石头轮廓有手绘起伏
uniform float edge_wave = 0.8;
// 边缘不规则程度（像素）
uniform float edge_roughness = 2.0;
// 油画笔触边缘缩放
uniform float oil_scale = 0.18;
// 切角触发概率
uniform float corner_cut_chance = 0.25;
// 切角深度（像素）
uniform float corner_cut_amount = 8.0;
// 裂纹触发概率
uniform float crack_chance = 0.15;
// 裂纹宽度
uniform float crack_width = 1.0;
// 裂纹不透明度
uniform float crack_opacity = 0.4;

// ── 颜色 ──
uniform vec3 color_light : source_color = vec3(0.930, 0.900, 0.830);
uniform vec3 color_mid : source_color = vec3(0.820, 0.780, 0.700);
uniform vec3 color_dark : source_color = vec3(0.580, 0.520, 0.440);
uniform vec3 color_mortar : source_color = vec3(0.380, 0.340, 0.300);

// 每块石头颜色随机变化幅度
uniform float color_var = 0.08;
// 色块混合柔和度（0=硬切，1=柔和）
uniform float color_block_blend = 0.42;
// 主光源方向（默认左上）
uniform vec2 light_dir = vec2(-1.0, -1.0);

// ── 表面细节 ──
// 划痕数量（每块石头）
uniform int scratch_count = 2;
uniform float scratch_width = 1.4;
uniform float scratch_opacity = 0.4;
// 风化污渍强度
uniform float stain_amount = 0.14;

// ── 缝隙细节 ──
// mortar 颜色深浅变化
uniform float mortar_var = 0.1;
// 缝隙内暗边强度
uniform float mortar_shadow = 0.55;

// ── 随机种子 ──
uniform int seed = 0;

// ── 调试 ──
uniform bool show_grid = false;

#include "res://modules/building_gen/shaders/lib/stone_lib.gdshaderinc"


void fragment() {
	// 1. 像素坐标
	vec2 p = UV * resolution;

	// 2. 计算砖块 cell
	vec2 cell_size = brick_size + gap_size;
	// 行号
	int row = int(floor(p.y / cell_size.y));
	// 工字缝：奇数行偏移半个 cell
	float row_phase = float(row % 2) * cell_size.x * 0.5;
	// 列号
	int col = int(floor((p.x + row_phase) / cell_size.x));

	// 当前 cell 的原点（左上角）
	vec2 cell_origin = vec2(float(col) * cell_size.x - row_phase, float(row) * cell_size.y);
	// cell 内局部坐标
	vec2 local = p - cell_origin;

	// 3. 基于砖块 ID 的确定性随机
	vec2 hseed = vec2(float(col) * 73.0, float(row) * 37.0) + vec2(float(seed));
	float h_len = hash21(hseed);
	float h_hgt = hash21(hseed + 1.23);
	float h_jx = hash21(hseed + 2.34);
	float h_jy = hash21(hseed + 3.45);
	float h_col = hash21(hseed + 4.56);
	float h_rot = hash21(hseed + 5.67);
	float h_stain = hash21(hseed + 6.78);
	float h_crack = hash21(hseed + 7.89);
	float h_cut1 = hash21(hseed + 8.90);
	float h_cut2 = hash21(hseed + 9.01);
	float h_cut3 = hash21(hseed + 10.12);
	float h_cut4 = hash21(hseed + 11.23);
	float h_r1 = hash21(hseed + 12.34);
	float h_r2 = hash21(hseed + 13.45);
	float h_r3 = hash21(hseed + 14.56);
	float h_r4 = hash21(hseed + 15.67);
	float h_wave = hash21(hseed + 16.78);

	// 4. 当前砖块实际尺寸和中心位置
	float bw = brick_size.x * (1.0 + (h_len - 0.5) * length_var * 2.0);
	float bh = brick_size.y * (1.0 + (h_hgt - 0.5) * height_var * 2.0);
	// 行高整体波动
	bh *= 1.0 + sin(float(row) * 1.7 + float(seed)) * row_height_var;

	vec2 brick_center = vec2(
		cell_size.x * 0.5 + (h_jx - 0.5) * position_jitter.x,
		cell_size.y * 0.5 + (h_jy - 0.5) * position_jitter.y
	);

	// 5. 用 SDF 判断是否在砖块内（不规则石头轮廓）
	vec2 brick_local = local - brick_center;
	vec2 brick_half = vec2(bw, bh) * 0.5;

	// 5.1 四个角独立圆角
	vec4 radii = vec4(corner_radius);
	radii.x *= 1.0 + (h_r1 - 0.5) * corner_radius_var;
	radii.y *= 1.0 + (h_r2 - 0.5) * corner_radius_var;
	radii.z *= 1.0 + (h_r3 - 0.5) * corner_radius_var;
	radii.w *= 1.0 + (h_r4 - 0.5) * corner_radius_var;
	radii = max(radii, vec4(0.5));

	// 5.2 随机切角掩码
	vec4 cut_mask = vec4(
		(h_cut1 < corner_cut_chance) ? 1.0 : 0.0,
		(h_cut2 < corner_cut_chance) ? 1.0 : 0.0,
		(h_cut3 < corner_cut_chance) ? 1.0 : 0.0,
		(h_cut4 < corner_cut_chance) ? 1.0 : 0.0
	);

	// 5.3 不规则石头 SDF
	float dist = sl_sd_irregular_stone(
		brick_local, brick_half, radii,
		edge_wave, cut_mask, corner_cut_amount, vec2(h_wave, h_rot)
	);

	// 6. 油画笔触边缘粗糙化
	float rough_dist = sl_painterly_edge(p, dist, edge_roughness, oil_scale, hseed);

	// 7. 颜色计算
	vec3 out_col;
	float alpha = 1.0;

	if (rough_dist < 0.0) {
		// 砖块内部
		// 7.1 三色块体积
		vec3 base_col = sl_stone_color_blocks(
			brick_local / (vec2(bw, bh) * 0.5),
			color_light, color_mid, color_dark,
			light_dir, color_block_blend
		);

		// 7.2 每块石头颜色随机偏移
		vec3 col_shift = vec3((h_col - 0.5) * color_var);
		col_shift += vec3((h_col - 0.5) * color_var * 0.3, 0.0, -(h_col - 0.5) * color_var * 0.2);
		out_col = clamp(base_col + col_shift, 0.0, 1.0);

		// 7.3 划痕
		for (int i = 0; i < 4; i++) {
			if (i >= scratch_count) break;
			vec2 hs = hseed + vec2(float(i) * 9.0, float(i) * 13.0);
			float a = hash21(hs) * 6.2831853;
			float l = (0.2 + hash21(hs + 1.0) * 0.6) * min(bw, bh) * 0.5;
			vec2 dir = vec2(cos(a), sin(a));
			vec2 mid = brick_local + dir * l * 0.2;
			vec2 start = mid - dir * l * 0.5;
			vec2 end = mid + dir * l * 0.5;
			float sc = sl_scratch_line(brick_local, start, end, scratch_width);
			// 划痕颜色比暗面再深一点
			vec3 scratch_col = color_dark * 0.7;
			out_col = mix(out_col, scratch_col, sc * scratch_opacity);
		}

		// 7.4 裂纹（折线，比划痕更深更长）
		if (h_crack < crack_chance) {
			vec2 hs = hseed + vec2(19.0, 23.0);
			float a1 = hash21(hs) * 6.2831853;
			float a2 = hash21(hs + 1.0) * 6.2831853;
			float l = (0.3 + hash21(hs + 2.0) * 0.5) * min(bw, bh) * 0.55;
			vec2 kink = vec2(cos(a2), sin(a2)) * l * 0.35;
			vec2 dir = vec2(cos(a1), sin(a1));
			vec2 mid = brick_local * 0.3 + kink;
			vec2 start = mid - dir * l * 0.5;
			vec2 end = mid + dir * l * 0.5;
			vec2 bend = mid + kink * 0.6;
			float cr = sl_crack_line(brick_local, start, bend, end, crack_width);
			out_col = mix(out_col, color_dark * 0.55, cr * crack_opacity);
		}

		// 7.5 风化污渍
		float stain = sl_value_noise(brick_local * 0.08 + hseed) * stain_amount;
		out_col = mix(out_col, color_mortar * 0.8, stain * h_stain);

	} else {
		// 缝隙区域
		// 8.1 mortar 基色 + 随机深浅
		float mv = hash21(hseed + 7.89) - 0.5;
		out_col = color_mortar * (1.0 + mv * mortar_var);

		// 8.2 缝隙内暗边：越靠近砖块边缘越深
		float shadow = smoothstep(gap_size.x * 0.8, 0.0, rough_dist);
		out_col *= 1.0 - shadow * mortar_shadow;
	}

	// 9. 调试网格
	if (show_grid) {
		vec2 grid = fract(local / cell_size);
		if (grid.x < 0.02 || grid.y < 0.02) {
			out_col = vec3(1.0, 0.0, 0.0);
		}
	}

	COLOR = vec4(out_col, alpha);
}
