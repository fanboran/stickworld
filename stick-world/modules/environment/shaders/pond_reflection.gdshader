shader_type canvas_item;
// Kingdom Two Crowns 式水面倒影 —— 屏幕纹理沿水面线镜像 + 正弦波纹扰动。
// 水面线屏幕 uv 由 pond.gd 每帧写入（相机/变焦跟随）；绘制序在天空/远山之后、
// 建筑与单位之前，故 screen_tex 已含天景（星月/极光/云）——倒影即真实天空镜像。

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
// 水面线在屏幕 uv 的 y（0=屏顶 1=屏底）
uniform float line_uv_y = 0.7;
uniform float time_seed = 0.0;
// 夜间压暗水面底色（0=白天 1=深夜）
uniform float night_mix = 0.0;
// 水体不透明度（倒影穿透感）
uniform float water_alpha : hint_range(0.0, 1.0) = 0.85;
// 波纹参数（视差扰动幅度 / 空间频率 / 时间速度）
uniform float wave_amp = 0.0028;
uniform float wave_freq = 42.0;
uniform float wave_speed = 1.8;
// 水底色（越深越浑）
uniform vec3 shallow_tint : source_color = vec3(0.13, 0.30, 0.42);
uniform vec3 deep_tint : source_color = vec3(0.05, 0.12, 0.22);
// 水面本地宽度（px，pond.gd 写入；岸沫定位用）
uniform float width_px = 1500.0;
// 岸沫带宽度（px）与强度
uniform float foam_width = 110.0;
uniform float foam_strength = 0.55;

void fragment() {
	vec2 suv = SCREEN_UV;
	// 纵向涟漪：镜像 y 上加正弦抖动（双层波叠加去机械感）
	float wob = sin(suv.y * wave_freq + time_seed * wave_speed + suv.x * 18.0) * wave_amp
			+ sin(suv.y * wave_freq * 0.37 - time_seed * wave_speed * 0.7) * wave_amp * 1.6;
	vec2 ruv = vec2(suv.x + wob, line_uv_y + (line_uv_y - suv.y));
	vec4 ref = texture(screen_tex, ruv);
	// 深度：水面为 0，越深越接近 1（按屏幕 uv 粗略标定 0.12 深度带）
	float depth_t = clamp((suv.y - line_uv_y) / 0.12, 0.0, 1.0);
	// 倒影 → 水色混合（白天倒影占主导偏亮，深处倒影淡出；夜里压暗兜底）
	vec3 base = mix(shallow_tint, deep_tint, depth_t);
	base = mix(base, base * 0.55, night_mix);
	vec3 col = mix(ref.rgb, base, 0.30 + 0.40 * depth_t);
	// 波光粼粼：浅水区细碎高光（随时间流动）
	float glint = (0.5 + 0.5 * sin(suv.x * 240.0 + time_seed * 2.6 + sin(suv.y * 60.0) * 3.0))
			* (1.0 - depth_t);
	col += glint * 0.09;
	// 水面线亮边（月色 meniscus）
	col += (1.0 - smoothstep(0.0, 0.005, suv.y - line_uv_y)) * vec3(0.55, 0.75, 0.85) * 0.28;
	// 岸沫（K2C：岸边滚动的白色泡沫条带）：两端边缘带内横向条带随时间滚动
	float edge_d = min(UV.x, width_px - UV.x);
	float foam_zone = 1.0 - smoothstep(0.0, foam_width, edge_d);
	float bands = 0.5 + 0.5 * sin(UV.y * 0.9 - time_seed * 1.6 + sin(UV.x * 0.045) * 2.2);
	float foam = foam_zone * (0.45 + 0.55 * bands) * (1.0 - 0.5 * depth_t) * foam_strength;
	col = mix(col, vec3(0.93, 0.97, 1.0), clamp(foam, 0.0, 1.0));
	COLOR = vec4(col, water_alpha);
}
