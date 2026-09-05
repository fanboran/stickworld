class_name InventoryService
extends Node
## 背包服务 —— 玩家背包持有者 + 装备→实体桥接（模块对外的运行时中枢）。
##
## 职责（设计文档 docs/设计/系统/背包与装备系统.md §2.4/§2.6）：
##   1. 持有唯一的玩家 PlayerInventory（背包跟着玩家走，不跟火柴人）
##   2. 监听装备变化 → 写入当前附身实体（weapon_type / 盾 / 护甲聚合）
##   3. 附身边界：附身记录实体原武器状态，脱离恢复（NPC 不感知背包）
##   4. 消耗品使用效果（绷带治疗 → 附身实体）
##   5. 初始装备发放 + 存档序列化转发
## SystemSetup 装配后挂 GameRoot 下。

## 开局装备（发放后自动穿上）
const STARTER_EQUIP: Array[StringName] = [
	&"wpn_sword_001", &"shd_wood_001",
	&"arm_head_cloth", &"arm_chest_cloth", &"arm_legs_cloth",
]
## 开局背包（原型全武器开放原则：与旧 1-5 直切等价的自由度）
const STARTER_PACK: Array = [
	[&"wpn_spear_001", 1], [&"wpn_bow_001", 1], [&"wpn_pickaxe_001", 1],
	[&"wpn_staff_001", 1], [&"con_bandage", 5],
]

var inventory: PlayerInventory = null

var _game_root: Node = null
## 当前桥接的附身实体（null = 未附身，装备变化只改数据不落地）
var _entity: Node = null
## 附身前的实体武器状态（脱离时恢复）
var _orig_weapon_type: int = -1
var _orig_shield_enabled: bool = true


func _init() -> void:
	inventory = PlayerInventory.new()


func setup(game_root: Node) -> void:
	_game_root = game_root
	inventory.equipment_changed.connect(_apply_equipment_to_entity)
	inventory.item_used.connect(_on_item_used)
	if EventBus != null:
		EventBus.possession_started.connect(_on_possession_started)
		EventBus.possession_ended.connect(_on_possession_ended)
	grant_starter_kit()


# ─────────────────────────────── 对外操作 ────────────────────────────────

## 数字键 1-4 / Hotbar 点击使用物品（需有附身实体承接效果）。
## 返回使用的物品 id（空 StringName = 无事发生）
func use_hotbar_item(index: int) -> StringName:
	if _entity == null or not is_instance_valid(_entity):
		return &""
	return inventory.use_hotbar_item(index)


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
	if entity != null and is_instance_valid(entity) and "armor_speed_factor" in entity:
		entity.armor_speed_factor = 1.0
		entity.armor_damage_reduction = 0.0
	_entity = null


## 装备落地：主手武器 → weapon_type；副手盾 → equipped_shield；
## 护甲三件 → 减伤率 + 移速乘子（写实体字段，DamagePipeline/移速链消费）
func _apply_equipment_to_entity() -> void:
	if _entity == null or not is_instance_valid(_entity):
		return
	var wm: Node = _get_weapon_mount(_entity)
	if wm != null:
		var weapon: ItemStack = inventory.get_main_weapon()
		if weapon != null and not weapon.is_empty() and weapon.def() != null:
			wm.weapon_type = weapon.def().weapon_type
		else:
			wm.weapon_type = WeaponMount.WeaponType.NONE
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

## 开局发放：先装备基础套装，背包再放全武器 + 绷带
func grant_starter_kit() -> void:
	for id in STARTER_EQUIP:
		inventory.add_item(id, 1)
	# 逐件穿上（add 顺序即槽位顺序，can_equip 兜底防意外）
	for i in inventory.slots.size():
		if inventory.can_equip(i):
			inventory.equip_from_backpack(i)
	for pair in STARTER_PACK:
		inventory.add_item(pair[0], int(pair[1]))


func to_dict() -> Dictionary:
	return inventory.to_dict()


func from_dict(d: Dictionary) -> void:
	inventory.from_dict(d)


# ─────────────────────────────── 内部 ────────────────────────────────

func _get_weapon_mount(entity: Node) -> Node:
	if entity == null or not is_instance_valid(entity):
		return null
	return entity.get_node_or_null("WeaponMount")
