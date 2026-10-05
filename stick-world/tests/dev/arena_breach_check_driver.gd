extends Node
## 无头验收 driver —— 遇阻接战（局部绕行 + 打通）行为回归观察：96 人档打完为止，
## 确认没有行为退化（停战/僵局/全员钉死）。轮询战场双方存活数，一方归零或战斗
## 实例收敛即判定打完；超时未收敛按停战嫌疑报 1（需人工复查）。
## 用法（headless 即可，无需显示）：
##   godot --headless --path stick-world res://tests/dev/arena_breach_check.tscn
## 输出：阶段性存活数 + 终局摘要；退出码 0 = 打完（有胜负），1 = 超时未收敛。

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const SETTLE_FRAMES := 120       ## 出生列阵等待（~2s）
const REPORT_EVERY := 300        ## 汇报间隔（~5s）
const MAX_FRAMES := 60 * 60 * 10 ## 墙钟兜底上限（10 分钟）
const PRESET_IDX := 2            ## 大军压境·96


func run() -> void:
	get_tree().change_scene_to_file(ARENA_SCENE)
	var arena: Node = await _wait_arena()
	if arena == null:
		push_error("[ArenaBreachCheck] 观察场装配失败")
		get_tree().quit(1)
		return
	# 等首场（默认 48 档）装配收束再切档：reload 打在分帧出生协程中段会掐断
	# arena 的 await（一次性 process_frame 空引用报错，无害但难看）
	await _frames(SETTLE_FRAMES)
	# 切 96 人档（arena 自带切档 API：内置 reload，static _preset_idx 跨 reload 保持；
	# driver 侧不可经 preloaded 脚本常量直写对方 static——解析期报"常量赋值"错）
	arena.call("_switch_preset", PRESET_IDX)
	await _frames(SETTLE_FRAMES)
	var battle := _find_battle_instance()
	if battle == null:
		push_error("[ArenaBreachCheck] 找不到 battle_instance，无法轮询")
		get_tree().quit(1)
		return
	print("[ArenaBreachCheck] 96 人档开战，开始轮询")
	var frames := 0
	while frames < MAX_FRAMES:
		await _frames(REPORT_EVERY)
		frames += REPORT_EVERY
		# 溃散收敛（9k-2 同款）：战斗实例可能提前结算并释放——收敛即判打完
		if not is_instance_valid(battle) or not battle.is_active():
			print("[ArenaBreachCheck] t=%5.1fs 战斗实例已收敛结束（打完为止）" % [frames / 60.0])
			get_tree().quit(0)
			return
		var la: int = _count_alive(battle.get("_units_attacker"))
		var ra: int = _count_alive(battle.get("_units_defender"))
		print("[ArenaBreachCheck] t=%5.1fs 蓝 %2d / 红 %2d" % [frames / 60.0, la, ra])
		if la == 0 or ra == 0:
			print("[ArenaBreachCheck] t=%5.1fs 一方全灭，战斗结束（蓝 %d，红 %d）"
					% [frames / 60.0, la, ra])
			get_tree().quit(0)
			return
	print("[ArenaBreachCheck] 超时未分胜负（停战/僵局嫌疑，需人工复查）")
	get_tree().quit(1)


## 等观察场场景就绪（current_scene 带 _switch_preset 方法；上限 10s）。
func _wait_arena() -> Node:
	for i in 600:
		await get_tree().process_frame
		var cs: Node = get_tree().current_scene
		if cs != null and cs.has_method("_switch_preset"):
			return cs
	return null


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _find_battle_instance() -> Node:
	var cs: Node = get_tree().current_scene
	if cs == null:
		return null
	var stack: Array = [cs]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != null and n.get_script() != null \
				and String(n.get_script().resource_path).ends_with("battle_instance.gd"):
			return n
		stack.append_array(n.get_children())
	return null


func _count_alive(units: Variant) -> int:
	if units == null or not (units is Array):
		return 0
	var n: int = 0
	for u in units:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			n += 1
	return n
