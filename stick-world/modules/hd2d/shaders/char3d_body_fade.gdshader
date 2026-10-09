shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_always;
// 直渲身体部件桶（渐隐版）：尸体淡出期部件从主桶迁来，实例色 alpha 逐帧压低。
// 透明混合 + 保深度写：渐隐各部件同 alpha 同步衰减，深度关系保持稳定。
void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
