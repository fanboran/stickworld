extends Node3D
## char_rig_3d.gd —— 关节烘焙路线的角色视觉宿主（HD-2D 角色渲染唯一路线，
## 2026-10-10 创始人观感验收通过后整卡烘焙退役、本路线转正）。
##
## 是什么：每实体一个本实例。持有一份真 StickmanRig（Skeleton2D +
## AnimationTree + 程序化叠加全照旧，藏在隐藏 CanvasLayer 里只解算不绘制
## ——CanvasItem 隐藏只停绘制，_process/动画推进不受影响）：晚优先级
## _process（1100 = rig 推进(0) 与俯仰叠加(1000) 之后，写序铁律）把部件
## 折进 26° 取景平面，逐行写入 char_direct_buckets 的全局 3D MultiMesh 桶。
## 零逐帧视口、零逐帧回读（预烘贴图一次性离线生成）。
##
## 部件来源（忠实搬运立项时的矢量渲染架构，stickman_skeleton.build_limbs）：
## rig 因 STICK_BATCH_RIG=0 真建了矢量部件节点（sprite_* 容器 + stroke/fill
## 两层 Line2D/Polygon2D）——本宿主逐件读它们的变换/宽度/半径/颜色，一对一
## 搬成 3D quad（形状 = char_joint_atlas 预烘的关节贴图，rig px 几何由
## 引擎画布光栅化器烘出——观感与烘焙卡同源贴图直出）：
##   - 挂靠：容器挂在哪根骨上就跟哪根骨（头圆挂 head 骨 −HEAD_ORBIT，
##     build_limbs 的修复自动生效，不经 crowd 战场表的旧死码约定）；
##   - 几何两遍（裁决#24，照抄画布「全局两遍」语义）：每部件一对行——
##     描边行（加宽胶囊格位、白色实例色、ZB_STROKE 沿法线垫后）+ 填充行。
##     depth_draw_always 下同角色填充恒比描边近 → 环带只在剪影外轮廓出线
##     （#19 关节白线的元凶＝填充边 mip 软坡叠白，由填充桶 edge_cutoff=0.5
##     硬切边治，见 char3d_body_opaque 头注）；填充遍内按画布树序（DFS 序）
##     编号实例序（同色共面无缝融合）；
##   - 部件宽度/半径只在构建期读一次（填充几何运行期不变）；描边宽 =
##     填充宽 + 2×eff（eff 随相机缩放补偿，画布 outline_world_width 同款
##     口径，量化 0.5 rig px 档变化才触发图集重烘）。
##
## 尺寸契约（历史沿革出自整卡烘焙的视口契约，现由本路线独承）：
##   rig px → 世界单位 S = RIG_SCALE(0.35625) × PX(1/24) = 0.01484375；
##   FOOT_ANCHOR(3,141) 钉在角色世界脚点；depth 纵深缩放乘进 S。
## tilt 基：X=(1,0,0) 右，Y=(0,cos t,−sin t) 上仰，Z=(0,sin t,cos t) 朝相机。
## rig 空间 y-down，折 3D 时 y 取负。
## feed API（set_world_pos/set_anim/set_weapon_type/…）由
## hd2d_map_base._sync_character_render 逐帧驱动。
##
## 血条：原版 health_bar_indicator 的驱动镜像画进共享图集视口
##（char_bar_atlas，原版 HealthBarIndicator 同一 apply_bar_state 协议），3D 面片贴头顶锚点。
## 血条/劳作条均为单位 HUD 层语义：免深度测试恒浮于单位件之上（char_bar_atlas 头注）。
##
## 尸体：死亡动画由 rig 播完停尾帧（状态机 dead 态），实体淡出期
## set_master_alpha<1 把部件段迁入渐隐桶逐帧压 alpha——rig 姿态 + 插箭，
## 图片卡渐隐不再存在。

const StickRigAPI := preload("res://modules/stick_rig/api.gd")
const StickProf := preload("res://core/services/stick_prof.gd")
const ANIMS := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT
const SHADOW_SHADER := preload("res://modules/hd2d/shaders/char_shadow.gdshader")
const RIG_SCENE_PATH: String = StickRigAPI.RIG_SCENE_PATH

