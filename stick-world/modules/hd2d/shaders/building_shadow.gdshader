shader_type spatial;
// building_shadow.gdshader —— 建筑接地影（HD-2D：把建筑钉在路肩上）
//
// 是什么：贴地的水平 quad，椭圆软影，铺在建筑正前方 1~2.5 格的路肩带上。
// 为什么需要：建筑卡里烘的接触阴影在**卡的深度面**上（z≈-1.5），而路肩面
//   （z∈[0,4]）比它更靠近相机 → 深度测试判路肩赢，烘的接触阴影会被路肩整片盖掉。
//   不补这一张，建筑就浮在路肩上、基线读不准（创始人反馈"建筑出现在路槛/道路带
//   下面"的观感来源）。补上后：建筑基线 = 路肩带顶线，且影落在路肩上。
render_mode blend_mix, unshaded, cull_disabled, depth_draw_never;

uniform vec4 blob_color : source_color = vec4(0.10, 0.09, 0.08, 0.42);
// 影在深度方向（屏幕纵向）的衰减比横向快：横向几乎铺满建筑宽度，
// 纵向只延伸 1~2.5 格，读作"建筑往外投的一片接地影"。
uniform float core_x : hint_range(0.0, 1.0) = 0.62;
uniform float core_y : hint_range(0.0, 1.0) = 0.06;

void fragment() {
	vec2 d = (UV - vec2(0.5)) * 2.0;
	float r = length(vec2(d.x / max(core_x, 0.001), d.y / max(core_y, 0.001)));
	float a = 1.0 - smoothstep(0.35, 1.0, r);
	ALBEDO = blob_color.rgb;
	ALPHA = a * blob_color.a;
}
