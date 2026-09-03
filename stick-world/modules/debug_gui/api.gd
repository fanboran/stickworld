extends Node
## DebugApi -- 调试覆盖层状态管理（autoload 单例）。
##
## 详见 docs/技术/架构/场景与战斗架构.md §10.5。
## 职责：
##   - 注册/注销调试绘制器（各模块注册自己的绘制器）
##   - 管理调试覆盖层可见性（F3 切换）
##   - 管理每个绘制器的独立开关
##   - 持久化 UI 位置和开关状态到 user://debug_settings.cfg

signal visibility_changed(is_visible: bool)
signal legend_visibility_changed(is_visible: bool)
signal drawer_enabled_changed(drawer_name: String, enabled: bool)
## 交互式调试工具面板（DebugToolsPanel）显隐；独立于 F3 总开关
signal tools_visibility_changed(is_visible: bool)

## 配置文件路径
const SETTINGS_PATH := "user://debug_settings.cfg"

## 已注册的绘制器：name -> Callable(control: Control, ctx: Dictionary)
var _drawers: Dictionary = {}

## 各绘制器的独立开关（name -> bool），默认全部启用
var _drawer_enabled: Dictionary = {}

## 调试覆盖层是否可见
var _visible: bool = true

## 图例是否可见
var _legend_visible: bool = true

## 调试按钮位置（收起状态）
var _button_position: Vector2 = Vector2(12, 64)
## 调试面板是否展开
var _panel_expanded: bool = false
## 调试面板位置（展开状态）
var _panel_position: Vector2 = Vector2(12, 100)
## 交互式工具面板显隐（独立于 F3 总开关，2026-08-22）
var _tools_visible: bool = false


func _ready() -> void:
	_load_settings()
	# 设置面板持久化项（debug/overlay、debug/legend）优先级高于调试自身 cfg；
	# 未在设置面板应用过（键不存在）时保持 debug_settings.cfg 行为
	if ConfigManager:
		if ConfigManager.has_key("debug/overlay"):
			set_overlay_visible(bool(ConfigManager.get_value("debug/overlay")))
		if ConfigManager.has_key("debug/legend"):
			if bool(ConfigManager.get_value("debug/legend")):
				show_legend()
			else:
				hide_legend()


# ─────────────────────────────── 绘制器注册 ────────────────────────────────

## 注册绘制器
func register_drawer(drawer_name: String, drawer: Callable) -> void:
	_drawers[drawer_name] = drawer
	# 新注册的绘制器默认启用（除非已从配置文件加载了状态）
	if not _drawer_enabled.has(drawer_name):
		_drawer_enabled[drawer_name] = true


## 注销绘制器
func unregister_drawer(drawer_name: String) -> void:
	_drawers.erase(drawer_name)


## 获取所有已注册的绘制器
func get_drawers() -> Dictionary:
	return _drawers


# ─────────────────────────────── 上下文附加数据（装配层注入） ────────────────────────────────

## 跨模块注入的调试上下文附加数据（如地图节点路径表，由装配层写入，本模块不自知其含义）
var _ctx_extras: Dictionary = {}


## 注入上下文附加数据（键值对；随每帧 ctx 下发给绘制器，面板可经 get_ctx_extra 读取）
func set_ctx_extra(key: String, value) -> void:
	_ctx_extras[key] = value


## 读取上下文附加数据
func get_ctx_extra(key: String, default: Variant = null) -> Variant:
	return _ctx_extras.get(key, default)


## 全量附加数据（DebugDrawControl 每帧并入 ctx）
func ctx_extras() -> Dictionary:
	return _ctx_extras


# ─────────────────────────────── 绘制器独立开关 ────────────────────────────────

## 查询绘制器是否启用
func is_drawer_enabled(drawer_name: String) -> bool:
	return _drawer_enabled.get(drawer_name, true)


## 设置绘制器开关
func set_drawer_enabled(drawer_name: String, enabled: bool) -> void:
	_drawer_enabled[drawer_name] = enabled
	drawer_enabled_changed.emit(drawer_name, enabled)
	_save_settings()


