shader_type canvas_item;

// 茅草屋顶渲染 Shader — 方案 N：零后处理
// 直接采样纹理 alpha，不做任何边缘生成/羽化/距离场处理
// 纹理本身的 alpha 通道就是真实草穗轮廓

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	
	if (base.a < 0.025) {
		discard;
	}
	
	COLOR = base;
}
