shader_type spatial;
// backdrop.gdshader —— HD-2D 背景封底层（树线/远山、云带）
//
// 是什么：一块与相机同基的超大 quad，纹理自带的 alpha 编码"剪影形状"。
// 为什么：20° 俯角下地面平面会一直延伸到画面很高的位置（"地面无限远 + 地平线
//   浮在画面上部"）。本原型把地面做成**有限条带**（远边 = 地平线），再让这层
//   不透明剪影把地平线以上彻底盖住，接上天空 —— 世界上不存在"看不到边"的地面。
// 不投影、不参与光照：它是纯色剪影层，颜色由 tint 统一控制（距离感靠 tint + DOF）。
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

uniform sampler2D bd_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float alpha_mul : hint_range(0.0, 2.0) = 1.0;
// 顶部再乘一层 alpha 衰减（把剪影/云的上缘融进天空，避免硬边横线）
uniform float top_fade : hint_range(0.0, 1.0) = 0.0;
uniform float blur_radius : hint_range(0.0, 32.0) = 0.0;

void fragment() {
	vec2 texel = 1.0 / vec2(textureSize(bd_tex, 0));
	vec3 rgb = texture(bd_tex, UV).rgb;
	if (blur_radius > 0.25) {
		vec3 acc = rgb;
		float wsum = 1.0;
		for (int i = 0; i < 10; i++) {
			float fi = float(i);
			float a = fi * 2.39996;
			float rr = sqrt((fi + 0.5) / 10.0);
			vec2 off = vec2(cos(a), sin(a)) * rr * blur_radius * texel;
			float w = 1.0 - rr * 0.5;
			acc += texture(bd_tex, UV + off).rgb * w;
			wsum += w;
		}
		rgb = acc / wsum;
	}
	vec4 c = vec4(rgb, texture(bd_tex, UV).a);
	float a = c.a * alpha_mul;
	if (top_fade > 0.001) {
		a *= 1.0 - smoothstep(1.0 - top_fade, 1.0, UV.y);
	}
	ALBEDO = c.rgb * tint;
	ALPHA = a;
}
