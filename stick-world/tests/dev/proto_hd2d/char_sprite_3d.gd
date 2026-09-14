extends Node3D
## char_sprite_3d.gd —— HD-2D 核心机制：「2D 绘制 → SubViewport → 3D quad」
##
## 数据流：
##   Node2D 火柴人（modules/units 的 StickmanRig：Skeleton2D + 骨骼 + MultiMesh 批渲染）
##     → SubViewport（transparent_bg，只跑 2D）
##       → ViewportTexture
##         → char_billboard.gdshader 贴到与相机同基的 QuadMesh 上
##
## 为什么走 SubViewport 而不是把火柴人直接画到 Viewport：
##   直接画到主 Viewport 只能是 2D 层（永远盖在 3D 之上，或被 3D 完全盖住）；
##   过一遍 SubViewport 才拿到一张"可被 3D 场景当材质用"的纹理，
##   才能让建筑按真深度遮挡角色（见 char_billboard.gdshader 注释）。
##
## 尺寸契约（本原型的锚，别乱改）：
##   StickmanRig 原生空间高 ≈ 262px，脚底在 local y=+131（髋部为原点）。
##   本脚本把 rig.scale 设成 0.5 → 角色在 SubViewport 里 **131px 高**。
##   SubViewport 1px 映射 1 格/32 → 角色 = 131/32 = 4.09 格 = 130 Blender 单位
##   = 1.70m，与交接档 §0.3 的比例锚（火柴人 130px / 1.70m）严格一致。
##
## 一个 SubViewport 可以被 N 个 quad 共用（同姿态）；要每个角色不同动画相位，
## 必须一个角色一个 SubViewport（成本见汇报的性能读数）。

const RIG_SCENE := "res://modules/units/scenes/stickman_test.tscn"
const CHAR_SHADER := preload("res://tests/dev/proto_hd2d/char_billboard.gdshader")
const SHADOW_SHADER := preload("res://tests/dev/proto_hd2d/char_shadow.gdshader")
const StickmanOutline := preload("res://modules/units/scripts/rig/stickman_outline.gd")

const SV_W := 144            # SubViewport 宽（px）
const SV_H := 176            # SubViewport 高（px）
const RIG_SCALE := 0.475      # 原生 ~274px -> ~130px（= 130 世界单位 = 1.70m，§0.3 比例锚）
const FOOT_ROW := 144        # 脚底落在 SubViewport 的第几行（自顶向下，留 32px 底边）
const PX := 1.0 / 32.0       # 1 SubViewport px = 1 Blender 世界单位 = 1/32 格
const SIZE_K := 1.2          # 角色 billboard 世界占位放大（2026-09-14：偏小反馈）
## 双脚 IK 目标的中点（stickman_test.tscn 里 outfoot=(28,131) / innerfoot=(-22,131)），
## 用来把角色水平居中、脚底钉在 FOOT_ROW。这两个 Marker 是**骨骼 IK 的契约锚点**，
## 位置稳定（不随动画帧漂），所以比 alpha 包围盒更适合当摆位基准。
## y 取 141 而非 131：矢量路径的腿用 ~9px 粗的圆头线段画，脚底墨迹中心在骨骼
## 位置下方约 10px（实测 idle 包围盒底 = 骨骼 +145），取 141 让墨迹贴地。
const FOOT_ANCHOR := Vector2(3.0, 141.0)

var viewport: SubViewport = null
var rig: Node2D = null
var mat: ShaderMaterial = null
var quads: Array[MeshInstance3D] = []
var bbox := Rect2i()

## 像素倍率：SubViewport 尺寸 / rig 缩放 / 脚底行一起乘这个数。
## 世界占位不变（角色永远是 4.06 格），只改 SubViewport 的分辨率。
## 默认 2（超采样）：SubViewport 以 2 倍分辨率画火柴人，再经线性过滤缩到 quad 上，
## 边缘得到 2x2 超采样 —— 这是把 2D 角色的硬边磨到和建筑卡一样柔的主手段。
var px_scale := 2.0
var _sv_size := Vector2i(SV_W, SV_H)
var _foot_row := FOOT_ROW


func set_px_scale(n: float) -> void:
	px_scale = maxf(0.25, n)

var _shadow: MeshInstance3D = null
## 供主脚本按光照档刷新的材质列表（角色 + 影共用）
var _shadow_mat: ShaderMaterial = null


