extends Node
## 诊断：血条视觉验收截图 driver —— 由 diag_arena_shots（boot）挂到
## SceneTree.root（跨场景存活：change_scene_to_file 释放场景时 driver 不死）。
## 进大乱斗观察场，在开战初期（满血圆点）与混战期（掉血横条）各截一张。


const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const SHOT_DIR := "user://shots"


func run() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	get_tree().change_scene_to_file(ARENA_SCENE)
	await _frames(90)   # ~1.5s：出生 + 编队推进开始（满血圆点阶段）
	await _shot("arena_health_0")
	await _frames(300)  # +5s：接战混战（掉血横条阶段）
	await _shot("arena_health_1")
	get_tree().quit(0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(shot_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[ArenaShots] %s.png" % shot_name)
