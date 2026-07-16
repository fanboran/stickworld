shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, vertex_lighting;

// 高度图（线性：原始 -0.1~1.0 映射到 16-bit 0~65535，着色器内恢复 h_raw = sample * 1.1 - 0.1）
uniform sampler2D heightmap : filter_linear;
uniform sampler2D landmask : filter_nearest;
uniform sampler2D river_mask : filter_nearest;
uniform sampler2D lake_mask : filter_nearest;

uniform float height_scale : hint_range(0.0, 50.0) = 7.5;
uniform float water_width : hint_range(0.0, 0.002) = 0.0008;

varying float v_h_raw;
varying float v_eff;  // 有效陆地（含湖泊）

void vertex() {
	// 恢复原始高度：h_raw = sample * 1.1 - 0.1
	float h_raw = texture(heightmap, UV).r * 1.1 - 0.1;
	float land = texture(landmask, UV).r;
	float lake = texture(lake_mask, UV).r;
	float eff = max(land, lake);
	v_h_raw = h_raw;
	v_eff = eff;
	// 线性垂直位移，海洋 (<0) 不抬升
	VERTEX.y += max(h_raw, 0.0) * height_scale * eff;
}

float sample_dilated(sampler2D tex, vec2 uv, float w) {
	float v = 0.0;
	v += texture(tex, uv).r;
	v += texture(tex, uv + vec2(w, 0.0)).r;
	v += texture(tex, uv - vec2(w, 0.0)).r;
	v += texture(tex, uv + vec2(0.0, w)).r;
	v += texture(tex, uv - vec2(0.0, w)).r;
	v += texture(tex, uv + vec2(w, w)).r;
	v += texture(tex, uv - vec2(w, w)).r;
	v += texture(tex, uv + vec2(-w, w)).r;
	v += texture(tex, uv - vec2(-w, w)).r;
	return clamp(v / 9.0, 0.0, 1.0);
}

void fragment() {
	float h = v_h_raw;
	float eff = v_eff;

	vec3 deep_ocean = vec3(0.03, 0.10, 0.28);
	vec3 ocean      = vec3(0.08, 0.25, 0.45);
	vec3 shallow    = vec3(0.20, 0.45, 0.60);
	vec3 beach      = vec3(0.80, 0.74, 0.55);
	vec3 grass      = vec3(0.35, 0.55, 0.25);
	vec3 forest     = vec3(0.18, 0.38, 0.15);
	vec3 rock       = vec3(0.42, 0.38, 0.33);
	vec3 snow       = vec3(0.92, 0.92, 0.90);

	vec3 color;
	if (eff < 0.5) {
		// 海洋
		float t = clamp((h + 0.1) / 0.1, 0.0, 1.0);
		color = mix(deep_ocean, ocean, smoothstep(0.0, 0.5, t));
		color = mix(color, shallow, smoothstep(0.5, 1.0, t));
	} else {
		// 陆地：沙滩 -> 草地 -> 森林 -> 岩石 -> 雪（原始值 0.0~0.93）
		if (h < 0.04) {
			color = mix(beach, grass, h / 0.04);
		} else if (h < 0.28) {
			color = mix(grass, forest, (h - 0.04) / 0.24);
		} else if (h < 0.56) {
			color = mix(forest, rock, (h - 0.28) / 0.28);
		} else if (h < 0.79) {
			color = mix(rock, snow, (h - 0.56) / 0.23);
		} else {
			color = snow;
		}
	}

	// ── 水体叠加 ──────────────────────────────────────────
	float on_land = step(0.5, eff);

	// 河流：加粗、深色
	float river = sample_dilated(river_mask, UV, water_width) * on_land;
	color = mix(color, vec3(0.06, 0.18, 0.35), river);

	// 湖泊
	float lake = sample_dilated(lake_mask, UV, water_width) * on_land;
	color = mix(color, vec3(0.08, 0.22, 0.42), lake);

	float water = max(river, lake);
	ALBEDO = color;
	ROUGHNESS = mix(0.9, 0.2, water);
	METALLIC = 0.0;
	SPECULAR = mix(0.15, 0.6, water);
}