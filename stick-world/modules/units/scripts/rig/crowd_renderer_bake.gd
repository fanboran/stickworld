extends RefCounted
## crowd_renderer 预烘库（冷路径 static）——骨骼拓扑、4 桶部件预烘、动画预编译。
##
## 是什么：进程级一次性构建的静态表。表状态（_bone_ids/_bone_pidx/_rest_pos/
## _anim_tables/_bucket_bidx/...）全部留在宿主 crowd_renderer.gd；本库无状态，
## 构建结果以返回值交还宿主（packed 表值语义，经 Dictionary/Array 容器返回）。
## 宿主 _ensure_statics 首建、_refresh_outline_zoom 在画布缩放变化时重入
## build_bucket_tables 重烘全表（zoom 补偿描边宽）。
##
## 性能边界：仅冷路径（首次 setup + 缩放变化帧），允许临时容器分配。

const Skel := preload("res://modules/units/scripts/rig/stickman_skeleton.gd")

## 动画资源目录（bake_anims 产物）
const ANIM_DIR := "res://modules/units/animations/"


## 骨骼拓扑排序：SKELETON_DATA+EXTRA_LIMBS 按 parent 链深度排序（父先于子），
## 与 batch_rig._walk_and_emit 的场景树先序等价（部件累乘只要求父先于子）。
## 返回 {ids, pidx, rest}：先序下标表 / 父先序下标（-1 = 根）/ rest 位置
## （骨骼局部平移；rotation 由动画插值附加）。
static func build_bone_topology() -> Dictionary:
	var ids := PackedInt32Array()
	var pidx := PackedInt32Array()
	var rest := PackedVector2Array()
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
				ids.append(id)
				pidx.append(ids.find(parent) if parent >= 0 else -1)
				rest.append(Vector2(data.get("x", 0.0), data.get("y", 0.0)))
				progressed = true
			else:
				next_pending.append(id)
		pending = next_pending
		if not progressed:
			break  # 环防御（数据错误时退出避免死循环）
	return {"ids": ids, "pidx": pidx, "rest": rest}


## 4 桶部件预烘（照搬 batch_rig._emit_limb 的尺寸语义，父骨下标换本表先序
## 下标）。可重入：zoom 补偿变化描边宽时宿主重烘全表（先清后建，实例数恒定）。
## 返回 [bidx, xform, color]：各为 ×4 桶容器
## （PackedInt32Array / Transform2D 数组 / PackedColorArray）。
static func build_bucket_tables(bone_ids: PackedInt32Array, bake_ow: float) -> Array:
	var bidx: Array = []   # PackedInt32Array ×4
	var xform: Array = []  # Array[Transform2D] ×4
	var color: Array = []  # PackedColorArray ×4（身体色占位白，注册时按单位实际色替换）
	for j in 4:
		bidx.append(PackedInt32Array())
		xform.append([])
		color.append(PackedColorArray())
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
	for i in bone_ids.size():
		var id: int = bone_ids[i]
		if limb_by_parent.has(id):
			_emit_limb(limb_by_parent[id], i, bidx, xform, color, bake_ow)
	return [bidx, xform, color]


## 单段肢体拆 4 桶（与 batch_rig._emit_limb 同式）。颜色哨兵制：
## 身体类（非武器/护甲）存 WHITE → 写 buffer 时替换为单位身体色；描边存
## BLACK → 替换为单位描边色；武器（TRIANGLE）/护甲（ELLIPSE）存模板真值
## （非阵营色，与骨骼管线里 colors 表语义一致）。
static func _emit_limb(data: Dictionary, bone_idx: int, bidx: Array, xforms: Array, colors: Array, bake_ow: float) -> void:
	var node_type: int = int(data.get("type", -1))
	var length := float(data.get("length", 1))
	var w := maxf(float(data.get("thickness", 0)), 1.0)
	var ow: float = bake_ow
	var is_body: bool = node_type != Skel.TYPE_TRIANGLE and node_type != Skel.TYPE_ELLIPSE
	var fill_color: Color = Color.WHITE if is_body else Skel._color_for_type(node_type, {})
	if node_type == Skel.TYPE_CIRCLE:
		var r := maxf(length, w * 2.0) / 2.0
		var base := Transform2D(0.0, Vector2(data["x"], data["y"]))
		_push(1, bone_idx, base * _scale2(r + ow, r + ow), Color.BLACK, bidx, xforms, colors)
		_push(3, bone_idx, base * _scale2(r, r), fill_color, bidx, xforms, colors)
		return
	var dir := Vector2(data["x"], data["y"])
	var base := Transform2D(dir.angle(), dir / 2.0)
	var half := length / 2.0
	var sw := w + ow * 2.0
	_push(0, bone_idx, base * _scale2(length, sw), Color.BLACK, bidx, xforms, colors)
	_push(1, bone_idx, base * _shift_scale(Vector2(-half, 0.0), sw / 2.0, sw / 2.0), Color.BLACK, bidx, xforms, colors)
	_push(1, bone_idx, base * _shift_scale(Vector2(half, 0.0), sw / 2.0, sw / 2.0), Color.BLACK, bidx, xforms, colors)
	_push(2, bone_idx, base * _scale2(length, w), fill_color, bidx, xforms, colors)
	_push(3, bone_idx, base * _shift_scale(Vector2(-half, 0.0), w / 2.0, w / 2.0), fill_color, bidx, xforms, colors)
	_push(3, bone_idx, base * _shift_scale(Vector2(half, 0.0), w / 2.0, w / 2.0), fill_color, bidx, xforms, colors)


static func _push(bucket: int, bone_idx: int, xf: Transform2D, col: Color, bidx: Array, xforms: Array, colors: Array) -> void:
	bidx[bucket].append(bone_idx)
	xforms[bucket].append(xf)
	colors[bucket].append(col)


static func _scale2(sx: float, sy: float) -> Transform2D:
	return Transform2D(Vector2(sx, 0.0), Vector2(0.0, sy), Vector2.ZERO)


static func _shift_scale(off: Vector2, sx: float, sy: float) -> Transform2D:
	return Transform2D(0.0, off) * _scale2(sx, sy)


## 动画预编译：扫描动画目录全部 .tres，解析 value track（:rotation）成
## 每骨骼关键帧浮点数组（运行时零解析成本，纯插值）。
## 返回 anim_name -> {length, loop, tracks: {bone_id -> PackedFloat32Array [t0,a0,t1,a1...]}}
static func compile_anims() -> Dictionary:
	var tables: Dictionary = {}
	var dir := DirAccess.open(ANIM_DIR)
	if dir == null:
		push_error("[CrowdRenderer] 动画目录不可读: " + ANIM_DIR)
		return tables
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
		tables[file.get_basename()] = {
			"length": anim.length,
			"loop": anim.loop_mode == Animation.LOOP_LINEAR,
			"tracks": tracks,
		}
	return tables
