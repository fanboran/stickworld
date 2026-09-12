extends RefCounted
## 小兵渲染代理（§十四 架构重构）——纯数据 + 代码插值矢量批渲染。
##
## 是什么：战斗小兵不再跑「23 骨 Skeleton2D + AnimationTree + 叠加层 +
## 每单位 4 MMI」的富管线；本类用**全局 4 桶 MultiMesh** 渲染全部小兵，
## 动画 = 对 bake_anims 烘焙的骨骼 rotation 关键帧做代码插值，几何与颜色
## 与骨骼管线同源（同 SKELETON_DATA / 同 batch_rig 部件数学），观感零损。
## 每小兵每刻成本 ≈ 若干次浮点插值 + 360 floats 的 buffer 段写入；
## 全战场身体 4 个 draw。
##
## 动画语义对齐 stickman_rig：
##   - play/play_hit 由 rig 播报（set_crowd_hook 注入回调），状态机不再运行；
##   - animation_finished：LOOP_NONE 动画 t ≥ length 时经 rig 信号补发
##     （攻击播完回切/移动锁的消费方无感知差异）；
##   - 命中帧时序归 sim（D 刀），渲染零依赖；hitstop/time_scale 经驱动方
##     的 delta 自然生效（由 BattleInstance._physics_process 驱动，与 sim
##     同门禁——暂停即停）。
##
## 槽位模型：注册即分配固定槽位（4 桶各 30 实例段），注销把实例色 alpha
## 置 0（一次写入后跳过）——无动态增删，buffer 偏移恒定。
##
## 开关：env STICK_CROWD=0 回退骨骼富管线（默认开）。

const Skel := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")
const BatchRig := preload("res://modules/units/scripts/rig/stickman_batch_rig.gd")

## 工程设置键 + 环境变量（A/B 惯例）
const SETTING_KEY := "render/crowd_renderer"
const ENV_OVERRIDE := "STICK_CROWD"

## 动画资源目录（bake_anims 产物）
const ANIM_DIR := "res://modules/units/animations/"


static func is_enabled() -> bool:
	var env := OS.get_environment(ENV_OVERRIDE)
	if env == "0":
		return false
	if env == "1":
		return true
	return bool(ProjectSettings.get_setting(SETTING_KEY, true))


# ─────────────────────────── 静态共享表（全进程一份） ───────────────────────────

## 骨骼先序表（父先于子；拓扑排序自 SKELETON_DATA+EXTRA_LIMBS）
static var _bone_ids: PackedInt32Array = PackedInt32Array()
## 先序下标 → 父先序下标（-1 = 根）
static var _bone_pidx: PackedInt32Array = PackedInt32Array()
## 先序下标 → rest 位置（骨骼局部平移；rotation 由动画插值附加）
static var _rest_pos: PackedVector2Array = PackedVector2Array()
## 动画预编译表：anim_name -> {length, loop, tracks: {bone_id -> PackedFloat32Array [t0,a0,t1,a1...]}}
static var _anim_tables: Dictionary = {}
## 4 桶部件预烘表（同 batch_rig._emit_limb 数学）：每实例 = (父骨先序下标, 局部变换, 颜色模板)
static var _bucket_bidx: Array = []  # PackedInt32Array ×4
static var _bucket_xform: Array = [] # Array[Transform2D] ×4
static var _bucket_color: Array = [] # PackedColorArray ×4（身体色占位白，注册时按单位实际色替换）
static var _statics_ready: bool = false


## 进程级静态表构建：骨骼拓扑 + 部件预烘 + 动画关键帧预编译。
static func _ensure_statics() -> void:
	if _statics_ready:
		return
	_statics_ready = true
	_build_bone_topology()
	_build_bucket_tables()
	_compile_anims()


## 骨骼拓扑排序：SKELETON_DATA+EXTRA_LIMBS 按 parent 链深度排序（父先于子），
## 与 batch_rig._walk_and_emit 的场景树先序等价（部件累乘只要求父先于子）。
static func _build_bone_topology() -> void:
	var all: Dictionary = Skel.SKELETON_DATA.merged(Skel.EXTRA_LIMBS, true)
	# 深度排序（迭代逼近：每轮把 parent 已入序的骨入序）
	var placed: Dictionary = {}
	var pending: Array = all.keys()
	while not pending.is_empty():
		var progressed: bool = false
		var next_pending: Array = []
		for id in pending:
			var parent: int = all[id].get("parent", -1)
			if parent < 0 or placed.has(parent):
				placed[id] = true
				var data: Dictionary = all[id]
				_bone_ids.append(id)
				_bone_pidx.append(_bone_ids.find(parent) if parent >= 0 else -1)
				_rest_pos.append(Vector2(data.get("x", 0.0), data.get("y", 0.0)))
				progressed = true
			else:
				next_pending.append(id)
		pending = next_pending
		if not progressed:
			break  # 环防御（数据错误时退出避免死循环）


## 部件预烘（照搬 batch_rig._emit_limb 的尺寸语义，父骨下标换成本表先序下标）。
static func _build_bucket_tables() -> void:
	for j in 4:
		_bucket_bidx.append(PackedInt32Array())
		_bucket_xform.append([])
		_bucket_color.append(PackedColorArray())
	var all: Dictionary = Skel.SKELETON_DATA.merged(Skel.EXTRA_LIMBS, true)
	# 部件查找表：父骨骼 id → 段参数（type>=0 才有几何）——同 batch_rig
	var limb_by_parent: Dictionary = {}
	for id in all:
		var data: Dictionary = all[id]
		if int(data.get("type", -1)) < 0:
			continue
		var pid: int = data["parent"]
		if not limb_by_parent.has(pid):
			limb_by_parent[pid] = data
	for i in _bone_ids.size():
		var id: int = _bone_ids[i]
		if limb_by_parent.has(id):
			_emit_limb(limb_by_parent[id], i)


## 单段肢体拆 4 桶（与 batch_rig._emit_limb 同式）。颜色哨兵制：
## 身体类（非武器/护甲）存 WHITE → 写 buffer 时替换为单位身体色；描边存
## BLACK → 替换为单位描边色；武器（TRIANGLE）/护甲（ELLIPSE）存模板真值
## （非阵营色，与骨骼管线里 colors 表语义一致）。
static func _emit_limb(data: Dictionary, bone_idx: int) -> void:
	var node_type: int = int(data.get("type", -1))
	var length := float(data.get("length", 1))
	var w := maxf(float(data.get("thickness", 0)), 1.0)
	var ow := Skel.OUTLINE_WIDTH
	var is_body: bool = node_type != Skel.TYPE_TRIANGLE and node_type != Skel.TYPE_ELLIPSE
	var fill_color: Color = Color.WHITE if is_body else Skel._color_for_type(node_type, {})
	if node_type == Skel.TYPE_CIRCLE:
		var r := maxf(length, w * 2.0) / 2.0
		var base := Transform2D(0.0, Vector2(data["x"], data["y"]))
		_push(1, bone_idx, base * _scale2(r + ow, r + ow), Color.BLACK)
		_push(3, bone_idx, base * _scale2(r, r), fill_color)
		return
	var dir := Vector2(data["x"], data["y"])
	var base := Transform2D(dir.angle(), dir / 2.0)
	var half := length / 2.0
	var sw := w + ow * 2.0
	_push(0, bone_idx, base * _scale2(length, sw), Color.BLACK)
	_push(1, bone_idx, base * _shift_scale(Vector2(-half, 0.0), sw / 2.0, sw / 2.0), Color.BLACK)
	_push(1, bone_idx, base * _shift_scale(Vector2(half, 0.0), sw / 2.0, sw / 2.0), Color.BLACK)
	_push(2, bone_idx, base * _scale2(length, w), fill_color)
	_push(3, bone_idx, base * _shift_scale(Vector2(-half, 0.0), w / 2.0, w / 2.0), fill_color)
	_push(3, bone_idx, base * _shift_scale(Vector2(half, 0.0), w / 2.0, w / 2.0), fill_color)


