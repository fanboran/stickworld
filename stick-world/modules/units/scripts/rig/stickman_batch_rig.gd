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
## 血条桶 wobble 相位组数：每组 = 一张预烘 wobble 数值表 + 4 张烘焙网格
## （条填充/条描边环带/圆点填充/圆点描边环带）。数值表用原版
## health_bar_indicator._wobble 逐字同式的 float64 公式烘制——GPU 侧不复算
## hash（float32 sin 大参数精度不可控，且无法与 CPU 路径逐位对齐）。这是血条
## 观感与原版像素级对齐的根基：probe 钉 seed 后两条路径逐顶点同值。
const WOBBLE_VARIANTS := 8
## 单位空间常量：条 wobble 纵向系数（0.9px 抖幅 / 7px 行高）、端头凸出系数
## （0.6×半高 = 2.1px 局部 = 0.3×行高）、圆点径向系数（0.9px / 6px 半径——
## 圆点实例均匀缩放，可全烘焙；条实例非均匀缩放，法线必须逐实例算）
const BAR_WOBBLE_U := 0.9 / 7.0
const BAR_TIP_U := 0.3
const DOT_WOBBLE_U := 0.9 / 6.0
static var _wobble_ready := false
static var _wobble_bar_meshes: Array = []       # ×N 条填充网格
static var _wobble_bar_ring_meshes: Array = []  # ×N 条描边环带网格
static var _wobble_dot_meshes: Array = []       # ×N 圆点填充网格
static var _wobble_dot_ring_meshes: Array = []  # ×N 圆点描边环带网格
static var _plain_bar_mesh: ArrayMesh = null       # 窄条退化直角填充
static var _plain_bar_ring_mesh: ArrayMesh = null  # 窄条退化直角描边
static var _bar_ring_deltas_tbl: Array = []        # ×N 条边单位向量表（16 边）
static var _bar_ring_coeffs_tbl: Array = []        # ×N 条边端头 x 修正系数表
static var _plain_ring_deltas_tbl: PackedVector2Array = PackedVector2Array()


static func _get_wobble_bar_mesh(variant: int) -> ArrayMesh:
	_ensure_wobble()
	return _wobble_bar_meshes[variant]


static func _get_wobble_bar_ring_mesh(variant: int) -> ArrayMesh:
	_ensure_wobble()
	return _wobble_bar_ring_meshes[variant]


static func _get_wobble_dot_mesh(variant: int) -> ArrayMesh:
	_ensure_wobble()
	return _wobble_dot_meshes[variant]


static func _get_wobble_dot_ring_mesh(variant: int) -> ArrayMesh:
	_ensure_wobble()
	return _wobble_dot_ring_meshes[variant]


static func _get_plain_bar_mesh() -> ArrayMesh:
	_ensure_wobble()
	return _plain_bar_mesh


static func _get_plain_bar_ring_mesh() -> ArrayMesh:
	_ensure_wobble()
	return _plain_bar_ring_mesh


## 条描边材质参数：该变体 16 条边的单位空间向量（端头按基位，端头位移由
## COEFF 在 shader 期按实例行高修正——非均匀缩放下边向量随宽高比变化）
static func _bar_ring_deltas(variant: int) -> PackedVector2Array:
	_ensure_wobble()
	return _bar_ring_deltas_tbl[variant]


static func _bar_ring_coeffs(variant: int) -> PackedFloat32Array:
	_ensure_wobble()
	return _bar_ring_coeffs_tbl[variant]


static func _plain_ring_deltas() -> PackedVector2Array:
	_ensure_wobble()
	return _plain_ring_deltas_tbl


## 预烘 wobble 表 + 变体网格（进程一次）。
static func _ensure_wobble() -> void:
	if _wobble_ready:
		return
	_wobble_ready = true
	for k in WOBBLE_VARIANTS:
		var tab := PackedFloat32Array()
		tab.resize(64)
		for i in 64:
			# 与 health_bar_indicator._wobble 逐字同式（float64）——probe 钉
			# _wobble_seed=k 时原版路径与本表逐位一致
			tab[i] = fposmod(sin(float(i) * 127.1 + float(k) * 0.3117) * 43758.5453, 1.0) - 0.5
		var geo := _bar_geometry(false, tab)
		_wobble_bar_meshes.append(_build_bar_fill_mesh(geo))
		_wobble_bar_ring_meshes.append(_build_bar_ring_mesh(geo))
		_bar_ring_deltas_tbl.append(geo.deltas)
		_bar_ring_coeffs_tbl.append(geo.coeffs)
		var dgeo := _dot_geometry(tab)
		_wobble_dot_meshes.append(_build_dot_fill_mesh(dgeo))
		_wobble_dot_ring_meshes.append(_build_dot_ring_mesh(dgeo))
	_plain_bar_mesh = _build_plain_fill_mesh()
	_plain_bar_ring_mesh = _build_plain_ring_mesh()
	_plain_ring_deltas_tbl = PackedVector2Array([
		Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1),
		Vector2(0, 0), Vector2(0, 0), Vector2(0, 0), Vector2(0, 0),
		Vector2(0, 0), Vector2(0, 0), Vector2(0, 0), Vector2(0, 0),
		Vector2(0, 0), Vector2(0, 0), Vector2(0, 0), Vector2(0, 0),
	])


