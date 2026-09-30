extends Node
## 观察对拍门（GDScript 侧）——状态注入式对拍，直接消费阿尔法原版代码。
##
## 原理：fixture（C++ dump_obs_fixture 产物）是紧凑环境跑出的**状态帧序列**
## （单位位置/血比/旗归属进度/上拍意图）。本脚本把每帧状态原样注入
## tests/dev/rl/battle_env.gd 的实例（只读不改：GDScript 无真私有，成员直接赋值；
## 单位/旗用鸭子 stub——原版 _encode_obs 只消费 get_health/is_dead/departed/
## global_position 与旗的四只读方法），然后调用**阿尔法自己写的 _encode_obs**
## 产出 57 维观察 → obs_gate_out.json。
## C++ 侧 test_core.exe verify-obs 帧对帧比对（fixture 内含 C++ 同状态编码）。
##
## 运行：godot --headless --path . -s res://addons/rl_core/tests/obs_gate.gd -- --fixture=<绝对路径>

const BattleEnvScript: GDScript = preload("res://tests/dev/rl/battle_env.gd")
const OUT := "res://temp/rl_core_mirror/obs_gate_out.json"


class StubHealth:
	extends RefCounted
	var ratio: float = 1.0

	func get_health_ratio() -> float:
		return ratio


class StubUnit:
	extends Node2D
	var departed = false
	var hp := StubHealth.new()

	func get_health():
		return hp

	func is_dead() -> bool:
		return hp.ratio <= 0.0


class StubFlag:
	extends RefCounted
	var owner_faction: int = 0
	var progress: float = 0.0
	var pos: Vector2 = Vector2.ZERO
	var radius: float = 180.0

	func get_owner_faction() -> int:
		return owner_faction

	func get_progress() -> float:
		return progress

	func get_position() -> Vector2:
		return pos

	func get_radius() -> float:
		return radius


func _ready() -> void:
	var fixture_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fixture="):
			fixture_path = a.substr(10)
	if fixture_path.is_empty():
		push_error("[obs_gate] 需要 --fixture=<绝对路径>")
		get_tree().quit(1)
		return
	var f := FileAccess.open(fixture_path, FileAccess.READ)
	if f == null:
		push_error("[obs_gate] fixture 打不开: " + fixture_path)
		get_tree().quit(1)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary) or not data.has("frames"):
		push_error("[obs_gate] fixture 解析失败")
		get_tree().quit(1)
		return

	var env = BattleEnvScript.new() # 不进树：_ready 不跑、EventBus 不连，纯调编码函数
	var out_frames: Array = []
	for fr_v in data["frames"]:
		var fr: Dictionary = fr_v
		# 旗 stub（世界序 f0 左 / f1 中 / f2 右；几何与 owner/progress 来自帧）
		var flags: Array = []
		for pf_v in data["flags"]:
			var pf: Dictionary = pf_v
			var sf := StubFlag.new()
			sf.pos = Vector2(float(pf["x"]), float(pf["y"]))
			sf.radius = float(pf["radius"])
			flags.append(sf)
		var frame_flags: Array = fr["flags"]
		for fi in flags.size():
			flags[fi].owner_faction = int(float(frame_flags[fi]["owner"]))
			flags[fi].progress = float(frame_flags[fi]["progress"])
		# 单位 stub：按 (side, squad) 分桶，保持 fixture 序
		var by_squad := {}
		for fac in [1, 2]:
			for si in 3:
				by_squad["%d_%d" % [fac, si]] = []
		for u_v in fr["units"]:
			var u: Dictionary = u_v
			var su := StubUnit.new()
			su.global_position = Vector2(float(u["x"]), float(u["y"]))
			su.hp.ratio = float(u["ratio"])
			by_squad["%d_%d" % [int(u["side"]) + 1, int(u["squad"])]].append(su)
		var side := {}
		for fac2 in [1, 2]:
			var squads: Array = []
			var units_all: Array = []
			for si2 in 3:
				var bucket: Array = by_squad["%d_%d" % [fac2, si2]]
				squads.append({"id": "s%d_%d" % [fac2, si2], "units": bucket, "initial_n": bucket.size()})
				units_all.append_array(bucket)
			side[fac2] = {"squads": squads, "units": units_all, "initial_n": units_all.size()}
		env._side = side
		env._flags = flags
		env._t = float(fr["t"])
		env._mid_x = float(data["mid_x"])
		env._spawn_y = float(data["spawn_y"])
		var li: Dictionary = fr["last_intent"]
		var order_state := {}
		for fac3 in [1, 2]:
			var arr: Array = li[str(fac3)]
			var per := {}
			for si3 in 3:
				per[str(si3)] = {"intent": int(arr[si3])}
			order_state[fac3] = per
		env._order_state = order_state
		out_frames.append({"obs_f1": env._encode_obs(1), "obs_f2": env._encode_obs(2)})

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://temp/rl_core_mirror"))
	var of := FileAccess.open(ProjectSettings.globalize_path(OUT), FileAccess.WRITE)
	if of == null:
		push_error("[obs_gate] 写出失败")
		get_tree().quit(1)
		return
	of.store_string(JSON.stringify({"frames": out_frames, "count": out_frames.size()}))
	of.close()
	print("[obs_gate] 写出 %s（frames=%d）" % [OUT, out_frames.size()])
	get_tree().quit(0)