const RIG_SCALE := 0.35625   # rig px → SV px（SV px → 世界 = PX；比例锚见类头）
const PX := 1.0 / 24.0
const S := RIG_SCALE * PX    # rig px → 世界单位
const FOOT_ANCHOR := Vector2(3.0, 141.0)
const SIZE_K := 1.0
## 血条锚点高度（沿 26° 上仰轴，随 depth 缩放）：卡顶留白 8 原生行 = 条中心
const BAR_H := (144.0 - 8.0) * PX
## 武器/盾的深度微移：恒在全部身体部件之上（原版树序「武器/盾盖头」）
const ZB_WEAPON := 0.008
## 描边行的深度垫后（沿 26° 法线）：同角色填充恒比描边近此量 → 深度缓冲
## 天然实现「填充盖描边、只在剪影外轮廓出线」（画布描边 z=-1/填充 z=0
## 的等价物；正交沿法线视角下 zb 无屏内位移，纯深度语义）。跨角色间距
## （量级 ~0.3+）远大于此值，前角色连描边整体压后角色（画布 y-sort 等价）。
const ZB_STROKE := -0.06

# ─────────────────────────── 部件记录（rig 实建矢量节点 → 3D 实例） ───────────────────────────

## 一个 sprite_* 容器的搬运表：容器引用 + 父骨走查下标 + 几何/颜色。
## 描边层节点只作配对存在性校验（部件对 = stroke+fill 两层），几何不读
## ——描边行 = 同容器变换 + 加宽格位（宽 +2×eff / 半径 +eff，画布公式）。
## 颜色构建期定格（运行期无 apply_colors 触发源）并转线性域（spatial ALBEDO）。
class Part:
	var cont: Node2D = null
	var fill_l: Line2D = null      # 线段肢体填充层（圆肢体为 null）
	var fill_p: Polygon2D = null   # 圆肢体填充层（线段肢体为 null）
	var pidx := 0                  # 容器父骨的走查下标
	var length := 0.0              # 线段长（fill points 跨度，恒定）
	var r_fill := 0.0              # 圆半径（构建期定格）
	var col_fill := Color.WHITE
	# 帧环静态量缓存（P0 帧成本治理）：描边键名/格位尺寸/UV 全是图集静态量，
	# 图集版本变化时由 _refresh_part_statics 刷新——_write_body 每帧每部件
	# 原要做的 1 次字符串拼接 + 4 次字典查找全部出环（102 单位 × ~19 部件 =
	# 每帧 ~8k 次查找/拼接是 rig 行写 15ms/帧的可去部分）
	var sk := ""                   # 描边格位键（name + "#s"）
	var cs_s := Vector2.ZERO       # 描边格位尺寸
	var uv_s := Rect2()            # 描边格位 UV
	var cs := Vector2.ZERO         # 填充格位尺寸
	var uv := Rect2()              # 填充格位 UV

var _parts: Array = []              # Array[Part]
var _joint_atlas: Node = null       # char_joint_atlas（build 时取引）
## 部件静态量已刷版本（图集 publish 版本号；-1 = 未刷，首帧必刷）
var _parts_statics_ver := -1
## 描边单侧宽当前档（rig px，0.5 量化——档变才重报图集规格；裁决#24）
var _eff_q := -1.0
## 脚底接地垫（rig px）：FOOT_ANCHOR 量到脚**骨线**，但线肢圆头半径 + 描边
## 环会探出骨线之下（描边回归后白环压过地面线才显眼——创始人 2026-10-12
## 点正「脚底穿模到地面以下」）。垫 = 最宽线肢半宽 + 当前描边档，几何两遍
## 描边行同吃此垫（环外底贴地）。随 eff 档重算；不动 FOOT_ANCHOR 跨文件
## 契约（hd2d_map_base 50.23 同步值/test_hd2d_projection 断言不受影响）。
var _foot_pad_rig := 0.0
## 部件链路探针一次性哨兵（首写/早退各打一行）
var _probed_once := false
## 停写/恢复迁移探针：最后一次真写帧（-1=未写过）
var _last_written_frame := -1
## 停写段已打点标记（同一停写段只打一行，值=该段最后一次真写帧）
var _stop_logged := -1
## rig 可见性探针：上次采样值
var _last_rig_visible := true

