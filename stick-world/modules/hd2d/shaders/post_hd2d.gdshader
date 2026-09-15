shader_type canvas_item;
// post_hd2d.gdshader —— HD-2D 后处理（屏幕空间，跑在 3D 渲染之后）
//
// 为什么放在 CanvasLayer 而不是 Environment：
//   Godot 的 Environment 只有 DOF / Glow（在 3D 管线内、色调映射之前），
//   **没有暗角、没有移轴、没有色彩分级**。这三样必须在色调映射之后做，
//   所以走一条 CanvasLayer + ColorRect + hint_screen_texture 的屏幕空间通道。
//   分工：DOF/Glow 走 Environment（有深度可用），暗角/移轴/分级走本 shader。
//
// 移轴（tilt-shift）：八方旅人式"上下一渐糊"的本质是**保持一条水平清晰带**，
//   带外按距离渐糊。这里用"清晰带中心 + 带厚 + 羽化"三个参数定义遮罩，
//   再按遮罩权重混入一圈 12-tap 黄金角螺旋模糊。
//   （真正的分离式高斯要两趟渲染 + 两个 Viewport；单 pass 12 tap 是性价比取舍，
//    半径 7px 内肉眼与高斯无差。）

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;
// 屏幕像素尺寸。Godot 4.7 的 canvas_item shader **没有** SCREEN_PIXEL_SIZE
// 这个内建（实测编译报 Unknown identifier），改用 uniform 从脚本灌
// （1/视口尺寸；窗口 resize/性能档改分辨率时必须一起更新）。
uniform vec2 px_size = vec2(0.000521, 0.000926);

// ── 暗角 vignette ──
uniform float vig_strength : hint_range(0.0, 2.0) = 0.55;
uniform float vig_inner : hint_range(0.0, 1.5) = 0.42;
uniform float vig_outer : hint_range(0.0, 1.6) = 0.95;

// ── 移轴 tilt-shift ──
uniform float tilt_level : hint_range(0.0, 1.0) = 0.0;   // 0 = 关
uniform float tilt_center : hint_range(0.0, 1.0) = 0.74; // 清晰带中心（屏幕 y，0=顶）
uniform float tilt_band : hint_range(0.0, 1.0) = 0.16;   // 清晰带半厚
uniform float tilt_feather : hint_range(0.0, 1.0) = 0.26; // 羽化宽
uniform float tilt_radius : hint_range(0.0, 24.0) = 7.0; // 最大模糊半径（px）

// ── 色彩分级 grade ──
uniform float exposure = 1.0;
uniform float contrast : hint_range(0.0, 2.0) = 1.06;
uniform float saturation : hint_range(0.0, 2.0) = 1.12;
uniform vec3 lift : source_color = vec3(0.0);            // 阴影抬升
uniform vec3 gain : source_color = vec3(1.0);            // 高光增益
uniform vec3 shadow_tint : source_color = vec3(-0.010, 0.0, 0.026); // 冷阴影
uniform vec3 high_tint : source_color = vec3(0.016, 0.008, -0.014); // 暖高光
uniform float split : hint_range(0.0, 1.0) = 1.0;

const int TAPS = 12;
const float GOLDEN = 2.39996323;

vec3 _blur(vec2 uv, float r) {
	if (r < 0.35) {
		return texture(screen_tex, uv).rgb;
	}
	vec3 acc = texture(screen_tex, uv).rgb;
	float wsum = 1.0;
	for (int i = 0; i < TAPS; i++) {
		float fi = float(i);
		float a = fi * GOLDEN;
		float rr = sqrt((fi + 0.5) / float(TAPS));
		vec2 off = vec2(cos(a), sin(a)) * rr * r * px_size;
		float w = 1.0 - rr * 0.55;
		acc += texture(screen_tex, uv + off).rgb * w;
		wsum += w;
	}
	return acc / wsum;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 col;
	if (tilt_level > 0.001) {
		float d = abs(uv.y - tilt_center);
		float k = smoothstep(tilt_band, tilt_band + tilt_feather, d);
		col = _blur(uv, tilt_radius * k * tilt_level);
	} else {
		col = texture(screen_tex, uv).rgb;
	}

	// 曝光 / 对比 / 饱和
	col *= exposure;
	col = (col - 0.5) * contrast + 0.5;
	float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(l), col, saturation);

	// lift / gain + 冷阴影暖高光分离调色
	col = col * gain + lift;
	float hi = smoothstep(0.42, 0.95, l);
	col += mix(shadow_tint, high_tint, hi) * split;

	// 暗角
	vec2 dv = (uv - vec2(0.5)) * vec2(1.06, 1.0);
	float vig = 1.0 - vig_strength * smoothstep(vig_inner, vig_outer, length(dv));
	col *= vig;

	COLOR = vec4(max(col, vec3(0.0)), 1.0);
}
