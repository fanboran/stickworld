shader_type canvas_item;

// 蓝灰石檐材质配方：上层浅色石墙 + 中层蓝灰石带 + 下垂滴水块

uniform vec2 resolution = vec2(512.0, 128.0);

// 砖块基础尺寸（像素）
uniform vec2 brick_size = vec2(80.0, 40.0);
uniform vec2 gap_size = vec2(4.0, 4.0);

// 浅色行数（石檐上方）
uniform int top_rows = 1;
// 蓝灰色行数
uniform int band_rows = 2;

// 砖块变化
uniform float length_var = 0.15;
uniform float height_var = 0.1;
uniform vec2 position_jitter = vec2(2.0, 1.5);
uniform float corner_radius = 5.0;
uniform float edge_roughness = 2.0;
uniform float oil_scale = 0.2;

// 浅色石墙配色
uniform vec3 top_color_light : source_color = vec3(0.930, 0.900, 0.830);
uniform vec3 top_color_mid : source_color = vec3(0.820, 0.780, 0.700);
uniform vec3 top_color_dark : source_color = vec3(0.580, 0.520, 0.440);

// 蓝灰色石带配色
uniform vec3 band_color_light : source_color = vec3(0.680, 0.710, 0.770);
uniform vec3 band_color_mid : source_color = vec3(0.540, 0.570, 0.630);
uniform vec3 band_color_dark : source_color = vec3(0.340, 0.370, 0.430);

uniform vec3 color_mortar : source_color = vec3(0.360, 0.330, 0.310);

uniform float color_var = 0.05;
uniform float color_block_blend = 0.5;
uniform vec2 light_dir = vec2(-1.0, -1.0);

// 滴水块
uniform float drip_chance = 0.45;
uniform float drip_length = 8.0;
uniform float drip_width = 18.0;
uniform float drip_var = 0.3;

uniform int seed = 0;

#include "res://modules/building_gen/shaders/lib/stone_lib.gdshaderinc"


void fragment() {
	vec2 p = UV * resolution;

	vec2 cell_size = brick_size + gap_size;
	int row = int(floor(p.y / cell_size.y));
	float row_phase = float(row % 2) * cell_size.x * 0.5;
	int col = int(floor((p.x + row_phase) / cell_size.x));

	vec2 cell_origin = vec2(float(col) * cell_size.x - row_phase, float(row) * cell_size.y);
	vec2 local = p - cell_origin;

	vec2 hseed = vec2(float(col) * 73.0, float(row) * 37.0) + vec2(float(seed));
	float h_len = hash21(hseed);
	float h_hgt = hash21(hseed + 1.23);
	float h_jx = hash21(hseed + 2.34);
	float h_jy = hash21(hseed + 3.45);
	float h_col = hash21(hseed + 4.56);
	float h_drip = hash21(hseed + 5.67);
	float h_drip_len = hash21(hseed + 6.78);

	float bw = brick_size.x * (1.0 + (h_len - 0.5) * length_var * 2.0);
	float bh = brick_size.y * (1.0 + (h_hgt - 0.5) * height_var * 2.0);

	vec2 brick_center = vec2(
		cell_size.x * 0.5 + (h_jx - 0.5) * position_jitter.x,
		cell_size.y * 0.5 + (h_jy - 0.5) * position_jitter.y
	);

	vec2 brick_local = local - brick_center;
	float dist = sl_sd_rounded_box(brick_local, vec2(bw, bh) * 0.5, corner_radius);
	float rough_dist = sl_painterly_edge(p, dist, edge_roughness, oil_scale, hseed);

	// 滴水块（仅蓝灰色最底行且随机触发）
	bool in_band = row >= top_rows && row < top_rows + band_rows;
	bool is_drip_row = row == top_rows + band_rows - 1;
	bool has_drip = is_drip_row && h_drip < drip_chance;
	float drip_dist = 9999.0;
	if (has_drip) {
		float dl = drip_length * (1.0 + (h_drip_len - 0.5) * drip_var);
		vec2 drip_center = vec2(cell_size.x * 0.5, cell_size.y * 0.5 + dl * 0.5);
		vec2 drip_local = local - drip_center;
		drip_dist = sl_sd_rounded_box(drip_local, vec2(drip_width, dl) * 0.5, corner_radius * 0.6);
		float drip_rough = sl_painterly_edge(p, drip_dist, edge_roughness, oil_scale, hseed + 8.9);
		drip_dist = drip_rough;
	}

	// 选择配色
	vec3 c_light = in_band ? band_color_light : top_color_light;
	vec3 c_mid = in_band ? band_color_mid : top_color_mid;
	vec3 c_dark = in_band ? band_color_dark : top_color_dark;

	vec3 out_col;
	float alpha = 1.0;

	if (rough_dist < 0.0 || drip_dist < 0.0) {
		// 石头内部（主砖块或滴水块）
		vec2 sample_local = rough_dist < 0.0 ? brick_local : (local - vec2(cell_size.x * 0.5, cell_size.y * 0.5 + drip_length * 0.25));
		vec3 base_col = sl_stone_color_blocks(
			sample_local / (vec2(bw, bh) * 0.5),
			c_light, c_mid, c_dark,
			light_dir, color_block_blend
		);
		vec3 col_shift = vec3((h_col - 0.5) * color_var);
		out_col = clamp(base_col + col_shift, 0.0, 1.0);
	} else {
		float mv = hash21(hseed + 7.89) - 0.5;
		out_col = color_mortar * (1.0 + mv * 0.08);
		float shadow = smoothstep(gap_size.x * 0.8, 0.0, rough_dist);
		out_col *= 1.0 - shadow * 0.4;
	}

	COLOR = vec4(out_col, alpha);
}
