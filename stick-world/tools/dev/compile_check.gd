extends Node
## 改动面编译自检 driver——在完整启动链（autoload 齐备）的上下文里逐个 load
## 改动脚本，让编译错误真实暴露。--check-only 模式不解析 autoload 标识符
## （EventBus/TimeManager 等），引用 autoload 的脚本全部假红，不可用（实测）。
## 用法（由 tools/dev/gate.sh 调用，也可手动）：
##   godot --headless --path . res://tools/dev/compile_check.tscn -- res://a.gd res://b.gd
## 退出码 0=全部编译通过；1=有失败（失败的逐个打印）。


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("[compile_check] 未传待检脚本列表")
		get_tree().quit(1)
		return
	var failed: Array[String] = []
	for res_path in args:
		var script: GDScript = load(res_path)
		if script == null or not script.can_instantiate():
			failed.append(res_path)
			print("[compile_check] ✗ %s" % res_path)
		else:
			print("[compile_check] ✓ %s" % res_path)
	print("[compile_check] %d/%d 通过" % [args.size() - failed.size(), args.size()])
	get_tree().quit(1 if not failed.is_empty() else 0)
