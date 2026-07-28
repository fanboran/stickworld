shader_type canvas_item;
// 邻接融合描边：相邻肢体重叠融合轮廓，不相邻重叠画分隔线
// 手动展开 8 邻域采样（不用 for 循环），fragment() 不用 return

uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float outline_width : hint_range(0.5, 4.0) = 1.5;
uniform sampler2D adj_tex : repeat_disable, filter_nearest;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_nearest;

int decode_id(float a) {
	if (a < 0.02) {
		return -1;
	}
	return int(round(a * 16.0)) - 1;
}

bool is_adjacent(int a, int b) {
	if (a == b) {
		return true;
	}
	if (a < 0 || b < 0 || a > 14 || b > 14) {
		return false;
	}
	vec2 uv = vec2((float(a) + 0.5) / 16.0, (float(b) + 0.5) / 16.0);
	return texture(adj_tex, uv).r > 0.5;
}

void fragment() {
	vec2 px = SCREEN_PIXEL_SIZE;
	vec4 center = texture(screen_tex, SCREEN_UV);
	int cid = decode_id(center.a);

	bool draw_outline = false;

	if (cid >= 0) {
		// 前景：1px 邻域检查不相邻的不同 ID -> 分隔线
		int n0 = decode_id(texture(screen_tex, SCREEN_UV + vec2(-1.0, -1.0) * px).a);
		int n1 = decode_id(texture(screen_tex, SCREEN_UV + vec2(0.0, -1.0) * px).a);
		int n2 = decode_id(texture(screen_tex, SCREEN_UV + vec2(1.0, -1.0) * px).a);
		int n3 = decode_id(texture(screen_tex, SCREEN_UV + vec2(-1.0, 0.0) * px).a);
		int n4 = decode_id(texture(screen_tex, SCREEN_UV + vec2(1.0, 0.0) * px).a);
		int n5 = decode_id(texture(screen_tex, SCREEN_UV + vec2(-1.0, 1.0) * px).a);
		int n6 = decode_id(texture(screen_tex, SCREEN_UV + vec2(0.0, 1.0) * px).a);
		int n7 = decode_id(texture(screen_tex, SCREEN_UV + vec2(1.0, 1.0) * px).a);

		if (n0 >= 0 && n0 != cid && !is_adjacent(cid, n0)) { draw_outline = true; }
		if (n1 >= 0 && n1 != cid && !is_adjacent(cid, n1)) { draw_outline = true; }
		if (n2 >= 0 && n2 != cid && !is_adjacent(cid, n2)) { draw_outline = true; }
		if (n3 >= 0 && n3 != cid && !is_adjacent(cid, n3)) { draw_outline = true; }
		if (n4 >= 0 && n4 != cid && !is_adjacent(cid, n4)) { draw_outline = true; }
		if (n5 >= 0 && n5 != cid && !is_adjacent(cid, n5)) { draw_outline = true; }
		if (n6 >= 0 && n6 != cid && !is_adjacent(cid, n6)) { draw_outline = true; }
		if (n7 >= 0 && n7 != cid && !is_adjacent(cid, n7)) { draw_outline = true; }
	} else {
		// 背景：outline_width 范围检查前景 -> 外轮廓
		vec2 opx = px * outline_width;
		if (decode_id(texture(screen_tex, SCREEN_UV + vec2(-1.0, -1.0) * opx).a) >= 0) { draw_outline = true; }
		if (decode_id(texture(screen_tex, SCREEN_UV + vec2(0.0, -1.0) * opx).a) >= 0) { draw_outline = true; }
		if (decode_id(texture(screen_tex, SCREEN_UV + vec2(1.0, -1.0) * opx).a) >= 0) { draw_outline = true; }
		if (decode_id(texture(screen_tex, SCREEN_UV + vec2(-1.0, 0.0) * opx).a) >= 0) { draw_outline = true; }
		if (decode_id(texture(screen_tex, SCREEN_UV + vec2(1.0, 0.0) * opx).a) >= 0) { draw_outline = true; }
		if (decode_id(texture(screen_tex, SCREEN_UV + vec2(-1.0, 1.0) * opx).a) >= 0) { draw_outline = true; }
		if (decode_id(texture(screen_tex, SCREEN_UV + vec2(0.0, 1.0) * opx).a) >= 0) { draw_outline = true; }
		if (decode_id(texture(screen_tex, SCREEN_UV + vec2(1.0, 1.0) * opx).a) >= 0) { draw_outline = true; }
	}

	if (draw_outline) {
		COLOR = outline_color;
	} else if (cid >= 0) {
		COLOR = vec4(center.rgb, 1.0);
	} else {
		COLOR = vec4(0.0);
	}
}