## 主场景俯角（build 时传入，与 proto_hd2d.TILT_DEG 同源——角色卡必须与相机正对）
var _tilt_deg: float = 26.0
var _host: Node = null

# 游戏接入（2026-09-14）：每实体一个本实例，渲染随 2D 实体逐帧移动
var _quad: MeshInstance3D = null
var _my_shadow: MeshInstance3D = null
var _flip := false
var _anim := "idle"
var _depth := 1.0


## 建 SubViewport + 火柴人。parent 必须是已在树内的节点。
func build(parent: Node, anim: String = "idle", tilt_deg: float = 26.0) -> void:
	_host = parent
	_tilt_deg = tilt_deg
	# 强制走**矢量部件路径**（旧路径），不走 MultiMesh 批渲染。
	# 实测：批渲染路径在本 SubViewport 里渲染出的是"未解算的横躺姿态"，
	# 用 probe_rig3.gd（--char 对照）可复现。
	# 怀疑成因：批渲染的快照靠 NOTIFICATION_INTERNAL_PROCESS 挂钩骨架解算帧，
	# 只有接上 UnitLodDirector（set_anim_update_hz）才会挂这个钩；裸实例化时快照
	# 落在解算之前 → 存的是 rest/未 IK 的姿态。本原型只用矢量路径取正确姿态，
	# 这个批渲染差异如实写进汇报，不当成功。
	OS.set_environment("STICK_BATCH_RIG", "0")
	_sv_size = Vector2i(int(SV_W * px_scale), int(SV_H * px_scale))
	_foot_row = FOOT_ROW * px_scale
	var rig_scale := RIG_SCALE * px_scale
	viewport = SubViewport.new()
	viewport.name = "CharSubViewport"
	viewport.size = _sv_size
	viewport.transparent_bg = true
	viewport.disable_3d = true
	# 4x MSAA：2D 角色是矢量线段（圆头 Line2D / 多边形），MSAA 直接作用在
	# 线段边缘像素上（不是纹理内容），是除超采样之外最有效的一道。
	viewport.msaa_2d = Viewport.MSAA_4X
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	# 每帧更新：角色在动就必须每帧重画。UPDATE_DISABLED / UPDATE_ONCE 的省法见 --perf。
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	parent.add_child(viewport)

	var inst: Node = load(RIG_SCENE).instantiate()
	# stickman_test.tscn 的根脚本是"编辑器演示"控制器（把实例挪到 (400,300)、
	# 加 Label、按主视口尺寸缩放）。摘掉它，由本脚本按 SubViewport 自己的坐标系统一摆位。
	inst.set_script(null)
	viewport.add_child(inst)
	rig = inst.get_node("OutlineGroup/StickmanRig") as Node2D
	rig.scale = Vector2(rig_scale, rig_scale)
	# **整棵实例根一起挪，不能只挪 rig**：手臂/腿的 IK 目标 Marker2D
	# （OutlineGroup/Node2D/outfoot…）是 rig 的兄弟节点，只有跟着一起平移，
	# IK 契约才成立。实测只挪 rig → 目标留在原点、肢体朝目标塌折成一个墨团
	# （与 stickman_rig.gd:371 记的"全身横躺 90°"是同一类失效）。
	(inst as Node2D).position = Vector2(
		float(_sv_size.x) * 0.5 - FOOT_ANCHOR.x * rig_scale,
		_foot_row - FOOT_ANCHOR.y * rig_scale)
	rig.play(anim)
	# 全融合描边（创始人定稿：白描边只包外轮廓、内部零描边）：OutlineGroup
	# 整棵收进 CanvasGroup（子树同搬保 IK 路径），ID+描边 pass 作用于组缓冲
	var og := inst.get_node_or_null("OutlineGroup")
	if og != null and og is Node2D and not og is CanvasGroup:
		var cg := CanvasGroup.new()
		cg.name = "FusedOutlineGroup"
		inst.add_child(cg)
		og.reparent(cg)
		StickmanOutline.setup(cg)

	mat = ShaderMaterial.new()
	mat.shader = CHAR_SHADER
	mat.set_shader_parameter("char_tex", viewport.get_texture())
	mat.set_shader_parameter("tint", Color(1, 1, 1))
	# 硬边切割（目标旧版=干净直轮廓）：软羽化边在明亮地面上会透出彩边
	mat.set_shader_parameter("alpha_soften", 0.0)
	mat.set_shader_parameter("alpha_cut", 0.35)

	_shadow_mat = ShaderMaterial.new()
	_shadow_mat.shader = SHADOW_SHADER


