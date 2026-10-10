extends Node3D
## char_rig_3d.gd —— S2 直渲路线的角色宿主（char_sprite_3d 的 duck 兼容替身）。
##
## 是什么：每实体一个本实例。与烘焙路线同构地持有一份真 StickmanRig
##（Skeleton2D + AnimationTree + 程序化叠加全照旧，藏在隐藏 CanvasLayer 里只
## 解算不绘制——CanvasItem 隐藏只停绘制，_process/动画推进不受影响），但
## **不再装配 SubViewport/回读烘焙**：晚优先级 _process（1100 = rig 推进(0)
## 与俯仰叠加(1000) 之后，写序铁律）读骨骼链，把每部件的 2D 变换折进 26°
## 取景平面，整段写入 char_direct_buckets 的全局 3D MultiMesh 桶。
## 零视口、零回读、零纹理上传；渲染侧成本 = 部件变换数学 + 桶缓冲段写入
##（crowd_renderer 同量级，已验证可承 96 单位）。
##
## 尺寸契约（与烘焙路线逐位同源，见 char_sprite_3d 尺寸契约段）：
##   rig px → 世界单位 S = RIG_SCALE(0.35625) × PX(1/24) = 0.01484375；
##   FOOT_ANCHOR(3,141) 钉在角色世界脚点；depth 纵深缩放乘进 S。
## tilt 基（与 char_sprite_3d._cam_basis 同式）：X=(1,0,0) 右，Y=(0,cos t,−sin t)
## 上仰，Z=(0,sin t,cos t) 朝相机。rig 空间 y-down，折 3D 时 y 取负。
## feed API（set_world_pos/set_anim/set_weapon_type/…）与 char_sprite_3d 同名
## 同义——hd2d_map_base._sync_character_render 零改动切换路线。
##
## 尸体（S2）：死亡动画由 rig 播完停尾帧（状态机 dead 态），实体淡出期
## set_master_alpha<1 把部件段迁入渐隐桶逐帧压 alpha——rig 姿态 + 插箭，
## 图片卡渐隐不再存在。

const StickRigAPI := preload("res://modules/stick_rig/api.gd")
const ANIMS := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT
const Skel := preload("res://modules/stick_rig/api.gd").SKELETON_SCRIPT
const HealthBarIndicator := preload("res://modules/stick_rig/api.gd").HEALTH_BAR_SCRIPT
const SHADOW_SHADER := preload("res://modules/hd2d/shaders/char_shadow.gdshader")
const RIG_SCENE_PATH: String = StickRigAPI.RIG_SCENE_PATH

## 路线开关：默认 bake（直渲观感已否决——见交接档裁决#10/#13）；
## STICK_CHAR_RENDER=direct 显式开直渲实验路线（新渲染路线未裁决前不动默认）。
static func route_enabled() -> bool:
	return OS.get_environment("STICK_CHAR_RENDER") == "direct"

const RIG_SCALE := 0.35625   # 与烘焙路线同值（rig px → SV px；SV px → 世界 = PX）
const PX := 1.0 / 24.0
const S := RIG_SCALE * PX    # rig px → 世界单位
const FOOT_ANCHOR := Vector2(3.0, 141.0)
const SIZE_K := 1.0
## 血条世界比例：烘焙路线镜像条在视口内 scale=px_scale/1.2=1.6667（SV px/原生 px），
## 折世界 = ×PX → 0.069444 世界单位/条原生 px
const BAR_UNIT := (2.0 / 1.2) * PX
## 血条中心高度（世界单位，随 depth 缩放）：卡顶(6.0) − 视口顶留白(8SV px=1/3)
const BAR_H := 6.0 - 8.0 / 24.0
## 武器/盾的深度微移：恒在全部身体部件（描边 −0.004…填充 0…+0.0007）之上
const ZB_WEAPON := 0.008

# ─────────────────────────── 装配 ───────────────────────────

var _buckets: Node = null          # char_direct_buckets
var _rig_parent: Node2D = null     # 隐藏画布里的 rig 挂点
var _rig: Node2D = null            # StickmanRig（骨架解算真源）
var _pure_sim := false
var _tilt_deg := 26.0

