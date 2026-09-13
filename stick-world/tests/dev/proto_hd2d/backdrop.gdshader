shader_type spatial;
// backdrop.gdshader —— HD-2D 背景封底层（树线/远山、天空云带）
//
// 是什么：一块与相机同基的超大 quad，纹理自带的 alpha 编码"剪影/云的形状"。
// 为什么：20° 俯角下地面平面会一直延伸到画面很高的位置（"地面无限延伸 + 地平线
//   浮在画面上部"）。本原型把地面做成**有限条带**（远边 = 地平线），再让这层
//   不透明剪影把地平线以上彻底盖住，接上天空 —— 世界上不存在"看不到边"的地面。
// 不投影、不参与光照：它是纯色剪影/云层，颜色由 tint 统一控制（距离感靠 tint + DOF）。
//
// 两个模式：
//   · 剪影层（树线/远山）：吃 `bd_tex` 的 alpha，`cloud_mul` 打开后**吃云影**
//     （远处地面同样在同一片云底下）；
//   · 天空云层：`sky_fluff = 1` 时改用**程序化蓬松云** —— 与云影同一套 value noise
//     族（cloud_noise.gdshaderinc），但在 UV 空间采样并在四边做纵向渐隐，避免在
//     天空带上下缘切出一条横向硬边。
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

global uniform vec4 cloud_shadow;
#include "res://tests/dev/proto_hd2d/cloud_noise.gdshaderinc"

uniform sampler2D bd_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float alpha_mul : hint_range(0.0, 2.0) = 1.0;
// 顶部再乘一层 alpha 衰减（把剪影/云的上缘融进天空，避免硬边横线）
uniform float top_fade : hint_range(0.0, 1.0) = 0.0;
uniform float blur_radius : hint_range(0.0, 32.0) = 0.0;
// 1 = 这层是"地面上的远山/树线"→ 吃云影；0 = 这层就是天空里的云本身 → 不自遮
uniform float cloud_mul : hint_range(0.0, 1.0) = 0.0;

// ── 天空云层：程序化蓬松团（同一噪声族）──
uniform float sky_fluff : hint_range(0.0, 1.0) = 0.0;
// 噪声周期数（横/纵各多少个周期，UV 空间）。
// **必须分开给**：天空带 quad 是 ~32:1 的横长条（500 单位宽 × 十几单位高），
// 用同一个周期数会让纵向周期过多，噪声在纵向被压成几十条细带 → 一眼读作
// 横向条纹（这正是"禁横向条带"要避开的）。纵向只给 2 个周期 → 2 排行云，
// 读作云堤/团块而不是扫描线。
uniform vec2 fluff_scale = vec2(9.0, 2.0);
// UV 空间漂移量，由 cloud_setup.gd 推进；按 fbm 周期 64 取模 → 永不跳变
uniform vec2 fluff_drift = vec2(0.0);
uniform float fluff_lo : hint_range(0.0, 1.0) = 0.44;
uniform float fluff_hi : hint_range(0.0, 1.0) = 0.64;
uniform float fluff_alpha : hint_range(0.0, 1.0) = 0.75;
// 上下缘渐隐（比例）：云的 alpha 在 quad 上下边归零，不会切出横向硬边
uniform float fluff_taper : hint_range(0.0, 0.5) = 0.16;

void fragment() {
	vec2 texel = 1.0 / vec2(textureSize(bd_tex, 0));
	vec3 rgb = texture(bd_tex, UV).rgb;
	float a = texture(bd_tex, UV).a * alpha_mul;

	if (sky_fluff > 0.5) {
		// 蓬松团状云：fbm 的高段（与地面云影同一套噪声），宽 smoothstep 出软边
		float n = cn_fbm(UV * fluff_scale + fluff_drift, 4);
		float band = smoothstep(0.0, fluff_taper, UV.y)
			* (1.0 - smoothstep(1.0 - fluff_taper, 1.0, UV.y));
		rgb = vec3(1.0);
		a = smoothstep(fluff_lo, fluff_hi, n) * fluff_alpha * alpha_mul * band;
	} else if (blur_radius > 0.25) {
		// 10 tap 黄金角螺旋模糊（逐层递增的远景虚化，见 card.gdshader 同款）
		vec3 acc = rgb;
		float wsum = 1.0;
		for (int i = 0; i < 10; i++) {
			float fi = float(i);
			float ang = fi * 2.39996;
			float rr = sqrt((fi + 0.5) / 10.0);
			vec2 off = vec2(cos(ang), sin(ang)) * rr * blur_radius * texel;
			float w = 1.0 - rr * 0.5;
			acc += texture(bd_tex, UV + off).rgb * w;
			wsum += w;
		}
		rgb = acc / wsum;
	}

	if (top_fade > 0.001) {
		a *= 1.0 - smoothstep(1.0 - top_fade, 1.0, UV.y);
	}
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ALBEDO = rgb * tint * (1.0 - cloud_shadow_at(wp.xz) * cloud_mul);
	ALPHA = a;
}
