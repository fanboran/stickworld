extends Control
## 载入屏 —— 主菜单 → 游戏 的跳板（本屏不再自带视觉）。
##
## 职责：把常驻加载层（WorldLoadingOverlay）挂到**场景树根**——它不随本场景
## 释放，切到 game_root 期间持续在屏；game_root 启动后经 group 认领同一块层，
## 继续驱动分段进度到世界就绪。点「继续游戏」到进世界是**同一块加载屏**，
## 交接零缝隙（旧两屏方案：各自挂场景内，切换时旧的销毁、新的没首帧，必卡缝）。
## 直启 game_root（编辑器 F5/测试）没有跳板，game_root 自建兜底。
##
## ⚠ 主动放弃的优化（2026-09-11，防重踩）：menu 闲时 `load_threaded_request`
## 预热 game_root.tscn/村庄图。收益被全屏加载层盖住，风险实测三次事故——
## 线程加载会后台编译 game_root.gd，编译期十几条地图 `preload` 与主线程资源
## 操作竞态（同步加载相撞=主线程死锁；编译竞态=preload 资源风暴、场景切空壳）。
## 资源线程化预热只对「无脚本 preload 闭包的纯数据资源」安全。

const GAME_ROOT_SCENE := "res://modules/world/scenes/game_root.tscn"
const _OverlayScript: GDScript = preload("res://modules/ui_global/scripts/overlays/world_loading_overlay.gd")
const _WarmupScript: GDScript = preload("res://modules/ui_global/scripts/loading/boot_warmup.gd")
## 跳板停留时间（给常驻层首帧渲染 + 提示可读的最低保障）
const LOAD_SECONDS := 0.5

## 常驻加载层上的覆盖层（跨本屏与 game_root 存活，game_root 启动后经 group 认领同一块）
var _overlay: Control = null


func _ready() -> void:
	# 必须 await：本函数内含等帧（deferred 挂层），不等就 _overlay 还是 null，
	# 预热的门禁会静默跳过整段预热
	await _install_root_overlay()
	var t0: int = Time.get_ticks_msec()
	# 先分块预热编译闭包（可见进度）——不预热则这段工时全炸在 change_scene_to_file 里
	await _warm_up()
	var rest: float = LOAD_SECONDS - float(Time.get_ticks_msec() - t0) / 1000.0
	if rest > 0.0:
		await get_tree().create_timer(rest).timeout
	get_tree().change_scene_to_file(GAME_ROOT_SCENE)


## 分块预热 `game_root` 的编译闭包（见 BootWarmup 头注）。
## 为什么放这里：这段编译工时原本整块落在下一行 `change_scene_to_file` 内，
## 而九段进度从 `GameRoot._ready` 才开始——不挪出来，加载屏只能钉在 0% 冻着。
func _warm_up() -> void:
	if _overlay == null or not _WarmupScript.enabled():
		return
	var warmup: RefCounted = _WarmupScript.new()
	if warmup.prepare() <= 0:
		return
	_show_progress("正在准备资源…", 0.0)
	await warmup.warm(get_tree(), func(done: int, total: int) -> void:
		_show_progress("正在准备资源…（%d/%d）" % [done, total], float(done) / float(total)))


func _show_progress(message: String, ratio: float) -> void:
	if _overlay != null and _overlay.has_method("show_loading"):
		_overlay.show_loading(message, ratio)


## 挂常驻加载层到场景树根（已存在则复用——回主菜单再进游戏的第二轮）。
## root.add_child 需 deferred：菜单 _ready 处于场景装配期，同步挂会撞
## "Parent is busy setting up children"（SketchTextures.ensure_driver 同坑）。
## 第二轮复用同一块层：overlay 已被 game_root 淡出隐藏过，这里重新点亮，
## 否则第二轮又回到「切场景期全黑无提示」（旧实现在层已存在时直接 return）。
func _install_root_overlay() -> void:
	var root := get_tree().root
	var layer: CanvasLayer = root.get_node_or_null("BootLoadingLayer") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "BootLoadingLayer"
		layer.layer = 100  # 压过一切场景内 UI（含 game_root 的 WorldLoadingLayer）
		root.add_child.call_deferred(layer)
		await get_tree().process_frame
	if not is_instance_valid(layer):
		return
	_overlay = layer.get_node_or_null("WorldLoadingOverlay") as Control
	if _overlay == null:
		var ov: Control = _OverlayScript.new()
		ov.name = "WorldLoadingOverlay"
		ov.set_anchors_preset(Control.PRESET_FULL_RECT)
		layer.add_child(ov)
		_overlay = ov
	_show_progress("正在进入世界…", 0.0)
