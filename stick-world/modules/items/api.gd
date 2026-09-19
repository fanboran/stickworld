class_name ItemsAPI
extends Object
## items 域对外契约（L1 基础设施：零模块依赖，模块间通信只经本文件）。
##
## 物品定义（ItemDef/ItemDB）、容器（ItemContainer）、转移（ItemTransfer）
## 是全项目公共底座；库存场景（玩家背包 inventory 模块 / 区域仓储桥
## RegionStorage / 尸体遗物）都是消费者，不各自造库存结构。
##
## 本文件只放跨域契约：资源品映射（resources.resource_id ↔ ItemDef.id）。
## 定义/容器/转移的 API 直接用各 class_name（纯数据层无装配态）。

## 资源品映射：ItemDef.id → resources.resource_id（村仓 RegionStorage 桥消费：
## 物品语义（离散件/容器）↔ 经济语义（float 台账/供需价格）两层的翻译表）
const RESOURCE_BY_ITEM: Dictionary = {
	&"mat_wood": &"res_wood",
	&"mat_stone": &"res_stone",
	&"mat_iron": &"res_metal_ore",
	&"mat_iron_ingot": &"res_iron_ingot",
	&"mat_silk": &"res_silk",
	&"mat_asphalt": &"res_black_asphalt",
}


## 物品 def 对应的经济资源 id（非资源品返回空 StringName）
static func resource_id_for(def_id: StringName) -> StringName:
	return RESOURCE_BY_ITEM.get(def_id, &"")


## 经济资源 id 对应的物品 def（无映射返回空 StringName）
static func item_id_for(resource_id: StringName) -> StringName:
	for key in RESOURCE_BY_ITEM:
		if RESOURCE_BY_ITEM[key] == resource_id:
			return key
	return &""