# ─────────────────────────── 装配 ───────────────────────────

var _buckets: Node = null          # char_direct_buckets
var _rig_parent: Node2D = null     # 隐藏画布里的 rig 挂点
var _rig: Node2D = null            # StickmanRig（骨架解算真源）
var _pure_sim := false
var _tilt_deg := 26.0

## 骨骼先序（Bone2D 树走查）+ 父下标
var _bones: Array = []             # Bone2D 先序
var _pidx: PackedInt32Array = PackedInt32Array()
var _acc: Array[Transform2D] = []

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

# 镜像通道缓存
var _anim_seq: int = -2
var _swap_state := ""
var _swap_anim := ""
var _anim_speed_sent: float = -1.0
var _aim_pitch_sent: float = NAN
var _stance_walk := ""
var _stance_idle := ""
var _stable_idle_variant := ""
var _shield_on := false

# 渲染帧插值（#9：sim 30Hz 写位置 → 渲染帧插值）
var _pos_prev := Vector3.ZERO
var _pos_cur := Vector3.ZERO
var _pos_pf := -1
var _pos_valid := false
var _moved_this_tick := false

# 折算参数（_write_body 帧首定格，_fold3d 共用——避免十参长传）
var _f_ct := 1.0
var _f_st := 0.0
var _f_s := 0.0
var _f_sfx := 0.0
var _f_p := Vector3.ZERO


func build(world: Node, buckets: Node, rig_parent: Node2D, anim: String, tilt_deg: float) -> void:
	_buckets = buckets
	_rig_parent = rig_parent
	_tilt_deg = tilt_deg
	_pure_sim = DisplayServer.get_name() == "headless"
	OS.set_environment("STICK_BATCH_RIG", "0")  # 矢量部件真建（读节点搬运的唯一来源）
	var inst: Node2D = load(RIG_SCENE_PATH).instantiate()
	inst.set_script(null)  # 摘掉演示控制器
	_rig_parent.add_child(inst)
	_rig = inst.get_node("OutlineGroup/StickmanRig") as Node2D
	_rig.play(anim)
	_walk_bones()
	_collect_parts()
	if _pure_sim:
		return
	_joint_atlas = buckets.get("joint_atlas")
	if _joint_atlas != null:
		_eff_q = roundf(float(buckets.get("outline_eff")) * 2.0) * 0.5
		_foot_pad_rig = _line_pad()
		_joint_atlas.ensure(_build_specs())
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


## 收集 rig 实建矢量部件（sprite_* 容器）。DFS 按画布树序遍历——
## 骨先容器后（build_limbs 在建骨之后追加容器），子骨 subtree 先于本骨容器
## 的兄弟序天然保持。层序（描边底/填充顶）不在此编序——由写段的遍序 +
## 实深度分离承担（见 _write_body）。
func _collect_parts() -> void:
	_parts.clear()
	_walk_parts(_rig, -1)


func _walk_parts(node: Node, widx: int) -> void:
	for child in node.get_children():
		if child is Bone2D:
			_walk_parts(child, _bones.find(child))
		elif child is Node2D and String(child.name).begins_with("sprite_"):
			_parse_part(child, widx)


func _parse_part(cont: Node2D, widx: int) -> void:
	var stroke_n: Node = cont.get_node_or_null("stroke")
	var fill_n: Node = cont.get_node_or_null("fill")
	# stroke+fill 两层同在 = rig 实建部件的配对信号（描边层不再搬运，裁决#20）
	if stroke_n == null or fill_n == null:
		return
	var p := Part.new()
	p.cont = cont
	p.pidx = widx
	if fill_n is Line2D:
		p.fill_l = fill_n
		var pts := p.fill_l.points
		if pts.size() < 2:
			return
		p.length = absf(pts[pts.size() - 1].x - pts[0].x)
		p.col_fill = p.fill_l.default_color.srgb_to_linear()
	elif fill_n is Polygon2D:
		p.fill_p = fill_n
		p.col_fill = p.fill_p.color.srgb_to_linear()
		var pts_f := p.fill_p.polygon
		p.r_fill = pts_f[0].length() if pts_f.size() > 0 else 0.0
	else:
		return
	_parts.append(p)


