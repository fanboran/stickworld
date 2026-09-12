shader_type canvas_item;
// 血条桶手绘感：顶点 boiling 扰动——直接复刻原版 health_bar_indicator
// _wobble 的 hash 公式（每顶点独立随机、seed 每 0.12s 整体重掷 = 逐帧跳变
// 的 boiling line），相位叠加 INSTANCE_CUSTOM.x 做单位间错相。
// INSTANCE_CUSTOM = (单位相位 seed, 扰动幅度[局部单位], 0, 0)
// mode 0=条（12 段网格，UV.x=分段位置，上下边按原版 i / i+40 索引扰动 y）
// mode 1=圆（10 段粗粝圆，UV.x=段索引，径向扰动）
uniform float mode : hint_range(0.0, 1.0) = 0.0;

float wobble(float i, float seed) {
	return fposmod(sin(i * 127.1 + seed * 0.3117) * 43758.5453, 1.0) - 0.5;
}

void vertex() {
	float seed = floor(TIME / 0.12) * 13.73 + INSTANCE_CUSTOM.x;
	float amp = INSTANCE_CUSTOM.y;
	if (mode < 0.5) {
		float side = sign(VERTEX.y);
		float i = UV.x * 12.0;
		if (side < 0.0) {
			i += 40.0;
		}
		VERTEX.y += side * wobble(i, seed) * amp;
	} else {
		float i = floor(UV.x * 10.0 + 0.5);
		VERTEX += normalize(VERTEX) * wobble(i, seed) * amp;
	}
}