## quad 世界中心（沿相机 up 轴）。契约：quad 覆盖整个 SubViewport，
## 每 SubViewport 像素 = PX/px_scale 格（超采样后 1 像素更小）。
## world_y(row) = center_y + (sv_h/2 - row) * PX/px_scale，令 world_y(foot_row) = 0。
func quad_center_offset_y() -> float:
	return (_foot_row - float(_sv_size.y) * 0.5) * (PX / px_scale) * SIZE_K


## 在 (x, z) 放一个角色（脚底落世界 y=0）。flip 只翻 x，共用同一张 SubViewport 纹理。
## quad 世界尺寸固定 = 基准 SubViewport 尺寸 × PX（与 px_scale 无关）：
## SubViewport 变大只是让 2D 角色被画得更精细，世界占位始终 4.06 格。
func add_char(x: float, z: float, flip: bool = false) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = Vector2(SV_W * PX, SV_H * PX) * SIZE_K
	var mi := MeshInstance3D.new()
	mi.mesh = q
	mi.material_override = mat
	mi.position = Vector3(x, quad_center_offset_y(), z)
	var b := _cam_basis()
	if flip:
		b = Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)) * b
	mi.basis = b
	mi.name = "Char_%d_%.1f" % [quads.size(), x]
	# 透明卡不投真阴影（真影交给下面那张贴地的程序化接地影）
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	quads.append(mi)

	# 接地影：贴地水平 quad，随角色 x/z 走
	var sq := QuadMesh.new()
	sq.size = Vector2(4.2, 2.6) * SIZE_K
	var sh := MeshInstance3D.new()
	sh.mesh = sq
	sh.material_override = _shadow_mat
	sh.position = Vector3(x, 0.09, z)
	sh.rotation = Vector3(deg_to_rad(-90), 0, 0)
	sh.name = "Shadow_%d" % quads.size()
	sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sh)
	if _shadow == null:
		_shadow = sh
	# 游戏接入：记录本实例的 quad/影引用（set_world_pos 每帧驱动）
	_quad = mi
	_my_shadow = sh
	return mi


## 3D 脚下四角框（possessed 玩家专用）：贴地 quad，同接地影口径——
## 框随 billboard 在同一相机/空间内，速度位置天然一致
static var _bracket_tex: ImageTexture = null

static func _get_bracket_tex() -> ImageTexture:
	if _bracket_tex == null:
		var w := 96
		var h := 64
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		var arm := 18
		var t := 4
		var white := Color(1, 1, 1, 0.95)
		for k in range(4):
			var cx := 8 if k % 2 == 0 else w - 8
			var cy := 8 if k < 2 else h - 8
			var dx := 1 if k % 2 == 0 else -1
			var dy := 1 if k < 2 else -1
			for i in range(arm):
				img.set_pixel(cx + dx * i, cy, white)
				for tt in range(t):
					img.set_pixel(cx + dx * i, cy + tt if dy > 0 else cy - tt, white)
			for j in range(arm):
				for tt in range(t):
					img.set_pixel(cx + tt if dx > 0 else cx - tt, cy + dy * j, white)
		_bracket_tex = ImageTexture.create_from_image(img)
	return _bracket_tex

var _bracket_quad: MeshInstance3D = null

func set_bracket_visible(v: bool) -> void:
	if v and _bracket_quad == null and not quads.is_empty():
		var q := QuadMesh.new()
		q.size = Vector2(3.4, 2.2)
		var mi := MeshInstance3D.new()
		mi.mesh = q
		var m := StandardMaterial3D.new()
		m.albedo_texture = _get_bracket_tex()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.render_priority = 5
		mi.material_override = m
		mi.rotation = Vector3(deg_to_rad(-90), 0, 0)
		mi.position = Vector3(0, 0.10, 0.35)
		mi.name = "FootBracket"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		quads[0].get_parent().add_child(mi)
		_bracket_quad = mi
	if _bracket_quad != null:
		_bracket_quad.visible = v


