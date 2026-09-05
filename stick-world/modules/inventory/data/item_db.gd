class_name ItemDB
extends Object
## 物品注册表（id → ItemDef）。当前真相源 = 内置 GDScript 定义。
##
## 为什么不是 .tres：excel 管线导出的 BalanceResource 是无类型 variables 字典
## 且 icon_path 全悬空；类型化导出落地后，把 _build_defs() 换成表装载即可迁移
## （设计文档 §2.2）。

## 武器贴图（与战斗场景共用同一来源，图标即实战模型贴图）
const TEX := "res://modules/units/assets/textures/weapons/"

static var _defs: Dictionary = {}
static var _loaded: bool = false


static func get_def(id: StringName) -> ItemDef:
	_ensure_loaded()
	return _defs.get(id, null)


static func all_ids() -> Array:
	_ensure_loaded()
	return _defs.keys()


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_build_defs()


static func _def(id: String, name: String, cat: int, max_stack: int,
		icon_path: String = "", stats: Dictionary = {}, weapon_type: int = -1,
		two_handed: bool = false, desc: String = "") -> void:
	var d := ItemDef.new()
	d.id = StringName(id)
	d.display_name = name
	d.category = cat as ItemDef.Category
	d.max_stack = max_stack
	if not icon_path.is_empty():
		d.icon = load(TEX + icon_path)
	d.stats = stats
	d.weapon_type = weapon_type
	d.two_handed = two_handed
	d.description = desc
	_defs[d.id] = d


static func _build_defs() -> void:
	# ── 武器（weapon_type 对齐 WeaponMount.WeaponType；MERIC 祭司专用不开放）──
	_def("wpn_sword_001", "铁剑", ItemDef.Category.WEAPON, 1, "sword.png",
			{"attack_mult": 1.2, "speed_mult": 0.9, "weight": 5}, 0, false,
			"制式铁剑。挥砍均衡，士兵的可靠伙伴。")
	_def("wpn_spear_001", "长矛", ItemDef.Category.WEAPON, 1, "spear.png",
			{"attack_mult": 1.0, "speed_mult": 0.95, "weight": 6}, 1, false,
			"长柄矛。距离优势明显，列阵时是铜墙铁壁。")
	_def("wpn_bow_001", "短弓", ItemDef.Category.WEAPON, 1, "bow.png",
			{"attack_mult": 0.8, "speed_mult": 1.0, "weight": 2}, 2, true,
			"双手武器。抛物线越顶抛射，装备时无法持盾。")
	_def("wpn_pickaxe_001", "铁镐", ItemDef.Category.WEAPON, 1, "pickaxe.png",
			{"attack_mult": 0.6, "speed_mult": 1.0, "weight": 4}, 3, false,
			"采矿镐。敲石头顺手，敲人勉强。")
	_def("wpn_staff_001", "学徒法杖", ItemDef.Category.WEAPON, 1, "magicstaff.png",
			{"attack_mult": 1.0, "speed_mult": 0.8, "weight": 3}, 4, false,
			"施法媒介。不可格挡的魔法飞弹。")
	# ── 盾 ──
	_def("shd_wood_001", "木盾", ItemDef.Category.SHIELD, 1, "shield.png",
			{"weight": 6}, -1, false,
			"左手圆盾。按住右键举盾格挡正面来袭。")
	# ── 护甲（damage_reduction 单件减伤率 / speed_penalty 移速乘子）──
	_def("arm_head_cloth", "布头巾", ItemDef.Category.ARMOR_HEAD, 1, "",
			{"damage_reduction": 0.04, "speed_penalty": 1.0, "weight": 1})
	_def("arm_chest_cloth", "布衣", ItemDef.Category.ARMOR_CHEST, 1, "",
			{"damage_reduction": 0.05, "speed_penalty": 1.0, "weight": 2})
	_def("arm_legs_cloth", "布腿带", ItemDef.Category.ARMOR_LEGS, 1, "",
			{"damage_reduction": 0.04, "speed_penalty": 1.0, "weight": 1})
	_def("arm_head_leather", "皮盔", ItemDef.Category.ARMOR_HEAD, 1, "",
			{"damage_reduction": 0.08, "speed_penalty": 0.99, "weight": 2})
	_def("arm_chest_leather", "皮甲", ItemDef.Category.ARMOR_CHEST, 1, "",
			{"damage_reduction": 0.10, "speed_penalty": 0.98, "weight": 3})
	_def("arm_legs_leather", "皮护胫", ItemDef.Category.ARMOR_LEGS, 1, "",
			{"damage_reduction": 0.08, "speed_penalty": 0.99, "weight": 2})
	_def("arm_head_mail", "锁子头罩", ItemDef.Category.ARMOR_HEAD, 1, "",
			{"damage_reduction": 0.14, "speed_penalty": 0.96, "weight": 4})
	_def("arm_chest_mail", "锁子甲", ItemDef.Category.ARMOR_CHEST, 1, "",
			{"damage_reduction": 0.18, "speed_penalty": 0.94, "weight": 6})
	_def("arm_legs_mail", "锁子护腿", ItemDef.Category.ARMOR_LEGS, 1, "",
			{"damage_reduction": 0.14, "speed_penalty": 0.96, "weight": 4})
	# ── 消耗品 ──
	_def("con_bandage", "绷带", ItemDef.Category.CONSUMABLE, 99, "",
			{"heal_amount": 30.0}, -1, false,
			"简单包扎，回复 30 点生命。数字键或点击 Hotbar 使用。")
