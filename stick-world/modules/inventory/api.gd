class_name InventoryAPI
extends Object
## inventory 模块对外契约（模块间通信只经本文件，架构原则 §3）。
##
## 服务实例由模块自装配器装配（setup.gd::assemble，SystemSetup 步骤表「背包」
## 步骤编排；GameRoot 子节点 "InventoryService"），
## UI 与其他模块经 GameRoot.inventory_service 或 InventoryAPI.get_service() 访问。
##
## 信号（转发自 PlayerInventory，UI 订阅刷新）：
##   inventory_changed  —— 背包格内容变化
##   equipment_changed  —— 装备槽变化（已同步落地到接管实体）
##   item_used(def_id)  —— 消耗品被使用（效果已结算）


## 取全局背包服务（无则 null；装配见本模块 setup.gd）。
## 主链路走 GameRoot.inventory_service 直引；本入口供测试/无 GameRoot 引用处兜底
static func get_service() -> InventoryService:
	var root := Engine.get_main_loop() as SceneTree
	if root == null or root.root == null:
		return null
	return root.root.find_child("InventoryService", true, false) as InventoryService


## 打开容器双栏界面（翻包/村仓共用；屏幕由本模块 setup 注册到服务）。
## 返回是否真正打开（服务/屏幕未就绪 → false，调用方无需自行找节点）。
static func open_container_screen(container: ItemContainer, title: String) -> bool:
	var service := get_service()
	if service == null:
		return false
	return service.open_container_screen(container, title)


## 打开建筑交互菜单（actions 数据驱动；屏幕由本模块 setup 注册到服务）。
static func open_building_menu(building_name: String, actions: Array) -> bool:
	var service := get_service()
	if service == null:
		return false
	return service.open_building_menu(building_name, actions)
