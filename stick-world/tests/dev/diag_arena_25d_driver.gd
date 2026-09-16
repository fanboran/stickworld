extends Node
## 诊断：大乱斗观察场 2.5D 观感巡检截图 driver —— 由 diag_arena_25d_shots（boot）
## 挂到 SceneTree.root（跨场景存活：change_scene_to_file 释放场景时 driver 不死）。
## 进大乱斗观察场（默认档·标准战役 48），等开场遮罩撤除（=战场已装配、相机
## 已对位、部队已出生）后按战斗阶段各截一张：开幕→推进→接战→混战→残局。


const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const SHOT_DIR := "user://shots/arena25d"


func run() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	get_tree().change_scene_to_file(ARENA_SCENE)
	# 等揭幕：ArenaCover 撤除 = _reveal 已跑（战场加载+相机对位+部队出生完成）。
	# 上限 ~70s（boot 30s + 战场装配余量），超时也照截（截到什么诊断什么）。
	var waited := false
	for i in 4200:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			waited = true
			break
	print("[Arena25dShots] cover gone=%s" % waited)
	await _frames(10)
	await _shot("t0_reveal")
	await _wait_s(6.0)
	await _shot("t1_advance")
	await _wait_s(9.0)
	await _shot("t2_contact")
	await _wait_s(15.0)
	await _shot("t3_melee")
	await _wait_s(20.0)
	await _shot("t4_late")
	get_tree().quit(0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait_s(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _shot(shot_name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[Arena25dShots] %s.png" % shot_name)
