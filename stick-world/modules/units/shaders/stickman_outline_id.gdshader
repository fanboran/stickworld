shader_type canvas_item;
// blend_disabled：直接写入（含 alpha），避免 alpha 混合破坏 ID 编码
render_mode blend_disabled;

// 零件 ID（0-13=火柴人零件，14=未分类前景如武器）
uniform int part_id = 0;

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	if (tex.a < 0.3) {
		discard;
	}
	// RGB = 正常颜色，A = 编码 ID（0=背景，(id+1)/16=前景）
	COLOR = vec4(tex.rgb * COLOR.rgb, float(part_id + 1) / 16.0);
}