## 从实建部件拼图集规格（char_joint_atlas.ensure 的输入契约见其类头）。
## 几何两遍（裁决#24）：每部件双格位——填充 + 描边（线宽 +2×eff / 圆半径
## +eff，画布 stroke 公式同款；格位居中契约保证描边环与填充同心，环带宽
## 恒为 eff）。eff 用量化档（_eff_q），指纹随档稳定。
func _build_specs() -> Array:
	var specs := []
	var eff := maxf(_eff_q, 0.5)
	for p in _parts:
		var n: String = p.cont.name
		if p.fill_p != null:
			specs.append({"name": n, "circle": true, "r_fill": p.r_fill})
			specs.append({"name": _stroke_key(n), "circle": true, "r_fill": p.r_fill + eff})
		else:
			specs.append({"name": n, "circle": false, "length": p.length,
					"w_fill": p.fill_l.width})
			specs.append({"name": _stroke_key(n), "circle": false, "length": p.length,
					"w_fill": p.fill_l.width + eff * 2.0})
	return specs


static func _stroke_key(name: String) -> String:
	return name + "#s"


## 部件帧环静态量刷新（图集重烘发布后格位表可能整表变化——版本比对失效）
func _refresh_part_statics() -> void:
	_parts_statics_ver = _joint_atlas.version()
	for p in _parts:
		p.sk = _stroke_key(p.cont.name)
		p.cs_s = _joint_atlas.cell_size(p.sk)
		p.uv_s = _joint_atlas.uv_rect(p.sk)
		p.cs = _joint_atlas.cell_size(p.cont.name)
		p.uv = _joint_atlas.uv_rect(p.cont.name)


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
	if _pure_sim:
		return
	if _buckets != null and is_instance_valid(_buckets):
		if _buckets.get("bar_atlas") != null:
			(_buckets.get("bar_atlas") as Node).release(get_instance_id())

# ─────────────────────────── feed API（hd2d_map_base 逐帧驱动） ───────────────────────────

## 逐帧世界摆位：x/z 格坐标、朝向、纵深缩放、地面抬升
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


## 整卡透明度（尸体渐隐）：实例色 alpha 逐帧压低（桶材质透明混合，不换桶）
func set_master_alpha(a: float) -> void:
	if is_equal_approx(a, _master_alpha):
		return
	_master_alpha = a


## 武器镜像（挂点补偿口径与 WeaponMount._mount_one 同式）：读武器场景
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
	# 换装不重播（churn 治理：重播会把 walk/idle 拉回第 0 帧）


func apply_health_state(s: Dictionary) -> void:
	_bar_state = s


func set_light(tint: Color, _add: Color) -> void:
	_tint = tint
	if _shadow_mat != null:
		_shadow_mat.set_shader_parameter("blob_color",
				Color(0.06, 0.05, 0.05, 0.50 * clampf(tint.get_luminance() + 0.25, 0.0, 1.0)))


## 显示/隐藏全部角色部件（A/B 对照出图用）：隐藏 = 清段停写 + 释放血条槽
func set_chars_visible(v: bool) -> void:
	_hidden = not v


# ── 3D 头顶劳作进度条 + 接管四角框（quad 方案）──

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
	# HUD 语义（与血条面片同批裁定）：免深度测试，浮于单位身体之上
	m.no_depth_test = true
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


## 接管四角框（user_controlled 玩家专用，贴地 quad）
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
	var _pt := StickProf.t0()
	_process_inner(_delta)
	StickProf.t1("rig宿主", _pt)


