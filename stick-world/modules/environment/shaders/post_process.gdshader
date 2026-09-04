shader_type canvas_item;
// 全屏后处理栈（求职 Demo"精品感"渲染层）
// 六层叠加：边缘色差 → 暖色分级 → 顶部天光 → 太阳炫光(glow/streak/ghost) → 渐晕 → 胶片颗粒
// 挂 CanvasLayer(0.5) 的全屏 ColorRect：压在游戏世界之上、UI(CanvasLayer 1) 之下。

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

uniform float vignette_strength : hint_range(0.0, 1.0) = 0.32;
uniform float aberration_px : hint_range(0.0, 6.0) = 1.5;
uniform float grain_strength : hint_range(0.0, 0.2) = 0.045;
uniform float saturation : hint_range(0.5, 1.8) = 1.08;
uniform float contrast : hint_range(0.8, 1.4) = 1.03;
uniform vec3 warm_tint : source_color = vec3(1.045, 1.0, 0.945);

// 太阳炫光：屏幕空间太阳位 + 强度（由脚本按昼夜驱动）
uniform vec2 sun_uv = vec2(0.78, 0.16);
uniform float flare_intensity : hint_range(0.0, 2.0) = 1.0;
uniform float top_light : hint_range(0.0, 0.3) = 0.12;
uniform float time_seed = 0.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 from_center = uv - vec2(0.5);
	// 纵横比校正：让色差/渐晕/炫光的圆形度量在宽屏下不变成椭圆
	vec2 aspect = vec2(SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x, 1.0);

	// ── 1) 边缘色差：离中心越远 R/B 通道偏移越大 ─────────────────────────
	vec2 ca = from_center * aspect * (aberration_px * SCREEN_PIXEL_SIZE);
	vec3 col;
	col.r = texture(screen_tex, uv + ca).r;
	col.g = texture(screen_tex, uv).g;
	col.b = texture(screen_tex, uv - ca).b;

	// ── 2) 暖色分级：tint → 饱和度 → 轻对比 ──────────────────────────────
	col *= warm_tint;
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(lum), col, saturation);
	col = clamp((col - 0.5) * contrast + 0.5, vec3(0.0), vec3(1.0));

	// ── 3) 顶部天光：上强下无的暖金渐变（黄金时刻氛围）──────────────────
	float top_f = pow(clamp(1.0 - uv.y, 0.0, 1.0), 2.2);
	col += vec3(1.0, 0.86, 0.62) * top_f * top_light;

	// ── 4) 太阳炫光：核心 glow + 水平 streak + 3 个 ghost 次级光斑 ────────
	if (flare_intensity > 0.002) {
		float breathe = 0.88 + 0.12 * sin(time_seed * 0.6);
		float sun_dist = length((uv - sun_uv) * aspect);
		float core = exp(-sun_dist * 9.0);
		float streak = exp(-abs(uv.y - sun_uv.y) * 60.0)
			* exp(-abs((uv.x - sun_uv.x) * aspect.x) * 2.4);
		vec3 ghost_rgb = vec3(0.0);
		for (int i = 0; i < 3; i++) {
			float t = 1.3 + 0.65 * float(i);
			vec2 gp = sun_uv + (vec2(0.5) - sun_uv) * t;
			float gd = length((uv - gp) * aspect);
			float gi = exp(-gd * 55.0) * 0.5;
			vec3 hue = i == 0 ? vec3(0.60, 0.90, 1.0)
				: (i == 1 ? vec3(0.85, 0.65, 1.0) : vec3(1.0, 0.85, 0.60));
			ghost_rgb += hue * gi;
		}
		vec3 flare = vec3(1.0, 0.90, 0.72) * core * 0.50
			+ vec3(1.0, 0.85, 0.60) * streak * 0.22
			+ ghost_rgb * 0.13;
		col += flare * flare_intensity * breathe;
	}

	// ── 5) 渐晕：角落压暗，视线聚焦画面中心 ──────────────────────────────
	float r2 = length((uv - vec2(0.5)) * aspect) / (0.5 * length(aspect));
	col *= 1.0 - vignette_strength * smoothstep(0.45, 1.05, r2);

	// ── 6) 胶片颗粒：暗部更明显的微噪声（帧间抖动）──────────────────────
	float grain = hash12(uv / SCREEN_PIXEL_SIZE + vec2(time_seed * 61.7, time_seed * 43.1)) - 0.5;
	col += grain * grain_strength * (1.0 - lum * 0.6);

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
