extends RefCounted
## hd2d_char_stage.gd —— HD-2D 角色舞台组件（hd2d_world 职责拆分）。
##
## 职责：把 2D 逻辑火柴人搬上 3D 街景的装配口——关节烘焙路线（裁决#15）的
## 每实体装配（char_direct_buckets 全局 MultiMesh 桶 + 隐藏 rig 画布按需装配
## 一次 + char_rig_3d 实体宿主），以及相机缩放时的描边宽档同步。
## 实体容器（_char_entities_root）的创建归门面 _build_world（烘焙排除层按容器
## 整体归层，创建时机在门面保持不变）。
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

const CharRig3D := preload("res://modules/hd2d/scripts/char_rig_3d.gd")
const CHAR_DIRECT_BUCKETS := preload("res://modules/hd2d/scripts/char_direct_buckets.gd")

## 宿主门面（hd2d_world）回引：门面 _ready 时注入。禁循环 preload（门面 preload 本文件），
## 故不标类型。
var w: Node3D = null

## 桶/隐藏 rig 画布（懒装配一次）
var _joint_buckets: Node = null
var _joint_rig_parent: Node2D = null
## 实体序号（billboard 命名用）
var _char_seq: int = 0


## 游戏接入：生成一个独立角色实例（各自 rig/动画），由宿主逐帧驱动。
func spawn_character() -> Node:
	return _spawn_joint_character()


## 相机缩放镜像入口（门面 set_cam_zoom 调）：桶未装配（尚无角色）时静默跳过
func update_outline_eff(user_zoom: float) -> void:
	if _joint_buckets != null:
		_joint_buckets.update_outline_eff(user_zoom)


## 关节烘焙路线（裁决#15）：每实体一个 char_rig_3d 宿主（真 rig 只解算不进
## 视口，部件直写全局 3D MultiMesh 桶——形状由 char_joint_atlas 预烘关节贴图
## 承运，零逐帧视口零逐帧回读）。桶/隐藏 rig 画布按需装配一次。
func _spawn_joint_character() -> Node:
	if _joint_buckets == null:
		var b: Node = CHAR_DIRECT_BUCKETS.new()
		b.name = "CharJoint3D"
		w.add_child(b)
		# 描边宽档初值：桶默认按 zoom=0.75，本场景 set_cam_zoom 已跑过则以实档覆盖
		if w._last_user_zoom > 0.0:
			b.update_outline_eff(clampf(w._last_user_zoom, 0.25, 8.0))
		_joint_buckets = b
		var layer := CanvasLayer.new()
		layer.name = "JointRigHosts"
		layer.visible = false   # 只解算不绘制（CanvasItem 隐藏停绘制不停 _process）
		w.add_child(layer)
		var rigs := Node2D.new()
		rigs.name = "Rigs"
		layer.add_child(rigs)
		_joint_rig_parent = rigs
	var h: Node = CharRig3D.new()
	h.name = "Char%d" % _char_seq
	_char_seq += 1
	# 挂实体容器（非 hd2d_world 根）：小地图烘焙按容器整体归排除层——
	# 散挂根上会漏进照片底图（实测：Char0..N 漏进街带贴图）
	if w._char_entities_root != null:
		w._char_entities_root.add_child(h)
	else:
		w.add_child(h)
	h.build(w, _joint_buckets, _joint_rig_parent, "idle", w.TILT_DEG)
	return h