func _process_inner(_delta: float) -> void:
	if _pure_sim or _buckets == null or not is_instance_valid(_buckets) or _rig == null:
		return
	# rig 可见性边沿探针（无条件）：LOD 导演 T2 档会翻 rig.visible——vanish 类
	# 报障与此的相关性一眼可判（每个宿主每次翻转一行）
	if _rig.visible != _last_rig_visible:
		_last_rig_visible = _rig.visible
		print("[RigVisProbe] f=%d iid=%d rig.visible=%s" % [
				Engine.get_process_frames(), get_instance_id(), _rig.visible])
	if _hidden:
		_release_bar_slot()
		return
	# 先序累乘（batch_rig._write_transforms 同式：骨骼局部 → rig 局部）
	var _pt1 := StickProf.t0()
	for i in _bones.size():
		var bone := _bones[i] as Bone2D
		if bone == null:
			continue
		var local := bone.transform
		var pi := _pidx[i]
		_acc[i] = local if pi < 0 else _acc[pi] * local
	var t := deg_to_rad(_tilt_deg)
	_f_ct = cos(t)
	_f_st = sin(t)
	_f_s = S * _depth
	_f_sfx = _f_s * (-1.0 if _flip else 1.0)
	_f_p = _pos
	StickProf.t1("rig骨骼", _pt1)
	var _pt2 := StickProf.t0()
	_watch_stroke_eff()   # 描边宽档监视（审计 A4 恢复：缩放换档→重报图集）
	_write_body()
	_write_weapons()
	StickProf.t1("rig行写", _pt2)
	var _pt3 := StickProf.t0()
	_feed_bar()
	StickProf.t1("rig喂条", _pt3)


## 描边宽档监视（裁决#24）：相机缩放改档（0.5 rig px 量化）时重报图集
## 规格——格位 4px 量化下多数缩放不换格位尺寸（零 UV 闪变），跨档才异步
## 重烘（旧贴图原子换新前照常服务）。
func _watch_stroke_eff() -> void:
	if _joint_atlas == null or _buckets == null:
		return
	var q := roundf(float(_buckets.get("outline_eff")) * 2.0) * 0.5
	if q > 0.0 and q != _eff_q:
		_eff_q = q
		_foot_pad_rig = _line_pad()
		_joint_atlas.ensure(_build_specs())


## 脚底接地垫：最宽线肢半宽（圆头探出量）+ 当前描边档（环带外沿）——
## 视觉脚底（描边环外底）恰好落在世界脚点/地面上。
func _line_pad() -> float:
	var wmx := 0.0
	for p in _parts:
		if p.fill_l != null:
			wmx = maxf(wmx, p.fill_l.width)
	return wmx * 0.5 + maxf(_eff_q, 0.5)


func _release_bar_slot() -> void:
	var atlas: Node = _buckets.get("bar_atlas")
	if atlas != null:
		atlas.release(get_instance_id())


## 身体写入：逐部件读 rig 实建节点的变换，折 26° 平面写行。几何两遍
##（裁决#24）：描边行（ZB_STROKE 垫后、白×tint）+ 填充行成对；填充遍内
## 按画布树序（DFS 序：腿→躯干→颈/头→臂），同色共面重叠无缝融合。
## 跨角色走真深度（前角色连描边整体压后角色＝画布 y-sort 等价）。
## quad 尺寸 = 图集格位尺寸（量化恒定），实际宽度承运在贴图像素里。
func _write_body() -> void:
	# 停写/恢复迁移探针（无条件边沿打点，vanish 类报障取证口）：
	# 本宿主 >10 帧没写过行 = 一次停写段；停写边沿与恢复边沿各打一行
	var fr := Engine.get_process_frames()
	if _joint_atlas == null or _buckets.body == null:
		if _last_written_frame > 0 and fr - _last_written_frame > 10 \
				and _stop_logged != _last_written_frame:
			_stop_logged = _last_written_frame
			print("[PartsProbe] f=%d iid=%d 停写中 gap>=%d帧 atlas=%s body桶=%s" % [
					fr, get_instance_id(), fr - _last_written_frame,
					_joint_atlas != null, _buckets != null and _buckets.body != null])
		return
	if _last_written_frame > 0 and fr - _last_written_frame > 10:
		print("[PartsProbe] f=%d iid=%d 恢复 gap=%d帧" % [
				fr, get_instance_id(), fr - _last_written_frame])
	_last_written_frame = fr
	if not _probed_once:
		_probed_once = true
		print("[PartsProbe] f=%d iid=%d 首写 parts=%d" % [
				fr, get_instance_id(), _parts.size()])
	var tr := _tint
	var alpha := _master_alpha
	var buckets: Node = _buckets
	var stroke_col := Color(tr.r, tr.g, tr.b, alpha)
	# 静态量失效检查（每帧一次版本比对；重烘发布才真刷）
	if _joint_atlas.version() != _parts_statics_ver:
		_refresh_part_statics()
	if OS.get_environment("STICK_TRACE_PARTS") == "1" and Engine.get_process_frames() % 60 == 0:
		var p0: Part = _parts[0] if _parts.size() > 0 else null
		print("[PartsTrace] iid=%d f=%d atlas_ver=%s statics_ver=%d parts=%d p0.cs=%s p0.uv=%s bucket游标 s:%s/%s b:%s/%s stroke_col=%s tint=%s" % [
				get_instance_id(), Engine.get_process_frames(), _joint_atlas.version(),
				_parts_statics_ver, _parts.size(),
				p0.cs if p0 != null else Vector2.ZERO, p0.uv if p0 != null else Rect2(),
				_buckets.stroke.get("cursor"), _buckets.stroke.get("high_water"),
				_buckets.body.get("cursor"), _buckets.body.get("high_water"),
				stroke_col, tr])
	for p in _parts:
		var xf: Transform2D = _acc[p.pidx] * p.cont.transform
		buckets.stroke_row(_fold3d(xf * _sc2(p.cs_s.x, p.cs_s.y), ZB_STROKE),
				stroke_col, p.uv_s)
		buckets.body_row(_fold3d(xf * _sc2(p.cs.x, p.cs.y), 0.0),
				Color(p.col_fill.r * tr.r, p.col_fill.g * tr.g,
						p.col_fill.b * tr.b, p.col_fill.a * alpha),
				p.uv)


