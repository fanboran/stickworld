extends Node
## 启动时间线探针（常驻量测工具）——量「进世界」这条路上不受分帧保护的两块硬成本：
##   1. `load(game_root.tscn)`：场景资源加载 + game_root.gd 编译 + 编译期 preload 闭包
##   2. 世界装配里首个「新视觉首次绘制」帧（GPU 侧管线编译，与 GDScript 工时无关）
##
## 口径：只报毫秒数不打点注入生产代码——生产侧一行业务改动都不需要，因此可随时复跑。
##
## 用法（**必须窗口态**：headless 无渲染设备、_yield_frame 短路，量不到第 2 块）：
##   STICK_DEV_QUIET=1 godot --path . res://tests/dev/boot_timeline_probe.tscn
## 换渲染后端对照：
##   ... --rendering-driver vulkan  /  --rendering-driver d3d12
##
## 读法：`add_child 同步段` 之后的 `世界就绪` 是把整段世界装配（含那一次超长首绘帧）
## 包在一起；配合 `最长单帧` 就能看出卡的是装配逻辑还是渲染后端。

const DevQuiet := preload("res://tests/dev/dev_quiet.gd")
const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
## 世界装配等待上限（秒）
const WORLD_TIMEOUT_SEC := 300.0

var _last_ms: int = 0


func _ready() -> void:
	DevQuiet.apply_if_requested()
	_mark("探针 _ready（引擎 + autoload + 本场景）")
	await get_tree().process_frame
	await get_tree().process_frame
	_mark("渲染首帧就绪")

	var ps: PackedScene = ResourceLoader.load(GAME_ROOT_SCENE)
	_mark("load(game_root.tscn)")
	var inst: Node = ps.instantiate()
	_mark("instantiate")
	get_tree().root.add_child(inst)
	_mark("add_child 同步段")

	var worst_frame: int = 0
	var waited: float = 0.0
	var prev: int = Time.get_ticks_msec()
	while waited < WORLD_TIMEOUT_SEC:
		await RenderingServer.frame_post_draw
		var now: int = Time.get_ticks_msec()
		worst_frame = maxi(worst_frame, now - prev)
		prev = now
		waited += get_process_delta_time()
		var ov: Node = inst.get("_world_loading_overlay") if is_instance_valid(inst) else null
		if ov != null and ov.get("visible") == false:
			break
	_mark("世界就绪（最长单帧 %dms）" % worst_frame)
	get_tree().quit()


func _mark(label: String) -> void:
	var now: int = Time.get_ticks_msec()
	print("[TIMELINE] %8dms  (+%7d)  %s" % [now, now - _last_ms, label])
	_last_ms = now
