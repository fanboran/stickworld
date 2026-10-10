shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;
// 直渲血条图集面片：采样槽位 UV 子矩形（INSTANCE_CUSTOM = off.xy + scale.zw，
// vertex 内建经 varying 带入 fragment），图集本体是 HealthBarIndicator
// 驱动镜像画进共享视口的回读纹理（原版画法）。
// blend_mix 透明混合：条的暗底 alpha≈0.72 需与背景正确混合（烘焙路线卡片
// 同为半透明混合语义）；depth_draw_never 面片不写深度，靠 3D 位置排序。
uniform sampler2D atlas_tex : source_color, filter_linear;

varying vec4 slot_uv;

void vertex() {
	slot_uv = INSTANCE_CUSTOM;
}

void fragment() {
	vec2 uv = vec2(slot_uv.x, slot_uv.y) + UV * vec2(slot_uv.z, slot_uv.w);
	vec4 c = texture(atlas_tex, uv);
	ALBEDO = c.rgb * COLOR.rgb;
	ALPHA = c.a * COLOR.a;
}
