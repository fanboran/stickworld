shader_type canvas_item;

// 把 Sprite2D 的 UV 映射到世界/像素坐标
uniform vec2 resolution = vec2(920.0, 300.0);

// 茅草生成的大致边界：x_min, y_min, x_max, y_max（像素坐标，y 向下）
// 这里 x 范围表示屋顶顶边的范围；两侧斜率由 blade_angle 自动推导。
uniform vec4 bounds = vec4(300.0, 0.0, 700.0, 300.0);

// 叶片方向：0 表示竖直向下，-1.047（-60°）表示向左下倾斜
uniform float blade_angle = -1.047;
// 单片角度随机范围（弧度）
uniform float angle_var = 0.12;
// 弯曲程度：0 = 直，1 = 明显弯曲
uniform float curve_amount = 0.18;

// 层数与密度
uniform int rows = 12;
uniform int blades_per_row = 36;
uniform float row_spacing = 32.0;
uniform float blade_spacing = 14.0;

// 叶片尺寸
uniform float blade_length_base = 110.0;
uniform float blade_length_var = 22.0;
uniform float blade_width_base = 10.0;
uniform float blade_width_var = 3.0;

// 笔刷形状
// 根部宽度倍率（>1 表示根部比 base 更粗）
uniform float root_width_mul = 1.6;
// 梢部宽度倍率（<1 表示梢部更细）
uniform float tip_width_mul = 0.25;
// 沿叶片长度方向的宽度抖动（油画笔触边缘不规则）
uniform float width_noise = 0.45;
// 笔触边缘粗糙度：0 = 光滑矢量，1 = 强烈油画边缘
uniform float oil_roughness = 0.35;

// 下边缘余量：允许部分叶片根部/梢部超出 bounds 底部这么多像素
uniform float margin_bottom = 55.0;
// 下边缘不规则程度：0 = 平直，1 = 高度随机
uniform float edge_noise = 1.0;

// 随机扰动
uniform float root_jitter = 6.0;
uniform float row_jitter = 12.0;
uniform int seed = 0;

// 配色（从 thatch_ref.png / smithy 参考提取）
// 基调更偏金黄麦秆色，避免过红过棕
uniform vec3 color1 : source_color = vec3(0.941, 0.765, 0.475);
uniform vec3 color2 : source_color = vec3(0.898, 0.659, 0.357);
uniform vec3 color3 : source_color = vec3(0.820, 0.549, 0.286);
uniform vec3 color4 : source_color = vec3(0.710, 0.424, 0.212);
uniform vec3 color5 : source_color = vec3(0.518, 0.294, 0.141);

// 调试：显示边界框
uniform bool show_bounds = false;


// 2D 伪随机，返回 [0, 1]
float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


// 根据层深 + 单片随机从 5 色板里选色，并做小幅随机偏移
// row_t: 0 = 顶层，1 = 底层
vec3 pick_color(float h, float row_t) {
	vec3 c;
	if (h < 0.20) c = color1;
	else if (h < 0.40) c = color2;
	else if (h < 0.60) c = color3;
	else if (h < 0.80) c = color4;
	else c = color5;

	// 层间基调：上层偏亮暖，下层偏暗冷
	// row_t 越大（越靠下），整体压暗并轻微降饱和
	float darken = row_t * 0.50;
	float desat = row_t * 0.15;
	c = mix(c, c * (1.0 - darken), 0.55);
	// 简单去饱和：往亮度方向拉一点
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(lum), desat * 0.25);

	// 单片内随机：亮度 + 极细微色相抖动
	float vary = (hash21(vec2(h, float(seed))) - 0.5) * 0.10;
	float hue_shift = (hash21(vec2(h + 1.0, float(seed))) - 0.5) * 0.04;
	c = clamp(c + vec3(vary + hue_shift, vary - hue_shift * 0.5, vary - hue_shift * 0.8), 0.0, 1.0);

	// 层间色调：上层偏暖黄，下层偏暖棕（RGB 中红色通道相对多一点）
	c.r = clamp(c.r + row_t * 0.02, 0.0, 1.0);
	c.b = clamp(c.b - row_t * 0.03, 0.0, 1.0);
	return c;
}