## 骨骼先序（Bone2D 树走查）+ 父下标 + 部件写表（拓扑下标 → 本树走查下标）
var _bones: Array = []             # Bone2D 先序
var _pidx: PackedInt32Array = PackedInt32Array()
var _acc: Array[Transform2D] = []
var _pt_walk: Array = []           # PackedInt32Array ×4（桶→本树骨骼下标）
var _bases: Dictionary = {}        # 不透明段基址（桶→实例基）
var _bases_fade: Dictionary = {}   # 渐隐段基址
var _using_fade := false

## 武器/盾挂载记录（无节点实例：贴图 + 手骨 + 挂点补偿，逐帧算 2D 变换）
var _weapon: Dictionary = {}
var _shield: Dictionary = {}
var _weapon_type_cached: int = -1

## feed 状态
var _anim := "idle"
var last_fed_xz := Vector2.ZERO
var _flip := false
var _depth := 1.0
var _pos := Vector3.ZERO
var _master_alpha := 1.0
var _tint := Color(1, 1, 1)
var _hidden := false
var _bar_state: Dictionary = {}
var _shadow: MeshInstance3D = null
var _shadow_mat: ShaderMaterial = null

# 镜像通道缓存（与 char_sprite_3d 同义）
var _anim_seq: int = -2
var _swap_state := ""
var _swap_anim := ""
var _anim_speed_sent: float = -1.0
var _aim_pitch_sent: float = NAN
var _stance_walk := ""
var _stance_idle := ""
var _stable_idle_variant := ""
var _shield_on := false

# 渲染帧插值（#9，与烘焙路线同机制）
var _pos_prev := Vector3.ZERO
var _pos_cur := Vector3.ZERO
var _pos_pf := -1
var _pos_valid := false
var _moved_this_tick := false


func build(world: Node, buckets: Node, rig_parent: Node2D, anim: String, tilt_deg: float) -> void:
	_buckets = buckets
	_rig_parent = rig_parent
	_tilt_deg = tilt_deg
	_pure_sim = DisplayServer.get_name() == "headless"
	OS.set_environment("STICK_BATCH_RIG", "0")  # 2D 批渲染件不参与（不绘制，免装配）
	var inst: Node2D = load(RIG_SCENE_PATH).instantiate()
	inst.set_script(null)  # 摘掉演示控制器（同烘焙路线）
	_rig_parent.add_child(inst)
	_rig = inst.get_node("OutlineGroup/StickmanRig") as Node2D
	_rig.play(anim)
	_walk_bones()
	_map_part_tables()
	if _pure_sim:
		return
	_bases = buckets.register_body()
	_bases_fade = buckets.register_body()
	_build_shadow()


## 骨骼树先序走查（父必先于子）——batch_rig._rebuild_instance_data 同式
func _walk_bones() -> void:
	_bones.clear()
	_pidx = PackedInt32Array()
	_walk_bones_rec(_rig, -1)
	_acc.resize(_bones.size())


func _walk_bones_rec(node: Node, parent_idx: int) -> void:
	for child in node.get_children():
		if child is Bone2D:
			var idx := _bones.size()
			_bones.append(child)
			_pidx.append(parent_idx)
			_walk_bones_rec(child, idx)


## 桶部件表（crowd 拓扑下标）→ 本树走查下标映射（骨名→id→拓扑→walk）
func _map_part_tables() -> void:
	var topo_to_walk := {}
	for i in _bones.size():
		var id: int = Skel.BONE_NAME_TO_ID.get(_bones[i].name, -1)
		var topo: int = _buckets._id_to_topo.get(id, -1)
		if topo >= 0:
			topo_to_walk[topo] = i
	_pt_walk = []
	for j in 4:
		var src: PackedInt32Array = _buckets._part_bidx[j]
		var out := PackedInt32Array()
		out.resize(src.size())
		for i in src.size():
			out[i] = topo_to_walk.get(src[i], 0)
		_pt_walk.append(out)


func _build_shadow() -> void:
	var sq := QuadMesh.new()
	sq.size = Vector2(4.2, 2.6) * SIZE_K
	var sh := MeshInstance3D.new()
	sh.mesh = sq
	_shadow_mat = ShaderMaterial.new()
	_shadow_mat.shader = SHADOW_SHADER
	sh.material_override = _shadow_mat
	sh.rotation = Vector3(deg_to_rad(-90), 0, 0)
	sh.name = "Shadow"
	sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sh)
	_shadow = sh


