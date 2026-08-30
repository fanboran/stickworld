extends Node
## 演练场视觉验收：直接加载 battle_arena，等交战后截图（战场全景 + 交战中景）。
## 运行（弹窗 ~12s 自动退出）：
##   godot --path stick-world res://tests/dev/diag_arena.tscn -- --shot=F:/out.png

const _ArenaScene: PackedScene = preload("res://tests/dev/battle_arena.tscn")

var _shot_path: String = ""
var _frames: int = 0
var _arena: Node = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
	get_window().grab_focus()
	_arena = _ArenaScene.instantiate()
	add_child(_arena)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames % 60 == 0 and _arena != null and _arena._attacker.size() > 0:
		var gr: Node = _arena.get("_game_root")
		var battles: Array = []
		if gr != null and gr.get("_combat_api") != null:
			var dir: Node = gr._combat_api.get("_director")
			if dir != null and dir.get("_battles") != null and dir._battles.size() > 0:
				var b: Node = dir._battles[0]
				if is_instance_valid(b):
					var ddead := 0
					for u in b._units_defender:
						if not is_instance_valid(u) or u.is_dead():
							ddead += 1
					battles = [b._state, b._count_alive(b._units_attacker), b._count_alive(b._units_defender), ddead]
				else:
					battles = ["battle_freed"]
		var u0 = _arena._attacker[0]
		var hc = u0.get("health_component")
		print("[timeline] f=%d 我的计数 攻%d/守%d | u0.hp=%s max=%s | battle=%s" % [_frames,
				_arena._count_alive(_arena._attacker), _arena._count_alive(_arena._defender),
				hc.get("hp"), hc.get("max_hp"), battles])
	if _frames == 300 and not _shot_path.is_empty():
		# 300 帧（~5s）：双方应已接战
		var img: Image = get_viewport().get_texture().get_image()
		var err := img.save_png(_shot_path)
		print("[arena-diag] 截图 %s (err=%d)" % [_shot_path, err])
		var gr: Node = _arena.get("_game_root")
		if gr != null:
			var battle: Node = gr.get("_combat_api")
			print("[arena-diag] 攻方存活=%d 守方存活=%d" % [
				_arena._count_alive(_arena._attacker), _arena._count_alive(_arena._defender)])
		get_tree().quit(0)
	elif _frames > 320:
		get_tree().quit(1)
