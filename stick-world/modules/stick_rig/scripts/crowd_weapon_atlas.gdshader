shader_type canvas_item;
// 武器图集桶：INSTANCE_CUSTOM = (UV 偏移 x/y, 子区域尺寸 w/h)，顶点期把
// quad 的 0~1 UV 映射到图集子区域；透明区域 alpha=0 走默认混合自然丢弃
// （二值 alpha 自建图集实测渲染正常，坑仅在半透明软渐变纹理）
void vertex() {
	UV = UV * INSTANCE_CUSTOM.zw + INSTANCE_CUSTOM.xy;
}
