shader_type spatial;
// char3d_body_fade.gdshader —— 关节烘焙身体部件桶（渐隐版）：尸体淡出期
// 部件从不透明桶整段迁来，实例色 alpha 逐帧压低（feed 的 set_master_alpha）。
// 图集采样与混合/深度语义同 char3d_body_opaque（blend_mix + 深度写：
// 渐隐期间部件保持跨角色深度关系；描边遍实深度垫后在填充已写深度处被
// 剔，只留外轮廓环带，描边不会泛白盖住身体）。
render_mode blend_mix, cull_disabled, depth_draw_always, unshaded;

uniform sampler2D atlas_tex : filter_linear_mipmap, repeat_disable;

varying vec4 slot_uv;

void vertex() {
	slot_uv = INSTANCE_CUSTOM;
}

void fragment() {
	vec4 t = texture(atlas_tex, slot_uv.xy + UV * slot_uv.zw);
	if (t.a <= 0.004) {
		discard;
	}
	ALBEDO = t.rgb * COLOR.rgb;
	ALPHA = t.a * COLOR.a;
}
