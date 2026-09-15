extends RefCounted
## 武器数值校准助手 —— 从 weapon_mount.gd 拆出的 static 函数库（无实例状态）。
##
## 职责（触发时机不变，仍由 WeaponMount._reload_weapons 尾部调用）：
## - apply(mount)：按武器类型从 BalanceConfig 读 SWL 真值覆盖 mount @export 默认
##   （P5 批次 2）+ 全局手感调参（balance.variables 弹道/格挡/HITSTOP/击退）
##   + 冷却 vs 攻击动画的约束校验告警（9d 检查项）；
## - check_cooldown_vs_anim(mount)：冷却 ≥ 命中帧硬约束 / 冷却 < 动画全长软提示。
##
## 纪律：读 BalanceConfig 写回 mount 字段；状态（_hp_calibrated 等）留在 mount。

## 武器类型 → 兵种数值 def（config/units/stickmen.tres 行 id）。
## 键 = WeaponMount.WeaponType 枚举值的本地等值整数（int 键查表与枚举键逐位等价）：
##   SWORD=0, SPEAR=1, BOW=2, PICKAXE=3, STAFF=4, MERIC=5（NONE=6 无 def 不入表）。
## 先例（behavior_profiles.gd）：本地常量避免跨类依赖。
## P5 数值校准：HP/伤害/冷却以 SWL wiki Normal 模式面板值为真值落表，
## 武器挂载在 _reload_weapons 时按此映射读 BalanceConfig 覆盖 @export 默认。
const WEAPON_DEF_ID: Dictionary = {
	0: "stm_sword_001",  ## WeaponType.SWORD
	1: "stm_spear_001",  ## WeaponType.SPEAR
	2: "stm_bow_001",    ## WeaponType.BOW
	3: "stm_miner_001",  ## WeaponType.PICKAXE
	4: "stm_staff_001",  ## WeaponType.STAFF
	5: "stm_meric_001",  ## WeaponType.MERIC
}

## 冷却 vs 动画检查告警去重（每武器类型只告警一次，防逐单位刷屏）
static var _cooldown_warned: Dictionary = {}


## 从 BalanceConfig 读兵种数值并覆盖（读不到/未装载保持 @export 默认，零回归）。
## 数据源：stickmen.tres SWL 校准行（P5 批次 2，namu wiki Normal 模式面板值）。
## 整行读取（get_value(行路径) 返回行字典）——逐字段 get_value 会对缺列行刷警告。
static func apply(mount) -> void:
	if BalanceConfig == null or BalanceConfig.data.is_empty():
		return  # 独立测试场景未装载 BalanceConfig（system_setup 未跑），跳过避免刷警告
	var def_id: String = str(WEAPON_DEF_ID.get(mount.weapon_type, ""))
	if def_id.is_empty():
		return
	var row_v: Variant = BalanceConfig.get_value("units.stickmen." + def_id)
	if not (row_v is Dictionary):
		return
	var row: Dictionary = row_v
	# Excel 空单元格经管线导出为 null：float(null) 会抛"Nonexistent float constructor"，
	# 数值列统一先判 null 再转换，缺列/空值保持代码默认（零回归）
	if _num_or_zero(row, "base_attack") > 0.0:
		mount.damage = _num_or_zero(row, "base_attack")
	if _num_or_zero(row, "attack_cooldown") > 0.0:
		mount.cooldown = _num_or_zero(row, "attack_cooldown")
	if row.get("head_shot_bonus_damage") != null:
		mount.head_shot_bonus_damage = _num_or_zero(row, "head_shot_bonus_damage")
	if not mount._hp_calibrated and _num_or_zero(row, "base_hp") > 0.0:
		var hp: float = _num_or_zero(row, "base_hp")
		var owner_entity: CharacterBody2D = mount.get_owner_entity()
		if owner_entity != null and owner_entity.has_method("get_health"):
			var health: Node = owner_entity.get_health()
			if health != null and "max_hp" in health:
				health.max_hp = hp
				# 满血基线只写活体：deferred 校准可能落在出生帧之后，若单位已死
				#（同帧接敌/陷阱/溅射），回写 hp 会把尸体复活成满血——只校准上限
				if not (health.has_method("is_dead") and health.is_dead()):
					health.hp = hp
			mount._hp_calibrated = true
	check_cooldown_vs_anim(mount)
	_apply_global_tuning(mount)


