shader_type spatial;
// card.gdshader —— HD-2D 原型：建筑纸片卡材质
//
// 复制自 tests/dev/proto_25d/card.gdshader（只读原目录，本目录独立改造）。
// 与原件一致的两条关键纪律（proto_25d 五条实测发现）：
//   1. albedo 亮度一阶差分伪造切空间法线 —— 平面卡只有靠这个才能吃真 3D 光照；
//   2. depth_prepass_alpha —— 深度/阴影 pass 也吃 ALPHA 裁剪，否则 quad 会投一块矩形黑影。
//
// 本原型新增：`alpha_cut` 可由运行时统一调，用于 A/B 对照"描边融合"式硬边 vs 软边。

// depth_prepass_alpha：深度预通道同样做 alpha 裁剪（消矩形影）。
// depth_draw_opaque：深度写在**不透明通道** —— 这是 HD-2D 遮挡正确性的地基：
//   建筑卡在不透明通道写深度，2D 角色 quad 在透明通道读深度测试 → 建筑挡角色天然成立。
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
// 逐层递增的"后景模糊"：按半径做 10 tap 黄金角螺旋模糊（只糊颜色，不糊 alpha
// 与伪法线 —— 剪影保持硬边、明暗结构仍在，读作"轻/中/重虚化的远景层"）。
// 为什么不用 Environment 的 DOF：DOF 只能给"近/远两档"，做不出"第一层轻糊、
// 第二层中糊、远山重糊"的逐层递增；逐层 uniform 是可控且可验证的做法。
uniform float blur_radius : hint_range(0.0, 32.0) = 0.0;

vec3 _blur_smp(sampler2D tex, vec2 uv, vec2 texel, float radius) {
	vec3 acc = texture(tex, uv).rgb;
	float wsum = 1.0;
	for (int i = 0; i < 10; i++) {
		float fi = float(i);
		float a = fi * 2.39996;
		float rr = sqrt((fi + 0.5) / 10.0);
		vec2 off = vec2(cos(a), sin(a)) * rr * radius * texel;
		float w = 1.0 - rr * 0.5;
		acc += texture(tex, uv + off).rgb * w;
		wsum += w;
	}
	return acc / wsum;
}

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
	ALBEDO = _blur_smp(albedo_tex, UV, d, blur_radius) * tint;
	// albedo 亮度差分 -> 切空间法线（TANGENT/BINORMAL 由 quad 的 UV 给出）
	float lx = _lum(UV + vec2(d.x, 0.0)) - _lum(UV - vec2(d.x, 0.0));
	float ly = _lum(UV + vec2(0.0, d.y)) - _lum(UV - vec2(0.0, d.y));
	vec3 n = normalize(vec3(-lx * relief, ly * relief, 1.0));
	NORMAL = normalize(TANGENT * n.x + BINORMAL * n.y + NORMAL * n.z);
	ROUGHNESS = rough;
	SPECULAR = 0.15;
	EMISSION = _blur_smp(glow_tex, UV, d, blur_radius * 1.5) * glow_energy * glow_tint;
}
