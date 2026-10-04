class_name InventoryService
extends Node
## 背包服务 —— 玩家背包持有者 + 装备→实体桥接（模块对外的运行时中枢）。
##
## 职责（设计文档 docs/设计/系统/14-背包与装备系统.md §2.3）：
##   1. 持有唯一的玩家 PlayerInventory（背包跟着玩家走，不跟火柴人）
##   2. 监听装备变化 → 写入当前附身实体（weapon_type / 盾 / 护甲聚合 /
##      武器 stats 乘子——attack_mult/speed_mult 经 weapon_mount 乘子字段生效）
##   3. 附身边界：附身记录实体原武器状态，脱离恢复（NPC 不感知背包）
##   4. 消耗品使用效果（绷带治疗 → 附身实体）
##   5. 初始装备发放 + 存档序列化（world_state 表 module_name="inventory"，
##      game_saving/game_loaded 信号直写——WorldState 同款契约）
## SystemSetup 装配后挂 GameRoot 下。

## 徒手武器类型（对齐 WeaponMount.WeaponType.NONE=6；本地常量防跨模块
## class_name 依赖成环——units 侧经 RegionStorage 依赖本模块的物品域）
const WEAPON_TYPE_NONE: int = 6

## 开局装备（发放后自动穿上）
const STARTER_EQUIP: Array[StringName] = [
	&"wpn_sword_001", &"shd_wood_001",
	&"arm_head_cloth", &"arm_chest_cloth", &"arm_legs_cloth",
]
## 开局背包（原型全武器开放原则：与玩家全能换装的自由度等价）
const STARTER_PACK: Array = [
	[&"wpn_spear_001", 1], [&"wpn_bow_001", 1], [&"wpn_pickaxe_001", 1],
	[&"wpn_staff_001", 1], [&"con_bandage", 5],
]
## 开局 Hotbar 预指派（1-6：五武器+绷带——滚轮/数字键即刻可切）
const STARTER_HOTBAR: Array[StringName] = [
	&"wpn_sword_001", &"wpn_spear_001", &"wpn_bow_001",
	&"wpn_pickaxe_001", &"wpn_staff_001", &"con_bandage",
]

var inventory: PlayerInventory = null

var _game_root: Node = null
## 当前桥接的附身实体（null = 未附身，装备变化只改数据不落地）
var _entity: Node = null
## 附身前的实体武器状态（脱离时恢复）
var _orig_weapon_type: int = -1
var _orig_shield_enabled: bool = true

# SQL 白名单（world_state 表与 WorldState 同契约；模块数据通道）
const _SQL_SELECT := "SELECT data FROM world_state WHERE slot_id = ? AND module_name = 'inventory'"
const _SQL_DELETE := "DELETE FROM world_state WHERE slot_id = ? AND module_name = 'inventory'"


func _init() -> void:
	inventory = PlayerInventory.new()


func setup(game_root: Node) -> void:
	_game_root = game_root
	inventory.equipment_changed.connect(_apply_equipment_to_entity)
	inventory.item_used.connect(_on_item_used)
	if EventBus != null:
		EventBus.possession_started.connect(_on_possession_started)
		EventBus.possession_ended.connect(_on_possession_ended)
		if EventBus.has_signal("game_saving"):
			EventBus.game_saving.connect(_on_game_saving)
		if EventBus.has_signal("game_loaded"):
			EventBus.game_loaded.connect(_on_game_loaded)
	grant_starter_kit()


# ─────────────────────────────── 对外操作 ────────────────────────────────

## 数字键 1-9/0 / Hotbar 点击使用指派格（武器=换装，消耗品=使用需附身实体承接）。
## 返回发生动作的物品 id（空 StringName = 无事发生）
func use_hotbar_slot(index: int) -> StringName:
	var id: StringName = inventory.hotbar[index] if index >= 0 and index < PlayerInventory.HOTBAR_SIZE else &""
	if id == &"":
		return &""
	var def: ItemDef = ItemDB.get_def(id)
	# 消耗品需要附身实体承接治疗效果；武器换装随时可行
	if def != null and def.category == ItemDef.Category.CONSUMABLE \
			and (_entity == null or not is_instance_valid(_entity)):
		return &""
	return inventory.use_hotbar_slot(index)


## 滚轮切换武器（附身态滚轮语义，09 文档 §二）：循环下一个武器指派格并换装
func cycle_weapon(dir: int) -> StringName:
	return inventory.hotbar_cycle_weapon(dir)


# ─────────────────────────────── 附身边界 ────────────────────────────────

func _on_possession_started(entity: Node) -> void:
	_entity = entity
	var wm: Node = _get_weapon_mount(entity)
	if wm != null:
		_orig_weapon_type = int(wm.weapon_type)
		_orig_shield_enabled = bool(wm.shield_enabled)
	_apply_equipment_to_entity()


func _on_possession_ended(entity: Node) -> void:
	# 恢复实体原武器状态（背包装备只属于玩家）
	var wm: Node = _get_weapon_mount(entity)
	if wm != null and _orig_weapon_type >= 0:
		wm.equipped_shield = false
		wm.shield_enabled = _orig_shield_enabled
		wm.weapon_type = _orig_weapon_type
		# 装备乘子一并复位（NPC 回兵种基准数值）
		if "equip_attack_mult" in wm:
			wm.equip_attack_mult = 1.0
		if "equip_speed_mult" in wm:
			wm.equip_speed_mult = 1.0
	if entity != null and is_instance_valid(entity) and "armor_speed_factor" in entity:
		entity.armor_speed_factor = 1.0
		entity.armor_damage_reduction = 0.0
	_entity = null


