class_name InventoryAPI
extends Object
## inventory 模块对外契约（模块间通信只经本文件，架构原则 §3）。
##
## 服务实例由 SystemSetup 装配（GameRoot 子节点 "InventoryService"），
## UI 与其他模块经 GameRoot.inventory_service 或 InventoryAPI.get_service() 访问。
##
## 信号（转发自 PlayerInventory，UI 订阅刷新）：
##   inventory_changed  —— 背包格内容变化
##   equipment_changed  —— 装备槽变化（已同步落地到附身实体）
##   item_used(def_id)  —— 消耗品被使用（效果已结算）


## 取全局背包服务（无则 null；装配见 SystemSetup._setup_inventory）。
## 主链路走 GameRoot.inventory_service 直引；本入口供测试/无 GameRoot 引用处兜底
static func get_service() -> InventoryService:
	var root := Engine.get_main_loop() as SceneTree
	if root == null or root.root == null:
		return null
	return root.root.find_child("InventoryService", true, false) as InventoryService