void fragment() {
	// 当前像素在世界/像素坐标系中的位置
	vec2 p = UV * resolution;

	// 叶片方向：角度从竖直向下开始，顺时针为正
	vec2 d = vec2(sin(blade_angle), cos(blade_angle));
	// 行方向垂直于叶片方向，这样每一行是一层茅草
	vec2 n = normalize(vec2(-d.y, d.x));
	// 起始角：向左倾斜时从右上角开始，向右倾斜时从左上角开始，确保叶片向区域内生长
	vec2 origin = (d.x < 0.0) ? vec2(bounds.z, bounds.y) : bounds.xy;

	vec3 out_col = vec3(0.0);
	float alpha = 0.0;

	const int MAX_ROWS = 32;
	const int MAX_BLADES = 64;

	for (int i = 0; i < MAX_ROWS; i++) {
		if (i >= rows) break;

		for (int j = 0; j < MAX_BLADES; j++) {
			if (j >= blades_per_row) break;

			// 当前叶片的确定性随机
			float hi = float(i) + 0.5;
			float hj = float(j) + 0.5;
			vec2 hash_seed = vec2(hi * 37.0, hj * 127.0) + vec2(float(seed), float(seed));

			float h_len = hash21(hash_seed);
			float h_wid = hash21(hash_seed + 1.23);
			float h_jit_x = hash21(hash_seed + 2.34);
			float h_jit_y = hash21(hash_seed + 3.45);
			float h_col = hash21(hash_seed + 4.56);
			float h_ang = hash21(hash_seed + 6.78);
			float h_curve = hash21(hash_seed + 7.89);

			// 每一层沿叶片方向向下推进，根部在行线上散开
			vec2 row_origin = origin + d * (float(i) * row_spacing + (h_jit_y - 0.5) * row_jitter);
			float s = (float(j) - float(blades_per_row) * 0.5) * blade_spacing + (h_jit_x - 0.5) * root_jitter;
			vec2 root = row_origin + n * s;

			// 叶片长度：大参数（层间波浪）+ 小参数（单片修正）
			float layer_wave = sin(float(i) * 0.7 + float(seed)) * blade_length_var * 0.5;
			float blade_len = blade_length_base + layer_wave + (h_len - 0.5) * blade_length_var;
			float blade_wid = blade_width_base + (h_wid - 0.5) * blade_width_var;

			// 单片角度和方向略有变化
			float a = blade_angle + (h_ang - 0.5) * angle_var;
			vec2 d_b = vec2(sin(a), cos(a));
			vec2 n_b = normalize(vec2(-d_b.y, d_b.x));

			vec2 tip = root + d_b * blade_len;

			// 整片裁剪：根部或梢部超出有效范围时，整片不渲染
			// 有效范围是一个平行四边形：顶部 x 范围由 bounds.x/bounds.z 定义，
			// 两侧边斜率 = tan(blade_angle)，与叶片倾斜方向一致。
			float side_slope = tan(blade_angle);
			float y_min = bounds.y;

			// 下边缘用正弦 + 每片随机做波浪，避免一刀切
			float h_edge = hash21(hash_seed + 5.67);
			float edge_wave = 0.5 + 0.5 * sin(float(i) * 1.1 + float(seed) * 0.7);
			float edge_factor = clamp(edge_wave + (h_edge - 0.5) * edge_noise, 0.0, 1.0);
			float y_max = bounds.w + margin_bottom * edge_factor;

			float root_x_at_top = root.x - (root.y - y_min) * side_slope;
			float tip_x_at_top = tip.x - (tip.y - y_min) * side_slope;
			bool root_in = root_x_at_top >= bounds.x && root_x_at_top <= bounds.z && root.y >= y_min && root.y <= y_max;
			bool tip_in = tip_x_at_top >= bounds.x && tip_x_at_top <= bounds.z && tip.y >= y_min && tip.y <= y_max;
			if (!root_in || !tip_in) {
				continue;
			}

			// 点到线段的距离（先用直线段求最近点参数 t）
			vec2 seg = tip - root;
			float len_sq = dot(seg, seg);
			float t = 0.0;
			if (len_sq > 0.0001) {
				t = clamp(dot(p - root, seg) / len_sq, 0.0, 1.0);
			}
			vec2 closest = root + seg * t;

			// 把直线段弯成弧线，模拟稻草自然弯曲
			float bend = sin(t * 3.14159265) * curve_amount * blade_len * (h_curve - 0.5);
			vec2 p_bent = p - n_b * bend;
			float dist = length(p_bent - closest);

			// 笔刷形状：根部更粗、梢部更细，中间用噪声造成不规则边缘
			float taper = mix(root_width_mul, tip_width_mul, t * t);
			float w = blade_wid * taper;
			// 沿长度方向的高频宽度抖动（油画笔触）
			float wobble = sin(t * 12.0 + hash_seed.x * 6.28) * 0.5 + 0.5;
			w *= 1.0 + (wobble - 0.5) * width_noise;
			w = max(w, 0.5);

			// 笔触边缘粗糙度：在距离场上叠加低频噪声，产生手绘毛边
			float edge_rough = (hash21(p * 0.15 + hash_seed) - 0.5) * oil_roughness * w * 0.6;
			dist -= edge_rough;

			float coverage = 1.0 - smoothstep(w * 0.40, w * 0.52, dist);

			if (coverage > 0.0) {
				float row_t = float(i) / max(float(rows) - 1.0, 1.0);
				vec3 base = pick_color(h_col, row_t);
				// 梢部稍暗，模拟稻草干枯
				base = mix(base, base * 0.72, t);
				// 手绘感：加入极细微的噪点
				float grain = hash21(p * 200.0 + hash_seed) - 0.5;
				base += grain * 0.03;
				base = clamp(base, 0.0, 1.0);

				// 油画式混合：新笔触与已绘颜色融合，而非完全覆盖
				out_col = mix(out_col, base, coverage);
				alpha = alpha + coverage * (1.0 - alpha);
			}
		}
	}

	// 边界框调试：绘制平行四边形边界
	if (show_bounds) {
		float dbg_slope = tan(blade_angle);
		float x_at_top = p.x - (p.y - bounds.y) * dbg_slope;
		bool on_left = abs(x_at_top - bounds.x) < 1.5;
		bool on_right = abs(x_at_top - bounds.z) < 1.5;
		bool on_top = abs(p.y - bounds.y) < 1.5 && x_at_top >= bounds.x && x_at_top <= bounds.z;
		bool on_bottom = abs(p.y - bounds.w) < 1.5 && x_at_top >= bounds.x && x_at_top <= bounds.z;
		if ((on_left || on_right || on_top || on_bottom)) {
			out_col = vec3(1.0, 0.0, 0.0);
			alpha = 1.0;
		}
	}

	COLOR = vec4(out_col, alpha);
}
