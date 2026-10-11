shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_always;
// char3d_mask_weapon.gdshader —— 描边后处理的武器/盾桶掩码孪生（裁决#20）。
// 与 char3d_weapon_atlas 同采样口径（整纹理 UV、实例色承运渐隐）。
// **武器全场景无描边（创始人全游戏口径）**——武器孪生不是描边源：编码写
// 深度哨兵 0（块级编码 level 全 0，正常角色视深 ≥ near ⇒ 永不为 0），作用：
// ① 合成源扫描跳过哨兵（武器自身/武器旁背景永不因武器出线）；② 目标像素
// 落在武器上时（m0 有形）邻域深度恒 ≤ 哨兵 0 ⇒ 判不出"更靠前" ⇒ 身后
// 角色的描边线不穿武器、自身轮廓线不压武器（旧路线 = 武器 quad 盖描边环
// 的等价语义）。形状硬二值（discard ≤0.5）、A=1 整写。块级编码见
// char3d_mask_body 类头。
uniform sampler2D atlas_tex;

void fragment() {
	vec4 t = texture(atlas_tex, UV);
	if (t.a <= 0.5) {
		discard;
	}
	ALBEDO = vec3(6.0 / 255.0);   // 哨兵：块 0 + 块心 6（解码=深度 0）
	ALPHA = 1.0;
}
