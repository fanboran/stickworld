extends RefCounted
## 开发期「后置底 + 静音」启动开关——只影响本地测试/测量跑，正式流程零副作用。
##
## 用法（agent 跑探针/测量时必须带上：弹出的窗口不抢焦点、不发声，不打扰用户）：
##     STICK_DEV_QUIET=1 godot --path stick-world res://tests/dev/xxx.tscn
##
## 行为：
##   ① 静音 Master 总线（无需依赖音频设置，直接静）
##   ② 窗口不抢焦点（WINDOW_FLAG_NO_FOCUS）+ 取消置顶——新窗口既不夺焦点也不
##      压在用户窗口之上，即「后置底」
##
## headless 下窗口 API 无意义，跳过（静音同样无需执行）。
## 新增会开窗口的探针场景时，在 _ready() 首行加：
##     const DevQuiet := preload("res://tests/dev/dev_quiet.gd")
##     DevQuiet.apply_if_requested()

const ENV_KEY := "STICK_DEV_QUIET"


static func apply_if_requested() -> void:
	if OS.get_environment(ENV_KEY).is_empty():
		return
	if DisplayServer.get_name() == "headless":
		return
	var master: int = AudioServer.get_bus_index("Master")
	if master >= 0:
		AudioServer.set_bus_mute(master, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, false)
