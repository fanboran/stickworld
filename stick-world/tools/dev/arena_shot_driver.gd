extends Node
## 观察场快照 driver——由 arena_shot_boot 挂到 SceneTree.root（跨场景存活），
## 按真实秒表在观察场内定时截图。复刻 diag_arena_driver 的已验证截图调用
## （get_viewport().get_texture().get_image()，采前等一帧渲染）。


const SHOT_DIR := "user://shots"
var _t0 := 0.0


func run(tag: String, preset: int, secs: int, every: int) -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_t0 = Time.get_ticks_msec() / 1000.0
	for t in range(0, secs + 1, maxi(every, 1)):
		await _wall_seconds(maxf(t - _elapsed(), 0.0))
		await get_tree().process_frame   # 当帧渲染完成后再采（diag 同口径）
		var img := get_viewport().get_texture().get_image()
		var name := "%s_p%d_t%d" % [tag, preset, t]
		img.save_png("%s/%s.png" % [SHOT_DIR, name])
		print("[ArenaWorkbench] shot %s/%s.png" % [SHOT_DIR, name])
	await _wall_seconds(maxf(secs - _elapsed(), 0.0))
	print("[ArenaWorkbench] done preset=%d secs=%d" % [preset, secs])
	get_tree().quit(0)


func _elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - _t0


func _wall_seconds(s: float) -> void:
	if s <= 0.0:
		return
	var target := Time.get_ticks_msec() + int(s * 1000.0)
	while Time.get_ticks_msec() < target:
		await get_tree().process_frame
