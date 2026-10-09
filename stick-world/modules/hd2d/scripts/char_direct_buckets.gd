extends Node
## char_direct_buckets.gd —— S2 直渲路线的全局 3D 桶管理（每 hd2d_world 一份）。
##
## 职责：角色身体部件（4 桶 × 不透明/渐隐双材质）+ 武器/盾（按纹理分桶）+
## 血条覆盖层（wobble 相位组，crowd 血条的 3D 移植）的 MultiMesh 装配、
## 槽位分配、每帧上传。宿主（char_rig_3d）在晚优先级 _process(1100) 把解算后
## 姿态写进各桶缓冲，本节点以更晚的 1200 一次性整缓冲上传。
##
## 布局（temp/mm3d_render_probe 实证，与 2D 的行交错布局不同！）：
##   TRANSFORM_3D 每实例 12 floats = [cx.x,cx.y,cx.z, ox, cy.x,cy.y,cy.y→oy, cz...] 列连续：
##   f0-2=基列X, f3=origin.x, f4-6=基列Y, f7=origin.y, f8-10=基列Z, f11=origin.z
##   + use_colors 4 floats（RGBA）+ use_custom_data 4 floats（血条 wobble 用）。
##   spatial 侧实例色经 COLOR、自定义数据经 INSTANCE_CUSTOM 到达 shader（同探针实证）。
##
## 部件表与几何同源 2D 链：crowd_renderer_bake.build_bucket_tables（SKELETON_DATA
## 逐段 4 桶拆分）——描边/填充桶序、发射序（腿→躯干→颈/头→臂）与 2D 战场
## 完全一致，观感同源。共面部件次序由 z_bias 决定（描边垫后 −0.004 起，
## 填充按发射序 +i×1e-5 递进朝相机），不依赖绘制序。

const Skel := preload("res://modules/stick_rig/api.gd").SKELETON_SCRIPT
const Bake := preload("res://modules/stick_rig/api.gd").CROWD_BAKE_SCRIPT
const BatchRig := preload("res://modules/stick_rig/api.gd").CROWD_BATCH_RIG_SCRIPT

const BODY_SHADER_OPAQUE := preload("res://modules/hd2d/shaders/char3d_body_opaque.gdshader")
const BODY_SHADER_FADE := preload("res://modules/hd2d/shaders/char3d_body_fade.gdshader")
const WEAPON_SHADER := preload("res://modules/hd2d/shaders/char3d_weapon_atlas.gdshader")
const BAR_SHADER := preload("res://modules/hd2d/shaders/char3d_bar_wobble.gdshader")

## 世界占位 AABB（MultiMesh 剔除按盒，实例动态写入不逐帧精确，给全域冗余）
const WORLD_AABB := AABB(Vector3(-30000.0, -2000.0, -30000.0), Vector3(60000.0, 4000.0, 60000.0))
## 同角色部件的深度微移基准（见类头 z_bias 说明；远小于相邻角色纵深差）
const ZBIAS_STROKE := -0.004
const ZBIAS_STEP := 0.00001

# ─────────────────────────── 静态共享表（全进程一份） ───────────────────────────

## crowd 拓扑（骨骼 id 先序）+ 部件 4 桶表（骨拓扑下标、预烘局部变换、已解析真色）
static var _topo_ids: PackedInt32Array = PackedInt32Array()
static var _id_to_topo: Dictionary = {}
static var _part_bidx: Array = []     # PackedInt32Array ×4（拓扑下标）
static var _part_xform: Array = []    # Array[Transform2D] ×4
static var _part_color: Array = []    # PackedColorArray ×4（哨兵已解析：身体暗色/描边白）
static var _part_zbias: Array = []    # PackedFloat32Array ×4
static var _statics_ready := false
static var _quad3d: ArrayMesh = null
static var _circle3d: ArrayMesh = null
## 描边宽 zoom 补偿当前值（set_outline_zoom 变更时全表重烘）
static var _bake_ow: float = Skel.OUTLINE_WIDTH


static func _ensure_statics() -> void:
	if _statics_ready:
		return
	_statics_ready = true
	var topo: Dictionary = Bake.build_bone_topology()
	_topo_ids = topo["ids"]
	for i in _topo_ids.size():
		_id_to_topo[_topo_ids[i]] = i
	_rebuild_part_tables()


