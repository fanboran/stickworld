shader_type canvas_item;

uniform vec2 resolution = vec2(920.0, 300.0);
uniform vec4 bounds = vec4(0.0, 0.0, 920.0, 300.0);
uniform vec2 bounds_bottom = vec2(170.0, 920.0);
uniform float blade_angle = -0.5236;
uniform float angle_var = 0.12;
uniform float curve_amount = 0.18;
uniform int rows = 12;
uniform int blades_per_row = 36;
uniform float row_spacing = 32.0;
uniform float blade_spacing = 14.0;
uniform float blade_length_base = 110.0;
uniform float blade_length_var = 35.0;
uniform float blade_width_base = 10.0;
uniform float blade_width_var = 3.0;
uniform float root_width_mul = 1.6;
uniform float tip_width_mul = 0.25;
uniform float width_noise = 0.45;
uniform float oil_roughness = 0.35;
uniform float margin_bottom = 35.0;
uniform float edge_noise = 1.0;
uniform float root_jitter = 6.0;
uniform float row_jitter = 12.0;
uniform int seed = 0;
uniform vec3 color1 : source_color = vec3(1.000, 0.980, 0.900);
uniform vec3 color2 : source_color = vec3(1.000, 0.930, 0.760);
uniform vec3 color3 : source_color = vec3(0.980, 0.820, 0.560);
uniform vec3 color4 : source_color = vec3(0.900, 0.620, 0.320);
uniform vec3 color5 : source_color = vec3(0.700, 0.420, 0.200);
uniform vec3 base_color : source_color = vec3(0.420, 0.260, 0.110);
uniform bool show_bounds = false;
uniform int debug_mode = 0;

void render_blade(
	vec2 p, vec2 d, vec2 n, vec2 origin, int i, int j, int rows_in, int blades_in,
	float row_t, vec2 hs, out vec3 out_col, out float alpha
) {
	vec2 ro = origin + d * (float(rows_in - 1 - i) * row_spacing);
	float s = (float(j) - float(blades_in) * 0.5) * blade_spacing;
	vec2 root = ro + n * s;
	float dbx = sin(blade_angle);
	float dby = cos(blade_angle);
	float nbx = -dby;
	float nby = dbx;
	float nblen = sqrt(nbx * nbx + nby * nby);
	nbx = nbx / nblen;
	nby = nby / nblen;
	vec2 tip = vec2(root.x + dbx * blade_length_base, root.y + dby * blade_length_base);

	float sx = tip.x - root.x;
	float sy = tip.y - root.y;
	float lsq = sx * sx + sy * sy;
	float t = 0.0;
	if (lsq > 0.0001) {
		t = clamp(((p.x - root.x) * sx + (p.y - root.y) * sy) / lsq, 0.0, 1.0);
	}
	float cx = root.x + sx * t;
	float cy = root.y + sy * t;
	float dx = p.x - cx;
	float dy = p.y - cy;
	float dist = sqrt(dx * dx + dy * dy);
	float taper = mix(root_width_mul, tip_width_mul, t * t);
	float w = blade_width_base * taper;
	// 用 if-else 阶梯函数代替 smoothstep，避免 D3D12 fragment 循环优化
	float cov;
	if (dist < w * 0.6) {
		cov = 0.85;
	} else if (dist < w * 0.9) {
		cov = 0.85 * (w * 0.9 - dist) / (w * 0.3);
	} else {
		cov = 0.0;
	}

	float hcol = fract(hs.x * 0.137 + hs.y * 0.319);

	vec3 ch;
	if (hcol < 0.24) ch = color1;
	else if (hcol < 0.46) ch = color2;
	else if (hcol < 0.66) ch = color3;
	else if (hcol < 0.84) ch = color4;
	else ch = color5;
	float lit = row_t * 0.28;
	float darken = (1.0 - row_t) * 0.18;
	ch = mix(ch, ch * (1.0 + lit - darken), 0.65);
	float lum = dot(ch, vec3(0.299, 0.587, 0.114));
	ch = mix(ch, vec3(lum), (1.0 - row_t) * 0.08);
	ch.r = clamp(ch.r + row_t * 0.03, 0.0, 1.0);
	ch.b = clamp(base_color.b, 0.0, 1.0);
	ch = mix(ch, ch * 0.92, t);
	ch = clamp(ch, 0.0, 1.0);
	out_col = ch;
	alpha = cov;
}


void fragment() {
	if (debug_mode == 2) {
		COLOR = vec4(UV, 0.0, 1.0);
	} else {
		vec2 p = UV * resolution;
		vec2 d = vec2(sin(blade_angle), cos(blade_angle));
		vec2 n = normalize(vec2(-d.y, d.x));
		float top_center = (bounds.x + bounds.z) * 0.5;
		float bottom_center = (bounds_bottom.x + bounds_bottom.y) * 0.5;
		float slope_dir = sign(bottom_center - top_center);
		float origin_shift = (bounds.z - bounds.x) * 0.15 * slope_dir;
		vec2 origin = vec2(top_center + origin_shift, bounds.y);

		vec3 out_col = vec3(0.0);
		float alpha = 0.0;

		for (int i = 0; i < 64; i++) {
			if (i < rows) {
				float row_t = float(i) / max(float(rows) - 1.0, 1.0);
				float hi = float(i) + 0.5;
				for (int j = 0; j < 32; j++) {
					if (j < blades_per_row) {
						float hj = float(j) + 0.5;
						vec2 hs = vec2(hi, hj);
						vec3 bcol;
						float ba;
						render_blade(p, d, n, origin, i, j, rows, blades_per_row, row_t, hs, bcol, ba);
						out_col = out_col * (1.0 - ba) + bcol * ba;
						alpha = alpha + ba * (1.0 - alpha);
					}
				}
			}
		}

		if (show_bounds) {
			float dbg_t = clamp((p.y - bounds.y) / (bounds.w - bounds.y), 0.0, 1.0);
			float dbg_x_min = mix(bounds.x, bounds_bottom.x, dbg_t);
			float dbg_x_max = mix(bounds.z, bounds_bottom.y, dbg_t);
			bool on_left = abs(p.x - dbg_x_min) < 1.5 && p.x >= dbg_x_min - 1.5 && p.x <= dbg_x_max + 1.5;
			bool on_right = abs(p.x - dbg_x_max) < 1.5 && p.x >= dbg_x_min - 1.5 && p.x <= dbg_x_max + 1.5;
			bool on_top = abs(p.y - bounds.y) < 1.5 && p.x >= dbg_x_min && p.x <= dbg_x_max;
			bool on_bottom = abs(p.y - bounds.w) < 1.5 && p.x >= dbg_x_min && p.x <= dbg_x_max;
			if ((on_left || on_right || on_top || on_bottom)) {
				out_col = vec3(1.0, 0.0, 0.0);
				alpha = 1.0;
			}
		}

		COLOR = vec4(out_col, 1.0);
	}
}