## 游戏接入：逐帧更新本角色的世界位置/朝向/纵深缩放（quad 贴相机基+接地影贴地）。
func set_world_pos(x: float, z: float, flip: bool, depth: float = 1.0) -> void:
	if _quad == null:
		return
	_flip = flip
	_depth = depth
	# 缩放并入 basis 一次赋值（scale setter 与 basis 先后赋值互相覆盖）；
	# 朝向翻转走 shader 的 UV 镜像（basis 镜像会把俯仰轴一起翻——旧 bug）
	var b := _cam_basis()
	b = b.scaled(Vector3(depth, depth, depth))
	_quad.basis = b
	_quad.position = Vector3(x, quad_center_offset_y() * depth, z)
	if mat != null:
		mat.set_shader_parameter("flip_uv", flip)
	if _my_shadow != null:
		_my_shadow.position = Vector3(x, 0.09, z)
		_my_shadow.scale = Vector3(depth * SIZE_K, depth * SIZE_K, 1.0)
	if _bracket_quad != null:
		_bracket_quad.position = Vector3(x, 0.10, z + 0.35)
		_bracket_quad.scale = Vector3(depth, depth, 1.0)


## 动画切换（只在变化时 play，避免每帧重置动画进度）
func set_anim(anim: String) -> void:
	if _anim == anim or rig == null:
		return
	_anim = anim
	rig.play(anim)


## 显示/隐藏全部角色（含影）。用于 A/B 对照出图。
func set_chars_visible(v: bool) -> void:
	for c in get_children():
		if c is MeshInstance3D:
			(c as MeshInstance3D).visible = v


## 把当前所有 quad/影登记为"常驻角色"。之后 add_char 加的都是临时验证站位，
## 可用 clear_extra() 一次清掉（否则临时站位的 quad 和它的接地影会漏到后续镜头里）。
var _regular: Array = []

func mark_regular() -> void:
	_regular.clear()
	for c in get_children():
		if c is MeshInstance3D:
			_regular.append(c)


func clear_extra() -> void:
	for c in get_children():
		if c is MeshInstance3D and not _regular.has(c):
			c.queue_free()


## 与相机同基（X 右 / Y 上 / Z 朝相机）：quad 与**建筑卡完全同取向**，
## 永远正对相机、零屏幕空间旋转、零透视收缩。
## 创始人两次澄清后的最终口径：火柴人卡 = 相机对齐 billboard（不是垂直插地），
## 与建筑卡同平面贴相机是**正确**结果，不得为"3D 感"给角色加任何角度。
## 只有"脚底锚定地面点"这一半是 3D 的：quad 中心沿世界 y 摆到脚底落 y=0。
## 俯角从主场景传入（2026-09-14 修：此前硬编码 20°，场景加俯角到 26° 后
## 没同步，角色卡与相机差 6° 不正对——"身高/角度不对"的观感即来自这里）。
func _cam_basis() -> Basis:
	var t := deg_to_rad(_tilt_deg)
	return Basis(Vector3(1, 0, 0),
		Vector3(0, cos(t), -sin(t)), Vector3(0, sin(t), cos(t)))


## 量 SubViewport 里角色的 alpha 包围盒（自检用：证明 2D 像素真的落进了纹理，
## 并给出与尺寸契约的偏差）。必须在出过一次图之后调。
func measure_bbox() -> Rect2i:
	await RenderingServer.frame_post_draw
	var img := viewport.get_texture().get_image()
	if img == null or img.get_width() == 0:
		return Rect2i()
	var minx := img.get_width()
	var miny := img.get_height()
	var maxx := -1
	var maxy := -1
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.02:
				minx = mini(minx, x)
				miny = mini(miny, y)
				maxx = maxi(maxx, x)
				maxy = maxi(maxy, y)
	if maxx < 0:
		return Rect2i()
	bbox = Rect2i(minx, miny, maxx - minx + 1, maxy - miny + 1)
	return bbox


func set_light(tint: Color, add: Color) -> void:
	if mat != null:
		mat.set_shader_parameter("tint", tint)
		mat.set_shader_parameter("light_add", add)
	if _shadow_mat != null:
		_shadow_mat.set_shader_parameter("blob_color",
			Color(0.06, 0.05, 0.05, 0.50 * clampf(tint.get_luminance() + 0.25, 0.0, 1.0)))
