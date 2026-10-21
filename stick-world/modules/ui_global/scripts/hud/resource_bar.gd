class_name ResourceBar
extends HBoxContainer
## 资源条组件 —— 顶栏内嵌的材料显示（挂 GlobalHUD 顶栏 HBox 中段）。
##
## 不画背景框：由顶栏通栏背景承载，本组件只显示"图标 名称 数量"条目。
## 监听 ResourcesApi.resource_changed 信号实时刷新；扣减时数量变红闪烁 0.5s。
## 另订阅 resource_not_enough（resources 模块 api 信号）：扣减失败时在对应
## 条目尾部浮出红字"缺N"，2s 节流窗内重复失败只刷新文案不重弹（防加工链
## 每拍重试刷屏），窗外重试重新浮出。

# ─────────────────────────────── 引用 ────────────────────────────────
var _resources_api: Node = null

# ─────────────────────────────── 配置 ────────────────────────────────
## 资源 5 种（木/石/铁 + 2026-09-06 新增钻石/黄金）
const _DISPLAY_RESOURCES: Array = [
	{"id": "res_wood", "name_zh": "木材", "color": Color(0.55, 0.35, 0.18)},
	{"id": "res_stone", "name_zh": "石料", "color": Color(0.6, 0.6, 0.62)},
	{"id": "res_metal_ore", "name_zh": "铁矿", "color": Color(0.7, 0.45, 0.25)},
	{"id": "res_gold", "name_zh": "黄金", "color": Color(0.92, 0.78, 0.25)},
	{"id": "res_diamond", "name_zh": "钻石", "color": Color(0.5, 0.85, 0.95)},
]

# ─────────────────────────────── 不足提示（resource_not_enough 接线）────────────────────────────────
## 提示停留时长 = 节流窗：窗内重复失败合并（只刷新文案），窗外重试重新浮出
const NOT_ENOUGH_HOLD_SEC := 2.0
## 提示淡出时长（停留期满后渐隐）
const NOT_ENOUGH_FADE_SEC := 0.4

## 时钟源（默认真实 msec；测试注入假时钟驱动节流窗，保持用例同步确定）
var time_source: Callable = Time.get_ticks_msec

## {resource_id -> Label}（"缺N"红字提示，初始隐藏）
var _hint_labels: Dictionary = {}
## {resource_id -> int msec} 节流窗截止时刻（0 = 无在途提示）
var _hint_deadline: Dictionary = {}
## {resource_id -> Tween}（淡出补间；重弹前 kill 旧补间防互踩）
var _hint_tweens: Dictionary = {}

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
		# 图标：优先笔触贴图（Demo 美术管线产物），缺图回退色块
		var icon_tex_path: String = _icon_texture_path(String(res["id"]))
		if not icon_tex_path.is_empty() and ResourceLoader.exists(icon_tex_path):
			var icon := TextureRect.new()
			icon.texture = load(icon_tex_path)
			icon.custom_minimum_size = Vector2(18, 18)
			icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			entry.add_child(icon)
			_icons[res["id"]] = icon
		else:
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
		qty_lbl.add_theme_font_size_override("font_size", StickTokens.FONT_HUD)
		qty_lbl.add_theme_color_override("font_color", Color.WHITE)
		entry.add_child(qty_lbl)
		_labels[res["id"]] = qty_lbl
		# 不足提示（"缺N"红字，隐藏不占位；触发时浮出、期满淡出）
		var hint_lbl := Label.new()
		hint_lbl.visible = false
		hint_lbl.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
		hint_lbl.add_theme_color_override("font_color", StickTokens.DANGER)
		entry.add_child(hint_lbl)
		_hint_labels[res["id"]] = hint_lbl
		add_child(entry)


# ─────────────────────────────── 信号连接 ────────────────────────────────

func _connect_signals() -> void:
	if _resources_api == null:
		return
	if _resources_api.has_signal("resource_changed"):
		_resources_api.resource_changed.connect(_on_resource_changed)
	if _resources_api.has_signal("resource_not_enough"):
		_resources_api.resource_not_enough.connect(_on_resource_not_enough)


# ─────────────────────────────── 信号回调 ────────────────────────────────

