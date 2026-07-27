shader_type canvas_item;
// 最小测试：整个多边形填充红色 + 透明度

uniform vec2 resolution = vec2(186.0, 140.0);

void fragment() {
	vec2 p = UV * resolution;
	// 简单测试：填充红色，alpha=0.5
	COLOR = vec4(1.0, 0.0, 0.0, 0.5);
}