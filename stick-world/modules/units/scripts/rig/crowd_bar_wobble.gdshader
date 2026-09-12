shader_type canvas_item;
// 血条桶（mode=0）：与原版 health_bar_indicator 像素级同构的顶点位移。
//
// - 填充网格（底/残影/填充）：wobble 已按 0.9/7 单位常量烘进顶点 y
//   （batch_rig._bar_geometry，CPU float64 同式烘表）；端头尖的 x 位移
//   （凸出 0.3×行高 + 端头相位抖动）经 UV.y.q 传入，按实例行高换算。
// - 描边环带网格：顶点 = 边界的 miter 偏移多边形（探针实验实证
//   draw_polyline join = miter：偏移 = 相邻两边世界法线角平分线 ×
//   0.8/cos(半外角)）。边向量 = DELTAS[i]（单位空间烘表，端头按基位）×
//   实例 (bw, hh) + COEFF[i]×hh（端头 x 位移修正）——条实例非均匀缩放，
//   法线随宽高比变化，必须逐实例在 shader 重建。
// - 窄条退化（plain，原版 draw_rect 回退）：无端头/无 wobble（另烘直角
//   网格），描边偏移 = (n1+n2)×0.8（直角方角，对齐 draw_rect 边框）。
// 圆点（mode=1）：实例均匀缩放，几何全烘焙，零位移。
//
// UV 编码：UV.x = 前边索引×32 + 后边索引（环带顶点）；UV.y = code×131072 + q，
// q = round((t+1)×65536)，t = 端头 x 位移系数（世界 px/行高，非端头 = 0）。
// code：0 无位移顶点 / 2,3 端头尖填充（左/右）/ 4,5 环带顶点外/内圈 /
// 6,7 端头尖环带左外/内 / 8,9 端头尖环带右外/内。
// INSTANCE_CUSTOM = (bw 行宽世界px, plain, hh 行高世界px, 0)。
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
					VERTEX += vec2(m.x / bw, m.y / hh) * (0.8 * s);
				} else {
					m = normalize(m);
					VERTEX += vec2(m.x / bw, m.y / hh) * (0.8 * s / max(dot(m, n1), 0.3));
				}
			}
		}
	}
}
