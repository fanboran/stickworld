extends Node
## 诊断：观察场战斗 AI 验收截图 driver —— 由 diag_arena_ai_shots（boot）挂到
## SceneTree.root（跨场景存活：change_scene_to_file 释放场景时 driver 不死）。
## 五阶段截图：揭幕列阵 → 夺点推进早期 → 接战混战 → 中盘 → 残局/结束判定。
## 用法（必须带显示）：
##   godot --path stick-world res://tests/dev/diag_arena_ai_shots.tscn --resolution 1920x1080
## 产物：user://shots/arena_ai/<阶段>.png

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const SHOT_DIR := "user://shots/arena_ai"


func run() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	get_tree().change_scene_to_file(ARENA_SCENE)
	await _shot_at("t0_reveal", 90)      # ~1.5s：出生列阵
	await _shot_at("t1_flags", 480)      # +8s：夺点推进早期
	await _shot_at("t2_melee", 1200)     # +20s：接战混战
	await _shot_at("t3_midgame", 2400)   # +40s：中盘（胶着/溃逃可见）
	await _shot_at("t4_late", 4200)      # +70s：残局/结束判定
	get_tree().quit(0)


func _shot_at(shot_name: String, frames: int) -> void:
	for i in frames:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [SHOT_DIR, shot_name])
	print("[ArenaAiShots] %s.png fps=%d" % [shot_name, Engine.get_frames_per_second()])
