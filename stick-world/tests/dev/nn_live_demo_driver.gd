extends Node
## NN 实机演示 driver —— 由 nn_live_demo（boot 场景）挂到 SceneTree.root
## （跨场景存活：change_scene_to_file / reload_current_scene 只换 current_scene，driver 不死）。
## 一侧由 RL checkpoint 驱动（benchmark_brains/nn_brain，号令走 TacticalOrders 通道），
## 对侧保持现任军师规划器；顶部横幅实时标注双方身份、NN 每班号令与终局判定。
## 用法（必须带显示，创始人肉眼观察）：
##   godot --path stick-world res://tests/dev/nn_live_demo.tscn -- --preset=2 --side=1
##     --preset 0/1/2 = 遭遇战16 / 标准战役48 / 大军压境96（默认 2）
##     --side   1/2   = NN 执蓝方(攻·左) / 红方(守·右)（默认 1）
## 热键：S 换边重开；R 重开 / 1-2-3 换规模 / 空格暂停 / ESC 退出由观察场自理。

const ARENA_SCENE := "res://tests/dev/battle_arena.tscn"
const ArenaScript: GDScript = preload("res://tests/dev/battle_arena.gd")
const NNBrainScript: GDScript = preload("res://tests/dev/benchmark_brains/nn_brain.gd")

## 训练器在写的 checkpoint → 开演前拷快照再装载，防读到半截 JSON
const SRC_CHECKPOINT := "user://rl/checkpoint_cpp.json"
const DEMO_CHECKPOINT := "user://rl/checkpoint_demo.json"
## 意图词表（与 nn_brain N_INTENTS=5 同序：攻左/中/右旗·驻防·接敌）
const INTENT_NAMES := ["攻左旗", "攻中旗", "攻右旗", "驻防", "接敌"]

var nn_side: int = 1
var _brain: RefCounted = null
var _arena: Node = null
var _ckpt_note: String = ""
var _banner: Label = null
var _order_line: Label = null
var _status_line: Label = null
var _poll_acc: float = 0.5


func run() -> void:
	var preset := 2
	for a in OS.get_cmdline_user_args():
		var kv := String(a).trim_prefix("--").split("=", true, 1)
		if kv.size() != 2:
			continue
		match kv[0]:
			"preset":
				preset = clampi(int(kv[1]), 0, 2)
			"side":
				nn_side = clampi(int(kv[1]), 1, 2)
	# 预设档位经脚本 static 写入（写不进 = 按场景默认档开演，可按 1/2/3 切换，不致命）
	ArenaScript.set("_preset_idx", preset)
	if int(ArenaScript.get("_preset_idx")) != preset:
		push_warning("[NNDemo] 预设档位写入失败，按默认档开演（可按 1/2/3 切换）")
	_build_banner()
	_snapshot_checkpoint()
	get_tree().change_scene_to_file(ARENA_SCENE)


func _process(delta: float) -> void:
	var scene := get_tree().current_scene
	if scene == null or scene.get_script() != ArenaScript:
		return
	if _arena != scene:
		# 新一局（R 重开 / 换预设 / S 换边）：重置挂载态重新等编班就位
		_arena = scene
		_brain = null
		_refresh_banner()
	if _brain == null:
		# 编班与规划器在开战序列尾段才就位（首次启动约 30s）——就位即挂载
		var planners: Dictionary = scene.get("_planners")
		if planners.size() >= 2 and _find_battle(scene) != null:
			_attach(scene)
		return
	if not TimeManager.is_paused():
		_brain.tick(delta)
	_poll_acc -= delta
	if _poll_acc <= 0.0:
		_poll_acc = 0.5
		_refresh_banner()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_S:
		nn_side = 3 - nn_side
		_brain = null
		_refresh_banner()
		get_tree().reload_current_scene()


func _attach(arena: Node) -> void:
	var brain: RefCounted = NNBrainScript.new()
	brain.ctx = {
		"battle": _find_battle(arena),
		"arena": arena,
		"faction": nn_side - 1,
		"checkpoint_path": DEMO_CHECKPOINT,
	}
	brain.setup()
	_brain = brain
	print("[NNDemo] NN 已挂载 %s（%s）%s" % [_side_name(nn_side), brain.brain_name(), _ckpt_note])
	_refresh_banner()


## 训练 checkpoint 快照：解析通过才落盘（防训练器写盘中途读到半截文件），
## 最多重试 12 次（~6s）；失败则 nn_brain 自行退化启发式（横幅会带说明）。
func _snapshot_checkpoint() -> void:
	for i in 12:
		var src := FileAccess.open(SRC_CHECKPOINT, FileAccess.READ)
		if src != null:
			var txt := src.get_as_text()
			src.close()
			var parsed: Variant = JSON.parse_string(txt)
			if parsed is Dictionary and parsed.get("net", {}) is Dictionary:
				var dst := FileAccess.open(DEMO_CHECKPOINT, FileAccess.WRITE)
				if dst != null:
					dst.store_string(txt)
					dst.close()
					_ckpt_note = "RL checkpoint iter %s（快照）· greedy 决策" % str(parsed.get("iteration", "?"))
					return
		await get_tree().create_timer(0.5).timeout
	push_warning("[NNDemo] checkpoint 快照失败——nn_brain 将走启发式退化（检查训练是否在跑）")


