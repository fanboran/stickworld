shader_type spatial;
// char3d_body_opaque.gdshader —— 关节烘焙身体部件桶（不透明版，裁决#15）。
//
// 是什么：预烘关节贴图图集（char_joint_atlas——rig 同款 Line2D 圆头线段/
// 40 边圆由引擎画布光栅化器烘出）采样出部件形状：每部件一对 quad，描边
// 贴图垫底（宿主写段时实深度 ZB_STROKE 垫后）、填充贴图置顶——两遍层序
// 照抄矢量「全局两遍」语义。实例色 = 部件真色（描边白/填充身体色，宿主
// 已转线性域）× 光照 tint × 渐隐 alpha（本桶恒 1，渐隐段迁 fade 桶）。
//
// 混合/深度语义与烘焙卡（char_billboard）逐字对齐：blend_mix +
// depth_draw_always（部件写深度，跨角色/建筑遮挡交深度缓冲判）+
// alpha_cut discard（透明裙边不写深度，不留"透明墙"）。cull_disabled
// 容纳朝向镜像的绕序翻转。INSTANCE_CUSTOM = 格位 UV 子矩形
//（off.xy + size.zw，vertex 内建经 varying 带入 fragment——spatial 的
// INSTANCE_CUSTOM 仅 vertex 可用，见交接档 §二b-5）。
render_mode blend_mix, cull_disabled, depth_draw_always, unshaded;

uniform sampler2D atlas_tex : filter_linear_mipmap, repeat_disable;

varying vec4 slot_uv;

void vertex() {
	slot_uv = INSTANCE_CUSTOM;
}

void fragment() {
	vec4 t = texture(atlas_tex, slot_uv.xy + UV * slot_uv.zw);
	if (t.a <= 0.004) {
		discard;
	}
	ALBEDO = t.rgb * COLOR.rgb;
	ALPHA = t.a * COLOR.a;
}
