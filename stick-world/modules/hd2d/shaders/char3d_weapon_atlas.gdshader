shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix;
// 直渲武器/盾桶：按武器纹理分桶（每纹理一个 MultiMesh，纹理=桶 uniform，
// 免图集与 INSTANCE_CUSTOM 的 UV 重映射——武器种类个位数，分桶即可）。
// quad 网格为 1x1 单位面片，实例变换承载武器位姿与像素尺寸缩放；
// 实例色只用于整体透明度（尸体渐隐 alpha）与光照 tint，恒白为常态。
uniform sampler2D atlas_tex;

void fragment() {
	vec4 t = texture(atlas_tex, UV);
	ALBEDO = t.rgb * COLOR.rgb;
	ALPHA = t.a * COLOR.a;
}
