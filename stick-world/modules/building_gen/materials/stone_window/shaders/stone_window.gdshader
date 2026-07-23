shader_type canvas_item;

// 拱形石窗材质配方：固定风格、无随机性，保证与石墙视觉一致

uniform vec2 resolution = vec2(240.0, 340.0);

// 窗户整体尺寸
uniform float window_width = 180.0;
uniform float window_height = 260.0;
// 拱顶高度（从矩形顶部往上隆起的半圆高度）
uniform float arch_height = 50.0;
// 窗框厚度
uniform float frame_thickness = 22.0;
// 窗框外凸厚度（让窗框有立体感）
uniform float frame_depth = 8.0;

// 拱顶石块数量
uniform int arch_stones = 9;

// 配色
uniform vec3 frame_color_light : source_color = vec3(0.900, 0.870, 0.800);
uniform vec3 frame_color_mid : source_color = vec3(0.780, 0.740, 0.660);
uniform vec3 frame_color_dark : source_color = vec3(0.520, 0.470, 0.390);
uniform vec3 inner_shadow : source_color = vec3(0.180, 0.160, 0.150);
uniform vec3 glass_color : source_color = vec3(0.080, 0.080, 0.090);
uniform vec3 bar_color : source_color = vec3(0.320, 0.280, 0.240);

// 铁栅栏
uniform int vertical_bars = 5;
uniform int horizontal_bars = 4;
uniform float bar_width = 4.0;

uniform vec2 light_dir = vec2(-1.0, -1.0);

#include "res://modules/building_gen/shaders/lib/stone_lib.gdshaderinc"


void fragment() {
	// 以 Sprite 中心为窗户中心
	vec2 p = (UV - 0.5) * resolution;

	// ── 拱形外框 SDF ──
	// 外框：底部矩形 + 顶部半圆
	float outer_arch_r = window_width * 0.5;
	float outer_body_h = window_height - arch_height;
	vec2 outer_center = vec2(0.0, -window_height * 0.5 + outer_body_h * 0.5);
	float outer_dist;
	{
		vec2 q = p - outer_center;
		vec2 d = abs(q) - vec2(outer_arch_r, outer_body_h * 0.5);
		float rect_dist = min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
		// 拱形圆心在矩形顶部中央（y 向上隆起，故圆心在 q.y 负方向）
		float circle_dist = length(q - vec2(0.0, -outer_body_h * 0.5)) - outer_arch_r;
		float top_mask = step(0.0, -q.y - outer_body_h * 0.5);
		outer_dist = mix(rect_dist, circle_dist, top_mask);
	}

	// 内框：外框向内缩
	float inner_arch_r = max(outer_arch_r - frame_thickness, 0.0);
	float inner_body_h = max(outer_body_h - frame_thickness * 2.0, 0.0);
	vec2 inner_center = vec2(0.0, -window_height * 0.5 + inner_body_h * 0.5);
	float inner_dist;
	{
		vec2 q = p - inner_center;
		vec2 d = abs(q) - vec2(inner_arch_r, inner_body_h * 0.5);
		float rect_dist = min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
		float circle_dist = length(q - vec2(0.0, -inner_body_h * 0.5)) - inner_arch_r;
		float top_mask = step(0.0, -q.y - inner_body_h * 0.5);
		inner_dist = mix(rect_dist, circle_dist, top_mask);
	}

	// 更内层的窗洞（用于玻璃和栅栏）
	float hole_arch_r = max(inner_arch_r - frame_depth, 0.0);
	float hole_body_h = max(inner_body_h - frame_depth * 2.0, 0.0);
	vec2 hole_center = vec2(0.0, -window_height * 0.5 + hole_body_h * 0.5);
	float hole_dist;
	{
		vec2 q = p - hole_center;
		vec2 d = abs(q) - vec2(hole_arch_r, hole_body_h * 0.5);
		float rect_dist = min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
		float circle_dist = length(q - vec2(0.0, -hole_body_h * 0.5)) - hole_arch_r;
		float top_mask = step(0.0, -q.y - hole_body_h * 0.5);
		hole_dist = mix(rect_dist, circle_dist, top_mask);
	}

	// ── 拱顶石块分割线 ──
	// 在窗框顶部区域，按角度划分石块
	float stone_line = 0.0;
	{
		vec2 q = p - outer_center;
		float top_mask = step(outer_body_h * 0.5, q.y);
		float ang = atan(q.x, q.y - outer_body_h * 0.5);
		float seg = 3.14159265 / float(arch_stones);
		float f = fract(ang / seg);
		stone_line = top_mask * (1.0 - smoothstep(0.02, 0.06, abs(f - 0.5)));
	}

	// ── 铁栅栏 ──
	float bars = 0.0;
	if (hole_dist < 0.0) {
		// 竖条
		float bar_spacing = hole_arch_r * 2.0 / float(vertical_bars + 1);
		for (int i = 1; i <= 8; i++) {
			if (i > vertical_bars) break;
			float x = -hole_arch_r + float(i) * bar_spacing;
			bars = max(bars, 1.0 - smoothstep(bar_width * 0.3, bar_width * 0.6, abs(p.x - x)));
		}
		// 横条
		float hbar_spacing = (hole_body_h + hole_arch_r * 2.0) / float(horizontal_bars + 1);
		for (int i = 1; i <= 8; i++) {
			if (i > horizontal_bars) break;
			float y = hole_center.y - (hole_body_h + hole_arch_r) * 0.5 + float(i) * hbar_spacing;
			// 横条只在窗洞范围内
			float in_hole = step(0.0, -hole_dist);
			bars = max(bars, in_hole * (1.0 - smoothstep(bar_width * 0.3, bar_width * 0.6, abs(p.y - y))));
		}
	}

	// ── 颜色合成 ──
	vec3 out_col = vec3(0.0);
	float alpha = 1.0;

	if (outer_dist > 0.0) {
		// 窗外：透明
		alpha = 0.0;
	} else if (inner_dist > 0.0) {
		// 窗框
		vec2 frame_local = p * 0.01;
		out_col = sl_stone_color_blocks(frame_local, frame_color_light, frame_color_mid, frame_color_dark, light_dir, 0.45);
		// 拱顶石块分割线加深
		out_col = mix(out_col, frame_color_dark * 0.7, stone_line * 0.6);
	} else if (hole_dist > 0.0) {
		// 内层阴影槽
		out_col = inner_shadow;
	} else {
		// 窗洞内部
		out_col = glass_color;
		// 铁栅栏
		out_col = mix(out_col, bar_color, bars);
	}

	COLOR = vec4(out_col, alpha);
}
