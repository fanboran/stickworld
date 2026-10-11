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
	float best_d = 1e9;
	float best_fade = 0.0;
	bool hit = false;
	for (int i = 0; i < 16; i++) {
		float ang = TAU * float(i) / 16.0;
		vec2 o = vec2(cos(ang), sin(ang)) * (outline_w / vp_size);
		vec4 m = texture(mask_tex, UV + o);
		if (m.a > 0.5) {
			vec2 df = decode_mask(m.rgb);
			if (df.x > 0.001 && df.x < best_d) {   // 哨兵0=武器占位，不是描边源
				best_d = df.x;
				best_fade = df.y;
				hit = true;
			}
		}
		vec4 m2 = texture(mask_tex, UV + o * 0.5);
		if (m2.a > 0.5) {
			vec2 df = decode_mask(m2.rgb);
			if (df.x > 0.001 && df.x < best_d) {
				best_d = df.x;
				best_fade = df.y;
				hit = true;
			}
		}
	}
	// canvas_item fragment 禁 return——单出口汇总：
	//   背景像素：命中即画；角色像素：邻居明显更靠前才画（前后分隔线），等深不画
	vec4 col = vec4(0.0);
	if (hit) {
		bool on_background = m0.a <= 0.5;
		bool front_sep = m0.a > 0.5 && best_d < decode_mask(m0.rgb).x - depth_eps;
		if (on_background || front_sep) {
			col = vec4(outline_col.rgb, outline_col.a * best_fade);
		}
	}
	COLOR = col;
}
