extends RefCounted
## 武器挂载与换装助手 —— 从 weapon_mount.gd 拆出的装备子域（无自持状态）。
##
## 职责：
## - reload_weapons：卸装重挂总入口（weapon_type / shield_enabled 变化时；
##   含兵种移速档案写入 + P5 数值校准 + walk/run 走姿分层换装）
## - _mount_weapons / _mount_shield / _mount_one：武器/盾模型挂到手骨骼
##   （GripPoint 对齐握把；HD-2D billboard 图只保战斗数据，视觉走镜像）
## - _find_hand_bone / _find_shield_bone：武器骨/盾骨路径查找
## - _connect_rig_events：rig 动画事件/动画结束信号惰性接线
## - play_event_sfx：Spine Sound 事件 → AudioManager 语义事件（SFX_EVENT_NAMES 映射表）
##
## 纪律：武器/盾实例（_weapon/_shield，被 weapon_block 格挡判定与
## get_weapon_node/get_shield_node 消费）与全部 @export 数值留在宿主
## WeaponMount，经 _mount 动态回引读写；宿主保留 _reload_weapons facade
## （@export setter 经 call_deferred 字符串调用，函数名不可变）。

## 数值校准助手（static 函数库；apply 的校准入口）
const WeaponBalance := preload("res://modules/units/scripts/entity/weapon_balance.gd")
## 兵种行为档案（move_mult / block_move_mult 按武器类型读取）
const ScriptBehaviorProfiles := preload("res://modules/units/scripts/ai/behavior_profiles.gd")
## 动画名映射（walk_for_weapon / run_for_weapon 走姿分层）
const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT

var _mount  ## 宿主 WeaponMount（动态回引；状态唯一真相源在宿主）


func _init(mount) -> void:
	_mount = mount


## 重挂武器/盾牌（weapon_type / shield_enabled 变化时）
func reload_weapons() -> void:
	if _mount._weapon != null and is_instance_valid(_mount._weapon):
		_mount._weapon.get_parent().remove_child(_mount._weapon)
		_mount._weapon.queue_free()
		_mount._weapon = null
	if _mount._shield != null and is_instance_valid(_mount._shield):
		_mount._shield.get_parent().remove_child(_mount._shield)
		_mount._shield.queue_free()
		_mount._shield = null
	_mount_weapons()
	# 兵种移速（SWL 兵种机动性差异：档案 move_mult → 实体 move_speed_mult）
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity != null and "move_speed_mult" in owner_entity:
		owner_entity.move_speed_mult = float(
				ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type)).get("move_mult", 1.0))
	# 持盾移速惩罚（盾姿态分层计划 5：举盾行军更沉稳，SPEAR 0.8）
	_mount.block_move_mult = float(
			ScriptBehaviorProfiles.get_profile(int(_mount.weapon_type)).get("block_move_mult", 1.0))
	# P5 数值校准（批次 2）：按武器类型从 BalanceConfig 读 SWL 真值覆盖默认
	# （本体在 weapon_balance.gd）
	WeaponBalance.apply(_mount)
	# 武器走姿分层（2026-09-30 实机验收：持弓行走要有脚步+持弓姿态）：
	# walk state 资源换装（盾姿态分层同款机制）。BOW → walk_bow（Archidon-Walk，
	# 下肢走步 + 上肢保持持弓），其余兵种恢复通用走姿。HD-2D 镜像侧同步换装在
	# char_rig_3d.set_weapon_type（本实体侧 rig 在该图型下为 null）。
	if owner_entity != null and "rig" in owner_entity:
		var rig: Node = owner_entity.get("rig")
		if rig != null and rig.has_method("set_state_anim"):
			rig.set_state_anim("walk", Anims.walk_for_weapon(_mount.weapon_type))
			# 跑姿同款分层：BOW → run_bow（Archidon-Run，弓手专属步态）
			rig.set_state_anim("run", Anims.run_for_weapon(_mount.weapon_type))


