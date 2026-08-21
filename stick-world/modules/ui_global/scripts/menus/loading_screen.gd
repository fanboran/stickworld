class_name LoadingScreen
extends Control
## 载入屏 —— 主菜单 → 游戏 的短过渡（标题 + 加载环，无假进度条）。
##
## 真实的世界加载在 game_root 内由 WorldLoadingOverlay 承载（game_root 启动第一帧即显示
## "正在加载…"，覆盖装配+加载全期，世界就绪淡出），因此本屏只做"主菜单→游戏"的
## 极短过渡（约 0.5s），不做假进度——假进度条会在切 game_root 装配期"卡死"，观感差。

const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
const LOAD_SECONDS := 0.5

## 过渡期提示（固定显示第一条；加条目 = 加一行）
const LOADING_TIPS: Array[String] = [
	"提示：空格暂停 · 1/2/3 调速 · Tab 战略图",
	"提示：F5 快速保存 · F9 快速读档 · Ctrl+S 存档面板",
	"提示：按 F3 调试（悬停 UI 显示控件名）",
]

@onready var _title_label: Label = $CenterBox/TitleLabel
@onready var _subtitle_label: Label = $CenterBox/SubtitleLabel
@onready var _tip_label: Label = $CenterBox/TipLabel


func _ready() -> void:
	theme = StickTheme.create()
	_title_label.add_theme_font_size_override("font_size", StickTokens.FONT_TITLE)
	_subtitle_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_subtitle_label.modulate = StickTokens.TEXT_DIM
	_tip_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_tip_label.modulate = StickTokens.TEXT_FAINT
	_tip_label.text = LOADING_TIPS[0]
	# 到点切游戏根（game_root 启动即显示加载覆盖，world 就绪淡出）
	await get_tree().create_timer(LOAD_SECONDS).timeout
	get_tree().change_scene_to_file(GAME_ROOT_SCENE)
