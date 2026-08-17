class_name PauseMenuPanel
extends StickScreen
## 暂停菜单 —— ESC 打开的标准暂停界面（游戏暂停 + 全屏遮罩屏蔽一切输入）。
##
## 由 SystemSetup 装配到 UIRoot.ModalOverlay；ESC 由 GameRoot 统一处理（见 game_root.gd
## _handle_escape）：未开任何模态时开本菜单，已开则逐层关闭。
## 打开即暂停（StickScreen.open 自动处理），关闭恢复原速度。
## 附身模式下 ESC 保留给"退出附身"，不弹本菜单。

const PANEL_SIZE: Vector2 = Vector2(400, 480)
const MAIN_MENU_SCENE := "res://modules/ui_global/scenes/menus/main_menu.tscn"

var _game_root: Node = null
## 是否处于"让位隐藏"状态（从暂停菜单打开设置/存档时隐藏自身，ESC 返回时恢复）
var _delegated: bool = false

## 帝国功能入口（依赖系统未建 → 打开空面板占位；系统落地后替换为真实面板）
const EMPIRE_ENTRIES: Array[Dictionary] = [
	{"id": "empire_overview", "label": "帝国总览"},
	{"id": "tech_tree", "label": "科技树"},
	{"id": "logistics", "label": "物流网络"},
	{"id": "collection", "label": "图鉴 / 成就"},
]


## 由 SystemSetup 调用，注入 GameRoot 并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	panel_size = PANEL_SIZE
	panel_title = "已暂停"
	_build_screen()


## 构建内容：动作按钮列表（继续/设置/存档/回主菜单）
func _build_content() -> void:
	StickKit.button(_body, "继续游戏", close, StickKit.ButtonKind.ACCENT, StickTokens.BTN_H_LG)
	StickKit.button(_body, "设置", _on_settings, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_LG)
	StickKit.button(_body, "存档管理", _on_save_panel, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_LG)
	# 帝国功能（空面板占位，内容留白但入口可达；系统接入后替换真实面板）
	var sec := StickKit.section(_body, "帝国功能")
	for entry in EMPIRE_ENTRIES:
		StickKit.button(sec, entry["label"], _open_placeholder.bind(entry["id"]),
				StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
	StickKit.button(_body, "保存并回到主菜单", _on_return_menu, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_LG)


## 打开帝国功能空面板（叠放在暂停菜单上：ModalOverlay 层序在暂停菜单之后，遮罩盖住它；
## ESC 先关占位面板、再关暂停菜单，逐层返回）
func _open_placeholder(preset_id: String) -> void:
	var layer := get_parent() as Control
	if layer == null:
		return
	UIPlaceholderPanel.open_panel(layer, preset_id)


func _on_settings() -> void:
	# 让位隐藏（不 close）：保持暂停状态 + 保留返回点；ESC 关设置后 restore_if_delegated 恢复
	_delegated = true
	visible = false
	if _game_root != null and _game_root.has_method("toggle_settings_menu"):
		_game_root.toggle_settings_menu()


func _on_save_panel() -> void:
	_delegated = true
	visible = false
	if _game_root != null and _game_root.has_method("toggle_save_panel"):
		_game_root.toggle_save_panel()


## ESC 关闭子面板后恢复暂停菜单（仅当本菜单是被"让位隐藏"时）
func restore_if_delegated() -> void:
	if _delegated:
		_delegated = false
		visible = true


func _on_return_menu() -> void:
	StickKit.confirm(self, "回到主菜单", "将保存当前进度（槽位 0）并回到主菜单。",
			func():
				close()
				if SaveManager and SaveManager.has_method("save_game"):
					SaveManager.save_game(0)
				get_tree().change_scene_to_file(MAIN_MENU_SCENE),
			"保存并退出")