## 挂载主手武器 + 副手盾牌到手骨骼（跟随手臂摆动）。
## 手骨骼挂在 forearm 末端（见 stickman_test.tscn），攻击/行走动画驱动
## forearm 时武器自动跟随；不再挂 IK marker（marker 静态，物体会飘在固定位置）。
func _mount_weapons() -> void:
	var owner_entity: CharacterBody2D = _mount.get_owner_entity()
	if owner_entity == null:
		push_warning("[WeaponMount] 无持有实体，无法挂武器")
		return
	# HD-2D 图（billboard 视觉）：2D 骨架树不创建（entity.rig 为 null），武器/盾
	# 模型由 billboard 宿主 set_weapon_type 镜像挂载，此处只保战斗数据——
	# 射程按武器类型照常生效（此前随挂骨失败一并早退，WEAPON_RANGE 各档
	# 在 HD-2D 图全员退化为默认 80，行为层交战距离全错）
	if owner_entity.get("rig") == null:
		_mount.attack_range = 0.0 if _mount.weapon_type == _mount.WeaponType.NONE \
				else float(_mount.WEAPON_RANGE.get(_mount.weapon_type, _mount.attack_range))
		_mount.attack_range_second_line = float(_mount.WEAPON_RANGE_SECOND_LINE.get(_mount.weapon_type, 0.0))
		# 盾实例对 billboard 图放行（修"矛兵盾 100% 缺失→格挡从未发生"）：
		# is_shield_blocking 第一重判定只认 _shield 实例存在，此前本分支早退
		# 使 blockChance 0.35 在观察场从未掷出。2D 骨架未建 → 盾以隐藏逻辑
		# 实例挂 WeaponMount 自身（数据与状态留 2D 侧），billboard 视觉由
		# char_rig_3d 镜像挂盾（渲染走镜像——HD-2D 铁律）。
		if _mount.shield_visual_enabled():
			_mount_shield(owner_entity)
		return
	var hand: Node2D = _find_hand_bone(owner_entity)
	if hand == null:
		push_warning("[WeaponMount] 未找到主手骨骼（hand_inner），无法挂武器")
		return
	# NONE = 徒手（背包装备系统卸空主手）：不挂武器模型，射程归零不可攻击
	if _mount.weapon_type == _mount.WeaponType.NONE:
		_mount.attack_range = 0.0
		_mount.attack_range_second_line = 0.0
	else:
		var scene_path: String = _mount.WEAPON_SCENE_PATHS.get(_mount.weapon_type, "")
		if scene_path.is_empty():
			push_warning("[WeaponMount] 未知武器类型: %d" % _mount.weapon_type)
			return
		var scene: PackedScene = load(scene_path)
		if scene == null:
			push_warning("[WeaponMount] 武器场景加载失败: %s" % scene_path)
			return
		_mount._weapon = _mount_one(scene, hand, "Weapon")
		_mount.attack_range = _mount.WEAPON_RANGE.get(_mount.weapon_type, _mount.attack_range)
		_mount.attack_range_second_line = float(_mount.WEAPON_RANGE_SECOND_LINE.get(_mount.weapon_type, 0.0))
	# 副手盾牌（**绑定矛兵**：原版也只有 Spearton 持盾，其余兵种无盾——
	# 曾给全员挂盾导致"人手一面盾"的怪相，用户决策回归原版；
	# equipped_shield = 玩家背包副手装备盾，任意武器可配）
	if _mount.shield_visual_enabled():
		_mount_shield(owner_entity)
	# 订阅动画内嵌事件（命中帧 + 音效钩子）
	_connect_rig_events(owner_entity)


func _mount_shield(owner_entity: CharacterBody2D) -> void:
	var scene: PackedScene = load(_mount.SHIELD_SCENE_PATH)
	if scene == null:
		push_warning("[WeaponMount] 盾牌场景加载失败: %s" % _mount.SHIELD_SCENE_PATH)
		return
	var off_hand: Node2D = _find_shield_bone(owner_entity)
	if off_hand == null:
		# HD-2D billboard 图（2D 骨架未创建，rig==null）：逻辑盾挂 WeaponMount
		# 自身并隐藏——格挡判定（weapon_block 只看 _shield 实例存在性）由此
		# 真实生效；本实例不进任何渲染（billboard 视觉由 char_rig_3d 镜像
		# 挂盾，数据与状态留 2D 侧、渲染走镜像）。2D 图走到这里 = 骨骼缺失，仍告警。
		if owner_entity.get("rig") == null:
			_mount._shield = scene.instantiate() as Node2D
			_mount._shield.name = "Shield"
			_mount._shield.visible = false
			_mount.add_child(_mount._shield)
		else:
			push_warning("[WeaponMount] 未找到副手骨骼（hand_outer），无法挂盾")
		return
	_mount._shield = _mount_one(scene, off_hand, "Shield")


