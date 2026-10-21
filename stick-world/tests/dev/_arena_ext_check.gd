extends Node
## 演练场扩展自验 driver（headless，非 CI 测试；下划线前缀 = 不入主菜单场景列表）。
##
## 覆盖（对应本轮两件扩展）：
##   A. 静态件：battle_arena 自定义编成 sanitize 钳制 / _auto_platoons 排聚合推导
##      / _effective_presets 第四档装配（文件层注入）；
##   B. 默认镜像回归：内置 16 档（无自定义档时）双方 16v16 正常开战（出生重构
##      _spawn_side 拆分后的镜像路径零回归）；
##   C. 自定义非对称：user:// 写入左右独立编成 → 第四档生效，左右人数按各自
##      编成出生（左 4 班×4 / 右 1 班 12 人含远程）；
##   D. 单挑观察场：配对出生 → 开战 → 一方阵亡收束（开局即战能打死）。
##
## 运行：godot --headless --path . res://tests/dev/_arena_ext_check.tscn
## 退出码：0 全过 / 1 有失败（[ArenaExt][FAIL] 逐条）。
## 收尾：删除 user://arena_composition.json（自验不留脏配置）。

const _ArenaScene: PackedScene = preload("res://tests/dev/battle_arena.tscn")
const _ArenaScript: GDScript = preload("res://tests/dev/battle_arena.gd")
const _DuelScene: PackedScene = preload("res://tests/dev/duel_arena.tscn")
const _DuelScript: GDScript = preload("res://tests/dev/duel_arena.gd")

## 等开战预算（秒，墙钟；含 GameRoot boot/切图/出生）
const STARTUP_BUDGET_SEC: float = 120.0
## 单挑收束预算（游戏秒 @time_scale 4）
const DUEL_TIMEOUT_SEC: float = 240.0
## headless 加速倍率（battle_sim 同口径）
const SIM_TIME_SCALE: float = 4.0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	Engine.time_scale = SIM_TIME_SCALE
	var failures: Array = []
	# A. 静态件
	failures.append_array(_check_statics())
	# B. 默认镜像回归（无自定义档）
	_cleanup_custom()
	_reset_arena_statics(0)
	var r_b: Dictionary = await _boot_arena()
	if not r_b["ok"]:
		failures.append("B 默认档开战失败：%s" % r_b["err"])
	elif int(r_b["left"]) != 16 or int(r_b["right"]) != 16:
		failures.append("B 默认档人数不对：左 %d / 右 %d（应 16/16）" % [r_b["left"], r_b["right"]])
	await _free_arena()
	# C. 自定义非对称（左右独立编成，文件层写入 = 面板「应用」的持久化产物）
	var comp := {
		"mirror": false,
		"left": [
			{"name": "矛士班", "rows": [{"weapon": 1, "count": 4}]},
			{"name": "剑士班", "rows": [{"weapon": 0, "count": 4}]},
			{"name": "混编班", "rows": [{"weapon": 0, "count": 2}, {"weapon": 1, "count": 2}]},
			{"name": "火力班", "rows": [{"weapon": 2, "count": 2}, {"weapon": 4, "count": 2}]},
		],
		"right": [
			{"name": "重装班", "rows": [{"weapon": 0, "count": 8}, {"weapon": 5, "count": 4}]},
		],
	}
	_write_custom_file(comp)
	_reset_arena_statics(3)   # 3 = 自定义第四档
	var r_c: Dictionary = await _boot_arena()
	if not r_c["ok"]:
		failures.append("C 自定义档开战失败：%s" % r_c["err"])
	elif int(r_c["left"]) != 16 or int(r_c["right"]) != 12:
		failures.append("C 自定义档人数不对：左 %d / 右 %d（应 16/12）" % [r_c["left"], r_c["right"]])
	await _free_arena()
	# D. 单挑观察场（矛 vs 剑，开局即战到分出胜负）
	_reset_arena_statics(0)
	_cleanup_custom()
	_DuelScript.set("_blue_weapon", 1)
	_DuelScript.set("_red_weapon", 0)
	var duel: Node = _DuelScene.instantiate()
	add_child(duel)
	var r_d: Dictionary = await _await_duel_settled(duel)
	if not r_d["ok"]:
		failures.append("D 单挑收束失败：%s" % r_d["err"])
	duel.queue_free()
	await get_tree().process_frame
	# 收尾
	Engine.time_scale = 1.0
	_cleanup_custom()
	if failures.is_empty():
		print("[ArenaExt] ================ 全过（静态件/默认镜像/自定义非对称/单挑收束）================")
		get_tree().quit(0)
	else:
		for f in failures:
			print("[ArenaExt][FAIL] %s" % f)
		print("[ArenaExt] ================ %d 项失败 ================" % failures.size())
		get_tree().quit(1)


# ─────────────────────────────── A. 静态件 ────────────────────────────────

