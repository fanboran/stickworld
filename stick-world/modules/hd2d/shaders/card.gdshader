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
uniform sampler2D albedo_night_tex : source_color, filter_linear_mipmap;
uniform sampler2D glow_tex : source_color, filter_linear_mipmap;
uniform vec2 tex_px = vec2(1024.0, 1024.0);
uniform float relief : hint_range(0.0, 40.0) = 9.0;
uniform float alpha_cut : hint_range(0.0, 1.0) = 0.4;
uniform float glow_energy : hint_range(0.0, 8.0) = 0.0;
uniform vec3 glow_tint : source_color = vec3(1.0, 0.90, 0.78);
uniform vec3 tint : source_color = vec3(1.0);
uniform float rough : hint_range(0.0, 1.0) = 0.85;
// 夜版卡混合（创始人 2026-09-15：月光在 Blender 里烘亮）——night_mix=1 时整卡
// 换用月夜灯位烘的 <卡>_night.png（窗/火自发光已烘进去）。夜版缺失时运行时以
// 日版垫底，混不出差别（安全回退）。
uniform float night_mix : hint_range(0.0, 1.0) = 0.0;
// 夜档亮度补偿：夜观感已完整烘在卡里，夜间场景光只按"未烘焙几何"（地面/角色）
// 的需要给暗档冷光；卡侧用 EMISSION 把烘卡亮度补回 ≈1.0（否则烘卡被场景光
// 二次压暗，夜里照样黑）。日档恒 0。
uniform float night_comp : hint_range(0.0, 1.0) = 0.0;
// 底部台基裁剪（创始人 2026-09-15：地基上的浅灰台基整段删除）。0 = 不裁；
// 0.15 = 裁掉贴图底部 15% 高度（卡底贴地落位后，台基带会铺在楼脚前地面上，
// 读作"地基上一圈浅灰方形"，故按卡内容整段裁掉，墙体底缘=可视底=落地线）。
uniform float base_cut : hint_range(0.0, 0.45) = 0.0;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

// 日/夜版按 night_mix 混色采样（亮度差分法线必须吃同一份混色——否则夜档
// 法线还停在日版明暗上，烘进卡里的月光方向感就全丢了）
vec3 _samp(vec2 uv) {
	return mix(texture(albedo_tex, uv).rgb, texture(albedo_night_tex, uv).rgb, night_mix);
}

vec4 _samp_rgba(vec2 uv) {
	return mix(texture(albedo_tex, uv), texture(albedo_night_tex, uv), night_mix);
}

float _lum(vec2 uv) {
	return dot(_samp(uv), LUMA);
}

void fragment() {
	vec2 d = 1.0 / max(tex_px, vec2(2.0));
	// 底部台基整段删除（含其下的透明留白）：先于一切光照处理
	if (UV.y > 1.0 - base_cut) {
		discard;
	}
	vec4 base = _samp_rgba(UV);
	ALPHA = base.a;
	if (base.a < alpha_cut) {
		discard;
	}
	ALBEDO = base.rgb * tint;
	// albedo 亮度差分 -> 切空间法线（TANGENT/BINORMAL 由 quad 的 UV 给出）
	float lx = _lum(UV + vec2(d.x, 0.0)) - _lum(UV - vec2(d.x, 0.0));
	float ly = _lum(UV + vec2(0.0, d.y)) - _lum(UV - vec2(0.0, d.y));
	vec3 n = normalize(vec3(-lx * relief, ly * relief, 1.0));
	NORMAL = normalize(TANGENT * n.x + BINORMAL * n.y + NORMAL * n.z);
	ROUGHNESS = rough;
	SPECULAR = 0.15;
	EMISSION = texture(glow_tex, UV).rgb * glow_energy * glow_tint + _samp(UV) * night_comp;
}
