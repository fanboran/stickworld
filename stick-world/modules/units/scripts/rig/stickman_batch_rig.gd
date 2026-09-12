extends RefCounted
## 火柴人批渲染骨架 —— 用 4 个 MultiMeshInstance2D 替换全部矢量部件 CanvasItem。
##
## 是什么：
##   旧路径（StickmanSkeleton.build_limbs）每单位 30 个矢量部件（约 15 段肢体 ×
##   stroke/fill 两遍），48v48 混战 draw calls ~4100、可见单位画布成本
##   ~0.4-0.6ms。本类在骨骼（Bone2D/AnimationTree/IK/ProceduralOverlay 全部照旧）
##   之上加一个批渲染层：把 15 段肢体拆成 4 个 MultiMeshInstance2D 桶——
##     stroke_rects / stroke_caps（z=-1，描边色）+ fill_rects / fill_caps（z=0，部件原色）
##   矩段肢体 = 中段矩形 quad（无纹理白底×实例色）+ 两端圆头（40 边形单位圆）；
##   头部 = 单个圆头实例。draws 从 30/单位降到 4/单位，单位内桶序即绘制序，
##   与旧"全部描边压底、全部填充置顶"两遍渲染语义对齐。
##
## 为什么 4 个 MMI 而非 2 个：同桶内矩段与圆头形状不同（quad mesh vs 圆 mesh），
##   一个 MultiMesh 只能挂一个 mesh；矩形/圆头分桶后互相覆盖顺序无关（同色不透明，
##   并集即胶囊剪影），描边桶 z=-1 整体压底、填充桶 z=0 置顶，语义不变。
##
## 为什么不用一张共享胶囊纹理：各段长宽比不同（脚趾 1.5:1 ~ 小腿 4:1），全段共用
##   一张纹理做非等比拉伸会把圆头压成椭圆（脚趾最明显）；按段缓存纹理做不到
##   一个 MMI 绑多张。矩形+圆头的纯几何拼装（旧 Line2D 圆头即同款构成）由项目
##   已开的 msaa_2d 平滑边缘，与旧矢量路径观感同源，零 shader。
##
## 为什么每单位 4 个 MMI 而非全局桶：单位间遮挡走实体 y-sort，MMI 挂在 rig 下
##   （实体原位）天然保留；MMI 作为 rig 首位子节点，武器/盾（挂手骨的 Sprite2D，
##   树序在后）依旧画在身体之上——复刻旧树序（颈/头提到双臂之前）。
##
## Pose 管线：骨骼/动画/IK/叠加层照旧驱动 Bone2D 节点变换；rig 在每帧 _process 尾部
## （骨骼 = 本帧最终合成姿态：推进 + 解算 + 程序化叠加）调 flush()，按骨骼树先序
## 遍历累乘出每根骨骼的 rig 局部变换，再乘构建期预烘的"部件局部 quad 变换"，
## 以整缓冲写（mm.buffer，12 floats/实例）灌入每桶；pose 未变帧跳过写入
## （mark_dirty 管线），随 LOD hz 节流单位自然降频更新。
##
## 不动的部分：武器/盾（挂手骨 Sprite2D）、ContactShadow、HealthBar、IK markers；
##   受击红闪/死亡淡出走 modulate（MMI 是 CanvasItem，挂在 rig 下免费继承）；
##   rig.scale.x 翻转对 MMI 天然生效（父变换）。

const Skel := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")

# ===== 开关（BalanceConfig 是 Excel 导出行数据，无 bool 配置机制；ProjectSettings + 环境变量兜底）=====
## 工程设置键：project.godot [render] 段写 batch_rig=false 可关闭批渲染（默认开）。
const SETTING_KEY := "render/batch_rig"
## 环境变量：STICK_BATCH_RIG=0/1 强制覆盖（A/B 实测用，免改工程文件）。
const ENV_OVERRIDE := "STICK_BATCH_RIG"


## 批渲染总开关：环境变量 > 工程设置 > 默认开。
static func is_enabled() -> bool:
	var env := OS.get_environment(ENV_OVERRIDE)
	if env == "0":
		return false
	if env == "1":
		return true
	return bool(ProjectSettings.get_setting(SETTING_KEY, true))


# ===== 静态共享资源（全单位同骨架，网格/纹理只生成一次）=====

static var _white_tex: ImageTexture = null
static var _quad_mesh: ArrayMesh = null
static var _circle_mesh: ArrayMesh = null
static var _wobble_bar_mesh: ArrayMesh = null
static var _wobble_circle_mesh: ArrayMesh = null


