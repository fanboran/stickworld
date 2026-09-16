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
##
## 子域索引（胖文件拆分，行为与公共 API 零变化）：
##   - crowd_renderer_bake.gd：骨骼拓扑/4 桶部件预烘/动画预编译
##     （冷路径 static 库，预烘表状态留本文件，返回值交还）
##   - crowd_renderer_buckets.gd：MMI/材质着色器装配、武器图集、容量扩缩、
##     槽位清段、每刻阴影/血条喂入与上传（static 库，宿主首参显式传入）
##   - crowd_renderer_overlay_bucket.gd：血条覆盖层桶（原内部类出壳）
##   - 本文件保留：_pose_slot/_sample_keys 热路径（直访宿主缓冲与累乘缓存）、
##     全部状态（static 预烘表/槽位/桶成员）与公共入口

const Skel := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")

## 子域助手库（const-preload 静态直调；同本文件一样不写 class_name）
const Bake := preload("res://modules/units/scripts/rig/crowd_renderer_bake.gd")
const Buckets := preload("res://modules/units/scripts/rig/crowd_renderer_buckets.gd")
const OverlayBucket := preload("res://modules/units/scripts/rig/crowd_renderer_overlay_bucket.gd")

## 工程设置键 + 环境变量（A/B 惯例）
const SETTING_KEY := "render/crowd_renderer"
const ENV_OVERRIDE := "STICK_CROWD"


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
## 部件预烘当前描边单侧宽（zoom 补偿；_refresh_outline_zoom 在画布缩放变化时
## 重烘全表。全表共享，按 1.0 体型基准补偿——0.65× 体型单位描边同比偏细，
## 与不补偿时的比例行为一致，不逐单位分表）
static var _bake_ow: float = Skel.OUTLINE_WIDTH
static var _statics_ready: bool = false


## 进程级静态表构建：骨骼拓扑 + 部件预烘 + 动画关键帧预编译。
## 构建逻辑下沉 Bake 库（冷路径 static），表状态全部留在本类。
static func _ensure_statics() -> void:
	if _statics_ready:
		return
	_statics_ready = true
	var topo: Dictionary = Bake.build_bone_topology()
	_bone_ids = topo["ids"]
	_bone_pidx = topo["pidx"]
	_rest_pos = topo["rest"]
	_rebuild_bucket_tables()
	_anim_tables = Bake.compile_anims()


## 重烘 4 桶部件预烘表（Bake 返回 ×4 容器整体替换宿主表；
## 首次构建与 zoom 补偿变化重烘共用）
static func _rebuild_bucket_tables() -> void:
	var t: Array = Bake.build_bucket_tables(_bone_ids, _bake_ow)
	_bucket_bidx = t[0]
	_bucket_xform = t[1]
	_bucket_color = t[2]


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
## 描边补偿已应用的画布缩放（-1 = 未初始化；zoom 变化时重烘静态部件表）
var _ow_canvas_scale: float = -1.0
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


## 装配：4 带 × 4 桶 MMI + 阴影/血条/武器桶（装配逻辑在 Buckets.build_layer；
## 容器节点名/CrowdLayer/z 序/树序桶序铁律见该库）。
func setup(parent: Node2D, y_top: float = 0.0, y_bottom: float = 1024.0) -> void:
	_ensure_statics()
	_host = parent
	_y_top = y_top
	_band_h = maxf((y_bottom - y_top) / float(BAND_COUNT), 1.0)
	Buckets.build_layer(self, parent)
	if _acc.size() != _bone_ids.size():
		_acc.resize(_bone_ids.size())
		_local.resize(_bone_ids.size())


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
## buffer/instance_count 由 Buckets.grow_band 按需扩。此前 BAND_CAP=48 截断
## 复用尾位，48v48 挤团即触发同段覆盖丢身体）
func _alloc_band_idx(band: int) -> int:
	while band >= _free_band.size():
		_free_band.append([])
	var pool: Array = _free_band[band]
	if not pool.is_empty():
		return pool.pop_back()
	_used_count[band] = _used_count.get(band, 0) + 1
	var idx: int = _used_count[band] - 1
	Buckets.grow_band(self, band, idx + 1)
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
	Buckets.clear_slot_instances(self, slot)
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
		Buckets.clear_slot_instances(self, slot)
	# 取消隐藏：下一 tick 重写槽位即恢复


## 描边宽 zoom 补偿（每刻首查，写入仅缩放变化帧）：画布缩放变化时按
## Skel.outline_world_width 重烘静态部件表（描边件随 eff 加宽/收窄）。
## tick 逐槽位全量重写实例行，重烘后同刻写入即生效，无需触碰带桶缓冲结构。
func _refresh_outline_zoom() -> void:
	var vp: Viewport = _host.get_viewport() if _host is Node else null
	if vp == null:
		return
	var s: float = vp.get_canvas_transform().get_scale().x
	if absf(s - _ow_canvas_scale) < 0.001:
		return
	_ow_canvas_scale = s
	var eff: float = Skel.outline_world_width(s)
	if absf(eff - _bake_ow) < 0.001:
		return
	_bake_ow = eff
	_rebuild_bucket_tables()


## 每物理刻推进（BattleInstance._physics_process 调用，在 sim.tick 之后——
## 读实体最新位置）。插值 → 累乘 → 写 4 桶 buffer → 上传。
## 跨库块级委托仅五处：Buckets.rebuild_atlas（dirty 早退）/clear_slot_instances
## （跨带分支）/write_shadows/write_bars/upload_weapon；tick 内零临时容器分配。
func tick(delta: float) -> void:
	if _host == null or _slots.is_empty():
		return
	_refresh_outline_zoom()
	Buckets.rebuild_atlas(self)  # 注册期收集的武器纹理在此一次 blit+上传
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
			Buckets.clear_slot_instances(self, slot)
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
	Buckets.write_shadows(self)
	Buckets.write_bars(self)
	Buckets.upload_weapon(self)


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
	# 身体色恒为默认：不读单位身上的颜色（火柴人身体不做身份染色，见 stickman_rig 类头）
	var body: Color = Skel.DEFAULT_BODY
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
		Buckets.ensure_weapon_cap(self, _weapon_count + 1)
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


## 读单位渲染色（rig 的 Inspector 色；阵营色在实体侧已写入）
func _read_color(rig: Node, prop: String, fallback: Color) -> Color:
	var c = rig.get(prop)
	return c if c is Color else fallback