## 条边界几何（单位条空间 1×1）：上边 7 点（左→右，6 段）→ 右端头 →
## 下边 7 点（右→左）→ 左端头，与原版 _draw_wobbly_rect 多边形同构。
## 边顶点 wobble 纵向位移烘进 y（BAR_WOBBLE_U 单位常量）；端头按基位
## （±0.5, 0），x 位移（凸出+端头抖动）由 shader 按实例行高加出，邻边
## delta 的缺额由 COEFF 修正。plain = 窄条退化：无 wobble 无凸出。
static func _bar_geometry(plain: bool, tab: PackedFloat32Array) -> Dictionary:
	var pts := PackedVector2Array()
	for i in 7:
		var wy := 0.0 if plain else tab[i] * BAR_WOBBLE_U
		pts.append(Vector2(-0.5 + float(i) / 6.0, -0.5 + wy))
	pts.append(Vector2(0.5, 0.0))
	for j in 7:
		var wy2 := 0.0 if plain else tab[40 + j] * BAR_WOBBLE_U
		pts.append(Vector2(0.5 - float(j) / 6.0, 0.5 + wy2))
	pts.append(Vector2(-0.5, 0.0))
	var c_r := 0.0 if plain else BAR_TIP_U + tab[20] * BAR_WOBBLE_U
	var c_l := 0.0 if plain else -BAR_TIP_U + tab[60] * BAR_WOBBLE_U
	# 端头 x 位移对邻边向量的修正：抵达端头的边（→cap）计入位移（+c），
	# 离开端头的边（cap→）基位差需扣回（-c）——同号会把斜边法线算歪
	var coeffs := PackedFloat32Array()
	coeffs.resize(16)
	coeffs[6] = c_r
	coeffs[7] = -c_r
	coeffs[14] = c_l
	coeffs[15] = -c_l
	var deltas := PackedVector2Array()
	deltas.resize(16)
	for i in 16:
		deltas[i] = pts[(i + 1) % 16] - pts[i]
	return {"pts": pts, "coeffs": coeffs, "deltas": deltas, "tip_r": c_r, "tip_l": c_l}


## UV.y 编码（canvas_item 无 UV2）：code×131072 + q，q = round((t+1)×65536)，
## t = 端头 x 位移系数（世界 px / 行高，∈[-1,1]），非端头顶点 t=0。
## code：0 无位移顶点 / 2,3 端头尖填充（左/右）/ 4,5 环带顶点外/内圈 /
## 6,7 端头尖环带左外/内 / 8,9 端头尖环带右外/内。
static func _uv_y(code: float, t: float) -> Vector2:
	var q := roundf((t + 1.0) * 65536.0)
	return Vector2(0.0, code * 131072.0 + q)


static func _finish_mesh(pts: PackedVector2Array, uvs: PackedVector2Array, idx: PackedInt32Array) -> ArrayMesh:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	# 网格必须带全白顶点色：MultiMesh 实例色与网格顶点色相乘，缺 COLOR 属性
	# 时顶点色按黑处理（实测黑影 bug）；长度必须与顶点数一致
	var cols := PackedColorArray()
	cols.resize(pts.size())
	cols.fill(Color.WHITE)
	arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## 条填充网格：边界多边形三角化（Geometry2D.triangulate_polygon，与
## draw_colored_polygon 内部同函数同输入）；端头尖顶点走 code 2/3。
static func _build_bar_fill_mesh(geo: Dictionary) -> ArrayMesh:
	var pts: PackedVector2Array = geo.pts
	var n := pts.size()
	var uvs := PackedVector2Array()
	for j in n:
		var code := 0.0
		var t := 0.0
		if j == 7:
			code = 2.0
			t = geo.tip_r
		elif j == 15:
			code = 3.0
			t = geo.tip_l
		uvs.append(_uv_y(code, t))
	return _finish_mesh(pts, uvs, Geometry2D.triangulate_polygon(pts))


