shader_type spatial;
render_mode unshaded, cull_disabled;
// 直渲身体部件桶（不透明版）：实例色（MultiMesh use_colors → COLOR）直进。
// 部件几何纯色无纹理；cull_disabled 容纳朝向镜像的三角形绕序翻转；
// 同角色部件共面，次序由宿主写入的 z_bias 决定（描边垫后/填充按发射序）。
// 部件排序依赖不透明深度写（默认深度写开）。
void fragment() {
	ALBEDO = COLOR.rgb;
}
