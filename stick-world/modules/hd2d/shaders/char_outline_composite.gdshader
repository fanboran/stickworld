shader_type canvas_item;
// char_outline_composite.gdshader —— 屏幕空间描边合成（裁决#20）。
// 对角色掩码（A=形状二值；RGB=3×5bit 块级深度编码，块心偏移承运渐隐）
// 做环形膨胀：膨胀邻域里取**最靠前**的角色作为轮廓归属（前角色的轮廓线
// 正确压在后角色身上——前后角色分隔线），目标像素自身是角色时须邻居
// 明显更靠前才出线（depth_eps 压掉等深——正交下同卡面部件屏内重叠必等深，
// 平面剪影语义：单角色内部无描边）。掩码纹理 filter_nearest：屏幕像素与
// 掩码纹素 1:1，最近邻免插值破坏块级编码。
uniform sampler2D mask_tex : filter_nearest;
uniform float cam_far = 600.0;
uniform float outline_w = 2.0;   // 轮廓宽（屏幕 px）
uniform vec4 outline_col : source_color = vec4(1.0);
uniform float depth_eps = 0.08;  // 前后角色分隔线的深度差门槛（世界单位）
uniform vec2 vp_size = vec2(1920.0, 1080.0);

// 块级解码：level=floor(v/8)（块心 2..6 距块缘 ≥2，往返误差 ≤~1.1 稳不越块）
// 返回 (深度, 渐隐)
vec2 decode_mask(vec3 rgb) {
	vec3 v = rgb * 255.0;
	float l1 = floor(v.r / 8.0);
	float l2 = floor(v.g / 8.0);
	float l3 = floor(v.b / 8.0);
	float depth = (l1 + l2 * 32.0 + l3 * 1024.0) / 32767.0 * cam_far;
	vec3 fr = (v - floor(v / 8.0) * 8.0 - 2.0) / 4.0;
	float fade = clamp((fr.r + fr.g + fr.b) / 3.0, 0.0, 1.0);
	return vec2(depth, fade);
}

void fragment() {
	vec4 m0 = texture(mask_tex, UV);
	bool self_is_char = m0.a > 0.5;
	float self_d = 0.0;
	if (self_is_char) {
		self_d = decode_mask(m0.rgb).x;
	}
	// 邻域 = 以 outline_w/2 为格距的 5×5 方阵（去四角 = 21 采样，半径 ≤2.24px）。
	// 原「16 方向 × 2 半径」环形采样在细/斜特征上会漏采（最近邻 + 硬边掩码下，
	// 两个采样点之间的像素可能整圈都探不到）——描边断续，肉眼即"描边变浅"。
	// 方阵逐像素铺满邻域、无角度空档，采样数还比原来少。
	float step_px = max(outline_w, 1.0) * 0.5;
	float best_d = 1e9;
	float best_fade = 0.0;
	bool hit = false;
	for (int dy = -2; dy <= 2; dy++) {
		for (int dx = -2; dx <= 2; dx++) {
			if (abs(dx) == 2 && abs(dy) == 2) {
				continue;   // 四角（半径 2.83）去掉：让外圈半径 ≤2.24，描边宽度均匀
			}
			vec2 o = vec2(float(dx), float(dy)) * step_px / vp_size;
			vec4 m = texture(mask_tex, UV + o);
			if (m.a > 0.5) {
				vec2 df = decode_mask(m.rgb);
				if (df.x > 0.001 && df.x < best_d) {   // 哨兵0=武器占位，不是描边源
					best_d = df.x;
					best_fade = df.y;
					hit = true;
				}
			}
		}
	}
	// canvas_item fragment 禁 return——单出口汇总：
	//   背景像素：命中即画；角色像素：邻居明显更靠前才画（前后分隔线），等深不画
	vec4 col = vec4(0.0);
	if (hit) {
		bool front_sep = self_is_char && best_d < self_d - depth_eps;
		if (!self_is_char || front_sep) {
			col = vec4(outline_col.rgb, outline_col.a * best_fade);
		}
	}
	COLOR = col;
}