func _exit_tree() -> void:
	if _buckets != null and is_instance_valid(_buckets) and not _pure_sim:
		if not _bases.is_empty():
			_buckets.unregister_body(_bases)
		if not _bases_fade.is_empty():
			_buckets.unregister_body(_bases_fade)


# ─────────────────────────── feed API（duck 兼容 char_sprite_3d） ───────────────────────────

## 逐帧世界摆位（烘焙路线同参：x/z 格坐标、朝向、纵深缩放、地面抬升）
func set_world_pos(x: float, z: float, flip: bool, depth: float = 1.0,
		ground_lift: float = 0.0) -> void:
	_flip = flip
	_depth = depth
	last_fed_xz = Vector2(x, z)
	var target := Vector3(x, ground_lift, z)
	_pos = _interp_render_pos(target)
	if _shadow != null:
		_shadow.position = Vector3(_pos.x, ground_lift + 0.09, _pos.z)
		_shadow.scale = Vector3(depth * SIZE_K, depth * SIZE_K, 1.0)
	_layout_work_bar()


func set_anim(anim: String, seq: int = -1, swap: String = "") -> void:
	if _rig == null:
		return
	if not swap.is_empty():
		if _swap_state != anim or _swap_anim != swap:
			if _rig.has_method("set_state_anim"):
				_rig.set_state_anim(anim, swap)
			_swap_state = anim
			_swap_anim = swap
	elif _swap_state == anim:
		if _rig.has_method("set_state_anim"):
			_rig.set_state_anim(anim, anim)
		_swap_state = ""
		_swap_anim = ""
	# seq 变更检测走 rig.play（同名重播恢复；无烘焙节拍差异）
	if anim == _anim and seq == _anim_seq:
		return
	_anim = anim
	_anim_seq = seq
	_rig.play(anim)


func set_anim_speed(scale: float) -> void:
	if _rig == null or is_equal_approx(scale, _anim_speed_sent):
		return
	_anim_speed_sent = scale
	_rig.set_anim_speed(scale)


func set_aim_pitch(rad: float) -> void:
	if _rig == null or is_equal_approx(rad, _aim_pitch_sent):
		return
	_aim_pitch_sent = rad
	_rig.set_aim_pitch(rad)


## 整卡透明度（尸体渐隐）：<1 时部件段迁入渐隐桶（透明混合材质）
func set_master_alpha(a: float) -> void:
	if is_equal_approx(a, _master_alpha):
		return
	_master_alpha = a


## 武器镜像（挂点补偿口径与 char_sprite_3d.set_weapon_type 同式）：读武器场景
## Sprite 贴图 + GripPoint 补偿 + 手骨下标，不建可见节点（贴图分桶直渲）。
func set_weapon_type(wt: int) -> void:
	if _pure_sim or _weapon_type_cached == wt:
		return
	_weapon_type_cached = wt
	if _rig != null and _rig.has_method("set_state_anim"):
		_rig.set_state_anim("walk", ANIMS.walk_for_weapon(wt))
		_rig.set_state_anim("run", ANIMS.run_for_weapon(wt))
		_stance_walk = ""
		_stable_idle_variant = ""
	_weapon = _mount_weapon_scene(str(StickRigAPI.WEAPON_SCENE_PATHS.get(wt, "")),
			"hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_inner/forearm_inner/hand_inner/weapon_hand")


func set_shield_visible(on: bool) -> void:
	if _pure_sim or on == _shield_on:
		return
	_shield_on = on
	_shield = {} if not on else _mount_weapon_scene(StickRigAPI.WEAPON_SHIELD_PATH,
			"hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_outer/forearm_outer/hand_outer/shield_hand")


