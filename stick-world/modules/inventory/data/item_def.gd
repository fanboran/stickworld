class_name ItemDef
extends Resource
## 物品静态定义（背包与装备系统，docs/设计/系统/背包与装备系统.md §2.2）。
##
## 定义"一件物品是什么"；运行时数量归 ItemStack。当前真相源是 ItemDB 内置
## 注册表（GDScript 定义），excel 管线支持类型化导出后迁 .tres。

## 物品大类（决定可装备槽位与 UI 行为）
enum Category {
	WEAPON,       ## 武器 → 主手（two_handed 占副手）
	SHIELD,       ## 盾 → 副手
	ARMOR_HEAD,   ## 头部护甲
	ARMOR_CHEST,  ## 胸部护甲
	ARMOR_LEGS,   ## 腿部护甲
	CONSUMABLE,   ## 消耗品（Hotbar 数字键使用）
	MATERIAL,     ## 材料（仅堆叠存放）
}

@export var id: StringName = &""
@export var display_name: String = ""
@export var category: Category = Category.MATERIAL
## 图标（null 时 UI 按 category 程序绘简笔占位，零美术资产依赖）
@export var icon: Texture2D = null
## 最大堆叠数（装备类 = 1 不可堆叠；消耗品/材料 99）
@export var max_stack: int = 1
## WEAPON 专用：映射 WeaponMount.WeaponType（-1 = 非武器）
@export var weapon_type: int = -1
## WEAPON 专用：双手武器（弓）——装入主手时锁定副手，盾自动卸回背包
@export var two_handed: bool = false
## 数值参数（键语义沿用 excel weapons/armors 表：attack_mult / speed_mult /
## damage_reduction / speed_penalty / heal_amount…）。武器侧只入数据不应用
## （战斗数值由 BalanceConfig 校准管，见设计文档 §2.4）
@export var stats: Dictionary = {}
@export var description: String = ""


## 是否装备类（占独立装备槽，不可堆叠）
func is_equipment() -> bool:
	return category in [Category.WEAPON, Category.SHIELD,
			Category.ARMOR_HEAD, Category.ARMOR_CHEST, Category.ARMOR_LEGS]


## 数值安全读取（stats 缺键/类型不符回退默认）
func stat(key: String, fallback: float) -> float:
	var v: Variant = stats.get(key)
	return float(v) if (v is float or v is int) else fallback
