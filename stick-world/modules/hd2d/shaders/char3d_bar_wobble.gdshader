shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;
// 直渲血条桶（spatial 移植，crowd_bar_wobble.gdshader 的 3D 版）：
// 顶点位移逻辑逐行同源——wobble 幅值烘在网格（单位空间），端头尖/环带
// miter 偏移在顶点期按 INSTANCE_CUSTOM 传的行宽/行高重建；实例变换把
// 单位面片放进 26° 取景平面（宿主写入）。COLOR（实例色）直通 fragment。
// 桶序/层序语义见 crowd_renderer_buckets.build_layer（同构移植）。
uniform float mode : hint_range(0.0, 1.0) = 0.0;
uniform vec2 DELTAS[16];
uniform float COEFF[16];

void vertex() {
	if (mode < 0.5) {
		float code = floor(UV.y / 131072.0 + 0.001);
		if (code > 0.5) {
			float bw = INSTANCE_CUSTOM.x;
			float hh = INSTANCE_CUSTOM.z;
			bool plain = INSTANCE_CUSTOM.y > 0.5;
			float q = UV.y - code * 131072.0;
			bool is_tip = (code > 1.5 && code < 3.5) || code > 5.5;
			if (is_tip && !plain) {
				VERTEX.x += (q / 65536.0 - 1.0) * hh / bw;
			}
			if (code > 3.5) {
				// 环带 miter 偏移
				float i1 = floor(UV.x / 32.0 + 0.001);
				float i2 = UV.x - i1 * 32.0;
				vec2 e1 = vec2(DELTAS[int(i1)].x * bw + COEFF[int(i1)] * hh, DELTAS[int(i1)].y * hh);
				vec2 e2 = vec2(DELTAS[int(i2)].x * bw + COEFF[int(i2)] * hh, DELTAS[int(i2)].y * hh);
				vec2 n1 = normalize(vec2(e1.y, -e1.x));
				vec2 n2 = normalize(vec2(e2.y, -e2.x));
				vec2 m = n1 + n2;
				float s = 1.0;
				if (code == 5.0 || code == 7.0 || code == 9.0) {
					s = -1.0;
				}
				if (plain) {
					VERTEX.xy += vec2(m.x / bw, m.y / hh) * (0.8 * s);
				} else {
					m = normalize(m);
					VERTEX.xy += vec2(m.x / bw, m.y / hh) * (0.8 * s / max(dot(m, n1), 0.3));
				}
			}
		}
	}
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
}
