class_name ResourceBar
extends Control
## 资源条 UI -- 顶部常驻显示 P0 三种资源（木头/石头/铁）。
##
## 详见 docs/项目/P0收口执行计划.md 阶段 E 任务 E2。
## 由 GameRoot 在 _ready 中 set_script 装配，随后调用 setup(resources_api)。
## 监听 ResourcesApi.resource_changed 信号实时刷新；扣减时数量变红闪烁 0.5s。

# ─────────────────────────────── 引用 ────────────────────────────────
var _resources_api: Node = null

# ─────────────────────────────── 配置 ────────────────────────────────
## P0 初始资源 3 种（创始人 2026-07-29 确认）
const _DISPLAY_RESOURCES: Array = [
	{"id": "res_wood", "name_zh": "木材", "color": Color(0.55, 0.35, 0.18)},
	{"id": "res_stone", "name_zh": "石料", "color": Color(0.6, 0.6, 0.62)},
	{"id": "res_metal_ore", "name_zh": "铁矿", "color": Color(0.7, 0.45, 0.25)},
]

# ─────────────────────────────── UI 元素 ────────────────────────────────
## {resource_id -> Label}
var _labels: Dictionary = {}
## {resource_id -> ColorRect}（色块图标）
var _icons: Dictionary = {}


# ─────────────────────────────── 装配 ────────────────────────────────

## 由 GameRoot 调用，注入 ResourcesApi 引用并构建 UI。
func setup(resources_api: Node) -> void:
	_resources_api = resources_api
	_build_ui()
	_connect_signals()
	_refresh_all()


# ─────────────────────────────── UI 构建 ────────────────────────────────

func _build_ui() -> void:
	# 父 Control 的位置/范围由 resource_bar.tscn 预置（顶栏下方横条，编辑器可见可调）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 背景：黑玻璃横条（与顶栏同质感，PanelContainer + StickStyle）
	var bg := PanelContainer.new()
	bg.name = "Background"
	bg.add_theme_stylebox_override("panel", StickStyle.window_panel_light())
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# 资源条目水平排列（顶栏下方横条）
	var hbox := HBoxContainer.new()
	hbox.name = "HBox"
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 16)
	add_child(hbox)
	# 每种资源一个条目（色块+名称+数量 水平排列）
	for res in _DISPLAY_RESOURCES:
		var entry := HBoxContainer.new()
		entry.add_theme_constant_override("separation", 6)
		entry.alignment = BoxContainer.ALIGNMENT_CENTER
		# 色块图标
		var icon := ColorRect.new()
		icon.color = res["color"]
		icon.custom_minimum_size = Vector2(14, 14)
		entry.add_child(icon)
		_icons[res["id"]] = icon
		# 名称
		var name_lbl := Label.new()
		name_lbl.text = res["name_zh"]
		name_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		entry.add_child(name_lbl)
		# 数量
		var qty_lbl := Label.new()
		qty_lbl.text = "0"
		qty_lbl.add_theme_font_size_override("font_size", 14)
		qty_lbl.add_theme_color_override("font_color", Color.WHITE)
		entry.add_child(qty_lbl)
		_labels[res["id"]] = qty_lbl
		hbox.add_child(entry)


# ─────────────────────────────── 信号连接 ────────────────────────────────

func _connect_signals() -> void:
	if _resources_api == null:
		return
	if _resources_api.has_signal("resource_changed"):
		_resources_api.resource_changed.connect(_on_resource_changed)


# ─────────────────────────────── 信号回调 ────────────────────────────────

func _on_resource_changed(resource_id: String, amount: float, delta: float, _region_id: String) -> void:
	if not _labels.has(resource_id):
		return
	_update_label(resource_id, amount)
	# 扣减时数量变红闪烁 0.5s
	if delta < 0.0:
		_flash_red(resource_id)


# ─────────────────────────────── 刷新 ────────────────────────────────

func _refresh_all() -> void:
	for res in _DISPLAY_RESOURCES:
		var rid: String = res["id"]
		var amount: float = 0.0
		if _resources_api != null and _resources_api.has_method("get_stock"):
			amount = _resources_api.get_stock(rid, "")
		_update_label(rid, amount)


func _update_label(resource_id: String, amount: float) -> void:
	var lbl: Label = _labels.get(resource_id)
	if lbl == null:
		return
	lbl.text = str(int(amount))


## 数量变红闪烁 0.5s
func _flash_red(resource_id: String) -> void:
	var lbl: Label = _labels.get(resource_id)
	if lbl == null or not is_instance_valid(lbl):
		return
	lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	var tween := create_tween()
	tween.tween_interval(0.5)
	tween.tween_property(lbl, "theme_override_colors/font_color", Color.WHITE, 0.3)
