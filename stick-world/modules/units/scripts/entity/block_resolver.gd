class_name BlockResolver
extends RefCounted
## 盾牌格挡判定 —— 从 weapon_mount 拆出的纯判定函数簇（无状态）。
##
## 概率掷骰（原版 blockChance）与正面扇区判定；调用方（WeaponMount）持有
## 盾存在性/举盾姿态/重置计时器等状态门控，判定通过后调 resolver 掷骰。

## 正面判定：来袭方向（攻击者→自己）与自身朝向相反 ⇒ 从正面打来。
## facing=+1 面向右 ⇒ 来自右侧的攻击（incoming_dir.x > 0）是正面。
## incoming_dir 为零向量（未知方向）视为正面。
static func is_frontal(incoming_dir: Vector2, facing: float, front_dot: float) -> bool:
	if incoming_dir == Vector2.ZERO:
		return true
	if facing == 0.0:
		return true
	return incoming_dir.normalized().dot(Vector2(signf(facing), 0.0)) >= front_dot


## 格挡掷骰（原版 blockChance 概率语义）
static func roll_block(chance: float) -> bool:
	return randf() < chance
