class_name ResourceBar
extends HBoxContainer
## 资源条组件 —— 顶栏内嵌的材料显示（挂 GlobalHUD 顶栏 HBox 中段）。
##
## 不画背景框：由顶栏通栏背景承载，本组件只显示"图标 名称 数量"条目。
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

## 由 GlobalHUD.attach_resources 调用，注入 ResourcesApi 并构建 UI。
func setup(resources_api: Node) -> void:
	_resources_api = resources_api
	_build_ui()
	_connect_signals()
	_refresh_all()


# ─────────────────────────────── UI 构建 ────────────────────────────────

func _build_ui() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 16)
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
		# 名称（白色磨砂横条上取深色次文本，见 StickTokens.TEXT_ON_LIGHT_DIM）
		var name_lbl := Label.new()
		name_lbl.text = res["name_zh"]
		name_lbl.add_theme_color_override("font_color", StickTokens.TEXT_ON_LIGHT_DIM)
		entry.add_child(name_lbl)
		# 数量
		var qty_lbl := Label.new()
		qty_lbl.text = "0"
		qty_lbl.add_theme_font_size_override("font_size", 14)
		qty_lbl.add_theme_color_override("font_color", StickTokens.TEXT_ON_LIGHT)
		entry.add_child(qty_lbl)
		_labels[res["id"]] = qty_lbl
		add_child(entry)


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
	tween.tween_property(lbl, "theme_override_colors/font_color", StickTokens.TEXT_ON_LIGHT, 0.3)