## 装备落地：主手武器 → weapon_type + stats 乘子；副手盾 → equipped_shield；
## 护甲三件 → 减伤率 + 移速乘子（写实体字段，DamagePipeline/移速链消费）
func _apply_equipment_to_entity() -> void:
	if _entity == null or not is_instance_valid(_entity):
		return
	var wm: Node = _get_weapon_mount(_entity)
	if wm != null:
		var weapon: ItemStack = inventory.get_main_weapon()
		var wdef: ItemDef = weapon.def() if weapon != null and not weapon.is_empty() else null
		if wdef != null:
			wm.weapon_type = wdef.weapon_type
			# 武器 stats 乘子（数据化应用：attack_mult/speed_mult 经乘子字段
			# 生效，不动基础值——battle_sim 校准锚点零影响，附身实体专属）
			if "equip_attack_mult" in wm:
				wm.equip_attack_mult = maxf(0.05, wdef.stat("attack_mult", 1.0))
			if "equip_speed_mult" in wm:
				wm.equip_speed_mult = maxf(0.05, wdef.stat("speed_mult", 1.0))
		else:
			wm.weapon_type = WEAPON_TYPE_NONE
			if "equip_attack_mult" in wm:
				wm.equip_attack_mult = 1.0
			if "equip_speed_mult" in wm:
				wm.equip_speed_mult = 1.0
		# 附身期间兵种默认盾让位装备语义（否则矛兵卸盾后模型还在）；
		# 脱离时 _on_possession_ended 恢复原 shield_enabled
		wm.shield_enabled = false
		wm.equipped_shield = inventory.has_shield()
	if "armor_speed_factor" in _entity:
		_entity.armor_speed_factor = inventory.armor_speed_factor()
		_entity.armor_damage_reduction = inventory.armor_damage_reduction()


# ─────────────────────────────── 消耗品效果 ────────────────────────────────

## 物品使用效果分派（当前仅治疗类）
func _on_item_used(def_id: StringName) -> void:
	var def: ItemDef = ItemDB.get_def(def_id)
	if def == null:
		return
	match def.category:
		ItemDef.Category.CONSUMABLE:
			_apply_heal(def)


## 治疗类消耗品：回复附身实体生命（StatusEffects 正向入口，不走 DamagePipeline）
func _apply_heal(def: ItemDef) -> void:
	var amount: float = def.stat("heal_amount", 0.0)
	if amount <= 0.0 or _entity == null or not is_instance_valid(_entity):
		return
	var health: Node = _entity.get_node_or_null("HealthComponent") \
			if _entity.has_method("get_node_or_null") else null
	if health != null and health.has_method("heal"):
		health.heal(amount)


# ─────────────────────────────── 初始物品 / 序列化 ────────────────────────────────

## 开局发放：先装备基础套装，背包再放全武器 + 绷带，Hotbar 预指派
func grant_starter_kit() -> void:
	for id in STARTER_EQUIP:
		inventory.add_item(id, 1)
		inventory.equip_from_backpack(id)
	for pair in STARTER_PACK:
		inventory.add_item(pair[0], int(pair[1]))
	for i in mini(STARTER_HOTBAR.size(), PlayerInventory.HOTBAR_SIZE):
		inventory.hotbar_assign(i, STARTER_HOTBAR[i])


## 存档回调：背包/装备/Hotbar 指派写 world_state 表（module_name="inventory"）
func _on_game_saving(_slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	var slot_id: int = SaveManager.get_current_slot() if SaveManager and SaveManager.has_method("get_current_slot") else -1
	if db == null or slot_id < 0:
		return
	db.query_with_bindings(_SQL_DELETE, [slot_id])
	if not db.insert_row("world_state", {
		"slot_id": slot_id,
		"module_name": "inventory",
		"data": JSON.stringify(inventory.to_dict()),
	}):
		push_error("[InventoryService] 背包存档写入失败 slot=%d: %s" % [slot_id, str(db.error_message)])


## 读档回调：从 world_state 表恢复（无行=新档，保持开局发放结果）
func _on_game_loaded(slot_index: int) -> void:
	var db = SaveManager.get_db() if SaveManager and SaveManager.has_method("get_db") else null
	if db == null:
		return
	var rows: Array = []
	if db.query_with_bindings(_SQL_SELECT, [slot_index]):
		rows = db.query_result
	if rows.is_empty():
		return
	var parsed = JSON.parse_string(str(rows[0]["data"]))
	if typeof(parsed) == TYPE_DICTIONARY:
		inventory.from_dict(parsed)


func to_dict() -> Dictionary:
	return inventory.to_dict()


func from_dict(d: Dictionary) -> void:
	inventory.from_dict(d)


# ─────────────────────────────── 内部 ────────────────────────────────

func _get_weapon_mount(entity: Node) -> Node:
	if entity == null or not is_instance_valid(entity):
		return null
	return entity.get_node_or_null("WeaponMount")
