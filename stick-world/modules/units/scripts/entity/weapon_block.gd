extends RefCounted
## 持盾格挡助手 —— 从 weapon_mount.gd 拆出的格挡判定子域（无自持状态）。
##
## 职责：is_shield_blocking 判定本体（复刻原版三件套：盾存在 ∧ 举盾姿态 ∧
## 正面扇区，外加 blockResetInterval 节流 + blockChance 概率掷骰）/
## notify_block_succeeded 成功格挡后的重置节流。
##
## 纪律：状态（_shield/_blocking/_block_reset_timer/BLOCK_* 数值）全部留在
## 宿主 WeaponMount，经 _mount 动态回引读写；判定原语（正面扇区/掷骰）在
## BlockResolver（class_name，裸用）。宿主侧 is_shield_blocking /
## notify_block_succeeded 保留转发 facade——DamagePipeline duck 入口签名不可变。

var _mount  ## 宿主 WeaponMount（动态回引；状态唯一真相源在宿主）


func _init(mount) -> void:
	_mount = mount


## 持盾格挡判定本体（被攻击方调用；DamagePipeline 的格挡入口）。
## 复刻原版三件套，缺一不可：
##   ① 装备了盾（持盾单位才可能挡）
##   ② **处于举盾姿态** IsBlocking()——原版不是无条件概率，Spearton 要真的举盾才挡
##   ③ 伤害来自**正面**（CanBlockAttack() 的姿态/方向判定）
## 外加 blockResetInterval 节流：刚格挡过的一段时间内不能再挡。
## incoming_dir: 攻击者→受击者方向；留空（零向量）时跳过正面判定。
func is_shield_blocking(incoming_dir: Vector2 = Vector2.ZERO) -> bool:
	if _mount._shield == null or not is_instance_valid(_mount._shield):
		return false
	if not _mount._blocking:
		return false
	if _mount._block_reset_timer > 0.0:
		return false
	var facing := _owner_facing_value()
	if not BlockResolver.is_frontal(incoming_dir, facing, _mount.BLOCK_FRONT_DOT):
		return false
	return BlockResolver.roll_block(_mount.BLOCK_CHANCE)


## 标记一次成功格挡（由 DamagePipeline 调用）：启动 blockResetInterval 冷却，
## 防止高攻速单位被同一面盾连续无限吃掉伤害。
func notify_block_succeeded() -> void:
	_mount._block_reset_timer = _mount.BLOCK_RESET_INTERVAL


## 正面判定：来袭方向（攻击者→自己）与自身朝向相反 ⇒ 从正面打来。
## facing=+1 面向右 ⇒ 来自右侧的攻击（incoming_dir.x > 0）是正面。
func _is_frontal(incoming_dir: Vector2) -> bool:
	return BlockResolver.is_frontal(incoming_dir, _owner_facing_value(), _mount.BLOCK_FRONT_DOT)


## 持有实体朝向（缺省 1.0 = 面向右）
func _owner_facing_value() -> float:
	var owner_entity: Node = _mount.get_owner_entity()
	if owner_entity != null and owner_entity.has_method("get_facing"):
		return float(owner_entity.get_facing())
	return 1.0