static func _push(bucket: int, bone_idx: int, xform: Transform2D, color: Color) -> void:
	_bucket_bidx[bucket].append(bone_idx)
	_bucket_xform[bucket].append(xform)
	_bucket_color[bucket].append(color)


static func _scale2(sx: float, sy: float) -> Transform2D:
	return Transform2D(Vector2(sx, 0.0), Vector2(0.0, sy), Vector2.ZERO)


static func _shift_scale(off: Vector2, sx: float, sy: float) -> Transform2D:
	return Transform2D(0.0, off) * _scale2(sx, sy)


## 动画预编译：扫描动画目录全部 .tres，解析 value track（:rotation）成
## 每骨骼关键帧浮点数组（运行时零解析成本，纯插值）。
static func _compile_anims() -> void:
	var dir := DirAccess.open(ANIM_DIR)
	if dir == null:
		push_error("[CrowdRenderer] 动画目录不可读: " + ANIM_DIR)
		return
	for file in dir.get_files():
		if not file.ends_with(".tres"):
			continue
		var anim: Animation = load(ANIM_DIR + file) as Animation
		if anim == null:
			continue
		var tracks: Dictionary = {}
		for i in anim.get_track_count():
			# 只取 value track（:rotation）；方法/事件轨（spine 导入的 Hit 等）
			# 的 key value 非数值，插值无意义
			if anim.track_get_type(i) != Animation.TYPE_VALUE:
				continue
			var path: NodePath = anim.track_get_path(i)
			if not str(path).ends_with(":rotation"):
				continue
			var bone_name := str(path.get_name(path.get_name_count() - 1))
			var bone_id: int = Skel.BONE_NAME_TO_ID.get(bone_name, -1)
			if bone_id < 0:
				continue
			var keys := PackedFloat32Array()
			var bad_track := false
			for k in anim.track_get_key_count(i):
				var v = anim.track_get_key_value(i, k)
				if not (v is float) and not (v is int):
					# 实验动画脏数据（如 run_bvh 的 hip:rotation 轨 value 是
					# Vector2）：整轨跳过，插值只信数值关键帧
					bad_track = true
					break
				keys.append(float(anim.track_get_key_time(i, k)))
				keys.append(float(v))
			if bad_track or keys.size() < 4:
				continue
			tracks[bone_id] = keys
		_anim_tables[file.get_basename()] = {
			"length": anim.length,
			"loop": anim.loop_mode == Animation.LOOP_LINEAR,
			"tracks": tracks,
		}


# ─────────────────────────── 实例状态 ───────────────────────────

## y 分带（§十三：MultiMesh 无逐实例排序，官方解法 = 按世界区域分桶）：
## 战场 y 切 12 带，每带 4 桶 MMI（共 48 draw）；带间树序遮挡保留（y 大的带
## 后画 = 前排盖后排），带内平铺。带高取 ~36px < 单位身高（90px×scale）——
## 带粗了同带单位部件逐个穿插会毁掉人形轮廓（实测 4 带碎片化的教训）；
## 48 draws 相比富管线 1516 仍 30 倍。单位跨带时段搬运（拷贝 30×12 floats×4
## 桶，平滑移动下频率很低）。
const BAND_COUNT := 12

## 挂载节点（BattleInstance 子节点，z=ENTITY 层；MMI 树序在实体前——
## 小兵 rig 已隐藏，仅武器 Sprite（若保留）会盖在其上）
var _host: Node = null
## 4 带 × 4 桶 MultiMesh/缓冲（下标 band*4+j）
var _mm: Array = []     # MultiMesh ×16
var _buf: Array = []    # PackedFloat32Array ×16
## 带 y 边界（setup 传 map 的 ground_y/ground_bottom）
var _y_top: float = 0.0
var _band_h: float = 1.0
## 单位槽位表（固定容量增长；free 槽跳过）
var _slots: Array = []  # Dictionary: {entity, rig, anim, t, finished, hidden, colors, band}
var _free_slots: Array = []  # int（保留：全局槽下标池，暂与带池并用）
## 每带槽位池：free 列表 + 已用计数（分配 O(1)）
var _free_band: Array = []   # Array[PackedInt32Array 或 Array] ×BAND_COUNT
var _used_count: Dictionary = {}  # band -> int
## 累乘缓存（tick 复用避免分配）
var _acc: Array = []
var _local: Array = []
## 阴影桶：全局单 MMI（接触阴影无单位间遮挡语义，不分带不随 y 排序）。
## 实例行 = 平移(0, foot_offset+2) × 压扁(0.9,0.26)，观感与原 ContactShadow
## Sprite 一致（同参数径向渐变纹理）。注册时隐藏原 Sprite，注销恢复。
var _shadow_mmi: MultiMeshInstance2D = null
var _shadow_mm: MultiMesh = null
var _shadow_buf: PackedFloat32Array = PackedFloat32Array()
var _shadow_cap: int = 0
## 血条桶：6 组 × N 相位 MMI（N=WOBBLE_VARIANTS；组序=树序=绘制序）。
## 层序复刻原版 _draw_bar 的描边两遍画：底色 → 描边① → 残影/填充 → 描边②
## （0.95 半透明描边双绘合成 ≈0.9975：外半环双描、填充段内半环被填充盖住
## 只剩单描——层序错一条视觉上就是边缘发灰/描边偏细，实测 3/255 系统差）。
## 手绘感对齐三件套：
## - boiling：预烘 wobble 表（batch_rig，原版 _wobble 同式 float64）烘进网格
##   UV，shader 只做线性位移——与原版 _draw 路径逐顶点同值；
## - 描边：边界 ±0.8px 环带网格（复刻 draw_polyline 1.6px 居中描边），填充层
##   保持全尺寸原几何——半透明底混页面而非混黑剪影，blending 与原版一致；
## - 相位组 = indicator wobble seed % N：原版每 0.12s 重掷 seed → 桶侧换组跳
##   相位（boiling 逐帧抖动一致）；满血圆点 seed 恒 0 → 静止（与原版一致）。
var _bar_bg: OverlayBucket = null      # 暗底填充（描边①之下）
var _bar_ring1: OverlayBucket = null   # 描边第一遍
var _bar_trail_fill: OverlayBucket = null  # 白残影 + 阵营填充（盖描边①内半环）
var _bar_ring2: OverlayBucket = null   # 描边第二遍（顶层）
var _dot_fill: OverlayBucket = null
var _dot_ring: OverlayBucket = null
## 武器图集桶：全局单 MMI（武器 z=18 绝对层本就无单位间遮挡语义）。
## 带透明底自建图集渲染正常（二值 alpha 实测 OK，坑仅在半透明软渐变纹理——
## weapon_probe 四行对照实验定性）；INSTANCE_CUSTOM=(UV 偏移,子区域尺寸)
## 经 crowd_weapon_atlas.gdshader 顶点期映射采样。行 stride 16 floats
## （变换 8 + 色 4 + custom 4），纹理明暗不动、实例色恒白
var _weapon_mmi: MultiMeshInstance2D = null
var _weapon_mm: MultiMesh = null
var _weapon_buf: PackedFloat32Array = PackedFloat32Array()
var _weapon_cap: int = 0
var _weapon_count: int = 0  # 本刻压实行计数（tick 开头清零）
var _atlas_tex: ImageTexture = null
var _atlas_img: Image = null
var _atlas_entries: Dictionary = {}  # texture_path -> Rect2i（图集像素区）
var _atlas_pending: Dictionary = {}  # texture_path -> true（待 blit）
var _atlas_dirty: bool = false