## 装载武器场景数据（贴图/尺寸/挂点补偿/手骨走查下标）；空路径返回空字典
func _mount_weapon_scene(scene_path: String, bone_path: String) -> Dictionary:
	if scene_path.is_empty():
		return {}
	var bone: Node2D = _rig.get_node_or_null(bone_path) as Node2D
	if bone == null:
		return {}
	var hand_idx := _bones.find(bone)
	if hand_idx < 0:
		return {}
	var scene: PackedScene = load(scene_path)
	if scene == null:
		return {}
	var inst: Node2D = scene.instantiate()
	var grip := inst.get_node_or_null("GripPoint") as Marker2D
	var spr := inst.get_node_or_null("Sprite") as Sprite2D
	if grip == null or spr == null or spr.texture == null:
		inst.free()
		return {}
	var tex: Texture2D = spr.texture
	var tsz: Vector2 = tex.get_size()
	var offset := -(grip.position * spr.scale).rotated(spr.rotation)
	var spr_xf: Transform2D = spr.transform
	inst.free()   # 读全再释放——free 连子节点一并销毁，之后 spr 引用即悬空
	return {
		"tex": tex,
		"tex_path": tex.resource_path,
		"tex_size": tsz,
		"hand": hand_idx,
		"attach": Transform2D(0.0, offset),
		"sprite_xf": spr_xf,
	}


func set_stance_anims(walk_anim: String, idle_anim: String) -> void:
	if walk_anim == _stance_walk and idle_anim == _stance_idle:
		return
	_stance_walk = walk_anim
	_stance_idle = idle_anim
	if _rig == null or not _rig.has_method("set_state_anim"):
		return
	if walk_anim.is_empty():
		_rig.set_state_anim("walk", ANIMS.walk_for_weapon(_weapon_type_cached))
	else:
		_rig.set_state_anim("walk", walk_anim)
	if idle_anim.is_empty():
		if _stable_idle_variant.is_empty():
			_stable_idle_variant = ANIMS.pick_stand_variant_for(_weapon_type_cached)
		_rig.set_state_anim("idle", _stable_idle_variant)
	else:
		_rig.set_state_anim("idle", idle_anim)
	# 换装不重播（churn 治理，同烘焙路线注释）


func apply_health_state(s: Dictionary) -> void:
	_bar_state = s


func set_light(tint: Color, _add: Color) -> void:
	_tint = tint
	if _shadow_mat != null:
		_shadow_mat.set_shader_parameter("blob_color",
				Color(0.06, 0.05, 0.05, 0.50 * clampf(tint.get_luminance() + 0.25, 0.0, 1.0)))


## 描边 zoom 补偿：暂不启用——烘焙路线实测在观战缩放(0.46)下描边为亚像素
## 级（每单位 ~2.6 白像素），直渲若按 OUTLINE_SCREEN_PX 恒定补偿会显著加粗
##（视觉验收实锤描边膨胀吞没身体）。A/B 按烘焙现状对齐（eff=OUTLINE_WIDTH
## 恒定），路线定夺后如需"屏幕像素恒定描边"再统一两路线口径。
func set_outline_zoom(_z: float) -> void:
	pass


## 显示/隐藏全部角色部件（A/B 对照出图用）：隐藏 = 清段停写
func set_chars_visible(v: bool) -> void:
	_hidden = not v


# ── 3D 头顶劳作进度条 + 附身四角框（char_sprite_3d 同款 quad 方案）──

const WP_SIZE := Vector2(1.3, 0.16)
const WP_LIFT := -0.15
var _wp_bg: MeshInstance3D = null
var _wp_fill: MeshInstance3D = null
var _wp_ratio: float = -1.0

func set_work_progress(ratio: float) -> void:
	if _pure_sim or is_equal_approx(_wp_ratio, ratio):
		return
	_wp_ratio = ratio
	if ratio >= 0.0:
		_ensure_work_bar()
	_layout_work_bar()


func _ensure_work_bar() -> void:
	if _wp_bg != null:
		return
	_wp_bg = _make_flat_quad(WP_SIZE, Color(0.08, 0.08, 0.10, 0.72), 6)
	_wp_fill = _make_flat_quad(WP_SIZE, Color(0.95, 0.72, 0.18, 0.95), 7)
	_wp_bg.visible = false
	_wp_fill.visible = false


func _make_flat_quad(size: Vector2, color: Color, priority: int) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = q
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.render_priority = priority
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _layout_work_bar() -> void:
	if _wp_bg == null:
		return
	var show: bool = _wp_ratio >= 0.0
	_wp_bg.visible = show
	_wp_fill.visible = show
	if not show:
		return
	var d := _depth
	var ct := cos(deg_to_rad(_tilt_deg))
	var stn := sin(deg_to_rad(_tilt_deg))
	var b := Basis(Vector3(1, 0, 0), Vector3(0, ct, -stn), Vector3(0, stn, ct)).scaled(
			Vector3(d, d, 1.0))
	var anchor := Vector3(_pos.x, _pos.y + (6.0 + WP_LIFT) * d, _pos.z)
	_wp_bg.basis = b
	_wp_bg.position = anchor
	var r := clampf(_wp_ratio, 0.0, 1.0)
	_wp_fill.basis = Basis(Vector3(1, 0, 0), Vector3(0, ct, -stn), Vector3(0, stn, ct)).scaled(
			Vector3(d * r, d, 1.0))
	_wp_fill.position = Vector3(anchor.x - WP_SIZE.x * 0.5 * (1.0 - r) * d, anchor.y, anchor.z + 0.02)


