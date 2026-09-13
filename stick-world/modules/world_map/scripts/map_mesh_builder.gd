class_name MapMeshBuilder
extends RefCounted
## 政治矢量 fill 的 ArrayMesh 构建（边界超分 S3 共用工具，L2/L3 渲染器同源）。
##
## 顶点色 = PoliticalLut 采样的**最终显示 RGB**（直烘，无 shader——实测 d3d12 下
## ShaderMaterial 的 canvas mesh 在 L3 真实场景整体不渲染，无材质可靠；LUT 改色
## 由渲染器订阅 state_color_changed 后调 rebake_colors 重烘）。
##
## ⚠️ canvas 渲染的 ArrayMesh 单 surface 顶点数受 65535（16-bit index）限制——
## 超限的 surface 实测整体不渲染（L3 全图 fill 34 万顶点曾整幅消失，L2 小 region
## 正常）。这里按三角形流式分块（每 surface 顶点重映射、≤ SURFACE_MAX_VERTS），
## 对索引引用顺序零假设。

## 单 surface 顶点上限（留余量避开 65535 边界与单三角 +3 溢出）
const SURFACE_MAX_VERTS := 20000


## 分块构建：每个 ArrayMesh 恰一个 surface。顶点色 = PoliticalLut 采样的**最终
## 显示 RGB**（直烘，无 shader——实测 d3d12 下 ShaderMaterial 的 canvas mesh 在
## L3 场景整体不渲染，无材质正常）。LUT 改色时用 rebake_colors 重烘顶点色。
static func build_political_fill_parts(verts: PackedVector2Array, codes: PackedInt32Array,
		idx: PackedInt32Array, lut: PoliticalLut) -> Array:
	var out: Array = []
	if verts.is_empty() or idx.is_empty() or codes.size() < verts.size():
		return out
	var sverts := PackedVector2Array()
	var scolors := PackedColorArray()
	var sidx := PackedInt32Array()
	var remap := {}
	for t in range(0, idx.size(), 3):
		var grows := false
		for k in 3:
			if not remap.has(idx[t + k]):
				grows = true
		# 本三角引入新顶点会突破上限 → 先收口当前块
		if grows and sverts.size() + 3 > SURFACE_MAX_VERTS and not sverts.is_empty():
			out.append(_make_surface_mesh(sverts, scolors, sidx))
			sverts = PackedVector2Array()
			scolors = PackedColorArray()
			sidx = PackedInt32Array()
			remap = {}
		for k in 3:
			var gi := idx[t + k]
			var local: int = remap.get(gi, -1)
			if local < 0:
				local = sverts.size()
				remap[gi] = local
				sverts.append(verts[gi])
				scolors.append(lut.color_of_code(codes[gi]))
			sidx.append(local)
	if not sverts.is_empty():
		out.append(_make_surface_mesh(sverts, scolors, sidx))
	return out


## LUT 改色重烘：对已建 parts（verts/codes 缓存）按新 LUT 重写顶点色。
## parts_meshes 元素 = ArrayMesh；就地重建 surface（draw_mesh 路线由渲染器
## 持缓存数组，直接替换元素）。
static func rebake_colors(parts_meshes: Array, codes: PackedInt32Array,
		lut: PoliticalLut) -> void:
	for mi in parts_meshes.size():
		var m: ArrayMesh = parts_meshes[mi]
		if m == null or m.get_surface_count() == 0:
			continue
		var arrays: Array = m.surface_get_arrays(0)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		# 本块的 code 段由调用方按块顶点数切——这里用顶点数累计（构建顺序一致）
		var n: int = colors.size()
		if _rebake_offsets.is_empty() or mi >= _rebake_offsets.size():
			return   # 需要调用方先 setup_rebake_offsets
		var base: int = _rebake_offsets[mi]
		for i in n:
			colors[i] = lut.color_of_code(codes[base + i])
		arrays[Mesh.ARRAY_COLOR] = colors
		var rebuilt := ArrayMesh.new()
		rebuilt.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		parts_meshes[mi] = rebuilt

## 重烘用：每块 mesh 对应 codes 的起始偏移（build 后由渲染器按块顶点数累计设置）
static var _rebake_offsets: PackedInt32Array = PackedInt32Array()


## 记录每块 codes 偏移（build 时顶点顺序 = codes 顺序的分块切分）
static func setup_rebake_offsets(parts_meshes: Array) -> void:
	_rebake_offsets = PackedInt32Array()
	var acc := 0
	for m in parts_meshes:
		var am: ArrayMesh = m
		if am != null and am.get_surface_count() > 0:
			var vs: PackedVector2Array = am.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			_rebake_offsets.append(acc)
			acc += vs.size()


static func _make_surface_mesh(sverts: PackedVector2Array, scolors: PackedColorArray,
		sidx: PackedInt32Array) -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = sverts
	arr[Mesh.ARRAY_COLOR] = scolors
	arr[Mesh.ARRAY_INDEX] = sidx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


static func _flush_surface(mesh: ArrayMesh, sverts: PackedVector2Array,
		scolors: PackedColorArray, sidx: PackedInt32Array) -> void:
	if sverts.is_empty() or sidx.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = sverts
	arr[Mesh.ARRAY_COLOR] = scolors
	arr[Mesh.ARRAY_INDEX] = sidx
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
