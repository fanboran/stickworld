class_name BuildListWindow
extends StickWindow
## 建造列表窗 —— DOCK 弹窗行为模板的首个业务面板（docs/技术/UI/弹窗与模态.md §六：
## 停靠屏幕角落、无遮罩、面板外鼠标穿透到游戏、✕/ESC 关闭自身）。
##
## 停靠右下角并夹进安全矩形（底部让出 ModePanel 底带、顶部让出顶栏/材料条，
## 见 StickKit.safe_rect）。窗体骨架（SketchPanel + 标题栏 + ✕）由 StickWindow
## 提供；建筑条目内容由 BuildMenu 经 list_container 装填与刷新。

## 建筑条目容器（BuildMenu._refresh_list 装填；ScrollContainer 滚动）
var list_container: VBoxContainer = null


func _ready() -> void:
	behavior = Behavior.DOCK
	dock_corner = StickKit.Corner.BOTTOM_RIGHT
	window_title = "建造"
	window_size = Vector2(208, 446)
	super._ready()
	_build_window()
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(scroll)
	list_container = VBoxContainer.new()
	list_container.name = "List"
	list_container.add_theme_constant_override("separation", 4)
	scroll.add_child(list_container)