## 部件表重烘（首建与描边宽变化共用）：crowd 表 + 哨兵色解析 + z_bias 编号。
## 描边宽变化只改 xform 内容（桶数/件数/骨序不变），宿主自动取新值。
static func _rebuild_part_tables() -> void:
	var t: Array = Bake.build_bucket_tables(_topo_ids, _bake_ow)
	_part_bidx = t[0]
	_part_xform = t[1]
	var raw_colors: Array = t[2]
	_part_color = []
	_part_zbias = []
	for j in 4:
		var cols: PackedColorArray = raw_colors[j]
		var resolved := PackedColorArray()
		resolved.resize(cols.size())
		var biases := PackedFloat32Array()
		biases.resize(cols.size())
		var base: float = ZBIAS_STROKE if j < 2 else 0.0
		for i in cols.size():
			var c: Color = cols[i]
			if c == Color.WHITE:
				c = Skel.DEFAULT_BODY
			elif c == Color.BLACK:
				c = Skel.DEFAULT_OUTLINE
			resolved[i] = c
			biases[i] = base + float(i) * ZBIAS_STEP
		_part_color.append(resolved)
		_part_zbias.append(biases)


## 描边宽 zoom 补偿（宿主收 set_outline_zoom 后调本口）：全表重烘。
static func set_outline_width(eff: float) -> void:
	if absf(eff - _bake_ow) < 0.001:
		return
	_bake_ow = eff
	if _statics_ready:
		_rebuild_part_tables()


# ─────────────────────────── 静态网格（3D 版） ───────────────────────────

## 1x1 居中 quad（XY 平面，z=0，白色顶点色——MultiMesh 实例色与顶点色相乘）
static func get_quad3d() -> ArrayMesh:
	if _quad3d != null:
		return _quad3d
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, -0.5, 0), Vector3(0.5, -0.5, 0), Vector3(0.5, 0.5, 0), Vector3(-0.5, 0.5, 0),
	])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1),
	])
	var cols := PackedColorArray()
	cols.resize(4)
	cols.fill(Color.WHITE)
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_quad3d = m
	return m


## 40 边形单位圆（z=0，白色顶点色）——几何与 batch_rig._get_circle_mesh 同源
static func get_circle3d() -> ArrayMesh:
	if _circle3d != null:
		return _circle3d
	var n := 40
	var pts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	for i in n:
		var a := TAU * float(i) / float(n)
		var v2 := Vector2(cos(a), sin(a))
		pts.append(Vector3(v2.x, v2.y, 0))
		uvs.append(v2 * 0.5 + Vector2(0.5, 0.5))
		cols.append(Color.WHITE)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	var idx := PackedInt32Array()
	for i in range(1, n - 1):
		idx.append_array([0, i, i + 1])
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_circle3d = m
	return m


