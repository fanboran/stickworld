class_name WorkspaceTemplate
extends Control
## 工作区预设切换模板 —— 组织管理面板：顶部标签切换 = 切换工作区（Blender 式）。
##
## 设计要点（详见 docs/设计/UI/04-游戏内HUD.md §工作区预设）：
## - 所有标签底层能力相同，预设只决定"默认摆出哪些快速操作"；
##   「完整功能」折叠区永远能展开全部能力
## - 工作区是数据（WORKSPACES）：加一个标签 = 加一行
## - 左树右操作：组织树占位 + 右侧快速操作随标签重建
##
## F6 直接运行可预览。

const INDEX_SCENE := "res://modules/ui_global/scenes/templates/template_index.tscn"

## 工作区预设数据：quick = 默认摆出的快速操作；full = 完整功能（折叠展开）；stats = 右下摘要
const WORKSPACES: Array[Dictionary] = [
	{
		"id": "military", "label": "军事",
		"quick": ["进攻", "防御", "行军", "呼叫支援", "部署", "操练"],
		"stats": {"编制数": "12", "总兵力": "1,480", "士气": "82%"},
	},
	{
		"id": "research", "label": "科研",
		"quick": ["分配课题", "审核论文", "调拨经费", "实验"],
		"stats": {"在研课题": "6", "研究员": "230", "产出/月": "14"},
	},
	{
		"id": "engineer", "label": "工程",
		"quick": ["开工", "验收", "材料调度", "质量检查"],
		"stats": {"在建项目": "4", "工匠": "96", "完工率": "91%"},
	},
	{
		"id": "admin", "label": "行政",
		"quick": ["征税", "户籍", "司法", "治安"],
		"stats": {"下辖聚落": "8", "户籍人口": "12,540", "治安": "良好"},
	},
	{
		"id": "commerce", "label": "商业",
		"quick": ["采购", "销售", "定价", "物流"],
		"stats": {"商队": "3", "月流水": "2,300", "库存周转": "12天"},
	},
]

## 完整功能列表：所有标签共享同一底层能力（演示取并集）
const FULL_OPS: Array[String] = [
	"进攻", "防御", "行军", "呼叫支援", "部署", "操练",
	"分配课题", "审核论文", "调拨经费", "实验",
	"开工", "验收", "材料调度", "质量检查",
	"征税", "户籍", "司法", "治安",
	"采购", "销售", "定价", "物流",
]

@onready var _tab_bar: HBoxContainer = $Window/MainVBox/TabBar
@onready var _tree_vbox: VBoxContainer = $Window/MainVBox/Body/TreePanel/TreeVBox
@onready var _right_panel: VBoxContainer = $Window/MainVBox/Body/RightPanel
@onready var _title_label: Label = $Window/MainVBox/Header/TitleLabel
@onready var _breadcrumb: Label = $Window/MainVBox/Header/Breadcrumb
@onready var _nav_button: Button = $Window/MainVBox/Header/NavButton

var _active_ws: String = ""
var _tab_buttons: Dictionary = {}


func _ready() -> void:
	theme = StickTheme.create()
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	_breadcrumb.modulate = StickTokens.TEXT_DIM
	_nav_button.pressed.connect(func(): get_tree().change_scene_to_file(INDEX_SCENE))
	_build_tabs()
	_build_tree_placeholder()
	_select_workspace(WORKSPACES[0]["id"])


# ─────────────────────────────── 标签栏 ────────────────────────────────

func _build_tabs() -> void:
	for ws in WORKSPACES:
		var btn := StickKit.button(_tab_bar, ws["label"],
				_select_workspace.bind(ws["id"]), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H)
		btn.custom_minimum_size = Vector2(120, StickTokens.BTN_H)
		_tab_buttons[ws["id"]] = btn


