shader_type spatial;
// char3d_body_opaque.gdshader —— 关节烘焙身体部件桶（几何两遍·裁决#24）。
//
// 是什么：预烘关节贴图图集（char_joint_atlas——rig 同款 Line2D 圆头线段/
// 40 边圆由引擎画布光栅化器烘出）采样出部件形状。几何两遍照抄画布
// 「全局两遍」语义：每部件一对行——描边行（加宽胶囊格位、白色实例色、
// zb 沿法线垫后）+ 填充行（真色置顶）；depth_draw_always 下同角色填充
// 恒比描边近 ZB_STROKE，深度缓冲天然实现「填充盖描边、只在剪影外轮廓
// 出线」（画布描边 z=-1 / 填充 z=0 的 3D 等价物），跨角色/建筑照旧真深度。
//
// 两桶同款着色器、不同 edge_cutoff：
//   · 描边桶 0.004——外缘保留 ~1px 软过渡（白对场景的抗锯齿）；
//   · 填充桶 0.5——硬切边。填充边缘即描边的内边界：直通 alpha 的 mip
//     软坡（图集对屏幕 ~5× 过采样，minification 恒吃 2~3 级 mip）叠在
//     白描边上会显 2~3px 灰白镶边（#19 关节白线/「图集 mip 泛白」同源），
//     切在 0.5 等覆盖率线上：内边界 crisp，存活像素的残余坡宽 ~1 屏幕
//     像素＝恰到好处的 AA。
// 实例色 = 真色（描边白/填充身体色，宿主已转线性域）× 光照 tint ×
// 渐隐 alpha。cutoff 只作用于贴图 ramp（t.a）——尸体淡出压 COLOR.a 时
// 形状不提前蒸发。
// blend_mix + depth_draw_always（部件写深度，跨角色/建筑遮挡交深度缓冲
// 判）+ cull_disabled 容纳朝向镜像的绕序翻转。INSTANCE_CUSTOM = 格位
// UV 子矩形（off.xy + size.zw，vertex 内建经 varying 带入 fragment——
// spatial 的 INSTANCE_CUSTOM 仅 vertex 可用，见交接档 §二b-5）。
render_mode blend_mix, cull_disabled, depth_draw_always, unshaded;

uniform sampler2D atlas_tex : filter_linear_mipmap, repeat_disable;
uniform float edge_cutoff = 0.004;

varying vec4 slot_uv;

void vertex() {
	slot_uv = INSTANCE_CUSTOM;
}

void fragment() {
	vec4 t = texture(atlas_tex, slot_uv.xy + UV * slot_uv.zw);
	if (t.a <= edge_cutoff) {
		discard;
	}
	ALBEDO = t.rgb * COLOR.rgb;
	ALPHA = t.a * COLOR.a;
}
