class_name WeaponPanel
extends Control
## 武器调控面板 —— 屏幕左上角，附身玩家主手武器切换 + 盾牌开关。
##
## 与 Minimap/ZoomBar 同款角落 HUD 部件：自设 anchor，经 UIRoot.add_to_slot
## ("HudOverlay") 挂载（见 SystemSetup._setup_weapon_panel）。
## 按钮 = weapon_mount.WeaponType 五型 + 盾开关；T/B 快捷键（GameRoot）与
## 本面板共享状态，双方操作后都走 refresh()。
## 附身实体随地图切换重建，_process 低频自刷（0.25s）自动跟上。

const _WeaponMountScript: GDScript = preload("res://modules/units/scripts/entity/weapon_mount.gd")

## 按钮顺序 = WeaponType 枚举序（SWORD/SPEAR/BOW/PICKAXE/STAFF）
const WEAPON_LABELS: Array[String] = ["剑", "矛", "弓", "镐", "杖"]

## 探索模式工具条占据顶缘，面板放其下方（旧调试标签同位）
const PANEL_POS := Vector2(12.0, 120.0)
const REFRESH_INTERVAL := 0.25

var _game_root: Node = null
var _weapon_buttons: Array[Button] = []
var _shield_button: Button = null
var _refresh_timer := 0.0


## 由 SystemSetup 调用，注入 GameRoot 并构建 UI。
func setup(game_root: Node) -> void:
	_game_root = game_root
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = PANEL_POS
	_build_ui()
	# 不在此处 refresh：装配期 travel_handler 尚未就绪，查玩家会踩空引用；
	# 首次刷新交给 _process 低频自刷（≤0.25s，此时装配已完成）


func _process(delta: float) -> void:
	# 换图重附身后武器状态可能变化（新实体默认剑+盾），低频自刷兜底
	_refresh_timer += delta
	if _refresh_timer >= REFRESH_INTERVAL:
		_refresh_timer = 0.0
		refresh()


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)
	var title := Label.new()
	title.text = "武器（T循环 / B盾）"
	title.add_theme_font_size_override("font_size", 13)
	vbox.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	vbox.add_child(row)
	for i in WEAPON_LABELS.size():
		var btn := Button.new()
		btn.text = WEAPON_LABELS[i]
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_weapon_pressed.bind(i))
		row.add_child(btn)
		_weapon_buttons.append(btn)
	_shield_button = Button.new()
	_shield_button.text = "盾"
	_shield_button.toggle_mode = true
	_shield_button.focus_mode = Control.FOCUS_NONE
	_shield_button.pressed.connect(_on_shield_pressed)
	row.add_child(_shield_button)


func _on_weapon_pressed(index: int) -> void:
	var wm := _find_weapon_mount()
	if wm != null:
		wm.weapon_type = index
	refresh()


func _on_shield_pressed() -> void:
	var wm := _find_weapon_mount()
	if wm != null:
		wm.shield_enabled = not wm.shield_enabled
	refresh()


## T/B 快捷键（GameRoot）调用：同步高亮当前武器/盾状态。
func refresh() -> void:
	var wm := _find_weapon_mount()
	for i in _weapon_buttons.size():
		var btn := _weapon_buttons[i]
		if wm != null:
			btn.disabled = false
			btn.set_pressed_no_signal(int(wm.weapon_type) == i)
		else:
			btn.disabled = true
			btn.set_pressed_no_signal(false)
	if _shield_button != null:
		_shield_button.disabled = wm == null
		_shield_button.set_pressed_no_signal(wm != null and wm.shield_enabled)


func _find_weapon_mount() -> Node:
	if _game_root == null or not _game_root.has_method("get_player_entity"):
		return null
	var player: Node2D = _game_root.get_player_entity()
	if player == null or not is_instance_valid(player):
		return null
	return player.get_node_or_null("WeaponMount")