## 附身四角框（possessed 玩家专用，贴地 quad——char_sprite_3d 同款）
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
	if _pure_sim:
		return
	if v and _bracket_quad == null:
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
		add_child(mi)
		_bracket_quad = mi
	if _bracket_quad != null:
		_bracket_quad.position = Vector3(_pos.x, _pos.y + 0.10, _pos.z + 0.35)
		_bracket_quad.scale = Vector3(_depth, _depth, 1.0)
		_bracket_quad.visible = v


# ─────────────────────────── 渲染帧插值（#9，烘焙路线同机制） ───────────────────────────

func _interp_render_pos(target: Vector3) -> Vector3:
	if not _pos_valid:
		_pos_prev = target
		_pos_cur = target
		_pos_pf = Engine.get_physics_frames()
		_pos_valid = true
		_moved_this_tick = false
		return target
	var pf := Engine.get_physics_frames()
	if pf != _pos_pf:
		_pos_prev = _pos_cur
		_pos_pf = pf
		_moved_this_tick = false
	if target != _pos_cur:
		if _moved_this_tick:
			_pos_prev = target
			_moved_this_tick = false
		else:
			_moved_this_tick = true
		_pos_cur = target
	return _pos_prev.lerp(_pos_cur, Engine.get_physics_interpolation_fraction())


# ─────────────────────────── 晚帧写入（1100 = 动画推进/叠加之后） ───────────────────────────

func _ready() -> void:
	process_priority = 1100


func _process(_delta: float) -> void:
	if _pure_sim or _buckets == null or not is_instance_valid(_buckets) or _rig == null:
		return
	if _hidden:
		if not _bases.is_empty() or not _bases_fade.is_empty():
			_clear_segments()
		return
	# 渐隐段迁移（尸体）：alpha<1 走渐隐桶，回 1 走主桶
	var want_fade := _master_alpha < 0.999
	if want_fade != _using_fade:
		_clear_segments()
		_using_fade = want_fade
	# 先序累乘（batch_rig._write_transforms 同式：骨骼局部 → rig 局部）
	for i in _bones.size():
		var bone := _bones[i] as Bone2D
		if bone == null:
			continue
		var local := bone.transform
		var pi := _pidx[i]
		_acc[i] = local if pi < 0 else _acc[pi] * local
	_write_body()
	_write_weapons()
	_write_bar()


## 清空两套段（隐藏/迁移时一次写入零 + 重新登记）
func _clear_segments() -> void:
	_buckets.unregister_body(_bases)
	_buckets.unregister_body(_bases_fade)
	_bases = _buckets.register_body()
	_bases_fade = _buckets.register_body()