func _on_resource_changed(resource_id: String, amount: float, delta: float, _region_id: String) -> void:
	if not _labels.has(resource_id):
		return
	# 扣减红闪 0.5s / 增加绿闪 0.6s（采集正向反馈）
	if delta < 0.0:
		_flash_red(resource_id)
	elif delta > 0.0:
		_flash_green(resource_id)


## 扣减失败：条目尾部浮出红字"缺N"（N = 需求 - 可用，向上取整）。
## 节流窗内重复失败只刷新文案（合并，不重启动画不刷屏）；窗外重新浮出。
## 资源条不展示的资源（如 res_silk/res_iron_ingot）无处挂提示，忽略。
func _on_resource_not_enough(resource_id: String, required: float, available: float, _region_id: String) -> void:
	var lbl: Label = _hint_labels.get(resource_id)
	if lbl == null or not is_instance_valid(lbl):
		return
	var now: int = time_source.call()
	if now < int(_hint_deadline.get(resource_id, 0)):
		# 节流窗内：合并——只刷新最新缺口，保留进行中的浮出/淡出补间
		lbl.text = "缺%d" % _deficit(required, available)
		return
	# 窗外（或首次）：全新浮出并起窗
	_hint_deadline[resource_id] = now + int(NOT_ENOUGH_HOLD_SEC * 1000.0)
	lbl.text = "缺%d" % _deficit(required, available)
	lbl.visible = true
	lbl.modulate.a = 1.0
	var old: Tween = _hint_tweens.get(resource_id)
	if old != null and old.is_valid():
		old.kill()
	var tween := create_tween()
	tween.tween_interval(NOT_ENOUGH_HOLD_SEC)
	tween.tween_property(lbl, "modulate:a", 0.0, NOT_ENOUGH_FADE_SEC)
	tween.tween_callback(func() -> void:
		lbl.visible = false
		_hint_deadline.erase(resource_id)
		_hint_tweens.erase(resource_id))
	_hint_tweens[resource_id] = tween


## 缺口数（需求 - 可用，向上取整；负数钳 0）
func _deficit(required: float, available: float) -> int:
	return int(ceil(maxf(required - available, 0.0)))


## 当前不足提示文案（"" = 无在途提示）——测试/调试观测位
func not_enough_text(resource_id: String) -> String:
	var lbl: Label = _hint_labels.get(resource_id)
	if lbl == null or not lbl.visible:
		return ""
	return lbl.text


## 不足提示节流窗截止时刻（msec；0 = 无）——测试/调试观测位
func not_enough_deadline_msec(resource_id: String) -> int:
	return int(_hint_deadline.get(resource_id, 0))


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
func _flash_green(resource_id: String) -> void:
	# 增加资源时数量短暂变绿提亮（采集/入库的正向确认）
	var lbl: Label = _labels.get(resource_id)
	if lbl == null or not is_instance_valid(lbl):
		return
	lbl.add_theme_color_override("font_color", Color(0.45, 1.0, 0.55))
	var tween := create_tween()
	tween.tween_interval(0.45)
	# 与 _flash_red 同路径：补间 font_color 本身（modulate 恒 WHITE，补间它绿字不会渐隐）
	tween.tween_property(lbl, "theme_override_colors/font_color", Color.WHITE, 0.25)
	tween.tween_callback(func() -> void:
		lbl.add_theme_color_override("font_color", Color.WHITE))


func _flash_red(resource_id: String) -> void:
	var lbl: Label = _labels.get(resource_id)
	if lbl == null or not is_instance_valid(lbl):
		return
	lbl.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	var tween := create_tween()
	tween.tween_interval(0.5)
	tween.tween_property(lbl, "theme_override_colors/font_color", Color.WHITE, 0.3)


## 资源 id → 图标贴图。优先图标管线母题（StickIcons 语义映射），回退
## 资源点同源笔触贴图，再回退色块——三档渐退，调用方零分支。
func _icon_texture_path(resource_id: String) -> String:
	var semantic_tex := StickIcons.semantic(resource_id)
	if semantic_tex != null:
		return semantic_tex.resource_path
	match resource_id:
		"res_wood": return "res://assets/resources/tree_paint.png"
		"res_stone": return "res://assets/resources/stone_paint.png"
		"res_metal_ore": return "res://assets/resources/metal_paint.png"
	return ""
