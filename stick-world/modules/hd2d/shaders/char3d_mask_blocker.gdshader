shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_always;
// char3d_mask_blocker.gdshader —— 掩码视口的建筑遮挡块（裁决#20）：
// 只写深度不写颜色（alpha=0 混合为无操作），把「被建筑挡住的角色」从
// 掩码里深度拒掉——否则屏幕空间描边会穿墙（掩码视口只看角色层，建筑
// 不在其中时挡不住）。材质级 render_priority=-100 恒先于角色掩码行
// （透明趟按优先级再按深度排序，遮挡块先行写深，后到的角色行吃深度测试）。
void fragment() {
	ALPHA = 0.0;
}
