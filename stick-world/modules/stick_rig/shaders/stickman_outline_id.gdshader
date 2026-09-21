shader_type canvas_item;
// 邻接融合描边 · ID Pass（2026-09-14 从 Git 历史复活，适配矢量肢体）
//
// 与旧位图版的差异：矢量肢体（Line2D/Polygon2D）无纹理——直接用顶点色
// COLOR.rgb 作为真实颜色；textured=true 时按旧版语义采 TEXTURE（位图件
// 如武器精灵）。alpha 通道统一编码 part_id（0=背景，(id+1)/16=前景）。
render_mode blend_disabled;

uniform int part_id = 0;
uniform bool textured = false;

void fragment() {
	if (textured) {
		vec4 tex = texture(TEXTURE, UV);
		if (tex.a < 0.3) {
			discard;
		}
		COLOR = vec4(tex.rgb * COLOR.rgb, float(part_id + 1) / 16.0);
	} else {
		COLOR = vec4(COLOR.rgb, float(part_id + 1) / 16.0);
	}
}
