extends SceneTree
## 闭包加载计时（诊断）：把 game_root.tscn 的冷加载 9.6s 拆到具体成分上。
##
## 手法：每个模式在**全新进程**里先冷加载一组已知条目，再加载 game_root.tscn，
## 于是 game_root.tscn 的剩余耗时 = 总成本 − 已预热部分。同一模式重复跑可看抖动。
##
## 用法：godot --headless --path . --script res://tests/dev/closure_probe.gd -- --stage=<模式>
##   模式 none       ：什么都不预热（基线，应复现 ~9.6s）
##   模式 maps       ：预热 13 张地图 PackedScene
##   模式 setup      ：预热 system_setup.gd（编译器会连带编译其 45 个 preload 脚本）
##   模式 maps,setup ：两者都预热
##   模式 warmup     ：走生产预热器 BootWarmup.prepare() 的闭包清单（**同步**全量加载，
##                     不逐帧——本探针只验缓存效果，分帧开销由 boot_timeline_probe 量）

const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
const SYSTEM_SETUP_SCRIPT := "res://modules/world/scripts/setup/system_setup.gd"
const _WarmupScript: GDScript = preload("res://modules/ui_global/scripts/loading/boot_warmup.gd")

static var MAP_PATHS: PackedStringArray = [
	"res://modules/world/scenes/maps/hd2d_street.tscn",
	"res://modules/world/scenes/maps/hd2d_village_b.tscn",
	"res://modules/world/scenes/maps/hd2d_battlefield.tscn",
	"res://modules/world/scenes/maps/hd2d_resource_w.tscn",
	"res://modules/world/scenes/maps/hd2d_resource_e.tscn",
	"res://modules/world/scenes/maps/hd2d_settlement_00.tscn",
	"res://modules/world/scenes/maps/hd2d_settlement_01.tscn",
	"res://modules/world/scenes/maps/hd2d_settlement_02.tscn",
	"res://modules/world/scenes/maps/hd2d_settlement_03.tscn",
	"res://modules/world/scenes/maps/hd2d_settlement_04.tscn",
	"res://modules/world/scenes/maps/hd2d_settlement_05.tscn",
	"res://modules/world/scenes/maps/hd2d_settlement_06.tscn",
	"res://modules/world/scenes/maps/hd2d_settlement_07.tscn",
]


func _initialize() -> void:
	var mode: String = ""
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--stage="):
			mode = str(a).get_slice("=", 1)
	var parts: PackedStringArray = mode.split(",") if not mode.is_empty() else PackedStringArray()
	var t0: int = Time.get_ticks_msec()
	if parts.has("maps"):
		for p in MAP_PATHS:
			_load(p, "预热地图")
	if parts.has("setup"):
		_load(SYSTEM_SETUP_SCRIPT, "预热 system_setup.gd（含 45 个 preload）")
	if parts.has("warmup"):
		var warmup: RefCounted = _WarmupScript.new()
		var count: int = warmup.prepare()
		print("[CLOSURE] BootWarmup 闭包清单 %d 条（起点 %d 个）：" % [
			count, (_WarmupScript.ROOT_PATHS as PackedStringArray).size()])
		var t_w: int = Time.get_ticks_msec()
		var worst: int = 0
		for i in count:
			var t_one: int = Time.get_ticks_msec()
			ResourceLoader.load(warmup.item_path(i))
			worst = maxi(worst, Time.get_ticks_msec() - t_one)
		print("[CLOSURE] 同步预热 %d 条耗时 %dms（最坏单项 %dms）" % [
			count, Time.get_ticks_msec() - t_w, worst])
	print("[CLOSURE] ---- 预热合计 %dms（模式 %s）----" % [Time.get_ticks_msec() - t0, mode])
	_load(GAME_ROOT_SCENE, "game_root.tscn 冷加载")
	print("[CLOSURE] ==== 进程总计 %dms（模式 %s）====" % [Time.get_ticks_msec() - t0, mode])
	quit()


func _load(path: String, label: String) -> void:
	var t: int = Time.get_ticks_msec()
	var r: Resource = ResourceLoader.load(path)
	var now: int = Time.get_ticks_msec()
	print("[CLOSURE] %7dms  (+%6d)  %s  %s  %s" % [
		now, now - t, "OK" if r != null else "FAIL", label, path])
