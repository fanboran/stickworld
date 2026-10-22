extends RefCounted
## inventory 模块自装配（AR-1 装配下沉首批样板）——背包装备系统的实例化与挂接，
## 函数体自 SystemSetup._setup_inventory 平移，行为逐行等价。
##
## 装配内容：
##   1. InventoryService（GameRoot 子节点：玩家背包 + 装备→接管实体桥接）
##   2. Hotbar（HudOverlay 底部常驻物品栏：主副手/Hotbar 物品/动作快捷键三组）
##   3. InventoryScreen（ModalOverlay 背包·角色合一模态：E 键开关，UIModalStack.INVENTORY
##      ——属性卡已并入背包窗口左栏，独立 StatsScreen 退役）
##   4. ContainerScreen（翻包/村仓共用双栏转移）+ BuildingMenuScreen（建筑交互菜单）
##
## 纪律：
## - 只 preload 本模块文件；宿主经 root: Node 动态回引（不引 GameRoot 类，防
##   world⇄inventory 依赖环）；UIKit 属 ui_global（模块既有依赖）；
## - 装配时机与步骤顺序由 SystemSetup 步骤表编排（本类只做"装"，不做业务）。

const _ServiceScript: GDScript = preload("res://modules/inventory/scripts/inventory_service.gd")
const _HotbarScript: GDScript = preload("res://modules/inventory/ui/hotbar.gd")
const _InventoryScreenScript: GDScript = preload("res://modules/inventory/ui/inventory_screen.gd")
const _ContainerScreenScript: GDScript = preload("res://modules/inventory/ui/container_screen.gd")
const _BuildingMenuScript: GDScript = preload("res://modules/inventory/ui/building_menu_screen.gd")


## 装配背包域（SystemSetup 步骤表「背包」步骤；前置：界面根已装配）。
func assemble(root: Node) -> void:
	if root.ui_root == null:
		return
	var service := Node.new()
	service.set_script(_ServiceScript)
	service.name = "InventoryService"
	root.add_child(service)
	if service.has_method("setup"):
		service.setup(root)
	root.inventory_service = service
	var hb := UIKit.widget(_HotbarScript, "Hotbar")
	root.ui_root.add_to_slot("HudOverlay", hb)
	if hb.has_method("setup"):
		hb.setup(root, service)
	root._hotbar = hb
	root._apply_observer_view()   # 观战机位可能早于装配置位（见 observer_view 声明）
	var inv := UIKit.full_rect(_InventoryScreenScript, "InventoryScreen")
	if not root.ui_root.add_to_slot("ModalOverlay", inv):
		return
	root._inventory_screen = inv
	if inv.has_method("setup"):
		inv.setup(root, service)
	# 容器交互窗口（翻包/村仓共用双栏转移）+ 建筑交互菜单（预制框架）
	var container := UIKit.full_rect(_ContainerScreenScript, "ContainerScreen")
	if root.ui_root.add_to_slot("ModalOverlay", container) \
			and container.has_method("setup"):
		container.setup(root, service)
		# 屏幕注册到服务：模块外经 InventoryAPI.open_container_screen 打开
		service.set_container_screen(container)
	var bmenu := UIKit.full_rect(_BuildingMenuScript, "BuildingMenuScreen")
	if root.ui_root.add_to_slot("ModalOverlay", bmenu) \
			and bmenu.has_method("setup"):
		bmenu.setup(root, service)
		# 屏幕注册到服务：模块外经 InventoryAPI.open_building_menu 打开
		service.set_building_menu_screen(bmenu)
