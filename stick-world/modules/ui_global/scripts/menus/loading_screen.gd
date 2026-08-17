class_name LoadingScreen
extends Control
## 载入屏 —— 主菜单 → 游戏 的过渡画面（纯黑 + 进度 + 提示轮换）。
##
## 当前为过渡型载入屏：显示约 2s 后切到 game_root（同步加载，进度为视觉过渡）。
## 真正的异步/分阶段进度加载留待世界生成并行化（见 03-主菜单与流程.md §四）。

const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
const LOAD_SECONDS := 2.0

## 提示轮换（数据驱动：加一条 = 加一行）
const LOADING_TIPS: Array[String] = [
	"提示：空格暂停 · 1/2/3 调速 · Tab 战略图",
	"提示：F5 快速保存 · F9 快速读档 · Ctrl+S 存档面板",
	"提示：按 F3 调试（悬停 UI 显示控件名）",
]

@onready var _title_label: Label = $CenterBox/TitleLabel
@onready var _subtitle_label: Label = $CenterBox/SubtitleLabel
@onready var _bar: ProgressBar = $CenterBox/ProgressBar
@onready var _tip_label: Label = $CenterBox/TipLabel


func _ready() -> void:
	theme = StickTheme.create()
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	_subtitle_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_subtitle_label.modulate = StickTokens.TEXT_DIM
	_tip_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_tip_label.modulate = StickTokens.TEXT_FAINT
	# 进度条：LOAD_SECONDS 内 0→100%（视觉过渡）
	var tween := create_tween()
	tween.tween_property(_bar, "value", 100.0, LOAD_SECONDS)
	# 提示轮换
	for i in LOADING_TIPS.size():
		get_tree().create_timer(i * (LOAD_SECONDS / float(LOADING_TIPS.size()))).timeout.connect(
				func(): _tip_label.text = LOADING_TIPS[i])
	# 到点切游戏根（game_root 按 SaveManager.boot_load_slot 决定新游戏/读档）
	await get_tree().create_timer(LOAD_SECONDS).timeout
	get_tree().change_scene_to_file(GAME_ROOT_SCENE)
