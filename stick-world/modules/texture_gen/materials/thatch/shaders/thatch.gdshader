shader_type canvas_item;
// 茅草屋顶材质（2026-08-22 替换红色占位）—— 程序化稻草束 + 色斑 + 捆扎带
//
// ⚠️ PLACEHOLDER 素材：参数为可用级占位，待美术调优/贴图替换。
// 替换清单见 docs/项目/待办事项.md「PLACEHOLDER 素材替换」。
//
// 结构（自底向上）：
//   1. 大尺度色斑（value noise）：干草底色 → 深色区
//   2. 两层稻草束：粗束（横向短线，行间错位）+ 细丝（碎屑感）
//   3. 捆扎带：每 N 像素一条深色横带（草绳压痕）
//   4. 边缘 AO：多边形边缘压暗增加体积
//
// 契约：保留 resolution uniform（thatch_building_demo / applier 依赖）

uniform vec2 resolution = vec2(186.0, 140.0);

// ── 配色 ──
uniform vec4 base_color : source_color = vec4(0.78, 0.62, 0.32, 1.0);
uniform vec4 dark_color : source_color = vec4(0.52, 0.38, 0.18, 1.0);
uniform vec4 light_color : source_color = vec4(0.92, 0.80, 0.48, 1.0);

// ── 草束尺寸（像素）──
uniform vec2 coarse_cell = vec2(16.0, 5.0);   // 粗束
uniform vec2 fine_cell = vec2(7.0, 2.2);      // 细丝

// ── 形态 ──
uniform float droop = 1.8;          // 行下垂幅度（像素）
uniform float row_jitter = 10.0;    // 行水平错位（像素）
uniform float strand_tone_var = 0.25; // 束间明暗差异
uniform float band_spacing = 34.0;  // 捆扎带间距（像素）
uniform float band_width = 3.0;     // 捆扎带宽（像素）
uniform float edge_ao = 0.35;       // 边缘压暗强度
uniform float seed = 7.0;

float hash21(vec2 p) {
	p = fract(p * vec2(233.34, 851.73));
	p += dot(p, p + 23.45 + seed);
	return fract(p.x * p.y);
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

// 单层草束：返回该层的明度贡献（-1 暗缝 ~ +1 受光面）
float straw_layer(vec2 p, vec2 cell, float tone_scale) {
	// 行号 + 行内错位与下垂
	float row = floor(p.y / cell.y);
	float rnd_row = hash21(vec2(row, tone_scale));
	float x_off = (rnd_row - 0.5) * row_jitter;
	float y_droop = sin((p.x + x_off) * 0.05 + row * 1.7) * droop;

	// 束坐标：沿 x 的相位（含下垂造成的 y 抬升）
	vec2 q = vec2((p.x + x_off) / cell.x, (p.y + y_droop) / cell.y);
	float col = floor(q.x);

	// 每束独立明暗
	float tone = (hash21(vec2(col, row)) - 0.5) * 2.0 * strand_tone_var * tone_scale;

	// 束内纵向位置：|v|∈[0,0.5]，中心受光、边缘成缝
	float v = abs(fract(q.y) - 0.5);
	float body = smoothstep(0.28, 0.12, v);   // 中心亮
	float gap = smoothstep(0.42, 0.5, v);     // 近边缘暗缝

	// 束端部随机截断（稻草长短不一）
	float len_cut = hash21(vec2(col * 3.1, row * 1.3));
	float end_fade = smoothstep(len_cut, len_cut - 0.15, fract(q.x));

	return tone + body * 0.55 - gap * 0.75 * end_fade;
}

void fragment() {
	vec2 p = UV * resolution;

	// 1. 底色斑块
	float patch = value_noise(p * 0.02);
	vec3 col = mix(base_color.rgb, dark_color.rgb, smoothstep(0.35, 0.75, patch));

	// 2. 两层草束
	float s_coarse = straw_layer(p, coarse_cell, 1.0);
	float s_fine = straw_layer(p + vec2(37.0, 11.0), fine_cell, 0.5);
	col += light_color.rgb * s_coarse * 0.30;
	col += light_color.rgb * s_fine * 0.14;

	// 3. 捆扎横带（略带波动）
	float band_y = p.y + sin(p.x * 0.03) * 2.0;
	float band = smoothstep(band_width, band_width * 0.4, abs(fract(band_y / band_spacing) * band_spacing - band_width));
	col = mix(col, dark_color.rgb * 0.8, band * 0.55);

	// 4. 边缘 AO（UV 四周）
	vec2 e = min(UV, 1.0 - UV);
	float edge = smoothstep(0.0, 0.06, min(e.x, e.y));
	col *= mix(1.0 - edge_ao, 1.0, edge);

	COLOR = vec4(col, 1.0);
}
