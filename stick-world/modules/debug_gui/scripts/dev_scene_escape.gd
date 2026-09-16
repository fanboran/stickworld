extends Node
## DevSceneEscape —— 开发场景 ESC 退回主菜单的兜底监听（autoload 单例）。
##
## 主菜单「测试场景」面板可达 40+ 开发场景，逐场景写 ESC 不现实；本节点统一兜底：
## 当前场景位于开发场景目录（res://tests/、界面模板陈列目录）时，ESC 即回主菜单。
##
## 事件派发为场景树逆序——当前场景先于本节点收到 _unhandled_input，自带 ESC
## 逻辑的场景（battle_arena / unit_action_gallery / sketch_compare /
## sketch_cloud_gallery）行为不变，本节点只接它们没接住的。
##
## 仅 debug 构建生效（与主菜单「测试场景」入口同门槛，发布构建零行为）；
## process_mode = ALWAYS，场景自行暂停（如 battle_arena 空格暂停）时 ESC 仍可用。

## 命中这些前缀的当前场景，ESC 视为「回主页」
const ESCAPE_PREFIXES: PackedStringArray = [
	"res://tests/",
	"res://modules/ui_global/scenes/templates/",
]

const MAIN_MENU_SCENE := "res://modules/ui_global/scenes/menus/main_menu.tscn"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if not (event is InputEventKey and event.pressed and not event.echo
			and event.keycode == KEY_ESCAPE):
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var path := scene.scene_file_path
	# 主菜单自身/启动早期无路径时不动
	if path.is_empty() or path == MAIN_MENU_SCENE:
		return
	for prefix in ESCAPE_PREFIXES:
		if path.begins_with(prefix):
			get_tree().change_scene_to_file(MAIN_MENU_SCENE)
			return
