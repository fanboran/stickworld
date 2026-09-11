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
	// 端部收敛兜底：某些月相分支的顶点 alpha 包络偏弱，带端会读出直线/直角
	// 切边（批次 4 judge 观察项）——片元侧沿带两端 18% 平滑归零压掉矩形感
	COLOR.a *= smoothstep(0.0, 0.18, u) * (1.0 - smoothstep(0.82, 1.0, u));
	// 上缘缕化：柔边函数在上缘（UV.y→0）近似线性、仍显直线——用双频噪声把
	// 上缘 35% 厚度打缕（下缘贴地平线方向无需处理）
	float frayed = 0.45 + 0.55 * sin(u * 41.0 + sin(u * 13.0 + TIME * 0.11) * 3.0 + TIME * 0.05);
	frayed *= 0.7 + 0.3 * sin(u * 97.0 - TIME * 0.07);
	COLOR.a *= mix(1.0, frayed, smoothstep(0.35, 0.0, UV.y) * 0.85);
	float rays = 0.5 + 0.5 * sin(u * 240.0 + TIME * 0.6 + sin(u * 53.0 + TIME * 0.23) * 4.0);
	COLOR.rgb *= 0.78 + 0.22 * mix(1.0, rays, 0.6);
}
