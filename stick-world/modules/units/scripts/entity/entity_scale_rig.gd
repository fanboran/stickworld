extends RefCounted
## 火柴人缩放/骨架同步助手 —— 从 stickman_entity 拆出的渲染判定缩放逻辑。
##
## 职责：
## - 脚底接触阴影（静态共享纹理 + 生成；z 序约定：z_as_relative=false 绝对 z=1）
## - 碰撞基准捕获（_capture_collision_bases，实体 _ready 同位调用：
##   Collider/Range/Hitbox 原始尺寸/偏移一次捕获并按 BASE_SCALE 摆位）
## - 渲染/判定缩放应用（_apply_scale：rig 翻转/体型缩放 + 三碰撞形状同步 + 血条跟随）
## - 体型缩放设置（set_body_scale；实体留一行壳供 behavior_attack/tests duck 调用）
## - IK markers 变换同步（_sync_markers_transform，脏标记节流；实体留壳供 bench 直呼）
## - 脚部偏移计算（_calculate_foot_offset）
##
## foot_offset/_foot_offset_base/body_scale/BASE_SCALE/rig/_markers_parent 等
## 状态字段留实体（crowd_renderer/save_handler/visual_controller/town_life 直读），
## 本类持实体回引直读直写。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null

# ─────────────────────────────── 碰撞基准（_ready 捕获）────────────────────────────────
## Collider 原始尺寸（_ready 时保存，_apply_scale 时乘以 BASE_SCALE）
var _collider_base_size: Vector2 = Vector2.ZERO
## Range 原始尺寸（悬停检测范围，与 Collider 同步缩放）
var _range_base_size: Vector2 = Vector2.ZERO
## Collider 原始 X 偏移（缩放后，朝右时基准；_apply_scale 时乘以 _facing 镜像）
var _collider_base_x: float = 0.0
## Range 原始 X 偏移（缩放后，朝右时基准；_apply_scale 时乘以 _facing 镜像）
var _range_base_x: float = 0.0
## Range 基准 Y 偏移（BASE_SCALE 后、body_scale=1.0 基线；9q y 偏移随体型缩放）
var _range_base_y: float = 0.0
## Hitbox 子 CollisionShape2D 原始尺寸（受击判定，与 Collider 同步缩放）
var _hitbox_base_size: Vector2 = Vector2.ZERO
## Hitbox 子 CollisionShape2D 原始 X 偏移（缩放后，朝右时基准；_apply_scale 时乘以 _facing 镜像）
var _hitbox_base_x: float = 0.0
## Hitbox 基准 Y 偏移（BASE_SCALE 后基线；9q y 偏移随体型缩放）
var _hitbox_base_y: float = 0.0

## markers 同步脏标记（性能）：markers_parent 与 rig 同父（RigHost/OutlineGroup），
## 二者局部 transform 一致时，全局变换随父节点自动保持一致——父（实体）移动
## 不需要重写。rig 的局部 transform 只在 _apply_scale（翻转/体型缩放）变化，
## 故只在置脏后写一次，替代此前每物理帧的全局矩阵读写（大群单位的稳定开销）。
var _markers_dirty: bool = true


func _init(entity: Node) -> void:
	_entity = entity


## 脚底接触阴影：径向渐变纹理压扁为椭圆，跟随 foot_offset（体型缩放同步）。
## 纹理全单位共享一张（静态缓存）——此前每单位运行时生成一张 GradientTexture2D，
## 196 单位混战=196 份冗余纹理与上传
static var _contact_shadow_tex: GradientTexture2D = null


static func _get_contact_shadow_tex() -> GradientTexture2D:
	if _contact_shadow_tex == null:
		var tex := GradientTexture2D.new()
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(0.5, 0.0)
		tex.width = 64
		tex.height = 64
		var grad := Gradient.new()
		grad.set_color(0, Color(0, 0, 0, 0.34))
		grad.set_color(1, Color(0, 0, 0, 0.0))
		tex.gradient = grad
		_contact_shadow_tex = tex
	return _contact_shadow_tex


func _spawn_contact_shadow() -> void:
	var spr := Sprite2D.new()
	spr.name = "ContactShadow"
	spr.texture = _get_contact_shadow_tex()
	spr.scale = Vector2(0.9, 0.26)  # 压成椭圆
	spr.position = Vector2(0.0, _entity.foot_offset + 2.0)
	# 刀②合批：绝对 z=1（DECORATION 层——地面之上可见、建筑/单位正常遮盖，
	# 与装饰同层但树序在后成连续段）。此前 z=-2 为相对实体 z（y 序 0~14 →
	# 阴影实际 z 各异、交错在各单位之间）——同纹理却因渲染序列不连续无法
	# 合批，96v96 192 个阴影 = 192 draws。
	spr.z_as_relative = false
	spr.z_index = 1
	_entity.add_child(spr)


