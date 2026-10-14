shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, depth_test_disabled;
// 直渲血条图集面片：采样槽位 UV 子矩形（INSTANCE_CUSTOM = off.xy + scale.zw，
// vertex 内建经 varying 带入 fragment），图集本体是 HealthBarIndicator
// 驱动镜像画进共享视口的回读纹理（原版画法）。
// blend_mix 透明混合：条的暗底 alpha≈0.72 需与背景正确混合（烘焙路线卡片
// 同为半透明混合语义）。
// 血条＝单位 HUD 层：depth_test_disabled + 材质 render_priority 压过全部
// 身体/武器桶（见 char_bar_atlas 头注）——免深度测试后"谁画在后"只由透明
// 排序决定，priority 10 保证条恒在所有单位件之后画；条与条之间同优先级
// 仍按 3D 深度排序（前排条盖后排条）。
// filter_linear_mipmap：回读纹理带 mip 链（char_bar_atlas 回读时生成），
// 屏上 minification ~3× 无 mip 双线性会闪断/爬行。
uniform sampler2D atlas_tex : source_color, filter_linear_mipmap;

varying vec4 slot_uv;

void vertex() {
	slot_uv = INSTANCE_CUSTOM;
}

void fragment() {
	vec2 uv = vec2(slot_uv.x, slot_uv.y) + UV * vec2(slot_uv.z, slot_uv.w);
	vec4 c = texture(atlas_tex, uv);
	ALBEDO = c.rgb * COLOR.rgb;
	ALPHA = c.a * COLOR.a;
}
