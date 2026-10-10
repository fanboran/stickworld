extends Node
## char_direct_buckets.gd —— 关节烘焙路线的全局 3D 桶管理（每 hd2d_world 一份）。
##
## 职责：角色身体（1 桶，预烘关节贴图图集采样）+ 武器/盾（按纹理分桶）+
## 关节贴图图集（char_joint_atlas 子节点，宿主申报规格、本节点在版本变化时
## 把新贴图绑给身体桶材质）+ 血条图集（char_bar_atlas 子节点）。
##
## 写段铁律＝**官方 setter 全程**（set_instance_transform/color/custom_data，
## 交接档 §二b-1 裁定：裸 buffer 手打包编码是死路，官方 setter 是唯一无格式
## 风险的坦途——temp/mm3d_setter_probe 实证三通道全到位）。紧凑行制：宿主在
## 晚优先级 _process(1100) 逐行追加（行写入自带帧戳游标复位），本节点 1200
## 清尾部（退化变换）——无段池无空闲簿记，死单位不追加即消失。
##
## 层序（画布「全局两遍」的 3D 直译）由宿主写行次序承运：同一角色的描边遍
## 先于填充遍（描边行实深度垫后 ZB_STROKE，由宿主写进变换），填充遍内按
## 画布树序（腿→躯干→颈/头→臂）。渐隐（尸体）不换桶——实例色 alpha 逐帧
## 压低（本桶材质本就是 blend_mix 透明混合，深度写保跨角色遮挡）。

const BODY_SHADER := preload("res://modules/hd2d/shaders/char3d_body_opaque.gdshader")
const WEAPON_SHADER := preload("res://modules/hd2d/shaders/char3d_weapon_atlas.gdshader")
const JOINT_ATLAS_SCRIPT := preload("res://modules/hd2d/scripts/char_joint_atlas.gd")
const BAR_ATLAS_SCRIPT := preload("res://modules/hd2d/scripts/char_bar_atlas.gd")

## 世界占位 AABB（MultiMesh 剔除按盒，实例动态写入不逐帧精确，给全域冗余）
const WORLD_AABB := AABB(Vector3(-30000.0, -2000.0, -30000.0), Vector3(60000.0, 4000.0, 60000.0))
## 退化变换（零基＝零面积三角形＝隐形；清尾用）
const XF_HIDDEN := Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)
## 「不写 custom 通道」哨兵色（合法 Color 域之外）
const CUSTOM_SKIP := Color(-1.0, -1.0, -1.0, -1.0)

# ─────────────────────────── 静态网格（3D 版） ───────────────────────────

## 1x1 居中 quad（XY 平面，z=0，白色顶点色——MultiMesh 实例色与顶点色相乘）
static var _quad3d: ArrayMesh = null

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


## 紧凑追加桶（官方 setter 写行；帧戳游标制，1200 清尾）
class RowBucket:
	extends Node
	var mm: MultiMesh = null
	var cursor := 0            # 本帧已写行数
	var high_water := 0        # 历史最大行数（instance_count 水位）
	var _stamp := -1           # 帧戳（新帧自动复位游标）

	func _setup(name: String, mesh: ArrayMesh, mat: Material, use_custom: bool) -> void:
		set_name(name)
		var mmi := MultiMeshInstance3D.new()
		mmi.material_override = mat
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = use_custom
		mm.mesh = mesh
		mm.instance_count = 0
		mm.custom_aabb = WORLD_AABB
		mmi.multimesh = mm
		add_child(mmi)

	## 行写入（官方 setter 三通道；custom=CUSTOM_SKIP 则不写该通道）
	func row(xf: Transform3D, col: Color, custom: Color) -> void:
		var f := Engine.get_process_frames()
		if f != _stamp:
			_stamp = f
			cursor = 0
		if cursor >= high_water:
			high_water = cursor + 1
			mm.instance_count = high_water
		mm.set_instance_transform(cursor, xf)
		mm.set_instance_color(cursor, col)
		if custom != CUSTOM_SKIP:
			mm.set_instance_custom_data(cursor, custom)
		cursor += 1

	## 尾部清隐（宿主全写完后调：本帧未写的旧行退化隐形——零面积三角形；
	## 整帧零写入时游标也要复位，否则上帧旧行残留可见）
	func end_tick() -> void:
		var f := Engine.get_process_frames()
		if f != _stamp:
			_stamp = f
			cursor = 0
		for i in range(cursor, high_water):
			mm.set_instance_transform(i, XF_HIDDEN)
		# 水位不回缩（避免频繁 realloc；隐形行零渲染成本）


# ─────────────────────────── 实例状态 ───────────────────────────

var body: RowBucket = null          # 身体部件桶（描边+填充全角色共用）
var _body_mat: ShaderMaterial = null
## 武器桶：纹理路径 → 桶（每纹理独立 MultiMesh，纹理=uniform；紧凑行制）
var _weapon_buckets: Dictionary = {}  # path -> {bucket: RowBucket, tex: Texture2D}
## 关节贴图图集（headless 跳过装配；宿主申报规格，版本变化时绑新贴图）
var joint_atlas: Node = null
var _joint_tex_version := -1
## 血条图集（headless 跳过装配）
var bar_atlas: Node = null


func _ready() -> void:
	process_priority = 1200  # 宿主(1100) 之后清尾
	if DisplayServer.get_name() != "headless":
		var body_node := RowBucket.new()
		add_child(body_node)
		_body_mat = ShaderMaterial.new()
		_body_mat.shader = BODY_SHADER
		body_node._setup("Char3DBody", get_quad3d(), _body_mat, true)
		body = body_node
		joint_atlas = JOINT_ATLAS_SCRIPT.new()
		joint_atlas.name = "JointBakeAtlas"
		add_child(joint_atlas)
		bar_atlas = BAR_ATLAS_SCRIPT.new()
		bar_atlas.name = "CharBarAtlas"
		add_child(bar_atlas)


func _process(_delta: float) -> void:
	if body == null:
		return
	# 关节贴图版本监视：图集重烘（zoom 补偿变描边宽）后绑新贴图给身体桶
	if joint_atlas != null:
		var v: int = joint_atlas.version()
		if v != _joint_tex_version:
			_joint_tex_version = v
			_body_mat.set_shader_parameter("atlas_tex", joint_atlas.texture())
	body.end_tick()
	for path in _weapon_buckets:
		(_weapon_buckets[path]["bucket"] as RowBucket).end_tick()


# ─────────────────────────── 宿主写行口（1100 内调用） ───────────────────────────

## 身体部件行：变换 + 真色（描边白/填充身体色×tint×alpha）+ 格位 UV 子矩形
func body_row(xf: Transform3D, col: Color, uv: Rect2) -> void:
	body.row(xf, col, Color(uv.position.x, uv.position.y, uv.size.x, uv.size.y))


## 武器/盾行（按纹理分桶；无 custom——整纹理 UV）
func weapon_row(tex_path: String, tex: Texture2D, xf: Transform3D, col: Color) -> void:
	var b: Dictionary = _weapon_buckets.get(tex_path, {})
	if b.is_empty():
		var bucket := RowBucket.new()
		add_child(bucket)
		var mat := ShaderMaterial.new()
		mat.shader = WEAPON_SHADER
		mat.set_shader_parameter("atlas_tex", tex)
		bucket._setup("Char3DWeapon_%d" % _weapon_buckets.size(), get_quad3d(), mat, false)
		b = {"bucket": bucket, "tex": tex}
		_weapon_buckets[tex_path] = b
	(b["bucket"] as RowBucket).row(xf, col, CUSTOM_SKIP)
