shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_always;
// char3d_mask_body.gdshader —— 描边后处理的身体桶掩码孪生材质（裁决#20）。
// 与 char3d_body_opaque 同采样口径（关节图集格位 UV 走 INSTANCE_CUSTOM），
// 输出为掩码编码：形状硬二值（discard ≤0.5）、A=1 整写（无混合损耗）。
// 深度走 **3×5bit 块级编码**：15bit 视深分 RGB 三通道、每通道 32 级、块距 8、
// 块心 2+4×fade 承运渐隐（5 档，距块缘 ≥2）——SubViewport 3D 输出恒
// RGBA8+sRGB（4.7 无 hdr 属性），直接数值打包会被 sRGB 往返在暗端放大成
// 整 LSB 深度误差（实测 0.2+ 世界单位）；块级值居格距中心，编解码往返最坏
// ±1.1 也不越块（temp/mask_pack_probe 实证，误差 ≤0.011 世界单位）。
// 视深取 (MV×VERTEX).z 取负（正交线性；同卡面部件视深=屏幕高度线性函数
// ⇒ 屏内重叠必等深，部件间分隔线在合成侧天然压死）。cam_far 由
// char_outline_post 逐帧推。武器孪生不编码深度（哨兵 0，见
// char3d_mask_weapon——武器全场景无描边，创始人全游戏口径）。
uniform sampler2D atlas_tex : filter_linear_mipmap, repeat_disable;
uniform float cam_far = 600.0;

varying vec4 slot_uv;
varying float v_depth;

void vertex() {
	slot_uv = INSTANCE_CUSTOM;
	vec4 vp = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	v_depth = -vp.z;   // 视空间前向为 -z（vertex() 的 VERTEX 是模型空间，须自乘 MV）
}

void fragment() {
	vec4 t = texture(atlas_tex, slot_uv.xy + UV * slot_uv.zw);
	if (t.a <= 0.5) {
		discard;
	}
	float q = clamp(v_depth / cam_far, 0.0, 1.0) * 32767.0;
	float l1 = floor(mod(q, 32.0));   // level 取整：小数位会漏进块心偏移污染 fade
	float q2 = floor(q / 32.0);
	float l2 = floor(mod(q2, 32.0));
	float l3 = floor(q2 / 32.0);
	float c_off = 2.0 + 4.0 * COLOR.a;
	ALBEDO = (vec3(l1, l2, l3) * 8.0 + vec3(c_off)) / 255.0;
	ALPHA = 1.0;
}