func _select_workspace(ws_id: String) -> void:
	_active_ws = ws_id
	for id in _tab_buttons:
		var btn: Button = _tab_buttons[id]
		if id == ws_id:
			btn.add_theme_stylebox_override("normal", StickStyle.tab_selected())
			btn.add_theme_color_override("font_color", StickTokens.ACCENT)
		else:
			btn.remove_theme_stylebox_override("normal")
			btn.remove_theme_color_override("font_color")
	_rebuild_right()


# ─────────────────────────────── 左侧组织树（占位）────────────────────────────────

func _build_tree_placeholder() -> void:
	StickKit.label(_tree_vbox, "组织结构", StickKit.LabelKind.SECTION)
	# 伪树：落地时换 Tree 控件接 organization_api
	var lines: Array[Array] = [
		[0, "▾ 帝国统帅部"],
		[1, "▾ 第一军"],
		[2, "第一步兵团 ✚"],
		[2, "第二步兵团"],
		[1, "▸ 第二军"],
		[0, "▸ 皇家工程总署"],
		[0, "▸ 中央科学院"],
	]
	for line in lines:
		var l := StickKit.label(_tree_vbox, "    ".repeat(line[0]) + line[1], StickKit.LabelKind.BODY)
		if String(line[1]).ends_with("✚"):
			l.modulate = StickTokens.ACCENT


# ─────────────────────────────── 右侧（随工作区重建）────────────────────────────────

func _rebuild_right() -> void:
	for child in _right_panel.get_children():
		child.queue_free()
	var ws: Dictionary = _find_workspace(_active_ws)
	if ws.is_empty():
		return
	# 快速操作（预设摆出的常用）
	var quick_sec := StickKit.section(_right_panel, "快速操作 · %s" % ws["label"])
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	quick_sec.add_child(grid)
	for op in ws["quick"]:
		var btn := StickKit.button(grid, op, func():
			StickKit.toast(self, "执行：%s（演示）" % op, "info")
		, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_LG)
		btn.custom_minimum_size = Vector2(160, StickTokens.BTN_H_LG)
	# 完整功能（折叠；所有标签同一底层能力）
	var fold_btn := StickKit.button(_right_panel, "完整功能 ▾（所有标签共享同一底层能力）",
			Callable(), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	fold_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var full_box := VBoxContainer.new()
	full_box.add_theme_constant_override("separation", 6)
	full_box.visible = false
	_right_panel.add_child(full_box)
	var full_grid := GridContainer.new()
	full_grid.columns = 6
	full_grid.add_theme_constant_override("h_separation", 6)
	full_grid.add_theme_constant_override("v_separation", 6)
	full_box.add_child(full_grid)
	for op in FULL_OPS:
		var is_quick: bool = op in ws["quick"]
		var btn := StickKit.button(full_grid, op, func():
			StickKit.toast(self, "执行：%s（演示）" % op, "info")
		, StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
		btn.custom_minimum_size = Vector2(110, StickTokens.BTN_H_SM)
		if is_quick:
			btn.modulate = StickTokens.TEXT_FAINT
	fold_btn.pressed.connect(func():
		full_box.visible = not full_box.visible
		fold_btn.text = ("完整功能 ▴" if full_box.visible else "完整功能 ▾") + "（所有标签共享同一底层能力）"
	)
	# 摘要统计
	var stat_sec := StickKit.section(_right_panel, "摘要")
	var stat_grid := GridContainer.new()
	stat_grid.columns = 3
	stat_grid.add_theme_constant_override("h_separation", 16)
	stat_grid.add_theme_constant_override("v_separation", 6)
	stat_sec.add_child(stat_grid)
	for key in ws["stats"]:
		var cell := VBoxContainer.new()
		stat_grid.add_child(cell)
		StickKit.label(cell, key, StickKit.LabelKind.TINY)
		var v := StickKit.label(cell, ws["stats"][key], StickKit.LabelKind.BODY)
		v.modulate = StickTokens.ACCENT


func _find_workspace(ws_id: String) -> Dictionary:
	for ws in WORKSPACES:
		if ws["id"] == ws_id:
			return ws
	return {}
