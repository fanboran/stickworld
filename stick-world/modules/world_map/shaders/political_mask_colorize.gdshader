shader_type canvas_item;
// 政权 ID mask 查表上色（R7/R9 过渡态裁决）：
//   id_mask 单通道（R 通道有效），像素值 = 政权 lut_index（1..80），0 = 无归属；
//   lut 为 256x1 色表（PoliticalLut 运行时维护，来自 political_data.json 的
//   CONTENT_PALETTE 派生色）——改 LUT 纹理即全图即时换色，零重烘。
// L2/L3 版 mask 另含保留码 253=自由城邦（无归属陆地）/ 254=湖泊 / 255=邻区灰底
// （PoliticalLut 同码表上色），0（海洋）统一输出 empty_color，与旧烘焙贴图的观感等价。
// 采样必须 NEAREST：ID 值不可插值混合。
//
// 边缘抗锯齿（第四批反馈：L2 政治图「正方形像素马赛克」）：
//   政治层是栅格 mask，L2 视角接近 1:1 采样，1 纹素台阶全部暴露成锯齿。
//   这里用「十字 5 点 ID 投票」做 1 纹素宽的软边：邻居 ID 与中心不同就把它的
//   LUT 色按票数混进来——边界变成 1px 的双色过渡，而不是硬台阶。
//   ID 本身仍逐点取自 NEAREST 采样，不存在插值混 ID 的问题。

uniform sampler2D id_mask: filter_nearest, repeat_disable;
uniform sampler2D lut: filter_nearest, repeat_disable;
uniform vec4 empty_color: source_color = vec4(0.117647, 0.215686, 0.372549, 1.0);

float id_at(vec2 uv) {
	return floor(texture(id_mask, uv).r * 255.0 + 0.5);
}

vec3 color_of(float idx) {
	return idx < 0.5 ? empty_color.rgb : texture(lut, vec2((idx + 0.5) / 256.0, 0.5)).rgb;
}

void fragment() {
	float idx = id_at(UV);
	vec3 acc = color_of(idx);
	float votes = 1.0;
	vec2 px = TEXTURE_PIXEL_SIZE;
	for (int i = 0; i < 4; i++) {
		vec2 off = i == 0 ? vec2(px.x, 0.0)
				: i == 1 ? vec2(-px.x, 0.0)
				: i == 2 ? vec2(0.0, px.y)
				: vec2(0.0, -px.y);
		float n = id_at(UV + off);
		if (abs(n - idx) > 0.5) {
			acc += color_of(n);
			votes += 1.0;
		}
	}
	COLOR = vec4(acc / votes, empty_color.a);
}
