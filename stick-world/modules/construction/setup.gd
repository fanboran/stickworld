extends RefCounted
## construction 模块自装配（AR-1 装配下沉首批样板）——建造系统与建造菜单的实例化、
## 互装与完工呈现接线，函数体自 SystemSetup 域助手平移，行为逐行等价。
##
## 装配内容：
##   - assemble / api_deferred（步骤表「建造系统」）：ConstructionManager +
##     ConstructionApi 互装；完工信号扇出 AudioManager 音效与 FxPool 尘土
##     （经建造完工事件接全局呈现框架，接线上移到模块自持）
##   - build_menu / build_menu_deferred（步骤表「建造菜单」）：BuildMenu 全屏根
##     挂 HudOverlay 槽，延迟 setup 等 ConstructionManager 就绪
##
## 纪律：
## - 只 preload 本模块文件；宿主经 root: Node 动态回引（不引 GameRoot 类，防
##   world⇄construction 依赖环）；UIKit 属 ui_global、FxPool/FxLibrary 属 fx
##   （业务方经 FxPool 静态入口消费是其设计口径，见 fx_pool.gd 头注）；
## - 装配时机与步骤顺序由 SystemSetup 步骤表编排（本类只做"装"，不做业务）。

const _ManagerScript: GDScript = preload("res://modules/construction/scripts/construction_manager.gd")
const _ApiScript: GDScript = preload("res://modules/construction/api.gd")
const _BuildMenuScript: GDScript = preload("res://modules/construction/ui/build_menu.gd")


## 实例化 ConstructionManager + api.gd 并互相挂接（详见 §15 阶段 0.4）。
## api.setup 须等 manager._ready（初始化 _assigner）——由 SystemSetup 调度
## api_deferred 的 call_deferred 保证顺序。
func assemble(root: Node) -> void:
	# 实例化 ConstructionManager
	var mgr := Node.new()
	mgr.set_script(_ManagerScript)
	mgr.name = "ConstructionManager"
	root.add_child(mgr)
	root._construction_manager = mgr
	# 实例化 api.gd（公共接口契约）
	var api := Node.new()
	api.set_script(_ApiScript)
	api.name = "ConstructionApi"
	root.add_child(api)
	root._construction_api = api


## api.setup（manager._ready 后）+ 完工信号扇出（音效/尘土呈现接线）。
func api_deferred(root: Node) -> void:
	var api = root._construction_api
	var mgr = root._construction_manager
	if api == null or mgr == null:
		return
	if not api.has_method("setup"):
		return
	api.setup(mgr)
	# 建造完工 → 音效事件（跨模块经 AudioManager 框架，资产未就位时静默）
	if api.has_signal("building_completed") and AudioManager != null:
		api.building_completed.connect(
				func(_building_id: String, _region_id: String) -> void:
					AudioManager.play_event("build_complete"))
	# 建造完工 → 尘土特效（经 FxPool 组查找，无池环境静默）
	if api.has_signal("building_completed") and mgr != null:
		api.building_completed.connect(
				func(building_id: String, _region_id: String) -> void:
					var b: Node = mgr.get_building_node(building_id)
					if b is Node2D:
						FxPool.spawn_burst(b.get_tree(), FxLibrary.BUILD_DUST, (b as Node2D).global_position))


## 实例化建造菜单并挂到 UIRoot（步骤表「建造菜单」；P1 + P2：全屏 UI 根一律用
## UIKit.full_rect（强制 FULL_RECT，杜绝"Control.new() 丢 anchor → 按钮静默
## 不可见"），并挂到 HudOverlay 槽（槽位化路由）。
func build_menu(root: Node) -> void:
	if root.ui_root == null:
		return
	root._build_menu = UIKit.full_rect(_BuildMenuScript, "BuildMenu")
	root.ui_root.add_to_slot("HudOverlay", root._build_menu)


## 建造菜单延迟 setup（等 ConstructionManager 就绪；由 SystemSetup 调度）。
func build_menu_deferred(root: Node) -> void:
	var bm = root._build_menu
	if bm == null:
		return
	if bm.has_method("setup"):
		bm.setup(root)
