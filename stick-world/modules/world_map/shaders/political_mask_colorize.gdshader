shader_type canvas_item;
// 政权 ID mask 查表上色（R7/R9 过渡态裁决）：
//   id_mask 单通道（R 通道有效），像素值 = 政权 lut_index（1..80），0 = 无归属；
//   lut 为 256x1 色表（PoliticalLut 运行时维护，来自 political_data.json 的
//   CONTENT_PALETTE 派生色）——改 LUT 纹理即全图即时换色，零重烘。
// L2/L3 版 mask 另含保留码 253=自由城邦（无归属陆地）/ 254=湖泊 / 255=邻区灰底
// （PoliticalLut 同码表上色），0（海洋）统一输出 empty_color，与旧烘焙贴图的观感等价。
// 采样必须 NEAREST：ID 值不可插值混合。

uniform sampler2D id_mask: filter_nearest, repeat_disable;
uniform sampler2D lut: filter_nearest, repeat_disable;
uniform vec4 empty_color: source_color = vec4(0.117647, 0.215686, 0.372549, 1.0);

void fragment() {
	float idx = floor(texture(id_mask, UV).r * 255.0 + 0.5);
	vec4 col = idx < 0.5 ? empty_color : texture(lut, vec2((idx + 0.5) / 256.0, 0.5));
	COLOR = col;
}
