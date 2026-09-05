extends Node
class_name MapModeManager
## 地图模式管理器（B4，总体设计 §5.5）—— TERRAIN 地形（默认）/ POLITICAL 政治
##
## 模式是跨视图全局状态（L3 切到政治，之后 Tab 开 L1 也是政治）：当前模式存静态变量，
## 每个战略图场景（L1/L2/L3）在 Content 下挂一个实例，实例负责两件事：
##   - 数字键切换（1=地形 / 2=政治）：Content 隐藏时（视图关闭）不响应，
##     地图关闭时 1/2 归场景图玩法占用，互不干扰
##   - mode_changed 信号：HUD 模式条 / L1 图例 / 渲染器订阅；
##     static set_mode 广播给全部存活实例，跨视图即时同步
## 资源/人口/战线模式本轮不实装（战略图架构 §八枚举预留，届时在 Mode 追加）。
## 渲染表现：地形底图层（B2 产 l3_terrain.png）/ 政权叠加层（Phase F）数据到位前，
## 两模式回退现状着色（渲染器持有 map_mode，数据到位即按模式分层）。

## 模式变更信号（本实例所在视图的 HUD/图例/渲染器订阅）
signal mode_changed(mode: int)

enum Mode { TERRAIN, POLITICAL }

## 全局当前模式（默认 TERRAIN——创始人要求默认地形图）
static var current_mode: int = Mode.TERRAIN

## 存活实例（static set_mode 广播 mode_changed 用；场景懒加载实例化/释放时进出）
static var _instances: Array[MapModeManager] = []

## 模式中文名（HUD 按钮/图例标题用）
const MODE_NAMES := {
	Mode.TERRAIN: "地形",
	Mode.POLITICAL: "政治",
}


func _ready() -> void:
	_instances.append(self)


func _exit_tree() -> void:
	_instances.erase(self)


## 切换全局模式并广播全部实例（重复设置同模式静默不发信号）
static func set_mode(mode: int) -> void:
	if mode == current_mode:
		return
	current_mode = mode
	for inst in _instances:
		inst.mode_changed.emit(mode)


static func get_mode() -> int:
	return current_mode


## 模式中文名（缺省 = 当前模式；未知值返回空串）
static func get_mode_name(mode: int = -1) -> String:
	return MODE_NAMES.get(mode if mode >= 0 else current_mode, "")


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


## 数字键 1/2 切换（仅本视图打开时响应；消费事件防场景图玩法键穿透）
func _unhandled_input(event: InputEvent) -> void:
	if not _is_view_open():
		return
	if event is InputEventKey and event.pressed and not event.is_echo():
		var key := event as InputEventKey
		if key.keycode == KEY_1 or key.keycode == KEY_KP_1:
			set_mode(Mode.TERRAIN)
			get_viewport().set_input_as_handled()
		elif key.keycode == KEY_2 or key.keycode == KEY_KP_2:
			set_mode(Mode.POLITICAL)
			get_viewport().set_input_as_handled()