## 配置行数值字段安全读取：null/缺键返回 0.0（float(null) 在运行时会抛错）
static func _num_or_zero(row: Dictionary, key: String) -> float:
	var v: Variant = row.get(key)
	if v == null:
		return 0.0
	return float(v)


## 全局手感数值校准：从 balance.variables（Excel 平衡变量表 var_* 行）读
## 弹道/格挡/HITSTOP/击退覆盖代码默认。行缺失保持默认，零回归。
static func _apply_global_tuning(mount) -> void:
	var rows_v: Variant = BalanceConfig.get_value("balance.variables")
	if not (rows_v is Array):
		return
	var by_id := {}
	for tuning_row: Dictionary in rows_v:
		if tuning_row.has("id"):
			by_id[tuning_row["id"]] = tuning_row.get("value")
	mount.ARROW_VX = _tuned(by_id, "var_arrow_vx", mount.ARROW_VX)
	mount.ARROW_GRAVITY = _tuned(by_id, "var_arrow_gravity", mount.ARROW_GRAVITY)
	mount.ARROW_LEAD_FACTOR = _tuned(by_id, "var_arrow_lead_factor", mount.ARROW_LEAD_FACTOR)
	mount.BLOCK_CHANCE = _tuned(by_id, "var_block_chance", mount.BLOCK_CHANCE)
	mount.BLOCK_DAMAGE_FACTOR = _tuned(by_id, "var_block_damage_factor", mount.BLOCK_DAMAGE_FACTOR)
	mount.BLOCK_RESET_INTERVAL = _tuned(by_id, "var_block_reset_interval", mount.BLOCK_RESET_INTERVAL)
	mount.BLOCK_FRONT_DOT = _tuned(by_id, "var_block_front_dot", mount.BLOCK_FRONT_DOT)
	mount.HITSTOP_TIME_SCALE = _tuned(by_id, "var_hitstop_time_scale", mount.HITSTOP_TIME_SCALE)
	mount.HITSTOP_DURATION = _tuned(by_id, "var_hitstop_duration", mount.HITSTOP_DURATION)
	mount.HITSTOP_MIN_INTERVAL = _tuned(by_id, "var_hitstop_min_interval", mount.HITSTOP_MIN_INTERVAL)
	mount.KNOCKBACK_PER_DAMAGE = _tuned(by_id, "var_knockback_per_damage", mount.KNOCKBACK_PER_DAMAGE)


## 单变量取值：行存在且 value 为数值时返回 value，否则回退 fallback
static func _tuned(by_id: Dictionary, id: String, fallback: float) -> float:
	var v: Variant = by_id.get(id)
	return float(v) if (v is float or v is int) else fallback


## 9d 检查项：冷却与攻击动画的约束校验。
## 硬约束：冷却 ≥ 命中帧时间（否则动画没挥到命中帧就重挥，永远打不出伤害）；
## 软提示：冷却 < 动画全长为原版合法语义——命中帧后尾段可被打断
## （AnimationCancelFraction；原版剑士攻速 1.0/s vs 攻击动画 1.33s 即同款）。
static func check_cooldown_vs_anim(mount) -> void:
	var owner_entity: CharacterBody2D = mount.get_owner_entity()
	if owner_entity == null or not "rig" in owner_entity:
		return
	var rig: Node = owner_entity.get("rig")
	if rig == null or not rig.has_method("get_anim_length"):
		return
	mount._resolve_hit_event_time()
	var anim_name: String = mount._attack_anim_name()
	var anim_len: float = rig.get_anim_length(anim_name)
	if anim_len <= 0.0:
		return
	if mount._hit_event_time >= 0.0 and mount.cooldown < mount._hit_event_time:
		if not _cooldown_warned.has(mount.weapon_type):
			_cooldown_warned[mount.weapon_type] = true
			push_warning("[WeaponMount] 冷却 %.2fs < 命中帧 %.2fs（%s）：命中帧前重挥，永远打不出伤害" % [mount.cooldown, mount._hit_event_time, anim_name])
	elif mount.cooldown < anim_len:
		if not _cooldown_warned.has(mount.weapon_type):
			_cooldown_warned[mount.weapon_type] = true
			push_warning("[WeaponMount] 冷却 %.2fs < 攻击动画时长 %.2fs（%s）：依赖命中帧后打断语义（原版剑士同款）" % [mount.cooldown, anim_len, anim_name])