## 碰撞基准捕获（实体 _ready 同位调用，时序敏感：foot_offset 计算之后、
## 首次 _apply_scale 之前）。
func _capture_collision_bases() -> void:
	# 碰撞体移到脚部位置（保留原始 X 偏移并缩放，不硬编码为 0）
	var col = _entity.get_node_or_null("Collider") as CollisionShape2D
	if col != null:
		var col_orig_x: float = col.position.x
		_collider_base_x = col_orig_x * _entity.BASE_SCALE
		col.position = Vector2(_collider_base_x, _entity.foot_offset)
		# duplicate shape 避免多实例共享同一资源导致 _apply_scale 互相覆盖
		if col.shape is RectangleShape2D:
			col.shape = (col.shape as RectangleShape2D).duplicate()
			_collider_base_size = (col.shape as RectangleShape2D).size
	# Range 节点也 duplicate shape 并保存原始尺寸
	var rng = _entity.get_node_or_null("Range") as CollisionShape2D
	if rng != null and rng.shape is RectangleShape2D:
		rng.shape = (rng.shape as RectangleShape2D).duplicate()
		_range_base_size = (rng.shape as RectangleShape2D).size
		# Range position 也需要缩放（编辑器中的值基于原始大小，运行时需乘以 BASE_SCALE）
		_range_base_x = rng.position.x * _entity.BASE_SCALE
		rng.position *= _entity.BASE_SCALE
		_range_base_y = rng.position.y
	# Hitbox 子 CollisionShape2D 同步缩放并保存原始尺寸/偏移
	if _entity.hitbox != null:
		var hb_shape = _entity.hitbox.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if hb_shape != null and hb_shape.shape is RectangleShape2D:
			hb_shape.shape = (hb_shape.shape as RectangleShape2D).duplicate()
			_hitbox_base_size = (hb_shape.shape as RectangleShape2D).size
			_hitbox_base_x = hb_shape.position.x * _entity.BASE_SCALE
			hb_shape.position *= _entity.BASE_SCALE
			_hitbox_base_y = hb_shape.position.y


func _apply_scale() -> void:
	var rig: Node2D = _entity.rig
	if rig == null:
		return
	var s: float = _entity.BASE_SCALE * _entity.body_scale
	rig.scale = Vector2(s * _entity._facing, s)
	# rig 局部缩放变了 → markers 同步置脏（_sync_markers_transform 只在脏时写，
	# 免每物理帧 200 单位 × 全局矩阵读写的纯浪费，见该函数注释）
	_markers_dirty = true
	# 9q：foot_offset 随体型重算（缩放单位脚随体型上移；消费点全部读本字段）
	_entity.foot_offset = _entity._foot_offset_base * _entity.body_scale
	# 同步缩放 Collider shape（Collider 不在 rig 层级下，不受 rig.scale 影响）
	if _collider_base_size != Vector2.ZERO:
		var col = _entity.get_node_or_null("Collider") as CollisionShape2D
		if col != null and col.shape is RectangleShape2D:
			(col.shape as RectangleShape2D).size = _collider_base_size * s
			# X 偏移随朝向镜像（原点不在碰撞箱中心时，翻转需镜像偏移）
			col.position.x = _collider_base_x * _entity._facing
			# Y 偏移：2D 图口径 Collider 跟到脚上（origin=髋、脚在 +foot_offset）；
			# origin 空间（HD-2D）origin 即视觉脚线，物理脚印贴脚线（箱居 origin）
			# ——否则物理脚印悬在视觉脚线"前方" ~foot_offset·k·ez，停位与视觉
			# 脱节（创始人 2026-09-16"实际逻辑位置也偏很多"）
			col.position.y = 0.0 if _entity._ground_constraints_origin_space else _entity.foot_offset
	# 同步缩放 Range shape（悬停检测范围，与 Collider 同步缩放）
	if _range_base_size != Vector2.ZERO:
		var rng = _entity.get_node_or_null("Range") as CollisionShape2D
		if rng != null and rng.shape is RectangleShape2D:
			(rng.shape as RectangleShape2D).size = _range_base_size * s
			rng.position.x = _range_base_x * _entity._facing
			rng.position.y = _range_base_y * _entity.body_scale
	# 同步缩放 Hitbox 子 shape（受击判定，与 Collider 同步缩放）
	if _hitbox_base_size != Vector2.ZERO and _entity.hitbox != null:
		var hb_shape = _entity.hitbox.get_node_or_null("CollisionShape2D") as CollisionShape2D
		if hb_shape != null and hb_shape.shape is RectangleShape2D:
			(hb_shape.shape as RectangleShape2D).size = _hitbox_base_size * s
			hb_shape.position.x = _hitbox_base_x * _entity._facing
			hb_shape.position.y = _hitbox_base_y * _entity.body_scale
	# 血条跟随体型（minidon 小一圈时血条高度/大小同步缩小，不再浮在半空）
	var health_bar: Node = _entity._health_bar
	if health_bar != null and is_instance_valid(health_bar) \
			and health_bar.has_method("set_body_scale"):
		health_bar.set_body_scale(_entity.body_scale)
	_sync_markers_transform()


## 设置体型缩放（SWL minidon 召唤护卫小一圈）：设置后立即重应用渲染/判定缩放。
func set_body_scale(v: float) -> void:
	_entity.body_scale = maxf(0.1, v)
	_apply_scale()


func _sync_markers_transform() -> void:
	var rig: Node2D = _entity.rig
	var markers_parent: Node2D = _entity._markers_parent
	if markers_parent == null or rig == null:
		return
	if not _markers_dirty:
		return
	_markers_dirty = false
	# IK markers 父节点必须与 StickmanRig 同 transform，否则 IK 不可达
	markers_parent.global_transform = rig.global_transform


## 从 RigHost 的 outfoot marker 位置计算脚部 Y 偏移。
## 公式：foot_offset = root_y + outfoot_local_y * BASE_SCALE
## 这样无论模型参考系怎么改，脚部位置都能正确对齐地面。
func _calculate_foot_offset() -> float:
	var rig_host = _entity.get_node_or_null("RigHost")
	if rig_host == null:
		return 45.0
	var root_y: float = (rig_host as Node2D).position.y
	var outfoot := rig_host.get_node_or_null("OutlineGroup/Node2D/outfoot") as Node2D
	if outfoot == null:
		return 45.0
	var outfoot_y: float = outfoot.position.y
	var offset: float = root_y + outfoot_y * _entity.BASE_SCALE
	return offset