func _check_statics() -> Array:
	var fails: Array = []
	# sanitize：垃圾输入全防御（类型错/越界裁剪/空侧拒绝）
	var garbage: Dictionary = _ArenaScript._sanitize_custom("not-a-dict")
	if not garbage.is_empty():
		fails.append("A sanitize 非法输入应返回空")
	var bad_side: Dictionary = _ArenaScript._sanitize_custom({
		"mirror": true,
		"left": [
			{"name": "a", "rows": [{"weapon": 9, "count": 3}, {"weapon": 0, "count": 0},
				{"weapon": 1, "count": 4}]},
			"junk",
			{"name": "b", "rows": "junk"},
		],
	})
	if bad_side.is_empty() or (bad_side["left"] as Array).size() != 1 \
			or int(bad_side["left"][0]["rows"][0]["count"]) != 4:
		fails.append("A sanitize 行级过滤不对：%s" % [bad_side])
	# 非镜像缺右方 → 空
	var no_right: Dictionary = _ArenaScript._sanitize_custom({"mirror": false, "left": [
		{"name": "a", "rows": [{"weapon": 0, "count": 4}]}]})
	if not no_right.is_empty():
		fails.append("A sanitize 非镜像缺右方应拒绝")
	# _auto_platoons：<4 无排层；4/6 两两；5 奇尾并三班
	var cases := {
		2: [], 3: [], 4: [[0, 1], [2, 3]], 5: [[0, 1, 2], [3, 4]],
		6: [[0, 1], [2, 3], [4, 5]],
	}
	for n in cases:
		var got: Array = _ArenaScript._auto_platoons(n)
		var want: Array = cases[n]
		if str(got) != str(want):
			fails.append("A auto_platoons(%d)=%s 应为 %s" % [n, got, want])
	# _effective_presets：无自定义 = 3 档（PRESETS 本体不被污染）
	_reset_arena_statics(0)
	_cleanup_custom()
	var eff: Array = _ArenaScript._effective_presets()
	if eff.size() != 3:
		fails.append("A 无自定义时生效档应 3，实为 %d" % eff.size())
	return fails


# ─────────────────────────── B/C. 观察场 boot ───────────────────────────

## 起 arena 等开战，返回 {ok, left, right, err}
func _boot_arena() -> Dictionary:
	var arena: Node = _ArenaScene.instantiate()
	add_child(arena)
	var waited: float = 0.0
	while waited < STARTUP_BUDGET_SEC:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if arena == null or not is_instance_valid(arena):
			return {"ok": false, "err": "arena 实例失效"}
		var atk: Array = arena.get("_attacker") if arena.get("_attacker") != null else []
		var dfd: Array = arena.get("_defender") if arena.get("_defender") != null else []
		if atk.size() > 0 and dfd.size() > 0 and bool(arena.get("_camera_following")):
			print("[ArenaExt] 开战: 左 %d vs 右 %d" % [atk.size(), dfd.size()])
			return {"ok": true, "left": atk.size(), "right": dfd.size(), "err": ""}
	return {"ok": false, "err": "开战超时（%.0fs）" % waited}


func _free_arena() -> void:
	var arena := get_node_or_null("BattleArena")
	if arena != null:
		arena.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame


# ─────────────────────────── D. 单挑收束 ───────────────────────────

## 等 duel 开战并打到一方阵亡，返回 {ok, winner, err}
func _await_duel_settled(duel: Node) -> Dictionary:
	var waited: float = 0.0
	var started := false
	while waited < DUEL_TIMEOUT_SEC:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if duel == null or not is_instance_valid(duel):
			return {"ok": false, "err": "duel 实例失效"}
		var blue: Node2D = duel.get("_blue")
		var red: Node2D = duel.get("_red")
		if blue == null or red == null:
			continue
		if not started and is_instance_valid(blue) and is_instance_valid(red):
			started = true
			print("[ArenaExt] 单挑开战: 矛 vs 剑")
		if started:
			var b_dead: bool = _unit_dead(blue)
			var r_dead: bool = _unit_dead(red)
			if b_dead or r_dead:
				var winner: String = "红方" if b_dead and not r_dead else ("蓝方" if r_dead and not b_dead else "同归")
				var tally: Dictionary = _DuelScript.get("_tally")
				print("[ArenaExt] 单挑收束: %s 胜（比分 蓝%d:红%d）" % [
					winner, int(tally.get(1, 0)), int(tally.get(2, 0))])
				if winner == "同归":
					return {"ok": true, "winner": winner, "err": ""}
				return {"ok": true, "winner": winner, "err": ""}
	return {"ok": false, "err": "单挑超时未分胜负（%.0fs）" % waited}


func _unit_dead(u: Node2D) -> bool:
	if u == null or not is_instance_valid(u):
		return true
	var hc = u.get("health_component")
	return hc == null or hc.is_dead()


# ─────────────────────────── 自定义档文件层 ───────────────────────────

## 复刻配置窗「应用」的落盘产物（不直接调 apply——它会 reload current scene，
## driver 场景下语义错位；落盘格式一致即同一持久层）
func _write_custom_file(comp: Dictionary) -> void:
	var sane: Dictionary = _ArenaScript._sanitize_custom(comp)
	var f := FileAccess.open(_ArenaScript.CUSTOM_SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("[ArenaExt] 落盘失败")
		return
	f.store_string(JSON.stringify(sane, "\t"))
	f.close()


func _cleanup_custom() -> void:
	if FileAccess.file_exists(_ArenaScript.CUSTOM_SAVE_PATH):
		DirAccess.remove_absolute(_ArenaScript.CUSTOM_SAVE_PATH)


## 重置 arena 静态态（跨用例隔离：编成缓存/档位）
func _reset_arena_statics(idx: int) -> void:
	_ArenaScript.set("_custom_comp", {})
	_ArenaScript.set("_preset_idx", idx)