## 粗粝 10 段圆（对齐原版 _wobbled_circle 拓扑）：血条圆点用，wobble shader
## 顶点期按段索引 hash 扰动半径复刻手绘感（40 边光滑圆观感不对）
static func _get_wobble_circle_mesh() -> ArrayMesh:
	if _wobble_circle_mesh != null:
		return _wobble_circle_mesh
	var n := 10
	var pts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	for i in n:
		var a := TAU * float(i) / float(n)
		var c := Vector2(cos(a), sin(a))
		pts.append(c)
		uvs.append(Vector2(float(i) / float(n), 0.0))
		cols.append(Color.WHITE)
	var idx := PackedInt32Array()
	for i in range(1, n - 1):
		idx.append_array([0, i, i + 1])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	_wobble_circle_mesh = ArrayMesh.new()
	_wobble_circle_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return _wobble_circle_mesh


## 手绘条模板：1×1 单位条，水平 12 段上下边顶点——血条桶 wobble shader
## 在顶点期扰动边缘顶点复刻 boiling line（quad 仅 4 角扰动=刚体晃动，不够）
static func _get_wobble_bar_mesh() -> ArrayMesh:
	if _wobble_bar_mesh != null:
		return _wobble_bar_mesh
	var n := 12
	var pts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	for i in n + 1:
		var x := -0.5 + float(i) / float(n)
		pts.append(Vector2(x, -0.5))
		pts.append(Vector2(x, 0.5))
		uvs.append(Vector2(x + 0.5, 0.0))
		uvs.append(Vector2(x + 0.5, 1.0))
		cols.append(Color.WHITE)
		cols.append(Color.WHITE)
	var idx := PackedInt32Array()
	for i in n:
		var a := i * 2
		var b := a + 1
		var c := a + 2
		var d := a + 3
		idx.append_array([a, c, b, b, c, d])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	_wobble_bar_mesh = ArrayMesh.new()
	_wobble_bar_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return _wobble_bar_mesh


## 1x1 纯白不透明纹理：兜底绑定（无纹理 canvas item 理论上按纯色渲染，
## 显式白纹理消除引擎版本差异风险；实际颜色全部走实例色相乘）。
static func _get_white_tex() -> ImageTexture:
	if _white_tex != null:
		return _white_tex
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_white_tex = ImageTexture.create_from_image(img)
	return _white_tex