## 2D 部件变换折 3D（官方 Transform3D 构造，零手打包）：
## rig y-down 折 3D 取负；基列 = rig 列 (a,b)/(c,d) 折上仰平面，
## 法列 = (0,sin t,cos t) 朝相机；zb 沿法线（描边垫后/武器置前）。
## FOOT_ANCHOR+脚垫 钉角色世界脚点（垫补偿圆头+描边环探出量，见
## _foot_pad_rig），depth 纵深缩放乘进 _f_s/_f_sfx。
func _fold3d(inst: Transform2D, zb: float) -> Transform3D:
	var a := _f_sfx * inst.x.x
	var b := -_f_s * inst.x.y
	var c := _f_sfx * inst.y.x
	var d := -_f_s * inst.y.y
	var dx := _f_sfx * (inst.origin.x - FOOT_ANCHOR.x)
	var dy := -_f_s * (inst.origin.y - (FOOT_ANCHOR.y + _foot_pad_rig))
	return Transform3D(
			Basis(
					Vector3(a, b * _f_ct, -b * _f_st),
					Vector3(c, d * _f_ct, -d * _f_st),
					Vector3(0.0, _f_st, _f_ct)),
			Vector3(_f_p.x + dx, _f_p.y + dy * _f_ct + zb * _f_st,
					_f_p.z - dy * _f_st + zb * _f_ct))


static func _sc2(sx: float, sy: float) -> Transform2D:
	return Transform2D(Vector2(sx, 0.0), Vector2(0.0, sy), Vector2.ZERO)


## 武器/盾：手骨 acc × 挂点补偿 × Sprite 局部 → 3D quad（贴图分桶）
func _write_weapons() -> void:
	if _weapon.is_empty() and _shield.is_empty():
		return
	var col := _tint.srgb_to_linear()
	col.a = _master_alpha
	for w in [_weapon, _shield]:
		if w.is_empty():
			continue
		var xf: Transform2D = _acc[w["hand"]] * w["attach"] * w["sprite_xf"]
		var tsz: Vector2 = w["tex_size"]
		_buckets.weapon_row(w["tex_path"], w["tex"],
				_fold3d(xf * _sc2(tsz.x, tsz.y), ZB_WEAPON), col)


## 血条喂图集：锚点 = 脚点 + 上仰轴 ×(FOOT_ROW−8)×PX×depth（卡顶留白行中心）
func _feed_bar() -> void:
	var atlas: Node = _buckets.get("bar_atlas")
	if atlas == null:
		return
	if _bar_state.is_empty():
		return
	var t := deg_to_rad(_tilt_deg)
	var ct := cos(t)
	var stn := sin(t)
	var h := BAR_H * _depth
	atlas.feed(get_instance_id(), _bar_state,
			Vector3(_pos.x, _pos.y + h * ct, _pos.z - h * stn),
			_tilt_deg, _depth, _master_alpha, _tint, _flip)
