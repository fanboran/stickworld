shader_type spatial;
// char_shadow.gdshader —— 角色接地影（让 2D 角色"踩在 3D 地面上"）
//
// 是什么：一个贴地的水平 quad，程序化径向渐变，画在角色脚底正下方。
// 为什么需要：2D 角色是"挂"在 3D 场景里的平面，没有接地影就会读作"飘"。
// 建筑卡自带烘焙接触阴影（blender 侧烘进 albedo），角色必须补一个同口径的，
// 否则角色与建筑的接地语言不一致 —— 这是 HD-2D 观感成立的最低要求。
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

uniform vec4 blob_color : source_color = vec4(0.06, 0.05, 0.05, 0.50);
uniform float core : hint_range(0.0, 1.0) = 0.18;
uniform float edge : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float a = 1.0 - smoothstep(core, edge, d);
	ALBEDO = blob_color.rgb;
	ALPHA = a * blob_color.a;
}
