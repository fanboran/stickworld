shader_type spatial;
// card.gdshader —— 2.5D 纸片卡材质（2.5D 原型用）
//
// 是什么：把 Blender 用 yaw=0°/tilt=20° 正交相机烘好的建筑卡（透明底 RGBA）
//   贴在一个正对相机的 quad 上，并让**真 3D 光照**对它生效。
//
// 为什么这样写：平面卡的法线处处相同 → 点光/太阳只会把整张卡整体调亮调暗，
//   做不出"窗户附近亮、屋檐下面暗"的逐像素明暗，等于没有 3D 光照。这里用
//   albedo 亮度的一阶差分**现场伪一个法线**（无需额外资产），法线进了 TBN 之后
//   点光源就能在卡上打出浮雕式明暗。代价是每像素多 4 次采样。
//
// 两层烘焙：albedo 卡（白天光照结果）+ glow 卡（只有自发光窗/火的形状，
//   其余压黑）叠在同一个材质里 —— 黑=加色下不可见，所以夜间只亮窗户。

// depth_prepass_alpha：让卡的**深度/阴影 pass 也吃 ALPHA 裁剪**。
// 少了它，整张 quad 会往地面投一个**矩形黑影**（透明部分也投影），
// 这是纸片路线最容易被忽略的坑；加上后剪影阴影才成立。
render_mode cull_disabled, depth_draw_opaque, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform sampler2D glow_tex : source_color, filter_linear_mipmap;
uniform vec2 tex_px = vec2(1024.0, 1024.0);
uniform float relief : hint_range(0.0, 40.0) = 9.0;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.4;
uniform float glow_energy : hint_range(0.0, 8.0) = 0.0;
uniform vec3 glow_tint : source_color = vec3(1.0, 0.78, 0.46);
uniform vec3 tint : source_color = vec3(1.0);
uniform float rough : hint_range(0.0, 1.0) = 0.85;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

float _lum(vec2 uv) {
	return dot(texture(albedo_tex, uv).rgb, LUMA);
}

void fragment() {
	vec2 d = 1.0 / max(tex_px, vec2(2.0));
	vec4 c = texture(albedo_tex, UV);
	ALPHA = c.a;
	if (c.a < alpha_cut) {
		discard;
	}
	ALBEDO = c.rgb * tint;
	// albedo 亮度差分 -> 切空间法线（TANGENT/BINORMAL 由 quad 的 UV 给出）
	float lx = _lum(UV + vec2(d.x, 0.0)) - _lum(UV - vec2(d.x, 0.0));
	float ly = _lum(UV + vec2(0.0, d.y)) - _lum(UV - vec2(0.0, d.y));
	vec3 n = normalize(vec3(-lx * relief, ly * relief, 1.0));
	NORMAL = normalize(TANGENT * n.x + BINORMAL * n.y + NORMAL * n.z);
	ROUGHNESS = rough;
	SPECULAR = 0.15;
	EMISSION = texture(glow_tex, UV).rgb * glow_energy * glow_tint;
}