## 切换绘制器开关
func toggle_drawer(drawer_name: String) -> void:
	set_drawer_enabled(drawer_name, not is_drawer_enabled(drawer_name))


# ─────────────────────────────── 全局可见性 ────────────────────────────────

## F3 切换调试覆盖层显示/隐藏
func toggle_visibility() -> void:
	_visible = not _visible
	_emit_visibility()
	_save_settings()


## 设置可见性（2026-08 改名：原 set_visible 遮蔽 Node.set_visible 内置方法）
func set_overlay_visible(v: bool) -> void:
	if _visible == v:
		return
	_visible = v
	_emit_visibility()
	_save_settings()


## 是否可见
func is_visible() -> bool:
	return _visible


## 发射可见性信号（本地 + EventBus 广播，供生产代码解耦订阅）
func _emit_visibility() -> void:
	visibility_changed.emit(_visible)
	if EventBus != null and EventBus.has_signal("debug_visibility_changed"):
		EventBus.debug_visibility_changed.emit(_visible)


# ─────────────────────────────── 图例 ────────────────────────────────

func show_legend() -> void:
	_legend_visible = true
	legend_visibility_changed.emit(_legend_visible)


func hide_legend() -> void:
	_legend_visible = false
	legend_visibility_changed.emit(_legend_visible)


func is_legend_visible() -> bool:
	return _legend_visible


# ─────────────────────────────── UI 位置持久化 ────────────────────────────────

func get_button_position() -> Vector2:
	return _button_position


func set_button_position(pos: Vector2) -> void:
	_button_position = pos
	_save_settings()


func is_panel_expanded() -> bool:
	return _panel_expanded


func set_panel_expanded(expanded: bool) -> void:
	_panel_expanded = expanded
	_save_settings()


func get_panel_position() -> Vector2:
	return _panel_position


func set_panel_position(pos: Vector2) -> void:
	_panel_position = pos
	_save_settings()


# ─────────────────────────────── 交互式工具面板 ────────────────────────────────

## 工具面板显隐（独立于 F3 总开关：F3 隐藏绘制覆盖层时工具面板保持原状）
func set_tools_visible(v: bool) -> void:
	if _tools_visible == v:
		return
	_tools_visible = v
	tools_visibility_changed.emit(v)
	_save_settings()


func toggle_tools_visible() -> void:
	set_tools_visible(not _tools_visible)


func is_tools_visible() -> bool:
	return _tools_visible


# ─────────────────────────────── 配置持久化 ────────────────────────────────

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("ui", "button_position", var_to_str(_button_position))
	cfg.set_value("ui", "panel_expanded", _panel_expanded)
	cfg.set_value("ui", "panel_position", var_to_str(_panel_position))
	cfg.set_value("ui", "overlay_visible", _visible)
	cfg.set_value("ui", "tools_visible", _tools_visible)
	for drawer_name in _drawer_enabled.keys():
		cfg.set_value("drawers", drawer_name, _drawer_enabled[drawer_name])
	cfg.save(SETTINGS_PATH)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	var bp = cfg.get_value("ui", "button_position", "Vector2(12, 64)")
	if bp is String:
		_button_position = str_to_var(bp)
	elif bp is Vector2:
		_button_position = bp
	var pp = cfg.get_value("ui", "panel_position", "Vector2(12, 100)")
	if pp is String:
		_panel_position = str_to_var(pp)
	elif pp is Vector2:
		_panel_position = pp
	_panel_expanded = cfg.get_value("ui", "panel_expanded", false)
	_visible = cfg.get_value("ui", "overlay_visible", true)
	_tools_visible = cfg.get_value("ui", "tools_visible", false)
	if cfg.has_section("drawers"):
		for drawer_name in cfg.get_section_keys("drawers"):
			_drawer_enabled[drawer_name] = cfg.get_value("drawers", drawer_name, true)
