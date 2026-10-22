extends SceneTree
## 单套件独立运行入口 —— 逐套普查/单跑用（census_unit_leaks.sh 等）。
##
## unit 套件是 Node 脚本（`tests/unit/*.gd`），不在盘上带 .tscn 壳；批量入口
## 是 batch_runner（一个进程跑全清单）。本脚本给"一进程只跑一套"的场合提供
## 通用宿主：--script 拉起本入口，用户参数传入套件 .gd 路径。
##
## 用法：
##   godot --headless --path stick-world --script res://tests/lib/unit_suite_main.gd -- \
##       res://tests/unit/test_wall_avoid.gd
##
## 套件自行经 TestRunner.finish_process 退出（独立模式直接 quit）；本入口只负责
## 实例化并挂树，另带 90s 看门狗防挂死（退出码 124，与 timeout 口径一致）。

const TIMEOUT_SEC: float = 90.0

var _elapsed: float = 0.0


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("[UnitSuite] 缺少套件路径参数（-- res://tests/unit/xxx.gd）")
		quit(2)
		return
	var suite_path: String = args[0]
	var script: GDScript = load(suite_path) as GDScript
	if script == null:
		push_error("[UnitSuite] 套件加载失败: %s" % suite_path)
		quit(2)
		return
	var inst: Node = script.new()
	if inst == null:
		push_error("[UnitSuite] 套件实例化失败: %s" % suite_path)
		quit(2)
		return
	inst.name = suite_path.get_file().get_basename()
	root.add_child(inst)
	print("[UnitSuite] 运行 %s" % suite_path)


func _process(delta: float) -> bool:
	_elapsed += delta
	if _elapsed >= TIMEOUT_SEC:
		push_error("[UnitSuite] 超时(%.0fs)，强退" % TIMEOUT_SEC)
		quit(124)
		return true
	return false
