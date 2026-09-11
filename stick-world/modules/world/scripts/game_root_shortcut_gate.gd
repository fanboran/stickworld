extends Node
## 暂停期快捷键通道 —— 引擎总闸（SceneTree.paused）冻结世界子树时，
## GameRoot（PAUSABLE）的 _unhandled_input 不再触发，而 ESC（退模态栈）、
## 空格（恢复暂停）、F5/F9（存读档）等快捷键必须在暂停期存活。
## 本节点 process_mode=ALWAYS（声明在 game_root.tscn），仅转发输入事件，
## 语义全部留在 GameRoot.handle_shortcuts，不做任何处理。

var _game_root: Node = null


func _ready() -> void:
	_game_root = get_parent()


func _unhandled_input(event: InputEvent) -> void:
	if _game_root != null and _game_root.has_method("handle_shortcuts"):
		_game_root.handle_shortcuts(event)