func _write_body() -> void:
	var buckets: Node = _buckets
	var t := deg_to_rad(_tilt_deg)
	var ct := cos(t)
	var stn := sin(t)
	var fx := -1.0 if _flip else 1.0
	var s := S * _depth
	var sfx := s * fx
	var alpha := _master_alpha
	var tr := _tint
	var p := _pos
	var j0 := 4 if _using_fade else 0
	for j in 4:
		var walk: PackedInt32Array = _pt_walk[j]
		if walk.is_empty():
			continue
		var xfs: Array = buckets._part_xform[j]
		var zbs: PackedFloat32Array = buckets._part_zbias[j]
		var cols: PackedColorArray = buckets._part_color[j]
		var buf: PackedFloat32Array = buckets.body_buf(j0 + j)
		var bases: Dictionary = _bases_fade if _using_fade else _bases
		var base: int = bases.get(j0 + j, 0) * walk.size() * 16
		for i in walk.size():
			var xf: Transform2D = _acc[walk[i]] * xfs[i]
			# 列连续布局（temp/mm3d_render_probe 实证）：
			# f0-2=cx, f3=ox, f4-6=cy, f7=oy, f8-10=cz, f11=oz
			# cx = X·a + Y·b：a/b 为 2D 列向量折 3D 的系数（y 取负）
			var a := sfx * xf.x.x
			var b := -s * xf.x.y
			var c := sfx * xf.y.x
			var d := -s * xf.y.y
			var dx := sfx * (xf.origin.x - FOOT_ANCHOR.x)
			var dy := -s * (xf.origin.y - FOOT_ANCHOR.y)
			var zb := zbs[i]
			var o := base + i * 16
			buf[o] = a
			buf[o + 1] = b * ct
			buf[o + 2] = -b * stn
			buf[o + 3] = p.x + dx
			buf[o + 4] = c
			buf[o + 5] = d * ct
			buf[o + 6] = -d * stn
			buf[o + 7] = p.y + dy * ct - zb * stn
			buf[o + 8] = 0.0
			buf[o + 9] = stn
			buf[o + 10] = ct
			buf[o + 11] = p.z - dy * stn + zb * ct
			var col: Color = cols[i].srgb_to_linear()
			buf[o + 12] = col.r * tr.r
			buf[o + 13] = col.g * tr.g
			buf[o + 14] = col.b * tr.b
			buf[o + 15] = col.a * alpha
		# PackedArray 按值语义：跨对象下标写不回写，整段交还桶（crowd 三步式）
		buckets.set_body_buf(j0 + j, buf)
		buckets.mark_body_dirty(j0 + j)


## 武器/盾：手骨 acc × 挂点补偿 × Sprite 局部 → 3D quad（贴图分桶）
func _write_weapons() -> void:
	if _weapon.is_empty() and _shield.is_empty():
		return
	var t := deg_to_rad(_tilt_deg)
	var ct := cos(t)
	var stn := sin(t)
	var fx := -1.0 if _flip else 1.0
	var s := S * _depth
	var sfx := s * fx
	var col := _tint.srgb_to_linear()
	col.a = _master_alpha
	for w in [_weapon, _shield]:
		if w.is_empty():
			continue
		var xf: Transform2D = _acc[w["hand"]] * w["attach"] * w["sprite_xf"]
		var tsz: Vector2 = w["tex_size"]
		var a := sfx * xf.x.x * tsz.x
		var b := -s * xf.x.y * tsz.x
		var c := sfx * xf.y.x * tsz.y
		var d := -s * xf.y.y * tsz.y
		var dx := sfx * (xf.origin.x - FOOT_ANCHOR.x)
		var dy := -s * (xf.origin.y - FOOT_ANCHOR.y)
		var cx := Vector3(a, b * ct, -b * stn)
		var cy := Vector3(c, d * ct, -d * stn)
		var o := Vector3(_pos.x + dx, _pos.y + dy * ct + ZB_WEAPON * stn,
				_pos.z - dy * stn + ZB_WEAPON * ct)
		_buckets.weapon_row(w["tex_path"], w["tex"], cx, cy, Vector3(0.0, stn, ct), o, col)