## 装配：创建 4 带 × 4 桶 MMI（容器 Node2D，z=ENTITY=3 同层；带间靠树序
## 遮挡——band 高的后加）。**挂载父级 parent 必须与实体同 canvas 链**：
## 挂 battle_instance（纯 Node 下）实测身体桶整体不渲染（仅武器 Sprite 可见），
## 故由调用方传 map（实体所在树）。
func setup(parent: Node2D, y_top: float = 0.0, y_bottom: float = 1024.0) -> void:
	_ensure_statics()
	_host = parent
	_y_top = y_top
	_band_h = maxf((y_bottom - y_top) / float(BAND_COUNT), 1.0)
	var container := Node2D.new()
	container.name = "CrowdLayer"
	parent.add_child(container)
	var names := ["CrowdStrokeRects", "CrowdStrokeCaps", "CrowdFillRects", "CrowdFillCaps"]
	var meshes := [BatchRig._get_quad_mesh(), BatchRig._get_circle_mesh(),
			BatchRig._get_quad_mesh(), BatchRig._get_circle_mesh()]
	for band in BAND_COUNT:
		for j in 4:
			var count: int = _bucket_bidx[j].size()
			var idx: int = band * 4 + j
			_mm.append(null)
			_buf.append(PackedFloat32Array())
			if count <= 0:
				continue
			var mmi := MultiMeshInstance2D.new()
			mmi.name = "%s_B%d" % [names[j], band]
			mmi.texture = BatchRig._get_white_tex()
			mmi.z_index = 3  # 与 ENTITY 同层（光照 range 一致）；带间遮挡靠树序
			mmi.z_as_relative = false
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_2D
			mm.use_colors = true
			mm.mesh = meshes[j]
			mm.instance_count = 0
			# 关键：2D MultiMesh 的可视剔除基于 custom_aabb，默认空盒在原点——
			# 相机视野不含原点时整个桶被剔除（实测"身体消失仅剩武器"的根因）。
			# 覆盖全域（实例动态写入，逐帧精确盒不划算，给足冗余）。
			mm.custom_aabb = AABB(Vector3(-4096.0, -4096.0, 0.0), Vector3(16384.0, 16384.0, 0.0))
			mmi.multimesh = mm
			container.add_child(mmi)
			# 树序 = 绘制序：创建循环本身就是「带主序 × 桶次序」（低带先画保留
			# y 遮挡；带内 0/1 描边先画、2/3 填充后画盖在描边之上）。此前在此
			# 调 move_child(mmi, band) 把每 MMI 重插到 index=band，将已就位的
			# 桶整体后推——最终桶序错成"填充先画、描边后画"，而描边矩形与填充
			# 同长同中心更宽，白描边完全盖住深色填充 = 实心白身体（涂色定位
			# 实证：描边涂蓝可见、填充涂红被盖）。同 z 下靠树序，严禁再 move_child。
			_mm[idx] = mmi
	if _acc.size() != _bone_ids.size():
		_acc.resize(_bone_ids.size())
		_local.resize(_bone_ids.size())
	# 阴影桶 MMI（z=1 DECORATION 层，与原 ContactShadow Sprite 同层同观感）
	var smmi := MultiMeshInstance2D.new()
	smmi.name = "CrowdShadows"
	smmi.texture = BatchRig._get_white_tex()  # 纯白兜底纹理：软边全靠多层实例色阶梯
	smmi.z_index = 1
	smmi.z_as_relative = false
	var smm := MultiMesh.new()
	smm.transform_format = MultiMesh.TRANSFORM_2D
	smm.use_colors = true
	smm.mesh = BatchRig._get_quad_mesh()
	smm.instance_count = 0
	smm.custom_aabb = AABB(Vector3(-4096.0, -4096.0, 0.0), Vector3(16384.0, 16384.0, 0.0))
	smmi.multimesh = smm
	container.add_child(smmi)
	_shadow_mmi = smmi
	_shadow_mm = smm
	# 血条桶：6 组 × (N 相位 + plain 直角退化槽) MMI（z=1000 顶层与原
	# indicator 同绝对层；组创建顺序 = 树序 = 绘制序：底色→描边①→残影/填充
	# →描边②→点填充→点描边）。环带材质按变体各带 DELTAS/COEFF 烘表
	# （shader 逐实例重建世界边向量——条实例非均匀缩放，法线随宽高比变化）。
	var wobble_shader: Shader = load("res://modules/units/scripts/rig/crowd_bar_wobble.gdshader")
	var fill_mat := ShaderMaterial.new()
	fill_mat.shader = wobble_shader
	fill_mat.set_shader_parameter("mode", 0.0)
	var dot_mat := ShaderMaterial.new()
	dot_mat.shader = wobble_shader
	dot_mat.set_shader_parameter("mode", 1.0)
	var ring_mats: Array = []
	for k in BatchRig.WOBBLE_VARIANTS:
		var rm := ShaderMaterial.new()
		rm.shader = wobble_shader
		rm.set_shader_parameter("mode", 0.0)
		rm.set_shader_parameter("DELTAS", BatchRig._bar_ring_deltas(k))
		rm.set_shader_parameter("COEFF", BatchRig._bar_ring_coeffs(k))
		ring_mats.append(rm)
	var ring_plain_mat := ShaderMaterial.new()
	ring_plain_mat.shader = wobble_shader
	ring_plain_mat.set_shader_parameter("mode", 0.0)
	ring_plain_mat.set_shader_parameter("DELTAS", _pad16(BatchRig._plain_ring_deltas()))
	var zero16 := PackedFloat32Array()
	zero16.resize(16)
	ring_plain_mat.set_shader_parameter("COEFF", zero16)
	var n := BatchRig.WOBBLE_VARIANTS
	var fill_meshes: Array = []
	var fill_mats: Array = []
	for k in n:
		fill_meshes.append(BatchRig._get_wobble_bar_mesh(k))
		fill_mats.append(fill_mat)
	fill_meshes.append(BatchRig._get_plain_bar_mesh())
	fill_mats.append(fill_mat)
	var ring_meshes: Array = []
	var ring_mats_all: Array = ring_mats.duplicate()
	for k in n:
		ring_meshes.append(BatchRig._get_wobble_bar_ring_mesh(k))
	ring_meshes.append(BatchRig._get_plain_bar_ring_mesh())
	ring_mats_all.append(ring_plain_mat)
	var dot_fill_meshes: Array = []
	var dot_ring_meshes: Array = []
	var dot_mats: Array = []
	for k in n:
		dot_fill_meshes.append(BatchRig._get_wobble_dot_mesh(k))
		dot_ring_meshes.append(BatchRig._get_wobble_dot_ring_mesh(k))
		dot_mats.append(dot_mat)
	_bar_bg = _make_bucket(container, "CrowdBarBg", fill_meshes, fill_mats)
	_bar_ring1 = _make_bucket(container, "CrowdBarR1", ring_meshes, ring_mats_all)
	_bar_trail_fill = _make_bucket(container, "CrowdBarTf", fill_meshes, fill_mats)
	_bar_ring2 = _make_bucket(container, "CrowdBarR2", ring_meshes, ring_mats_all)
	_dot_fill = _make_bucket(container, "CrowdDotF", dot_fill_meshes, dot_mats)
	_dot_ring = _make_bucket(container, "CrowdDotR", dot_ring_meshes, dot_mats)
	# 武器图集桶（z=18 浮于单位身体之上，原武器 Sprite 同层）
	_weapon_mm = _make_weapon_mm(container)