## 1x1 居中白 quad（带白色顶点色）：矩段用，尺寸全走实例变换 scale。
## 必须自建 ArrayMesh 而非 QuadMesh：2D MultiMesh 实例色与网格顶点色相乘，
## 网格无 COLOR 属性时顶点色按黑处理 → 实例色再白也渲染成黑（实测黑影 bug）。
static func _get_quad_mesh() -> ArrayMesh:
	if _quad_mesh != null:
		return _quad_mesh
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = PackedVector2Array([
		Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5),
	])
	arr[Mesh.ARRAY_TEX_UV] = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	arr[Mesh.ARRAY_COLOR] = PackedColorArray([
		Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE,
	])
	arr[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_quad_mesh = mesh
	return _quad_mesh


## 单位圆网格（40 边形，半径 1，居中，带白色顶点色——理由同 quad）：圆头/头部用。
## 复刻旧头部 Polygon2D 40 边形，纯几何边缘由 msaa_2d 平滑（与旧路径同款抗锯齿）。
static func _get_circle_mesh() -> ArrayMesh:
	if _circle_mesh != null:
		return _circle_mesh
	var pts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var n := 40
	for i in n:
		var c := Vector2(cos(TAU * float(i) / float(n)), sin(TAU * float(i) / float(n)))
		pts.append(c)
		uvs.append(c * 0.5 + Vector2(0.5, 0.5))
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
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_circle_mesh = mesh
	return _circle_mesh


# ============================================================
#  实例状态
# ============================================================

var _rig: Skeleton2D
## 骨骼树先序数组（父必在子之前）——累乘基准
var _bones_pre: Array = []  # Bone2D
## 每根骨骼的节点父在先序数组中的下标（-1 = rig 直属，acc 基准为单位阵）
var _parent_idx: PackedInt32Array = PackedInt32Array()
## 先序累乘结果缓存（flush 复用，避免每帧分配）
var _acc: Array[Transform2D] = []

## 4 桶实例表（下标 = 桶序 = 绘制序：0 描边矩形 → 1 描边圆头 → 2 填充矩形 → 3 填充圆头）：
## 每实例 = (父骨骼先序下标, 预烘局部变换, 颜色)
var _bidx: Array = []   # PackedInt32Array ×4
var _xform: Array = []  # Array[Transform2D] ×4（构建期预烘，flush 只读）
var _color: Array = []  # PackedColorArray ×4

## 4 个 MultiMesh（整缓冲写：buffer 属性一次灌整桶实例数据）。
## 缓冲布局（temp/batch30/mm_stride_test.gd 实证，TRANSFORM_2D + use_colors）：
##   每实例 12 floats = [X.x, Y.x, 0, O.x, X.y, Y.y, 0, O.y, R, G, B, A]
##   （变换为行主 2×4 布局 + 颜色 RGBA；步长 12，整缓冲大小必须恰为 12×实例数）。
## 注：逐实例 API（set_instance_transform_2d）实测 ~20µs/次（96 单位混战
## ~8000 次/帧 → proc +50ms，fps 7），弃用；遗作曾试整缓冲写但按
## (xx,xy,yx,yy,ox,oy) 字段序写 → 形块塌缩，实为字段序错，已破解。
var _mm: Array = []    # MultiMesh ×4（空桶占位 null）
var _mmi: Array = []   # MultiMeshInstance2D ×4（空桶占位 null）
## 整缓冲缓存（每桶一份，flush 复用不重分配；空桶为空数组）
var _buf: Array = []   # PackedFloat32Array ×4

## pose 脏标记（pose 未变帧跳过缓冲写入）
var _dirty: bool = false

## 复刻旧路径的部件参数缓存（reconfigure 重烘用）
var _thickness_scale: float = 1.0
var _colors: Dictionary = {}


## 构建：骨骼树先序 + 部件桶 + 初始实例缓冲。失败返回 false（调用方回退旧矢量路径）。
func setup(rig: Skeleton2D, bones: Dictionary, thickness_scale: float, colors: Dictionary) -> bool:
	_rig = rig
	_thickness_scale = thickness_scale
	_colors = colors
	if bones.is_empty():
		return false
	_rebuild_instance_data()
	if _bidx[0].is_empty() and _bidx[1].is_empty():
		return false
	if not _create_mmis():
		_discard()
		return false
	_write_transforms()  # 首帧即写（含颜色）：消除"实例 identity 簇拥在原点"的入场瑕疵
	_dirty = true
	return true


## 颜色/厚度重建（对应旧路径 _do_rebuild）：重烘局部变换与颜色 + 重写实例缓冲。
func reconfigure(thickness_scale: float, colors: Dictionary) -> void:
	_thickness_scale = thickness_scale
	_colors = colors
	_rebuild_instance_data()
	if _mm.is_empty():
		return
	_write_transforms()
	_dirty = true


## pose 脏标记（本帧生效）：动画推进/骨架解算落地/叠加层改写骨骼后由 rig 调用。
func mark_dirty() -> void:
	_dirty = true


## flush（rig _process 每帧调用）：有脏标记且 rig 可见时重写实例缓冲。
## 不可见期跳过写入并保留脏标记（LOD FAR 档 rig.visible=false），重新可见时补写。
func flush() -> void:
	if _mm.is_empty():
		return
	if not _dirty:
		return
	if _rig == null or not _rig.is_visible_in_tree():
		return  # 保留 _dirty，重新可见后下一帧补写
	_dirty = false
	_write_transforms()


# ============================================================
#  内部：构建与写入
# ============================================================

## 骨骼树先序遍历（含父下标记录）+ 按部件参数生成 4 桶实例表。
## 先序 = 旧 canvas 绘制序（部件容器是骨骼子节点，树序即绘制序），
## 复刻 reorder_render_order 整理后的腿→躯干→颈/头→内臂→外臂层次。
func _rebuild_instance_data() -> void:
	_bones_pre.clear()
	_parent_idx = PackedInt32Array()
	_bidx = []
	_xform = []
	_color = []
	for j in 4:
		_bidx.append(PackedInt32Array())
		_xform.append([])
		_color.append(PackedColorArray())
	# 部件查找表：父骨骼 id → 段参数（SKELETON_DATA + EXTRA_LIMBS，type>=0 才有几何）
	var all_data: Dictionary = Skel.SKELETON_DATA.merged(Skel.EXTRA_LIMBS, true)
	var limb_by_parent: Dictionary = {}
	for id in all_data:
		var data: Dictionary = all_data[id]
		if int(data.get("type", -1)) < 0:
			continue
		var pid: int = data["parent"]
		if not limb_by_parent.has(pid):
			limb_by_parent[pid] = data
	_walk_and_emit(_rig, -1, limb_by_parent)
	if _acc.size() != _bones_pre.size():
		var acc: Array[Transform2D] = []
		acc.resize(_bones_pre.size())
		_acc = acc


## 递归：先序收集 Bone2D 并对每根骨骼 emit 其挂载的部件（父骨骼 acc 基准 = 该骨骼先序下标）。
func _walk_and_emit(node: Node, parent_idx: int, limb_by_parent: Dictionary) -> void:
	for child in node.get_children():
		if child is Bone2D:
			var bone := child as Bone2D
			var idx := _bones_pre.size()
			_bones_pre.append(bone)
			_parent_idx.append(parent_idx)
			var id: int = Skel.BONE_NAME_TO_ID.get(bone.name, -1)
			if id >= 0 and limb_by_parent.has(id):
				_emit_limb(limb_by_parent[id], idx)
			_walk_and_emit(bone, idx, limb_by_parent)


## 把一段肢体拆进 4 桶（中段矩形 + 两端圆头；CIRCLE 型只有单个圆）。
## 局部变换预烘（容器变换 × 尺寸缩放），运行时只需再乘父骨骼 acc。
## 尺寸语义与旧 _build_limb 逐位对齐：
##   矩段 fill：Line2D 点距 length、宽 thickness*scale、圆头 → 总长 length+width；
##   stroke：同点位宽 +2*OUTLINE。
##   注意：quad 网格边长 1（scale=边长），圆网格半径 1（**scale=半径**，直径要 ÷2）——
##   Line2D 圆头直径=线宽、旧头部 Polygon2D 半径 r，故圆实例 scale 取 w/2、(w+4)/2、
##   r、r+ow（半径语义）。头部：r = max(length, width*2)/2，stroke 外扩 OUTLINE。
## 桶下标：0=描边矩形 1=描边圆头 2=填充矩形 3=填充圆头。
func _emit_limb(data: Dictionary, bone_pre_idx: int) -> void:
	var node_type: int = int(data.get("type", -1))
	var length := float(data.get("length", 1))
	var w := maxf(float(data.get("thickness", 0)) * _thickness_scale, 1.0)
	var fill_color: Color = Skel._color_for_type(node_type, _colors)
	var stroke_color: Color = _colors.get("outline", Skel.DEFAULT_OUTLINE)
	var ow := Skel.OUTLINE_WIDTH
	if node_type == Skel.TYPE_CIRCLE:
		var r := maxf(length, w * 2.0) / 2.0
		var base := Transform2D(0.0, Vector2(data["x"], data["y"]))
		_push(1, bone_pre_idx, base * _scale2(r + ow, r + ow), stroke_color)
		_push(3, bone_pre_idx, base * _scale2(r, r), fill_color)
		return
	# 矩段：容器 = 段中点、旋向对齐父子骨骼连线（与旧 _build_limb 同式）
	var dir := Vector2(data["x"], data["y"])
	var base := Transform2D(dir.angle(), dir / 2.0)
	var half := length / 2.0
	# stroke：加宽的三件（中段 + 两端圆头）；圆头直径 = 线宽 → 圆实例 scale = 半径
	var sw := w + ow * 2.0
	_push(0, bone_pre_idx, base * _scale2(length, sw), stroke_color)
	_push(1, bone_pre_idx, base * _shift_scale(Vector2(-half, 0.0), sw / 2.0, sw / 2.0), stroke_color)
	_push(1, bone_pre_idx, base * _shift_scale(Vector2(half, 0.0), sw / 2.0, sw / 2.0), stroke_color)
	# fill：中段 + 两端圆头
	_push(2, bone_pre_idx, base * _scale2(length, w), fill_color)
	_push(3, bone_pre_idx, base * _shift_scale(Vector2(-half, 0.0), w / 2.0, w / 2.0), fill_color)
	_push(3, bone_pre_idx, base * _shift_scale(Vector2(half, 0.0), w / 2.0, w / 2.0), fill_color)


func _push(bucket: int, bone_pre_idx: int, xform: Transform2D, color: Color) -> void:
	_bidx[bucket].append(bone_pre_idx)
	_xform[bucket].append(xform)
	_color[bucket].append(color)


## 纯缩放阵（局部轴向缩放；Transform2D 无 (rot,pos,scale) 三参构造，用基向量直拼）
func _scale2(sx: float, sy: float) -> Transform2D:
	return Transform2D(Vector2(sx, 0.0), Vector2(0.0, sy), Vector2.ZERO)


## 平移后再缩放：圆头中心在段端点、直径 = 宽
func _shift_scale(off: Vector2, sx: float, sy: float) -> Transform2D:
	return Transform2D(0.0, off) * _scale2(sx, sy)


## 创建 4 桶 MMI（rig 首位子节点：武器/盾 Sprite2D 在骨骼子树内，树序在后 = 盖住身体，
## 复刻旧"颈/头提到双臂之前、武器挂臂 subtree"的层次语义）。
## 空桶也按位占位（_mm/_mmi 下标恒等于桶下标，与 _bidx/_xform/_color 对齐），
## 防止"跳过空桶"造成桶序错位——写入循环按 null 跳过。
func _create_mmis() -> bool:
	var specs := [
		{"name": "BatchStrokeRects", "z": -1, "mesh": _get_quad_mesh()},
		{"name": "BatchStrokeCaps", "z": -1, "mesh": _get_circle_mesh()},
		{"name": "BatchFillRects", "z": 0, "mesh": _get_quad_mesh()},
		{"name": "BatchFillCaps", "z": 0, "mesh": _get_circle_mesh()},
	]
	var created := 0
	for j in specs.size():
		var count: int = _bidx[j].size()
		_mm.append(null)
		_mmi.append(null)
		_buf.append(PackedFloat32Array())
		if count <= 0:
			continue
		var mmi := MultiMeshInstance2D.new()
		mmi.name = specs[j]["name"]
		mmi.texture = _get_white_tex()
		mmi.z_index = int(specs[j]["z"])
		var mm := MultiMesh.new()
		# transform_format/use_colors 必须在 instance_count 之前设置
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.mesh = specs[j]["mesh"]
		mm.instance_count = count
		mmi.multimesh = mm
		_rig.add_child(mmi)
		_rig.move_child(mmi, 0)  # 压到骨骼子树之前
		_mm[j] = mm
		_mmi[j] = mmi
		# 整缓冲缓存：12 floats/实例（变换 8 + 颜色 4，布局见 _buf 注）
		var buf := PackedFloat32Array()
		buf.resize(count * 12)
		_buf[j] = buf
		created += 1
	return created > 0


## 全量重写实例缓冲：先序累乘骨骼 rig 局部变换 × 预烘部件局部变换，
## 按整缓冲布局（12 floats/实例，变换+颜色同缓冲）灌入每桶 MultiMesh。
## 根骨（rig 直属）acc 基准为单位阵——实例空间 = rig 局部空间（MMI 挂 rig 原点）。
func _write_transforms() -> void:
	# 先序累乘：acc[i] = acc[parent] * bones[i].transform（父必在子前，单遍完成）
	for i in _bones_pre.size():
		var bone := _bones_pre[i] as Bone2D
		if bone == null:
			continue
		var local := bone.transform
		var pi := _parent_idx[i]
		_acc[i] = local if pi < 0 else _acc[pi] * local
	for j in _mm.size():
		var mm: MultiMesh = _mm[j]
		if mm == null:
			continue  # 空桶占位（无实例）
		var table_bidx: PackedInt32Array = _bidx[j]
		var table_xform: Array = _xform[j]
		var table_color: PackedColorArray = _color[j]
		var buf: PackedFloat32Array = _buf[j]
		for i in table_bidx.size():
			var xf: Transform2D = _acc[table_bidx[i]] * table_xform[i]
			var col: Color = table_color[i]
			var base := i * 12
			buf[base] = xf.x.x
			buf[base + 1] = xf.y.x
			buf[base + 2] = 0.0
			buf[base + 3] = xf.origin.x
			buf[base + 4] = xf.x.y
			buf[base + 5] = xf.y.y
			buf[base + 6] = 0.0
			buf[base + 7] = xf.origin.y
			buf[base + 8] = col.r
			buf[base + 9] = col.g
			buf[base + 10] = col.b
			buf[base + 11] = col.a
		mm.buffer = buf


## 构建失败/回退清理：释放已挂载的批渲染 MMI 节点
func _discard() -> void:
	for j in _mmi.size():
		var mmi = _mmi[j]
		if mmi != null and is_instance_valid(mmi):
			(mmi as MultiMeshInstance2D).queue_free()
	_mm.clear()
	_mmi.clear()
	_buf.clear()