## 血条（crowd write_bars 单位版移植，世界折算：BAR_UNIT×bs×depth）
func _write_bar() -> void:
	var st: Dictionary = _bar_state
	if st.is_empty() or not bool(st.get("active", false)):
		return
	var t := deg_to_rad(_tilt_deg)
	var ct := cos(t)
	var stn := sin(t)
	var bx := Vector3(1.0, 0.0, 0.0)
	var by := Vector3(0.0, ct, -stn)
	var bz := Vector3(0.0, stn, ct)
	var bs: float = float(st.get("scale", 1.0)) * BAR_UNIT * _depth
	var center := _pos + by * (BAR_H * _depth)
	var shown: float = float(st.get("shown", 0.0))
	var alpha := _master_alpha
	var buckets: Node = _buckets
	var k_wobble: int = int(st.get("wobble", 0)) % 8
	var k_plain: int = buckets.bar_plain_k()
	# 圆点（满血/未展开：expand<0.999 才画，本体/描边 alpha 同乘 1-expand）
	if float(st.get("expand", 1.0)) < 0.999:
		var dot_a: float = shown * (1.0 - float(st.get("expand", 1.0))) * alpha
		var rr: float = HealthBarIndicator.DOT_RADIUS * bs
		var dc: Color = st.get("color", Color.WHITE)
		var olc: Color = HealthBarIndicator.COLOR_OUTLINE
		buckets._dot_fill.row(k_wobble, bx * rr, by * rr, bz, center,
				Color(dc.r, dc.g, dc.b, dc.a * dot_a), 0.0, 0.0, 0.0)
		buckets._dot_ring.row(k_wobble, bx * rr, by * rr, bz, center,
				Color(olc.r, olc.g, olc.b, olc.a * dot_a), 0.0, 0.0, 0.0)
	# 横条层序：底→描边①→残影→填充→描边②
	var half: float = float(st.get("width", 20.0)) * 0.5 * float(st.get("expand", 1.0)) * bs
	if half >= bs:
		var at: float = float(st.get("anim_time", 0.0))
		var se: float = float(st.get("shake", 0.0))
		var shk: float = sin(at * HealthBarIndicator.SHAKE_FREQ) * se \
				* HealthBarIndicator.SHAKE_MAX_OFFSET \
				+ sin(at * HealthBarIndicator.SHAKE_FREQ * 2.3) * se \
				* HealthBarIndicator.SHAKE_MAX_OFFSET * 0.3
		var c2 := center + bx * shk
		var bw: float = half * 2.0
		var hh: float = HealthBarIndicator.BAR_HEIGHT * bs
		var k: int = k_plain if bw / bs < 6.0 else k_wobble
		_bar_row(buckets._bar_bg, k, c2, bx, by, bz, bw, hh,
				HealthBarIndicator.COLOR_BG, shown * alpha, bw / bs < 6.0)
		_bar_row(buckets._bar_ring1, k, c2, bx, by, bz, bw, hh,
				HealthBarIndicator.COLOR_OUTLINE, shown * alpha, bw / bs < 6.0)
		var trail: float = float(st.get("trail", 0.0))
		if trail > float(st.get("ratio", 0.0)) + 0.005:
			var tw := bw * trail
			_bar_row(buckets._bar_trail_fill,
					k_plain if tw / bs < 6.0 else k_wobble,
					c2 - bx * (half - tw * 0.5), bx, by, bz,
					tw, hh, HealthBarIndicator.COLOR_TRAIL, shown * alpha, tw / bs < 6.0)
		var fw := bw * float(st.get("ratio", 0.0))
		if fw > 0.5 * bs:
			_bar_row(buckets._bar_trail_fill,
					k_plain if fw / bs < 6.0 else k_wobble,
					c2 - bx * (half - fw * 0.5), bx, by, bz,
					fw, hh, st.get("color", Color.WHITE), shown * alpha, fw / bs < 6.0)
		_bar_row(buckets._bar_ring2, k, c2, bx, by, bz, bw, hh,
				HealthBarIndicator.COLOR_OUTLINE, shown * alpha, bw / bs < 6.0)
	# 军衔方点（血条上侧横排居中；rank0 无标记）
	var rank: int = clampi(int(st.get("rank", 0)), 0, 3)
	if rank > 0:
		var ds: float = HealthBarIndicator.RANK_DOT_SIZE * bs
		var dg: float = HealthBarIndicator.RANK_DOT_GAP * bs
		var total := rank * ds + (rank - 1) * dg
		var dpos := center + by * (-HealthBarIndicator.RANK_DOT_Y * bs)
		for i in rank:
			var p := dpos + bx * (-total * 0.5 + i * (ds + dg) + ds * 0.5)
			_bar_row(buckets._bar_trail_fill, k_plain, p, bx, by, bz,
					ds + 2.0 * bs, ds + 2.0 * bs, HealthBarIndicator.COLOR_BG,
					shown * alpha, true)
			_bar_row(buckets._bar_trail_fill, k_plain, p, bx, by, bz,
					ds, ds, HealthBarIndicator.COLOR_RANK, shown * alpha, true)


func _bar_row(bucket, k: int, center: Vector3, bx: Vector3, by: Vector3, bz: Vector3,
		w: float, h: float, col: Color, a: float, plain: bool) -> void:
	var lin := col.srgb_to_linear()   # 画布色值 → spatial 线性域
	bucket.row(k, bx * w, by * h, bz, center,
			Color(lin.r, lin.g, lin.b, lin.a * a), w, 1.0 if plain else 0.0, h)
