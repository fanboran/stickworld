shader_type canvas_item;
// 血条桶手绘感：顶点 boiling 扰动（边缘 sin 扰动，相位按 floor(TIME/0.12)
// 离散跳变复刻「逐帧重掷 seed」的 boiling line 质感）。
// INSTANCE_CUSTOM = (单位相位差 seed, 扰动幅度[局部单位], 0, 0)
// 条模式（横条 mesh）：上下边缘顶点（|y|≈0.5）沿 y 扰动；
// 圆点模式（圆 mesh）：径向 8 瓣扰动。
uniform float mode : hint_range(0.0, 1.0) = 0.0; // 0=条 1=圆

void vertex() {
	float ph = floor(TIME / 0.12) * 7.13 + INSTANCE_CUSTOM.x;
	float amp = INSTANCE_CUSTOM.y;
	if (mode < 0.5) {
		// 条：只扰动上下边缘顶点（|UV.y-0.5|→接近 0.5 的才是边缘；
		// 用 VERTEX.y 相对半高 0.5 的比例衰减，中部顶点不动）
		float edge_w = abs(VERTEX.y) / 0.5;
		VERTEX.y += sign(VERTEX.y) * edge_w * amp * (sin(VERTEX.x * 13.0 + ph) * 0.6 + sin(VERTEX.x * 31.0 + ph * 1.7) * 0.4);
	} else {
		// 圆：径向扰动（40 边圆 mesh，8 瓣低频 + 高频细节）
		float ang = atan(VERTEX.y, VERTEX.x);
		VERTEX += normalize(VERTEX) * amp * (sin(ang * 8.0 + ph) * 0.6 + sin(ang * 17.0 + ph * 1.7) * 0.4);
	}
}
