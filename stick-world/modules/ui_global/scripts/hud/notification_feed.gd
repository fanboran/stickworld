class_name NotificationFeed
extends VBoxContainer
## 通知流 —— 左下堆叠 feed（docs/设计/UI/04-游戏内HUD.md §六）。
##
## - 最多 MAX_VISIBLE 条同时可见，超出移除最旧
## - 每条停留 toast_seconds 后经 fade_seconds 淡出销毁
## - 三级着色：info 蓝 / warn 黄 / error 红（EventBus `ui_notification` 的 level）
## - 由 UIRoot 挂到 HudOverlay 槽（角落 HUD 部件自设 anchor，布局单一真相源见 UI.md）

## 同时可见上限
const MAX_VISIBLE := 5

## 停留时长（默认 StickTokens.T_TOAST；测试可注入短时长）
var toast_seconds: float = StickTokens.T_TOAST
## 淡出时长（默认 StickTokens.T_PANEL；测试可注入短时长）
var fade_seconds: float = StickTokens.T_PANEL


func _ready() -> void:
	# 左下角：贴左 12px、离底 96px（避让底部 ModePanel 高 78 + 空隙）
	set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = 12.0
	offset_top = -324.0
	offset_right = 380.0
	offset_bottom = -96.0
	grow_horizontal = Control.GROW_DIRECTION_END
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	# 新通知贴底；HUD 部件不拦截输入
	alignment = BoxContainer.ALIGNMENT_END
	add_theme_constant_override("separation", 4)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 压入一条通知（超上限移除最旧；自动过期淡出）
func push_notification(title: String, body: String, level: String = "info") -> void:
	while get_child_count() >= MAX_VISIBLE:
		var oldest: Node = get_child(0)
		remove_child(oldest)
		oldest.queue_free()
	var panel := SketchPanel.new()
	panel.tone = SketchPanel.Tone.LIGHT
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var color := StickTokens.INFO
	match level:
		"warn":
			color = StickTokens.WARN
		"error":
			color = StickTokens.DANGER
	StickKit.label(panel, "%s — %s" % [title, body], StickKit.LabelKind.HINT, color)
	add_child(panel)
	var tween := panel.create_tween()
	tween.tween_interval(toast_seconds)
	tween.tween_property(panel, "modulate:a", 0.0, fade_seconds)
	tween.tween_callback(panel.queue_free)


## 当前可见条数（含正在淡出的）
func visible_count() -> int:
	return get_child_count()
