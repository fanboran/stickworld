class_name MainMenuPanel
extends Control
## 临时主页菜单 -- 进入游戏时显示，提供测试场景预选入口。
##
## 定位：原型阶段（P0）的"调试启动器"（可视化版 dev_playtest）——
## 正式版应替换为主菜单/读档界面。
##
## 按钮：
##   村庄探索（默认）    —— 关菜单留在村庄
##   遭遇战战场          —— 直达战场（带默认步兵）
##   跨图跑图（往返）     —— 直达道路地图（村落 A↔B 往返测试）
##   森林区域            —— 直达森林
##
## 由 SystemSetup 装配到 UIRoot，启动时显示；game_root.close_main_menu() 关闭。

# ─────────────────────────────── 状态 ────────────────────────────────
var _game_root: Node = null
var _buttons: VBoxContainer = null


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 SystemSetup 调用，注入 GameRoot 并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_build_ui()


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)


## 显示主页菜单（GameRoot 启动时调用）。
func open_menu() -> void:
	visible = true


func close_menu() -> void:
	visible = false


func is_open() -> bool:
	return visible


# ─────────────────────────────── UI 构建 ────────────────────────────────

func _build_ui() -> void:
	# 半透明背景（点击不穿透）
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)
	# 面板
	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(520, 420)
	add_child(panel)
	# 标题
	var title := Label.new()
	title.text = "Stick World · 原型菜单"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 22)
	title.set_anchors_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 24
	title.offset_bottom = 60
	panel.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "测试场景预选（正式版替换为主菜单）"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 12)
	subtitle.modulate = Color(0.7, 0.7, 0.7)
	subtitle.set_anchors_preset(Control.PRESET_TOP_WIDE)
	subtitle.offset_top = 60
	subtitle.offset_bottom = 84
	panel.add_child(subtitle)
	# 按钮组
	_buttons = VBoxContainer.new()
	_buttons.set_anchors_preset(Control.PRESET_FULL_RECT)
	_buttons.offset_top = 96
	_buttons.offset_bottom = -24
	_buttons.offset_left = 60
	_buttons.offset_right = -60
	_buttons.add_theme_constant_override("separation", 10)
	panel.add_child(_buttons)
	_add_scene_button("村庄探索（默认）", "village_a", "进入初始村落：建造/编队/跟随练习")
	_add_scene_button("遭遇战战场（带默认步兵）", "battlefield", "直达战场：队伍 vs 敌方，可带随行编队")
	_add_scene_button("跨图跑图（村落 A↔B 往返）", "road_a_b", "道路地图：边界步行往返测试")
	_add_scene_button("森林区域", "forest_zone", "附属区域探索")
	# 提示
	var hint := Label.new()
	hint.text = "游戏中：Tab 打开大世界地图导航 · Q 切换战斗模式 · 顶栏「编制」编队"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 11)
	hint.modulate = Color(0.75, 0.75, 0.75)
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_top = -28
	hint.offset_bottom = -6
	panel.add_child(hint)


func _add_scene_button(text: String, map_id: String, desc: String) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, 44)
	btn.pressed.connect(_on_scene_selected.bind(map_id))
	_buttons.add_child(btn)
	var tip := Label.new()
	tip.text = "　%s" % desc
	tip.add_theme_font_size_override("font_size", 11)
	tip.modulate = Color(0.65, 0.65, 0.65)
	_buttons.add_child(tip)


# ─────────────────────────────── 回调 ────────────────────────────────

## 选择测试场景：关闭菜单并 travel 到目标地图。
## village_a（默认）不 travel，直接留在初始村落。
func _on_scene_selected(map_id: String) -> void:
	close_menu()
	if _game_root == null or _game_root.scene_loader == null:
		return
	if map_id == "village_a":
		# 已出生在初始村落
		if EventBus != null and EventBus.has_signal("ui_notification"):
			EventBus.ui_notification.emit("主页", "已进入初始村落：可建造/编队/按 Tab 导航", "info")
		return
	_game_root.scene_loader.travel_to_map(map_id, WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