## 覆盖层 MMI 构造（血条桶共用；z=1000 绝对层与原 indicator 一致）
func _make_overlay_mm(container: Node2D, mm_name: String, mesh: Mesh, mat: ShaderMaterial) -> MultiMeshInstance2D:
	var mmi := MultiMeshInstance2D.new()
	mmi.name = mm_name
	mmi.texture = BatchRig._get_white_tex()
	mmi.z_index = 1000
	mmi.z_as_relative = false
	mmi.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 0
	mm.custom_aabb = AABB(Vector3(-4096.0, -4096.0, 0.0), Vector3(16384.0, 16384.0, 0.0))
	mmi.multimesh = mm
	container.add_child(mmi)
	return mmi


## 血条桶组构造：逐槽（N 相位 + plain 退化槽）网格/材质配对 + 空缓冲
func _make_bucket(container: Node2D, prefix: String, meshes: Array, mats: Array) -> OverlayBucket:
	var b := OverlayBucket.new()
	for k in meshes.size():
		b.mmis.append(_make_overlay_mm(container, "%s%d" % [prefix, k], meshes[k], mats[k]))
		b.bufs.append(PackedFloat32Array())
		b.caps.append(0)
		b.cnt.append(0)
		b.prev.append(0)
	return b


## 补齐 PackedVector2Array 到 16 项（shader uniform 数组定长）
static func _pad16(arr: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(arr)
	while out.size() < 16:
		out.append(Vector2.ZERO)
	return out


## 武器图集桶 MMI（use_custom_data 传 UV 子区域，shader 顶点期映射）
func _make_weapon_mm(container: Node2D) -> MultiMesh:
	var mmi := MultiMeshInstance2D.new()
	mmi.name = "CrowdWeapons"
	mmi.texture = null  # 图集就绪后由 _rebuild_atlas 赋
	mmi.z_index = 18
	mmi.z_as_relative = false
	var mat := ShaderMaterial.new()
	mat.shader = load("res://modules/units/scripts/rig/crowd_weapon_atlas.gdshader")
	mmi.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = BatchRig._get_quad_mesh()
	mm.instance_count = 0
	mm.custom_aabb = AABB(Vector3(-4096.0, -4096.0, 0.0), Vector3(16384.0, 16384.0, 0.0))
	mmi.multimesh = mm
	container.add_child(mmi)
	_weapon_mmi = mmi
	return mm


## 图集构建（注册期收集，首 tick 前一次）：扫描线摆放，宽 256 高 1024
func _rebuild_atlas() -> void:
	if not _atlas_dirty:
		return
	_atlas_dirty = false
	const AW := 256
	const AH := 1024
	if _atlas_img == null:
		_atlas_img = Image.create(AW, AH, false, Image.FORMAT_RGBA8)
	var x := 0
	var y := 0
	var row_h := 0
	for path in _atlas_pending.keys():
		var tex: Texture2D = load(path)
		if tex == null:
			continue
		var img: Image = tex.get_image()
		img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		var sz := img.get_size()
		if x + sz.x > AW:
			x = 0
			y += row_h
			row_h = 0
		if y + sz.y > AH:
			push_error("[CrowdRenderer] 武器图集溢出，跳过 " + path)
			continue
		_atlas_img.blit_rect(img, Rect2i(Vector2i.ZERO, sz), Vector2i(x, y))
		_atlas_entries[path] = Rect2i(x, y, sz.x, sz.y)
		x += sz.x
		row_h = maxi(row_h, sz.y)
	_atlas_pending.clear()
	_atlas_tex = ImageTexture.create_from_image(_atlas_img)
	_weapon_mmi.texture = _atlas_tex


## 武器桶容量按需翻倍扩（stride 16：变换 8 + 色 4 + custom 4）
func _ensure_weapon_cap(n: int) -> void:
	if n <= _weapon_cap:
		return
	while _weapon_cap < n:
		_weapon_cap = maxi(_weapon_cap * 2, 16)
	_weapon_mm.instance_count = _weapon_cap
	_weapon_buf.resize(_weapon_cap * 16)
	_weapon_mm.buffer = _weapon_buf


## 阴影桶容量按需翻倍扩（零变换行=隐形，instance_count 恒为容量）
func _ensure_shadow_cap(n: int) -> void:
	if n <= _shadow_cap:
		return
	while _shadow_cap < n:
		_shadow_cap = maxi(_shadow_cap * 2, 16)
	_shadow_mm.instance_count = _shadow_cap
	_shadow_buf.resize(_shadow_cap * 12)
	_shadow_mm.buffer = _shadow_buf


## y → 带号（clamp 到尾带兜底）
func _band_of(y: float) -> int:
	return clampi(int((y - _y_top) / _band_h), 0, BAND_COUNT - 1)


## 注册小兵：按 y 分带、带内池分配槽位、初始化动画状态、挂 rig 播报 hook。
## 返回槽位句柄（Dictionary；unregister 时交回）。附身单位不应注册。
func register_unit(entity: Node) -> Dictionary:
	var rig: Node = null
	if entity.has_method("get_node_or_null"):
		for p in ["OutlineGroup/StickmanRig", "RigHost/OutlineGroup/StickmanRig"]:
			rig = entity.get_node_or_null(p)
			if rig != null:
				break
	if rig == null:
		return {}
	var band: int = _band_of(entity.global_position.y)
	var band_idx: int = _alloc_band_idx(band)
	# 全局槽位：独立自增池（与带无关）——此前 slot_idx=band*CAP+band_idx，
	# 带内超员复用尾位时两单位撞出同一下标，后者覆盖前者致身体永久消失
	# （武器/血条/阴影挂 entity 侧照常渲染 = "浮空武器血条"观感）
	var slot_idx: int
	if not _free_slots.is_empty():
		slot_idx = _free_slots.pop_back()
	else:
		slot_idx = _slots.size()
		_slots.append(null)
	var slot := {
		"entity": entity,
		"rig": rig,
		"anim": "idle",
		"t": 0.0,
		"finished": false,
		"hidden": false,
		"body_color": _read_color(rig, "body_color", Color.WHITE),
		"outline_color": _read_color(rig, "outline_color", Color.BLACK),
		"slot": slot_idx,  # 全局槽位表下标（与带无关，注册/注销互斥分配）
		"band": band,
		"band_idx": band_idx,
		"weapons": _adopt_weapons(entity, rig),
		"renderer": weakref(self),  # 实体 _exit_tree/_on_possession_changed 经此注销
	}
	_slots[slot["slot"]] = slot
	# 阴影进 crowd 桶：原 ContactShadow Sprite 停用（注销/回退时恢复）
	var shadow: Node = entity.get_node_or_null("ContactShadow")
	if shadow != null:
		shadow.visible = false
	# 血条进 crowd 桶：indicator 切数据模式（状态机照跑，绘制让位实例行）
	var bar: Node = entity.get_node_or_null("HealthBar")
	if bar != null and bar.has_method("set_crowd_data_mode"):
		bar.set_crowd_data_mode(true)
		slot["_bar"] = bar
	if rig.has_method("set_crowd_hook"):
		rig.set_crowd_hook(Callable(self, "_on_rig_play").bind(slot))
	return slot


## 带内槽位池分配（free 复用 O(1)；无上限——挤团一带超百单位也各占其段，
## buffer/instance_count 由 _grow_band 按需扩。此前 BAND_CAP=48 截断复用
## 尾位，48v48 挤团即触发同段覆盖丢身体）
func _alloc_band_idx(band: int) -> int:
	while band >= _free_band.size():
		_free_band.append([])
	var pool: Array = _free_band[band]
	if not pool.is_empty():
		return pool.pop_back()
	_used_count[band] = _used_count.get(band, 0) + 1
	var idx: int = _used_count[band] - 1
	_grow_band(band, idx + 1)
	return idx


## 武器接管：武器/盾挂 rig 手骨下，rig 隐藏会连带隐藏——reparent 到实体
## 直挂（保全局变换），记录「相对手骨局部变换 + 手骨先序下标」。代理模式
## 下节点停用（visible=false），绘制走图集桶实例行；纹理与 Sprite 局部
## 变换在此记录（attach_local=场景根相对手骨，sprite_local=Sprite 相对根）
func _adopt_weapons(entity: Node, rig: Node2D) -> Array:
	var out: Array = []
	var wm: Node = entity.get_node_or_null("WeaponMount")
	if wm == null:
		return out
	for prop in ["_weapon", "_shield"]:
		var w: Node2D = wm.get(prop)
		if w == null or not is_instance_valid(w):
			continue
		var hand: Node2D = w.get_parent() as Node2D
		if hand == null or not (hand is Bone2D):
			continue
		var hand_id: int = Skel.BONE_NAME_TO_ID.get(hand.name, -1)
		var hand_idx: int = _bone_ids.find(hand_id)
		if hand_idx < 0:
			continue
		var sprite: Sprite2D = _find_sprite(w)
		if sprite == null or sprite.texture == null or sprite.texture.resource_path.is_empty():
			continue
		var attach_local: Transform2D = hand.global_transform.affine_inverse() * w.global_transform
		w.reparent(entity)
		# 代理模式武器进图集桶（全局单 MMI z=18 浮于身体之上，原绝对层语义）
		w.visible = false
		w.z_as_relative = false
		w.z_index = 18
		var tex: Texture2D = sprite.texture
		_atlas_pending[tex.resource_path] = true
		_atlas_dirty = true
		out.append({"node": w, "hand_idx": hand_idx, "attach_local": attach_local, "hand": hand,
				"sprite_local": sprite.transform, "tex_path": tex.resource_path,
				"tex_size": tex.get_size()})
	return out


## 深找第一个 Sprite2D（武器场景根下）
static func _find_sprite(root: Node) -> Sprite2D:
	if root is Sprite2D:
		return root
	for c in root.get_children():
		var s := _find_sprite(c)
		if s != null:
			return s
	return null


## 注销：解 rig hook（恢复富管线可见）、武器 reparent 回手骨（保全局变换）、
## 槽位置 free、实例色清零（alpha=0 一次写入即隐身）。
## 死亡释放路径（实体 queue_free）武器随实体走，还骨是幂等安全操作。
func unregister_unit(slot: Dictionary) -> void:
	if slot.is_empty() or _host == null:
		return
	var idx: int = slot.get("slot", -1)
	if idx < 0 or idx >= _slots.size() or _slots[idx] != slot:
		return
	var rig: Node = slot.get("rig")
	if rig != null and is_instance_valid(rig) and rig.has_method("set_crowd_hook"):
		rig.set_crowd_hook(Callable())  # 解除代理：rig 恢复可见，动画交还 LOD/富管线
	var ent = slot.get("entity")
	if ent != null and is_instance_valid(ent):
		var shadow: Node = ent.get_node_or_null("ContactShadow")
		if shadow != null:
			shadow.visible = true  # 阴影交还原 Sprite
		var bar: Node = ent.get_node_or_null("HealthBar")
		if bar != null and bar.has_method("set_crowd_data_mode"):
			bar.set_crowd_data_mode(false)  # 血条交还原 _draw
	for w in slot.get("weapons", []):
		var node: Node2D = w.get("node")
		var hand: Node2D = w.get("hand")
		if node != null and is_instance_valid(node) and hand != null and is_instance_valid(hand):
			node.visible = true  # 图集桶让位，恢复武器 Sprite 自绘
			node.z_as_relative = true
			node.z_index = 0
			node.reparent(hand)
	_clear_slot_instances(slot)
	var band: int = slot.get("band", 0)
	var band_idx: int = slot.get("band_idx", 0)
	while band >= _free_band.size():
		_free_band.append([])
	_free_band[band].append(band_idx)
	_slots[slot["slot"]] = null


## rig 动画播报（play/play_hit 的统一入口；变体名直接可索引预编译表）
func _on_rig_play(anim_name: String, slot: Dictionary) -> void:
	if slot.is_empty() or not _anim_tables.has(anim_name):
		anim_name = "idle"
	slot["anim"] = anim_name
	slot["t"] = 0.0
	slot["finished"] = false


## 隐藏/显示槽位（LOD FAR 档沿用：hidden 时写零 alpha 一次并跳过后续写入）
func set_slot_hidden(slot: Dictionary, hidden: bool) -> void:
	if slot.is_empty():
		return
	if bool(slot["hidden"]) == hidden:
		return
	slot["hidden"] = hidden
	if hidden:
		_clear_slot_instances(slot)
	# 取消隐藏：下一 tick 重写槽位即恢复


## 每物理刻推进（BattleInstance._physics_process 调用，在 sim.tick 之后——
## 读实体最新位置）。插值 → 累乘 → 写 4 桶 buffer → 上传。
func tick(delta: float) -> void:
	if _host == null or _slots.is_empty():
		return
	_rebuild_atlas()  # 注册期收集的武器纹理在此一次 blit+上传
	_weapon_count = 0
	for idx in _slots.size():
		var slot = _slots[idx]  # 空槽为 null（无类型赋值 + 判空）
		if slot == null or slot.is_empty() or bool(slot["hidden"]):
			continue
		var entity: Node = slot["entity"]
		var rig: Node = slot["rig"]
		if entity == null or not is_instance_valid(entity):
			continue
		# 跨带检测（单位移动到别的 y 带）：旧段清零、旧带内槽位还池、
		# 新带分配段（本刻 pose 直接写新带；搬运动画语义无感，平滑移动下
		# 频率很低）
		var new_band: int = _band_of(entity.global_position.y)
		if new_band != int(slot["band"]):
			_clear_slot_instances(slot)
			var old_band: int = slot.get("band", 0)
			while old_band >= _free_band.size():
				_free_band.append([])
			_free_band[old_band].append(slot.get("band_idx", 0))
			slot["band"] = new_band
			slot["band_idx"] = _alloc_band_idx(new_band)
		# 死者淡出后实体释放：槽位由 unregister 清理；死后保持尾帧姿态
		var info: Dictionary = _anim_tables.get(slot["anim"], _anim_tables.get("idle", {}))
		var length: float = info.get("length", 1.0)
		var loop: bool = info.get("loop", true)
		var t: float = slot["t"] + delta
		if loop:
			t = fmod(t, length) if length > 0.0 else 0.0
		elif t >= length:
			t = length
			if not bool(slot["finished"]):
				slot["finished"] = true
				# LOOP NONE 完成信号经 rig 补发（攻击播完回切/移动锁消费方无感知）
				if rig != null and is_instance_valid(rig):
					rig.emit_signal("animation_finished", slot["anim"])
		slot["t"] = t
		_pose_slot(slot, info, t)
	# 上传全部带桶（整缓冲；仅 instance_count>0 的桶）
	for idx in _mm.size():
		var mm: MultiMesh = (_mm[idx].multimesh if _mm[idx] is MultiMeshInstance2D else null)
		if mm != null and mm.instance_count > 0:
			mm.buffer = _buf[idx]
	# 阴影桶：全部活单位写入（变换布局与身体桶一致：[xx,yx,0,ox, xy,yy,0,oy, rgba]）。
	# quad 基准 1×1、白纹理 4px——软边观感用 3 层同心椭圆阶梯叠加（alpha 合成
	# 中心 ≈0.34 边缘 0.08，逼近原渐变 Sprite）；带 alpha 的自绘纹理在 MMI
	# 管线实测不渲染（白纹对照实验定位），故纹理只用纯白、明暗全走实例色
	if _shadow_mm != null:
		var ts: float = 64.0
		var n: int = 0
		for idx in _slots.size():
			var slot = _slots[idx]
			if slot == null or slot.is_empty() or bool(slot["hidden"]):
				continue
			var entity: Node = slot["entity"]
			if entity == null or not is_instance_valid(entity):
				continue
			_ensure_shadow_cap(n + 3)
			var fo = entity.get("foot_offset")
			var oy: float = (float(fo) if fo != null else 45.0) + 2.0
			var px: float = entity.global_position.x
			var py: float = entity.global_position.y + oy
			for layer in 3:
				var r: float = [1.0, 0.72, 0.46][layer]
				var a: float = [0.08, 0.13, 0.16][layer]
				var o := (n + layer) * 12
				_shadow_buf[o] = 0.9 * ts * r
				_shadow_buf[o + 1] = 0.0
				_shadow_buf[o + 2] = 0.0
				_shadow_buf[o + 3] = px
				_shadow_buf[o + 4] = 0.0
				_shadow_buf[o + 5] = 0.26 * ts * r
				_shadow_buf[o + 6] = 0.0
				_shadow_buf[o + 7] = py
				_shadow_buf[o + 8] = 0.0
				_shadow_buf[o + 9] = 0.0
				_shadow_buf[o + 10] = 0.0
				_shadow_buf[o + 11] = a
			n += 3
		_shadow_mm.buffer = _shadow_buf
	# 血条桶：6 组 × N 相位（见成员区注释）。行几何/绘制门与原版 _draw_bar/
	# _draw_dot 逐层同构；相位组 = wobble seed % N（原版 0.12s 重掷 → 换组跳相）
	_bar_bg.begin_tick()
	_bar_ring1.begin_tick()
	_bar_trail_fill.begin_tick()
	_bar_ring2.begin_tick()
	_dot_fill.begin_tick()
	_dot_ring.begin_tick()
	for idx in _slots.size():
		var slot2 = _slots[idx]
		if slot2 == null or slot2.is_empty() or bool(slot2["hidden"]):
			continue
		var ind = slot2.get("_bar")
		if ind == null or not is_instance_valid(ind) or not ind._data_mode:
			continue
		var st: Dictionary = ind.get_bar_state()
		if not bool(st["active"]):
			continue
		var bs: float = float(st["scale"])
		var cx: float = ind.global_position.x
		var cy: float = ind.global_position.y
		var shown: float = float(st["shown"])
		var seed_k: int = int(st["wobble"]) % BatchRig.WOBBLE_VARIANTS
		# 圆点（原版 _draw_dot：expand<0.999 才画，本体/描边 alpha 同乘 1-expand；
		# 几何全烘焙，CUSTOM 无用）
		if float(st["expand"]) < 0.999:
			var dot_a: float = shown * (1.0 - float(st["expand"]))
			var rr: float = HealthBarIndicator.DOT_RADIUS * bs
			var dc: Color = st["color"]
			_dot_fill.row(seed_k, cx, cy, rr, rr, Color(dc.r, dc.g, dc.b, dc.a * dot_a), 0.0, 0.0, 0.0)
			var olc: Color = HealthBarIndicator.COLOR_OUTLINE
			_dot_ring.row(seed_k, cx, cy, rr, rr, Color(olc.r, olc.g, olc.b, olc.a * dot_a), 0.0, 0.0, 0.0)
		# 横条（原版 _draw_bar 层序：底→描边①→残影→填充→描边②；受击抖动同式）
		var half: float = float(st["width"]) * 0.5 * float(st["expand"]) * bs
		if half >= bs:  # 原版局部 half<1.0 早退（世界 px = 局部×bs）
			var t: float = float(st["anim_time"])
			var se: float = float(st["shake"])
			var shk: float = sin(t * HealthBarIndicator.SHAKE_FREQ) * se * HealthBarIndicator.SHAKE_MAX_OFFSET \
					+ sin(t * HealthBarIndicator.SHAKE_FREQ * 2.3) * se * HealthBarIndicator.SHAKE_MAX_OFFSET * 0.3
			var cx2: float = cx + shk
			var bw: float = half * 2.0
			var hh: float = HealthBarIndicator.BAR_HEIGHT * bs
			var left: float = cx2 - half
			var plain: bool = bw / bs < 6.0  # 原版 _draw_wobbly_rect 窄矩形回退门
			# plain 路由到直角退化网格槽（桶尾槽 = BatchRig.WOBBLE_VARIANTS）
			var kbg: int = BatchRig.WOBBLE_VARIANTS if plain else seed_k
			var bgc: Color = HealthBarIndicator.COLOR_BG
			_bar_bg.row(kbg, cx2, cy, bw, hh, _colc(HealthBarIndicator.COLOR_BG, shown), bw, plain, hh)
			_bar_ring1.row(kbg, cx2, cy, bw, hh, _colc(HealthBarIndicator.COLOR_OUTLINE, shown), bw, plain, hh)
			var trail: float = float(st["trail"])
			if trail > float(st["ratio"]) + 0.005:  # 原版残影绘制门
				var tw := bw * trail
				var kt: int = BatchRig.WOBBLE_VARIANTS if tw / bs < 6.0 else seed_k
				_bar_trail_fill.row(kt, left + tw * 0.5, cy, tw, hh,
						_colc(HealthBarIndicator.COLOR_TRAIL, shown), tw, tw / bs < 6.0, hh)
			var fw := bw * float(st["ratio"])
			if fw > 0.5 * bs:  # 原版填充绘制门（局部 0.5px）
				var kf: int = BatchRig.WOBBLE_VARIANTS if fw / bs < 6.0 else seed_k
				_bar_trail_fill.row(kf, left + fw * 0.5, cy, fw, hh,
						_colc(st["color"], shown), fw, fw / bs < 6.0, hh)
			_bar_ring2.row(kbg, cx2, cy, bw, hh, _colc(HealthBarIndicator.COLOR_OUTLINE, shown), bw, plain, hh)
	_bar_bg.end_tick()
	_bar_ring1.end_tick()
	_bar_trail_fill.end_tick()
	_bar_ring2.end_tick()
	_dot_fill.end_tick()
	_dot_ring.end_tick()
	# 武器图集桶上传（_wcount 压实行数；未用行=零变换隐形）
	if _weapon_mm != null and _weapon_cap > 0 and _atlas_tex != null:
		_weapon_mm.buffer = _weapon_buf


## 战斗结束/销毁：释放容器（含全部带桶 MMI；实体侧 meta 由调用方清）
func teardown() -> void:
	if _host != null and is_instance_valid(_host):
		var container: Node = _host.get_node_or_null("CrowdLayer")
		if container != null:
			container.queue_free()
	_mm.clear()
	_buf.clear()
	_slots.clear()
	_free_slots.clear()
	_free_band.clear()
	_used_count.clear()
	_shadow_mmi = null
	_shadow_mm = null
	_shadow_buf = PackedFloat32Array()
	_shadow_cap = 0
	_bar_bg.clear()
	_bar_ring1.clear()
	_bar_trail_fill.clear()
	_bar_ring2.clear()
	_dot_fill.clear()
	_dot_ring.clear()
	_weapon_mmi = null
	_weapon_mm = null
	_weapon_buf = PackedFloat32Array()
	_weapon_cap = 0
	_weapon_count = 0
	_atlas_tex = null
	_atlas_img = null
	_atlas_entries = {}
	_atlas_pending = {}
	_atlas_dirty = false
	_host = null


## 单槽位姿态合成与写入：插值骨骼角 → rest 合成局部变换 → 先序累乘 →
## 单位全局变换（位置 + rig 缩放/朝向）→ ×预烘部件局部 → 12 floats/实例。
func _pose_slot(slot: Dictionary, info: Dictionary, t: float) -> void:
	var entity: Node = slot["entity"]
	var rig: Node2D = slot["rig"]
	var tracks: Dictionary = info.get("tracks", {})
	# 骨骼角插值 + 局部变换合成
	for i in _bone_ids.size():
		var keys: PackedFloat32Array = tracks.get(_bone_ids[i], PackedFloat32Array())
		var ang := 0.0
		if keys.size() >= 4:
			ang = _sample_keys(keys, t)
		_local[i] = Transform2D(ang, _rest_pos[i])
		var pi := _bone_pidx[i]
		_acc[i] = _local[i] if pi < 0 else _acc[pi] * _local[i]
	# 单位全局变换：位置 + 朝向/体型（读 rig.scale——含 facing 翻转与体型）
	var unit_xf := Transform2D(0.0, entity.global_position)
	var rs: Vector2 = rig.scale if rig != null else Vector2.ONE
	unit_xf = unit_xf.scaled_local(rs)
	var body: Color = slot.get("body_color", Color.WHITE)
	var outline: Color = slot.get("outline_color", Color.BLACK)
	var band: int = slot.get("band", 0)
	var band_idx: int = slot.get("band_idx", 0)
	# 武器/盾：手骨姿态 × attach × Sprite 局部 → 图集桶实例行（节点已停用，
	# 绘制终点在 CrowdWeapons MMI；行 stride 16 = 变换 8 + 色 4 + custom UV 4）
	var weapons: Array = slot.get("weapons", [])
	for w in weapons:
		var path: String = w.get("tex_path", "")
		if path.is_empty() or not _atlas_entries.has(path):
			continue
		var rect: Rect2i = _atlas_entries[path]
		_ensure_weapon_cap(_weapon_count + 1)
		var xf: Transform2D = unit_xf * _acc[w["hand_idx"]] * w["attach_local"] * w["sprite_local"]
		var tsz: Vector2 = w["tex_size"]
		var aw: float = float(_atlas_img.get_width())
		var ah: float = float(_atlas_img.get_height())
		var wo := _weapon_count * 16
		_weapon_buf[wo] = xf.x.x * tsz.x
		_weapon_buf[wo + 1] = xf.y.x * tsz.y
		_weapon_buf[wo + 2] = 0.0
		_weapon_buf[wo + 3] = xf.origin.x
		_weapon_buf[wo + 4] = xf.x.y * tsz.x
		_weapon_buf[wo + 5] = xf.y.y * tsz.y
		_weapon_buf[wo + 6] = 0.0
		_weapon_buf[wo + 7] = xf.origin.y
		_weapon_buf[wo + 8] = 1.0
		_weapon_buf[wo + 9] = 1.0
		_weapon_buf[wo + 10] = 1.0
		_weapon_buf[wo + 11] = 1.0
		_weapon_buf[wo + 12] = float(rect.position.x) / aw
		_weapon_buf[wo + 13] = float(rect.position.y) / ah
		_weapon_buf[wo + 14] = float(rect.size.x) / aw
		_weapon_buf[wo + 15] = float(rect.size.y) / ah
		_weapon_count += 1
	for j in 4:
		var bidx: PackedInt32Array = _bucket_bidx[j]
		var xforms: Array = _bucket_xform[j]
		var colors: PackedColorArray = _bucket_color[j]
		var buf: PackedFloat32Array = _buf[band * 4 + j]
		var per_unit: int = bidx.size()
		var base_i: int = band_idx * per_unit * 12  # 带桶内段基址（buffer 按带独立）
		for i in per_unit:
			var xf: Transform2D = unit_xf * _acc[bidx[i]] * xforms[i]
			var col: Color = colors[i]
			if col == Color.WHITE:
				col = body
			elif col == Color.BLACK:
				col = outline
			var o := base_i + i * 12
			buf[o] = xf.x.x
			buf[o + 1] = xf.y.x
			buf[o + 2] = 0.0
			buf[o + 3] = xf.origin.x
			buf[o + 4] = xf.x.y
			buf[o + 5] = xf.y.y
			buf[o + 6] = 0.0
			buf[o + 7] = xf.origin.y
			buf[o + 8] = col.r
			buf[o + 9] = col.g
			buf[o + 10] = col.b
			buf[o + 11] = col.a


## 关键帧线性插值（keys = [t0,a0,t1,a1...]；角度弧度，与 bake 同单位）
static func _sample_keys(keys: PackedFloat32Array, t: float) -> float:
	var n := keys.size() / 2
	if n <= 0:
		return 0.0
	if t <= keys[0]:
		return keys[1]
	var last := (n - 1) * 2
	if t >= keys[last]:
		return keys[last + 1]
	for i in range(n - 1):
		var t0 := keys[i * 2]
		var t1 := keys[(i + 1) * 2]
		if t >= t0 and t <= t1:
			var a0 := keys[i * 2 + 1]
			var a1 := keys[(i + 1) * 2 + 1]
			var span := t1 - t0
			if span <= 0.0:
				return a1
			return lerpf(a0, a1, (t - t0) / span)
	return keys[last + 1]


# ─────────────────────────── 内部工具 ───────────────────────────

## 读单位渲染色（rig 的 Inspector 色；阵营色在实体侧已写入）
func _read_color(rig: Node, prop: String, fallback: Color) -> Color:
	var c = rig.get(prop)
	return c if c is Color else fallback


## 带容量按需扩容（带内已分配段数 count 只增不减；buffer 一次扩到位、
## 新位默认 0 = 零缩放阵，防 identity 簇拥原点）
func _grow_band(band: int, count: int) -> void:
	for j in 4:
		var holder = _mm[band * 4 + j]
		var mm: MultiMesh = (holder.multimesh if holder is MultiMeshInstance2D else null)
		if mm == null:
			continue
		var per_unit: int = _bucket_bidx[j].size()
		if per_unit <= 0:
			continue
		var need: int = maxi(mm.instance_count / per_unit, count) * per_unit
		if mm.instance_count >= need:
			continue
		mm.instance_count = need
		_buf[band * 4 + j].resize(need * 12)
		mm.buffer = _buf[band * 4 + j]


## 清槽位实例（该槽位段零缩放 + 全透明，一次写入）
func _clear_slot_instances(slot: Dictionary) -> void:
	var band: int = slot.get("band", 0)
	var band_idx: int = slot.get("band_idx", 0)
	for j in 4:
		var holder = _mm[band * 4 + j]
		var mm: MultiMesh = (holder.multimesh if holder is MultiMeshInstance2D else null)
		if mm == null:
			continue
		var per_unit: int = _bucket_bidx[j].size()
		if per_unit <= 0 or band_idx * per_unit >= mm.instance_count:
			continue
		var buf: PackedFloat32Array = _buf[band * 4 + j]
		var base_i: int = band_idx * per_unit * 12
		for o in range(base_i, base_i + per_unit * 12):
			buf[o] = 0.0
		mm.buffer = buf


## 血条覆盖层桶：一组 N 相位 MMI + 逐相位缓冲。行 stride 16 =
## 变换 8（w,0,0,cx / 0,h,0,cy）+ 实例色 4 + CUSTOM 4（c0,c1,c2,0）。
## 每刻 begin→逐单位 row→end：end 时清尾段（死亡/换相位组后旧行残留会渲染
## 成幽灵血条——instance_count 恒为容量，压实行数之后必须归零）并整缓冲上传。
class OverlayBucket:
	extends RefCounted

	var mmis: Array = []           # MultiMeshInstance2D ×N（相位组）
	var bufs: Array = []           # PackedFloat32Array ×N
	var caps := PackedInt32Array() # 容量 ×N
	var cnt := PackedInt32Array()  # 本刻压实行数 ×N
	var prev := PackedInt32Array() # 上刻高水位 ×N

	func begin_tick() -> void:
		for k in cnt.size():
			cnt[k] = 0

	## 写一行实例。cx/cy=中心，w/h=行宽高（世界 px），col=实例色，
	## CUSTOM = (c0, c1, c2, 0)：条填充/环带 = (行宽, plain, 行高, 0)
	func row(k: int, cx: float, cy: float, w: float, h: float, col: Color, c0: float, c1: float, c2: float) -> void:
		var i := cnt[k]
		_ensure_cap(k, i + 1)
		var buf: PackedFloat32Array = bufs[k]
		var o := i * 16
		buf[o] = w
		buf[o + 1] = 0.0
		buf[o + 2] = 0.0
		buf[o + 3] = cx
		buf[o + 4] = 0.0
		buf[o + 5] = h
		buf[o + 6] = 0.0
		buf[o + 7] = cy
		buf[o + 8] = col.r
		buf[o + 9] = col.g
		buf[o + 10] = col.b
		buf[o + 11] = col.a
		buf[o + 12] = c0
		buf[o + 13] = c1
		buf[o + 14] = c2
		buf[o + 15] = 0.0
		bufs[k] = buf
		cnt[k] = i + 1

	func end_tick() -> void:
		for k in cnt.size():
			var c := cnt[k]
			if prev[k] > c:
				var buf: PackedFloat32Array = bufs[k]
				for i in range(c * 16, prev[k] * 16):
					buf[i] = 0.0
				bufs[k] = buf
			prev[k] = c
			if caps[k] > 0:
				mmis[k].multimesh.buffer = bufs[k]

	## 容量翻倍扩（stride 16）
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
		buf.resize(cap * 16)
		bufs[k] = buf
		mm.buffer = buf

	func clear() -> void:
		mmis.clear()
		bufs.clear()
		caps = PackedInt32Array()
		cnt = PackedInt32Array()
		prev = PackedInt32Array()


## 颜色 × 显示系数（渐隐 shown；rgb 不动，仅乘 alpha）
static func _colc(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * a)