# ─────────────────────────────── 顶部横幅 ────────────────────────────────

func _build_banner() -> void:
	var layer := CanvasLayer.new()
	layer.name = "NNDemoBanner"
	layer.layer = 60   # 压观察场 HUD（50）之上一层
	add_child(layer)
	# CanvasLayer 直挂自锚定容器（顶部居中），不设全屏 Control 根——无丢锚风险
	var box := VBoxContainer.new()
	box.name = "BannerBox"
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_END
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 2)
	box.theme = StickTheme.create()
	layer.add_child(box)
	_banner = _make_line(box, Color(0.95, 0.86, 0.45), StickTokens.FONT_HUD + 4)
	_order_line = _make_line(box, Color(0.62, 0.82, 1.0), StickTokens.FONT_HUD)
	_status_line = _make_line(box, Color(0.8, 0.8, 0.8), StickTokens.FONT_HINT)


func _make_line(parent: Control, color: Color, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _refresh_banner() -> void:
	if _banner == null:
		return
	_banner.text = "◆ %s = %s　◆ %s = 军师规划器（现任默认AI）" % [
		_side_name(nn_side), "NN 指挥官（RL 自博弈）" if _brain != null else "NN 指挥官（装载中）",
		_side_name(3 - nn_side)]
	if _order_line == null or _status_line == null:
		return
	if _brain == null or _arena == null:
		_order_line.text = ""
		_status_line.text = "战斗装配中…（首次启动约 30s，黑屏为正常遮罩）"
		return
	_order_line.text = _order_text()
	_status_line.text = _status_text()


## NN 实时号令行：班名→意图（空班/全灭班/未下令槽不显示）
func _order_text() -> String:
	var intents: Array = _brain.get("_last_intents")
	if intents.is_empty():
		return "NN 号令：待首拍决策…"
	var names: Array = _squad_names(intents.size())
	var parts: Array = []
	for si in intents.size():
		var li: int = int(intents[si])
		if li < 0:
			continue
		parts.append("%s→%s" % [names[si], INTENT_NAMES[clampi(li, 0, INTENT_NAMES.size() - 1)]])
	if parts.is_empty():
		return "NN 号令：待首拍决策…"
	return "NN 号令：%s" % " ｜ ".join(parts)


func _squad_names(n: int) -> Array:
	var names: Array = []
	var presets: Variant = ArenaScript.get("PRESETS")
	var idx: int = int(ArenaScript.get("_preset_idx"))
	if presets is Array and idx >= 0 and idx < (presets as Array).size():
		var squads: Array = (presets as Array)[idx]["squads"]
		for si in n:
			names.append(str(squads[si]["name"]) if si < squads.size() else "班%d" % (si + 1))
	else:
		for si in n:
			names.append("班%d" % (si + 1))
	return names


## 状态行：checkpoint 说明 + 存活比 / 终局判定（斩首优先）
func _status_text() -> String:
	var base := _ckpt_note if _ckpt_note != "" else "RL checkpoint · greedy 决策"
	var la := _count_alive(_arena.get("_attacker"))
	var ra := _count_alive(_arena.get("_defender"))
	var decap: String = str(_arena.call("_commander_down_text"))
	if decap != "":
		return "%s ｜ %s / S 换边再战" % [base, decap]
	if la == 0 or ra == 0:
		var nn_won := (ra == 0) == (nn_side == 1)
		return "%s ｜ 战斗结束：%s%s 胜（存活 %d:%d）—— R 重开 / S 换边再战" % [
			base, "蓝方" if ra == 0 else "红方", "（NN）" if nn_won else "（军师）", la, ra]
	return "%s ｜ 存活 %d:%d ｜ S 换边 · R 重开 · 1/2/3 规模 · 空格 暂停" % [base, la, ra]


func _count_alive(arr_v: Variant) -> int:
	if not (arr_v is Array):
		return 0
	var n := 0
	for u in arr_v:
		if is_instance_valid(u) and u.get("health_component") != null \
				and not u.health_component.is_dead():
			n += 1
	return n


func _side_name(side: int) -> String:
	return "蓝方（攻·左）" if side == 1 else "红方（守·右）"


func _find_battle(root: Node) -> Node:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_script() != null \
				and String(n.get_script().resource_path).ends_with("battle_instance.gd"):
			return n
		stack.append_array(n.get_children())
	return null