## 挂载单个物品到骨骼，GripPoint 对齐握把。
## GripPoint = 纹理像素坐标（贴图中心为原点，即"手抓在贴图哪个点"），
## 来自解包附件数据换算（推导见各武器 tscn 头注释）。经 Sprite 的缩放+旋转
## 映射到武器根空间后取负，使握点精确落在挂载骨骼原点（手）上。
## 武器根自身不旋转，朝向完全由 Sprite.rotation 承担——旧实现把
## -grip.rotation 写在挂载根上、且映射忽略 Sprite 旋转，对带 ±90° 的
## 矛/镐/杖握点必错（跨栈翻译保真度审计 2026-08-30 修复）。
func _mount_one(scene: PackedScene, bone: Node2D, node_name: String) -> Node2D:
	var instance: Node2D = scene.instantiate()
	var grip := instance.get_node_or_null("GripPoint") as Marker2D
	var spr := instance.get_node_or_null("Sprite") as Sprite2D
	if grip != null and spr != null:
		instance.position = -(grip.position * spr.scale).rotated(spr.rotation)
	instance.name = node_name
	bone.add_child(instance)
	# 层级跟随单位所在带（EntityHost z=3）：相对层级 + 树序近似 SWL 槽序。
	# 旧写法 z_as_relative=false 是"绝对 z"——武器 -2 掉到所有地图瓦片层
	# （地面 0/装饰 1/建筑 2）之下、盾 20 压过前景层 10，武器被地面盖住。
	# 全局两遍渲染（stickman_skeleton.gd）下肢体填充层相对 z 最高 0，
	# 武器/盾取 +7 盖全身肢体；树序盾挂外臂
	# subtree（后画）盖武器——保持"盾 > 武器"的原语义。全局 z=10 与
	# 地图前景层同值：树序单位在后，仅武器尖角过前景支柱时轻微盖柱
	# （身体仍正确被前景遮挡）。
	instance.z_index = 7
	instance.z_as_relative = true
	return instance


## 惰性连接 rig.animation_event（Spine events[] 复刻信号）+ animation_finished（治疗动画收尾）。
func _connect_rig_events(owner_entity: Node) -> void:
	var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
	if rig == null or not rig.has_signal("animation_event"):
		return
	if rig.animation_event.is_connected(_mount._on_rig_anim_event):
		return
	rig.animation_event.connect(_mount._on_rig_anim_event)
	# 治疗动画播完收尾（P7 批次 7b：heal_meric_* 结束 → _heal_anim_playing = false）
	if rig.has_signal("animation_finished") \
			and not rig.animation_finished.is_connected(_mount._on_rig_animation_finished):
		rig.animation_finished.connect(_mount._on_rig_animation_finished)


## Spine 事件 string（"Swoosh"/"Thump"/"MagikillBlast"…）→ AudioManager 语义事件名。
## 取值与动画 metadata/anim_events 的 Sound.string 同名同源。**这里不再自带音效路径表**：
## 资产与播放策略（节流/合并/优先级/抖动/定位）全部收口到
## AudioManager.SFX_EVENTS / SFX_POLICY（唯一真相源），否则绕过者会让合并策略形同虚设。
## 缺表项 = 该事件只转发信号、不发声（不会出现加载报错）。
const SFX_EVENT_NAMES: Dictionary = {
	"Swoosh":        "weapon_swoosh",
	"headbutt1":     "weapon_headbutt",
	"MagikillBlast": "weapon_blast",
	"Thump":         "weapon_thump",
	"fall":          "weapon_fall",
	"clang":         "weapon_clang",
}

func play_event_sfx(sfx_name: String) -> void:
	var event_name: String = SFX_EVENT_NAMES.get(sfx_name, "")
	if event_name.is_empty():
		return
	# 世界坐标交给 AudioManager：spatial 事件据此做距离衰减与左右定位
	AudioManager.play_event(event_name, _mount.global_position)


## 查找武器骨 weapon_hand（SWL pickaxe1 补译；挂 hand_inner 手骨原点，
## 挥剑时武器随腕甩动——动画经 pickaxe1 通道驱动该骨旋转）。
func _find_hand_bone(owner_entity: Node2D) -> Node2D:
	var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
	if rig == null:
		return null
	return rig.get_node_or_null("hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_inner/forearm_inner/hand_inner/weapon_hand")


## 查找盾骨 shield_hand（SWL Arrow1 补译；挂 hand_outer 手骨原点，
## 拉弓/举盾的动画经 Arrow1 通道驱动该骨）。
func _find_shield_bone(owner_entity: Node2D) -> Node2D:
	var rig: Node = owner_entity.get("rig") if "rig" in owner_entity else null
	if rig == null:
		return null
	return rig.get_node_or_null("hip/spine_root/lower_torso/chest_mid/upper_torso/upper_arm_outer/forearm_outer/hand_outer/shield_hand")