## 条描边环带网格：边界 miter 偏移多边形的内外双拷贝环形缝合（实验实证
## draw_polyline join = miter，偏移在 shader 逐实例重建，见 crowd_bar_wobble）。
static func _build_bar_ring_mesh(geo: Dictionary) -> ArrayMesh:
	var pts: PackedVector2Array = geo.pts
	var n := 16
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	for side in 2:
		var s := 1.0 if side == 0 else -1.0
		for j in n:
			verts.append(pts[j])
			var code := 4.0 if s > 0.0 else 5.0
			var t := 0.0
			if j == 7:
				code = 8.0 if s > 0.0 else 9.0
				t = geo.tip_r
			elif j == 15:
				code = 6.0 if s > 0.0 else 7.0
				t = geo.tip_l
			var i1 := (j + n - 1) % n
			uvs.append(Vector2(float(i1 * 32 + j), _uv_y(code, t).y))
	var idx := PackedInt32Array()
	for j in n:
		var j1 := (j + 1) % n
		idx.append_array([j, j1, n + j, j1, n + j1, n + j])
	return _finish_mesh(verts, uvs, idx)


## 窄条退化填充：直角矩形（原版 _draw_wobbly_rect 的 draw_rect 回退）。
static func _build_plain_fill_mesh() -> ArrayMesh:
	var pts := PackedVector2Array([
		Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5),
	])
	var uvs := PackedVector2Array()
	for j in 4:
		uvs.append(_uv_y(0.0, 0.0))
	return _finish_mesh(pts, uvs, PackedInt32Array([0, 1, 2, 0, 2, 3]))


## 窄条退化描边：矩形 4 角 × 内外圈（shader plain 分支 = (n1+n2)×0.8 直角方
## 角偏移，对齐 draw_rect 边框语义）。
static func _build_plain_ring_mesh() -> ArrayMesh:
	var corners := [
		Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5),
	]
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	for side in 2:
		var s := 1.0 if side == 0 else -1.0
		for j in 4:
			verts.append(corners[j])
			var code := 4.0 if s > 0.0 else 5.0
			var i1 := (j + 3) % 4
			uvs.append(Vector2(float(i1 * 32 + j), _uv_y(code, 0.0).y))
	var idx := PackedInt32Array()
	for j in 4:
		var j1 := (j + 1) % 4
		idx.append_array([j, j1, 4 + j, j1, 4 + j1, 4 + j])
	return _finish_mesh(verts, uvs, idx)


## 圆点几何：10 段圆，径向 wobble 全烘焙进半径（DOT_WOBBLE_U 单位常量——
## 圆点实例均匀缩放 rr，位移与缩放同比，无需 shader 参与）。
static func _dot_geometry(tab: PackedFloat32Array) -> Dictionary:
	var pts := PackedVector2Array()
	for i in 10:
		var a := TAU * float(i) / 10.0
		pts.append(Vector2(cos(a), sin(a)) * (1.0 + tab[i] * DOT_WOBBLE_U))
	return {"pts": pts}


static func _build_dot_fill_mesh(geo: Dictionary) -> ArrayMesh:
	var pts: PackedVector2Array = geo.pts
	var uvs := PackedVector2Array()
	for j in 10:
		uvs.append(_uv_y(0.0, 0.0))
	return _finish_mesh(pts, uvs, Geometry2D.triangulate_polygon(pts))


## 圆点描边环带：miter 偏移在构建期烘焙（均匀缩放 → 单位空间法线即世界
## 法线），内外双拷贝环形缝合，shader 零位移。
static func _build_dot_ring_mesh(geo: Dictionary) -> ArrayMesh:
	var pts: PackedVector2Array = geo.pts
	var n := 10
	var mit := []
	for j in n:
		# 两条邻边都必须取「前进方向」向量（j-1→j 与 j→j+1），法线才同朝外——
		# 一反向则角平分线退化为差向量，miter 偏移严重偏短
		var e1 := pts[j] - pts[(j + n - 1) % n]
		var e2 := pts[(j + 1) % n] - pts[j]
		var n1 := Vector2(e1.y, -e1.x).normalized()
		var n2 := Vector2(e2.y, -e2.x).normalized()
		var m := (n1 + n2).normalized()
		mit.append(m * (0.8 / 6.0) / maxf(m.dot(n1), 0.3))
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	for side in 2:
		var s := 1.0 if side == 0 else -1.0
		for j in n:
			verts.append(pts[j] + mit[j] * s)
			uvs.append(_uv_y(0.0, 0.0))
	var idx := PackedInt32Array()
	for j in n:
		var j1 := (j + 1) % n
		idx.append_array([j, j1, n + j, j1, n + j1, n + j])
	return _finish_mesh(verts, uvs, idx)



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

