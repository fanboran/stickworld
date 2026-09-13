shader_type spatial;
// char_billboard.gdshader —— HD-2D 原型的核心机制：2D 角色 quad 材质
//
// 是什么：quad 上贴 SubViewport 的纹理（ViewportTexture），即"2D 画出来的火柴人"
//   原样进 3D 场景。
//
// 为什么这么写（三条决定）：
//  1. `unshaded`，直接把 SubViewport 的像素原样输出。八方旅人的契约是"2D 角色保持
//     2D 的清晰度与颜色"，一旦让 3D 光照去乘它的 albedo，就等于给 2D 精灵重新打光
//     （会得到"发灰"的观感）。场景的光影响通过 `tint` / `light_add` 两个 uniform
//     **近似**注入（夜景暖光池），不做逐像素光照。
//  2. `depth_draw_never`：透明通道**不写深度**。深度测试保持开启（默认）。
//     → 建筑卡（不透明通道 depth_draw_opaque）先把深度写进缓冲，
//       角色像素若比建筑远，深度测试直接判负 → 天然被建筑遮挡。
//       遮挡不需要任何手工排序，这是 Godot 不透明/透明两通道划分的免费红利。
//     → 代价：角色**不参与深度**，因此 DOF 在角色像素上读到的是它背后几何的深度。
//  3. `cull_disabled`：quad 要在 x 轴翻面复用同一张纹理（左右朝向），背面不剔除。
//
// 姿态：quad basis = **相机基**（与建筑卡同取向），正对相机、零屏幕空间旋转、
//   零透视收缩；只有脚底锚定在世界地面点。
//
// 云影：2D 角色与 3D 场景共享同一片云 —— 这是"角色不吃场景光"的落差补上的那一块。
//   注意**只压 base color，不压 light_add**：灯笼的加色是光源落在角色上的量，
//   不该被天上的云再削一次。

render_mode blend_mix, cull_disabled, depth_draw_never, unshaded;

global uniform vec4 cloud_shadow;
#include "res://tests/dev/proto_hd2d/cloud_noise.gdshaderinc"

uniform sampler2D char_tex : source_color, filter_linear_mipmap, repeat_disable;
// 场景光近似（day = 1,1,1；night = 冷蓝压暗）
uniform vec3 tint : source_color = vec3(1.0);
// 灯笼等点光在角色附近的加色（夜景用，模拟角色被暖光"点亮"）
uniform vec3 light_add : source_color = vec3(0.0);
// SubViewport 里 alpha 之外的杂散像素（清屏残留）直接切掉
uniform float alpha_cut : hint_range(0.0, 0.5) = 0.004;
// 边缘羽化：把 SubViewport 的超采样 alpha 渐变再拉宽一点，让 2D 角色边缘
// 与「2x 烘培 + 线性过滤」的建筑卡边缘同一种柔和度。0 = 不处理，
// 0.35 ≈ 屏幕上 ~1px 的过渡带。
uniform float alpha_soften : hint_range(0.0, 1.0) = 0.35;

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 c = texture(char_tex, UV);
	if (c.a <= alpha_cut) {
		discard;
	}
	// 半像素级柔化：alpha 在 [0, soften] 区间重映射为平滑过渡
	float a = c.a;
	if (alpha_soften > 0.001) {
		a = smoothstep(0.0, alpha_soften, c.a);
	}
	a = clamp(a * (1.0 + alpha_soften), 0.0, 1.0);
	ALBEDO = c.rgb * tint * (1.0 - cloud_shadow_at(wp.xz)) + light_add * a;
	ALPHA = a;
}
