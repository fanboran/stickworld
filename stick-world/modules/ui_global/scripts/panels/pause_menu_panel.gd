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
	StickKit.button(_body, "保存并回到主菜单", _on_return_menu, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_LG)


func _on_settings() -> void:
	if _game_root != null and _game_root.has_method("toggle_settings_menu"):
		_game_root.toggle_settings_menu()


func _on_save_panel() -> void:
	if _game_root != null and _game_root.has_method("toggle_save_panel"):
		_game_root.toggle_save_panel()


func _on_return_menu() -> void:
	StickKit.confirm(self, "回到主菜单", "将保存当前进度（槽位 0）并回到主菜单。",
			func():
				close()
				if SaveManager and SaveManager.has_method("save_game"):
					SaveManager.save_game(0)
				get_tree().change_scene_to_file(MAIN_MENU_SCENE),
			"保存并退出")
