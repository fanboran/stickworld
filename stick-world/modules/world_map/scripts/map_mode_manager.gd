extends Node
class_name MapModeManager
## 地图层开关管理器（B4，总体设计 §5.5）—— 底图恒在 + 四个独立开关层
##
## 层语义（四层独立可叠加，底图 l1_terrain.png 恒画）：
##   - 政治：政权色覆盖（本省半透明 α=0.55 + 邻省暗一阶）
##   - 城市：建成区 blob 三档 + 城市常驻描边链
##   - 交通：道路矢量折线（土路/官道两 tier）
##   - 资源：资源点矢量标记
##
## 层开关是跨视图全局状态（L3 开政治，之后 Tab 开 L1 也是政治）：开关表存静态变量，
## 每个战略图场景（L1/L2/L3）在 Content 下挂一个实例，实例负责两件事：
##   - 数字键 1/2/3/4 切层（政治/城市/交通/资源）：Content 隐藏时（视图关闭）不响应，
##     地图关闭时 1/2/3 归场景图玩法占用，互不干扰
##   - layer_toggled 信号：HUD 开关条 / L1 图例 / 渲染器订阅；
##     static set_layer_on 广播给全部存活实例，跨视图即时同步
## 层开关只表达"画不画这一层"，渲染内容全在各渲染器内，L2/L3 无对应层的开关被忽略。

## 层开关变更信号（本实例所在视图的 HUD/图例/渲染器订阅）
signal layer_toggled(layer: int, on: bool)

## 层枚举（顺序 = 渲染叠放顺序：政治 → 城市 → 交通 → 资源）
enum Layer { POLITICAL, CITY, TRAFFIC, RESOURCE }

## 层开关表（静态全局状态）：政治/城市默认开（底图上叠政权色与建成区），
## 交通/资源默认关（按需开）
static var _layer_on: Dictionary = {
	Layer.POLITICAL: true,
	Layer.CITY: true,
	Layer.TRAFFIC: false,
	Layer.RESOURCE: false,
}

## 存活实例（static set_layer_on 广播 layer_toggled 用；场景懒加载实例化/释放时进出）
static var _instances: Array[MapModeManager] = []

## 层中文名（HUD 开关按钮/图例标题用）
const LAYER_NAMES := {
	Layer.POLITICAL: "政治",
	Layer.CITY: "城市",
	Layer.TRAFFIC: "交通",
	Layer.RESOURCE: "资源",
}


func _ready() -> void:
	_instances.append(self)


func _exit_tree() -> void:
	_instances.erase(self)


## 设置某层开关并广播全部实例（重复设置同状态静默不发信号；未知层忽略）
static func set_layer_on(layer: int, on: bool) -> void:
	if not _layer_on.has(layer) or bool(_layer_on[layer]) == on:
		return
	_layer_on[layer] = on
	for inst in _instances:
		inst.layer_toggled.emit(layer, on)


## 翻转某层开关，返回新状态（未知层返回 false 且不改状态）
static func toggle_layer(layer: int) -> bool:
	if not _layer_on.has(layer):
		return false
	var on: bool = not bool(_layer_on[layer])
	set_layer_on(layer, on)
	return on


static func is_layer_on(layer: int) -> bool:
	return bool(_layer_on.get(layer, false))


## 层中文名（未知层返回空串）
static func layer_name(layer: int) -> String:
	return LAYER_NAMES.get(layer, "")


## 视图是否打开：沿父链找第一个 CanvasItem（Content，控制器 open/close 切它的 visible）
## 读 visible。不用 is_visible_in_tree——本节点是纯 Node 没有该方法，且 headless 下
## is_visible_in_tree 因窗口不可见恒 false（L2 控制器同款坑，见其 _input 注释）
func _is_view_open() -> bool:
	var p := get_parent()
	while p != null:
		if p is CanvasItem:
			return p.visible
		p = p.get_parent()
	return false


## 数字键 1/2/3/4 切层（InputMap 动作 strategy/layer_*，主键盘+小键盘双绑定一次覆盖；
## 仅本视图打开时响应；消费事件防场景图玩法键穿透）
func _unhandled_input(event: InputEvent) -> void:
	if not _is_view_open():
		return
	if event is InputEventKey and event.pressed:
		if event.is_action_pressed("strategy/layer_political"):
			toggle_layer(Layer.POLITICAL)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("strategy/layer_city"):
			toggle_layer(Layer.CITY)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("strategy/layer_traffic"):
			toggle_layer(Layer.TRAFFIC)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("strategy/layer_resource"):
			toggle_layer(Layer.RESOURCE)
			get_viewport().set_input_as_handled()
