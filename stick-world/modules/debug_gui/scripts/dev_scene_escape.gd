extends Node
## DevSceneEscape —— 开发场景 ESC 退回主菜单（autoload 单例，确认弹窗制）。
##
## 主菜单「测试场景」面板与右侧临时演示入口可达 40+ 开发场景，逐场景写 ESC
## 退出不现实；本单例统一兜底：当前场景位于开发场景目录（res://tests/、界面
## 模板陈列目录）时，ESC 弹确认框，确认后才回主菜单。
##
## 拦截在 _input 层（早于场景自身与 GUI/模态）：内嵌真实 GameRoot 的开发场景
## （battle_arena / dev_playtest）里，ShortcutGate 会把 ESC 抢去退模态栈/开
## 暂停菜单，场景自己的 ESC 热键收不到——本单例在更早的层拦截才兜得住。
## 让位规则（本地 ESC 语义优先）：
##   · 有可见 StickWindow → 让位，ESC 先关窗
##   · UIModalStack 有模态开着 → 让位，ESC 先逐层退栈（暂停菜单/背包/设置…）
##   · 本单例的确认框开着 → ESC = 取消（再按一次退出弹窗）
##
## 仅 debug 构建生效（与主菜单「测试场景」入口同门槛，发布构建零行为）；
## process_mode = ALWAYS，场景自行暂停（如 battle_arena 空格暂停）时仍可用。

## 命中这些前缀的当前场景，ESC 视为「请求回主页」。
## 只收浏览型 dev 场景（tests/dev/），不收 tests/ 其余层级——integration 等
## 自动化挂钩场景会把 GameRoot 挂进来注入 ESC 测游戏语义，不能劫持。
const ESCAPE_PREFIXES: PackedStringArray = [
	"res://tests/dev/",
	"res://modules/ui_global/scenes/templates/",
]

const MAIN_MENU_SCENE := "res://modules/ui_global/scenes/menus/main_menu.tscn"

## 确认框宿主（全屏 Control，挂根窗口下；父非 Control 时确认框遮罩会塌缩）
var _host: Control = null
## 当前确认框（关闭即 queue_free，引用需 is_instance_valid 兜底）
var _dialog: Control = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_host = Control.new()
	_host.name = "DevEscapeConfirmHost"
	_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_host.set_anchors_preset(Control.PRESET_FULL_RECT)
	_host.theme = StickTheme.create()
	get_tree().root.add_child.call_deferred(_host)


func _input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if not (event is InputEventKey and event.pressed and not event.echo
			and event.keycode == KEY_ESCAPE):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var path := scene.scene_file_path
	if path.is_empty() or path == MAIN_MENU_SCENE:
		return
	var hit := false
	for prefix in ESCAPE_PREFIXES:
		if path.begins_with(prefix):
			hit = true
			break
	if not hit:
		return
	# 确认框已开 → ESC = 取消
	if _dialog != null and is_instance_valid(_dialog) and _dialog.is_open():
		_dialog.close()
		_dialog = null
		get_viewport().set_input_as_handled()
		return
	# 本地 ESC 语义优先：有窗口/模态开着时不抢
	if _has_local_escape_ui():
		return
	# 弹确认框（确认后真正切场景）
	get_viewport().set_input_as_handled()
	var on_ok := func() -> void:
		_dialog = null
		get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	_dialog = StickConfirmDialog.new()
	_dialog.setup("返回主菜单", "离开当前场景，返回主菜单？",
			on_ok, "返回主页", StickKit.ButtonKind.ACCENT)
	_host.add_child(_dialog)
	_dialog.open()


## 场景内是否存在应先于「回主页」处理 ESC 的界面
func _has_local_escape_ui() -> bool:
	# 可见 StickWindow（ESC 先关窗）
	for w in get_tree().root.find_children("*", "Control", true, false):
		var s: Script = w.get_script()
		if s != null and s.resource_path.ends_with("stick_window.gd") and w.visible:
			return true
	# 模态栈开着（ESC 先逐层退栈）
	for ms in get_tree().root.find_children("*", "UIModalStack", true, false):
		if ms.is_any_open():
			return true
	return false
