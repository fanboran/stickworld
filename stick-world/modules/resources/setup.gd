extends RefCounted
## resources 模块自装配（AR-1 装配下沉首批样板）——ResourcesApi 实例化与
## ResourceManager 注入，函数体自 SystemSetup 核心系统域助手平移，行为逐行等价。
##
## 装配内容：
##   - assemble（步骤表「资源系统」）：ResourcesApi 节点挂 GameRoot
##   - api_deferred（SystemSetup 调度）：api 注入 ResourceManager（_ready 后）
##
## 跨模块接线留在装配编排（SystemSetup 侧）：产出注入 ConstructionManager、
## P0 初始资源发放、资源条并入 GlobalHUD——这些是跨模块编排与开局政策，
## 不属本模块自持范围。粒子特效池（FxPool）同留在编排侧（fx 基础设施）。
##
## 纪律：
## - 只 preload 本模块文件；宿主经 root: Node 动态回引（不引 GameRoot 类，防
##   world⇄resources 依赖环）；
## - 装配时机与步骤顺序由 SystemSetup 步骤表编排（本类只做"装"，不做业务）。

const _ApiScript: GDScript = preload("res://modules/resources/api.gd")
const _ManagerScript: GDScript = preload("res://modules/resources/scripts/resource_manager.gd")


## 实例化 ResourcesApi 并挂为 GameRoot 子节点（P0-9）。
func assemble(root: Node) -> void:
	var api := Node.new()
	api.set_script(_ApiScript)
	api.name = "ResourcesApi"
	root.add_child(api)
	root._resources_api = api


## api 注入 ResourceManager（须在 api._ready 后；由 SystemSetup 调度）。
func api_deferred(root: Node) -> void:
	var api = root._resources_api
	if api == null or not api.has_method("setup"):
		return
	var mgr = _ManagerScript.new()
	api.setup(mgr)