## 2D ArrayMesh → 3D（顶点 Vector2→Vector3 z=0，其余数组原样；血条 wobble 网格用）
static func mesh2d_to_3d(src: ArrayMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for si in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(si)
		var verts: PackedVector2Array = arrays[Mesh.ARRAY_VERTEX]
		var v3 := PackedVector3Array()
		v3.resize(verts.size())
		for i in verts.size():
			v3[i] = Vector3(verts[i].x, verts[i].y, 0)
		arrays[Mesh.ARRAY_VERTEX] = v3
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


# ─────────────────────────── 3D 血条覆盖层桶（crowd OverlayBucket 移植） ───────────────────────────

## 行 stride 20：变换 12（列连续布局）+ 色 4 + CUSTOM 4（bw, plain, hh, 0）。
## 变换由调用方给齐三列与原点（宿主按 tilt 平面折算）；每帧 begin→row…→end。
class Overlay3D:
	var mmis: Array = []           # MultiMeshInstance3D ×N（相位组）
	var bufs: Array = []           # PackedFloat32Array ×N
	var caps := PackedInt32Array()
	var cnt := PackedInt32Array()
	var prev := PackedInt32Array()
	var dirty := PackedByteArray()


	func begin_tick() -> void:
		for k in cnt.size():
			cnt[k] = 0


	## 写一行：basis 三列 + 原点 + 色 + custom（crowd OverlayBucket.row 的 3D 版）
	func row(k: int, bx: Vector3, by: Vector3, bz: Vector3, o: Vector3,
			col: Color, c0: float, c1: float, c2: float) -> void:
		var i := cnt[k]
		_ensure_cap(k, i + 1)
		var buf: PackedFloat32Array = bufs[k]
		var b := i * 20
		buf[b] = bx.x; buf[b + 1] = bx.y; buf[b + 2] = bx.z; buf[b + 3] = o.x
		buf[b + 4] = by.x; buf[b + 5] = by.y; buf[b + 6] = by.z; buf[b + 7] = o.y
		buf[b + 8] = bz.x; buf[b + 9] = bz.y; buf[b + 10] = bz.z; buf[b + 11] = o.z
		buf[b + 12] = col.r; buf[b + 13] = col.g; buf[b + 14] = col.b; buf[b + 15] = col.a
		buf[b + 16] = c0; buf[b + 17] = c1; buf[b + 18] = c2; buf[b + 19] = 0.0
		bufs[k] = buf
		dirty[k] = 1
		cnt[k] = i + 1


	func end_tick() -> void:
		for k in cnt.size():
			var c := cnt[k]
			if prev[k] > c:
				var buf: PackedFloat32Array = bufs[k]
				for i in range(c * 20, prev[k] * 20):
					buf[i] = 0.0
				bufs[k] = buf
				dirty[k] = 1
			prev[k] = c
			if caps[k] > 0 and dirty[k] != 0:
				mmis[k].multimesh.buffer = bufs[k]
				dirty[k] = 0


	func _ensure_cap(k: int, n: int) -> void:
		if n <= caps[k]:
			return
		var cap := caps[k]
		while cap < n:
			cap = maxi(cap * 2, 16)
		caps[k] = cap
		var mm: MultiMesh = mmis[k].multimesh
		mm.instance_count = cap
		var buf: PackedFloat32Array = bufs[k]
		buf.resize(cap * 20)
		bufs[k] = buf
		mm.buffer = buf


	func clear() -> void:
		mmis.clear()
		bufs.clear()
		caps = PackedInt32Array()
		cnt = PackedInt32Array()
		prev = PackedInt32Array()
		dirty = PackedByteArray()


# ─────────────────────────── 实例状态 ───────────────────────────

## 身体 8 桶：0-3 不透明 / 4-7 渐隐（同 mesh 同表，异材质）。每桶一个 MultiMesh。
var _body_mmi: Array = []        # MultiMeshInstance3D ×8
var _body_mm: Array = []         # MultiMesh ×8
var _body_buf: Array = []        # PackedFloat32Array ×8
var _body_dirty := PackedByteArray()  # ×8
## 每桶槽位（段基址，步长=该桶部件数）空闲池
var _body_free: Array = []       # Array[int] ×8

## 武器桶：纹理路径 → 桶（每纹理独立 MultiMesh，纹理=uniform；紧凑行制）
var _weapon_buckets: Dictionary = {}  # path -> {mmi, mm, buf, cap, count}
var _weapon_dirty := false

## 血条 6 组桶（层序同 crowd：bg→ring1→trail_fill→ring2→dot_fill→dot_ring）
var _bar_bg: Overlay3D = null
var _bar_ring1: Overlay3D = null
var _bar_trail_fill: Overlay3D = null
var _bar_ring2: Overlay3D = null
var _dot_fill: Overlay3D = null
var _dot_ring: Overlay3D = null


func _ready() -> void:
	_ensure_statics()
	process_priority = 1200  # 宿主(1100) 之后统一上传
	var meshes := [get_quad3d(), get_circle3d(), get_quad3d(), get_circle3d()]
	for j in 8:
		var fade := j >= 4
		var count: int = _part_bidx[j % 4].size()
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Char3DBody%d%s" % [j % 4, "_Fade" if fade else ""]
		var mat := ShaderMaterial.new()
		mat.shader = BODY_SHADER_FADE if fade else BODY_SHADER_OPAQUE
		mmi.material_override = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = meshes[j % 4]
		mm.instance_count = 0
		mm.custom_aabb = WORLD_AABB
		mmi.multimesh = mm
		add_child(mmi)
		_body_mmi.append(mmi)
		_body_mm.append(mm)
		_body_buf.append(PackedFloat32Array())
		_body_dirty.append(0)
		_body_free.append([])
	_build_bar_buckets()


func _build_bar_buckets() -> void:
	var n := BatchRig.WOBBLE_VARIANTS
	var fill_meshes: Array = []
	var fill_mats: Array = []
	for k in n:
		fill_meshes.append(mesh2d_to_3d(BatchRig._get_wobble_bar_mesh(k)))
		fill_mats.append(_bar_mat(0.0, null, null))
	fill_meshes.append(mesh2d_to_3d(BatchRig._get_plain_bar_mesh()))
	fill_mats.append(_bar_mat(0.0, null, null))
	var ring_meshes: Array = []
	var ring_mats: Array = []
	for k in n:
		ring_meshes.append(mesh2d_to_3d(BatchRig._get_wobble_bar_ring_mesh(k)))
		ring_mats.append(_bar_mat(0.0, BatchRig._bar_ring_deltas(k), BatchRig._bar_ring_coeffs(k)))
	ring_meshes.append(mesh2d_to_3d(BatchRig._get_plain_bar_ring_mesh()))
	var zero16 := PackedFloat32Array()
	zero16.resize(16)
	ring_mats.append(_bar_mat(0.0, BatchRig._plain_ring_deltas(), zero16))
	var dot_fill_meshes: Array = []
	var dot_ring_meshes: Array = []
	var dot_mats: Array = []
	for k in n:
		dot_fill_meshes.append(mesh2d_to_3d(BatchRig._get_wobble_dot_mesh(k)))
		dot_ring_meshes.append(mesh2d_to_3d(BatchRig._get_wobble_dot_ring_mesh(k)))
		dot_mats.append(_bar_mat(1.0, null, null))
	_bar_bg = _make_bar_bucket("Char3DBarBg", fill_meshes, fill_mats)
	_bar_ring1 = _make_bar_bucket("Char3DBarR1", ring_meshes, ring_mats)
	_bar_trail_fill = _make_bar_bucket("Char3DBarTf", fill_meshes, fill_mats)
	_bar_ring2 = _make_bar_bucket("Char3DBarR2", ring_meshes, ring_mats)
	_dot_fill = _make_bar_bucket("Char3DDotF", dot_fill_meshes, dot_mats)
	_dot_ring = _make_bar_bucket("Char3DDotR", dot_ring_meshes, dot_mats)


func _bar_mat(mode: float, deltas = null, coeffs = null) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = BAR_SHADER
	m.set_shader_parameter("mode", mode)
	if deltas != null and coeffs != null:
		var d16 := PackedVector2Array(deltas)
		while d16.size() < 16:
			d16.append(Vector2.ZERO)
		m.set_shader_parameter("DELTAS", d16)
		m.set_shader_parameter("COEFF", coeffs)
	return m


func _make_bar_bucket(prefix: String, meshes: Array, mats: Array) -> Overlay3D:
	var b := Overlay3D.new()
	for k in meshes.size():
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s%d" % [prefix, k]
		mmi.material_override = mats[k]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = meshes[k]
		mm.instance_count = 0
		mm.custom_aabb = WORLD_AABB
		mmi.multimesh = mm
		add_child(mmi)
		b.mmis.append(mmi)
		b.bufs.append(PackedFloat32Array())
		b.caps.append(0)
		b.cnt.append(0)
		b.prev.append(0)
		b.dirty.append(0)
	return b


# ─────────────────────────── 身体槽位 ───────────────────────────

## 注册宿主：每桶分配一个段（不透明/渐隐两套同步分配，零段=隐形）。
## 返回 {bucket: base, ...}（宿主写段用；base 为实例下标）。
func register_body() -> Dictionary:
	var bases := {}
	for j in 8:
		var count: int = _part_bidx[j % 4].size()
		if count <= 0:
			continue
		var pool: Array = _body_free[j]
		var base: int
		if not pool.is_empty():
			base = pool.pop_back()
		else:
			base = _body_mm[j].instance_count / count
			_grow_body(j, base + 1)
		bases[j] = base
	return bases


## 注销宿主：段还池 + 清零段（一次写入隐形）
func unregister_body(bases: Dictionary) -> void:
	for j in bases.keys():
		var count: int = _part_bidx[j % 4].size()
		var base: int = bases[j]
		var buf: PackedFloat32Array = _body_buf[j]
		var o0: int = base * count * 16
		for o in range(o0, o0 + count * 16):
			buf[o] = 0.0
		_body_buf[j] = buf
		_body_dirty[j] = 1
		(_body_free[j] as Array).append(base)


## 容量扩到 units 个段（步长=桶部件数；新位默认 0=零缩放隐形）
func _grow_body(j: int, units: int) -> void:
	var count: int = _part_bidx[j % 4].size()
	var need: int = units * count
	var mm: MultiMesh = _body_mm[j]
	mm.instance_count = need
	var buf: PackedFloat32Array = _body_buf[j]
	_body_buf[j] = PackedFloat32Array()  # 摘引用独占写
	buf.resize(need * 16)
	_body_buf[j] = buf
	_body_dirty[j] = 1


func mark_body_dirty(j: int) -> void:
	_body_dirty[j] = 1


func body_buf(j: int) -> PackedFloat32Array:
	return _body_buf[j]


## 宿主写回通道（PackedArray 按值语义：跨对象的下标写不回写宿主，
## 宿主写完必须整段交还——同 crowd 桶库三步式纪律）
func set_body_buf(j: int, buf: PackedFloat32Array) -> void:
	_body_buf[j] = buf


## 血条相位组数外的 plain 直角退化槽下标（宿主窄条回退用）
func bar_plain_k() -> int:
	return BatchRig.WOBBLE_VARIANTS


# ─────────────────────────── 武器桶（按纹理分桶，紧凑行制） ───────────────────────────

## 武器行追加（宿主晚 _process 调）：返回行号（宿主记引用无需——行每帧重写）。
func weapon_row(tex_path: String, tex: Texture2D, bx: Vector3, by: Vector3, bz: Vector3,
		org: Vector3, col: Color) -> void:
	var b: Dictionary = _weapon_buckets.get(tex_path, {})
	if b.is_empty():
		b = _make_weapon_bucket(tex_path, tex)
	var i: int = b["count"]
	var cap: int = b["cap"]
	if i >= cap:
		while cap <= i:
			cap = maxi(cap * 2, 8)
		b["cap"] = cap
		var mm: MultiMesh = b["mm"]
		mm.instance_count = cap
		var buf: PackedFloat32Array = b["buf"]
		b["buf"] = PackedFloat32Array()
		buf.resize(cap * 16)
		b["buf"] = buf
	var buf: PackedFloat32Array = b["buf"]
	var o := i * 16
	buf[o] = bx.x; buf[o + 1] = bx.y; buf[o + 2] = bx.z; buf[o + 3] = org.x
	buf[o + 4] = by.x; buf[o + 5] = by.y; buf[o + 6] = by.z; buf[o + 7] = org.y
	buf[o + 8] = bz.x; buf[o + 9] = bz.y; buf[o + 10] = bz.z; buf[o + 11] = org.z
	buf[o + 12] = col.r; buf[o + 13] = col.g; buf[o + 14] = col.b; buf[o + 15] = col.a
	b["buf"] = buf
	b["count"] = i + 1
	_weapon_dirty = true


func _make_weapon_bucket(tex_path: String, tex: Texture2D) -> Dictionary:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Char3DWeapon_%d" % _weapon_buckets.size()
	var mat := ShaderMaterial.new()
	mat.shader = WEAPON_SHADER
	mat.set_shader_parameter("atlas_tex", tex)
	mmi.material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = get_quad3d()
	mm.instance_count = 0
	mm.custom_aabb = WORLD_AABB
	mmi.multimesh = mm
	add_child(mmi)
	var b := {"mmi": mmi, "mm": mm, "buf": PackedFloat32Array(), "cap": 0, "count": 0}
	_weapon_buckets[tex_path] = b
	return b


# ─────────────────────────── 上传节拍（晚于全部宿主写入） ───────────────────────────

func _process(_delta: float) -> void:
	# 身体桶：脏了才整缓冲上传（静止单位不产生带宽）
	for j in 8:
		if _body_dirty[j] != 0 and _body_mm[j].instance_count > 0:
			_body_mm[j].buffer = _body_buf[j]
			_body_dirty[j] = 0
	# 武器桶：清尾段 + 上传（紧凑行制）
	if _weapon_dirty:
		for path in _weapon_buckets:
			var b: Dictionary = _weapon_buckets[path]
			var buf: PackedFloat32Array = b["buf"]
			var count: int = b["count"]
			var cap: int = b["cap"]
			if cap > 0:
				for o in range(count * 16, cap * 16):
					buf[o] = 0.0
				b["buf"] = buf
				(b["mm"] as MultiMesh).buffer = buf
			b["count"] = 0
		_weapon_dirty = false
	# 血条桶：清尾 + 上传（Overlay3D 自带脏门）
	_bar_bg.end_tick()
	_bar_ring1.end_tick()
	_bar_trail_fill.end_tick()
	_bar_ring2.end_tick()
	_dot_fill.end_tick()
	_dot_ring.end_tick()
	# 下一帧血条行计数复位
	_bar_bg.begin_tick()
	_bar_ring1.begin_tick()
	_bar_trail_fill.begin_tick()
	_bar_ring2.begin_tick()
	_dot_fill.begin_tick()
	_dot_ring.begin_tick()
