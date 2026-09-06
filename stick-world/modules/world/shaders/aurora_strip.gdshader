shader_type canvas_item;
render_mode blend_add, unshaded;
// 极光三角带的片元处理 —— Terraria AuroraSky 用 GameShaders.Misc["Aurora"]
// （编译型 XNB，无公开 HLSL 源）。原版观感的主体在顶点数据（AuroraSky.cs 逐顶点
// HSL 渐变 + alpha 包络），本 shader 只补两件事：
// 1. 厚度方向柔边（UV.y: 0=上缘 1=下缘，sin 半周期 → 两缘归零中部最亮）
// 2. 细竖丝缕（招牌 ray 质感：两频嵌套正弦沿带漂移，只微调亮度不做色相变化）
void fragment() {
	// COLOR 即插值后的顶点色（逐顶点 HSL × alpha 包络，见 sky_aurora.gd）
	COLOR.a *= sin(clamp(UV.y, 0.0, 1.0) * PI);
	float u = UV.x;
	float rays = 0.5 + 0.5 * sin(u * 240.0 + TIME * 0.6 + sin(u * 53.0 + TIME * 0.23) * 4.0);
	COLOR.rgb *= 0.78 + 0.22 * mix(1.0, rays, 0.6);
}
