extends Node
## 顶栏占用区实测探针 —— 打印顶栏各按钮 / 右上时钟区的真实屏幕矩形。
##
## 为什么需要：`hud_zone_layout.gd` 的顶部中央跨度合同（TOP_CENTER_FREE_LEFT_PX /
## TOP_CENTER_FREE_RIGHT_PX，小地图宽度上限的根据）是**从顶栏实测反填的常数**——
## 顶栏增删按钮（`global_hud.tscn` 的 HBoxContainer 子项）后这两个数会失效，
## 用本探针复测并回填 zone 表，再跑 `verify_hud_zones` 验防撞合同仍成立。
##
## 运行（要窗口，headless 量不到真实布局）：
##   godot --path stick-world res://tests/dev/probe_hud_bands.tscn
## 输出：各按钮/时钟/日时标签的 global_rect，以及当前地图的投影参数。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const BOOT_TIMEOUT_FRAMES := 900
## 顶栏 HBox 子项（顺序 = 布局顺序；Spring 是撑开通栏的空件，其左右即两段按钮群边界）
const TOP_BAR_CHILDREN: Array = [
	"SettingsButton", "FormationButton", "OverviewButton", "TechButton",
	"LogisticsButton", "CollectionButton", "CenteredButton",
	"PlaceholderPreviewButton", "Spring", "OrgButton",
]
## 右上区（时钟/日时）
const TOP_RIGHT_CHILDREN: Array = ["ClockWidget", "DayTimeLabel"]

var _game_root: Node = null


func _ready() -> void:
	_run()


func _run() -> void:
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = Vector2i(1920, 1080)
	await get_tree().process_frame
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)
	for i in BOOT_TIMEOUT_FRAMES:
		if _game_root.get_current_map() != null:
			break
		await get_tree().process_frame
	for i in 30:
		await get_tree().process_frame
	var vp := get_viewport().get_visible_rect().size
	print("=== 画布 %s（窗口 %s）===" % [vp, get_window().size])
	var map: Node2D = _game_root.get_current_map()
	if map != null:
		print("[INFO] map.left=%.1f map.right=%.1f width=%.1f ground_y=%.1f ratio=%.3f"
				% [map.map_left, map.map_right, map.map_right - map.map_left,
				map.ground_y, map.ground_ratio])
	var hud: Control = _game_root.ui_root.get_slot("GlobalHUD")
	if hud == null:
		print("[FAIL] GlobalHUD 未装配")
		get_tree().quit(1)
		return
	var hbox := hud.get_node_or_null("MarginContainer/HBoxContainer")
	if hbox != null:
		for cname in TOP_BAR_CHILDREN:
			_print_rect(hbox.get_node_or_null(cname), cname)
	for cname2 in TOP_RIGHT_CHILDREN:
		_print_rect(hud.get_node_or_null(cname2), cname2)
	print("=== 顶部中央空档（回填 hud_zone_layout.gd 用）：左 %.1f / 右 %.1f ==="
			% [HudZoneLayout.TOP_CENTER_FREE_LEFT_PX, HudZoneLayout.TOP_CENTER_FREE_RIGHT_PX])
	get_tree().quit(0)


func _print_rect(c: Control, label: String) -> void:
	if c == null:
		print("  %-24s （不存在）" % label)
		return
	var r := c.get_global_rect()
	print("  %-24s x %.1f..%.1f  y %.1f..%.1f" % [label, r.position.x, r.end.x, r.position.y, r.end.y])
