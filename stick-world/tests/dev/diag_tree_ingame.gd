extends Node
## 诊断：毛线团树游戏内观察 —— 真实 GameRoot + 村落地图 + 相机跟随实拍。
## 运行（必须带显示）：
##   godot --path stick-world res://tests/dev/diag_tree_ingame.tscn --resolution 1920x1080
## 产物：user://shots/diag_tree_ingame.png + _t2.png（两帧 diff = 游戏内树叶实时翻动）

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const SHOT_DIR := "user://shots"

var _frames: int = 0
var _stage: int = 0
var _shot1: Image = null
var _game_root: Node = null
var _delta_acc := 0.0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)


func _process(delta: float) -> void:
	_frames += 1
	_delta_acc += delta
	match _stage:
		0:
			if _frames < 150:  # 等地图/资源点生成完
				return
			_stage = 1
			# 找一棵 WOOD 树，把玩家传送过去（相机跟随玩家）
			var tree: Node2D = _find_tree()
			if tree == null:
				print("[FAIL] 场景内未找到 WOOD 资源树")
				get_tree().quit(1)
				return
			var env: Node = _game_root.get_node_or_null("EnvironmentSystem")
			if env != null and env.has_method("set_time_of_day"):
				env.set_time_of_day(10.0)  # 白天光照，避免夜色盖住
			# 强制停雨（天气系统随机降雨会糊画面）
			var weather: Node = _game_root.get_current_map().get_node_or_null("Weather")
			if weather != null and weather.has_method("force_rain"):
				weather.force_rain(false)
			for e in _game_root.get_current_map().get_entities():
				if e != null and is_instance_valid(e) and e.has_method("is_possessed") and e.is_possessed():
					e.global_position = tree.global_position + Vector2(30.0, -10.0)
					break
			# 关掉欢迎弹窗（任意键关闭，走 _unhandled_input），让截图画面干净；
			# 不能用 ESC（=暂停菜单）也不能用 E（=采集合树旁交互），用无绑定的 9
			var any_key := InputEventKey.new()
			any_key.keycode = KEY_9
			any_key.pressed = true
			Input.parse_input_event(any_key)
			print("[DiagTreeIngame] 玩家已传送到树旁 %s" % tree.global_position)
		1:
			if _frames < 230:  # 等相机跟上 + 光照 lerp
				return
			_stage = 2
			_shot1 = get_viewport().get_texture().get_image()
			_shot1.save_png("%s/diag_tree_ingame.png" % SHOT_DIR)
			print("[DiagTreeIngame] shot1 saved")
		2:
			if _frames < 300:  # ~1.2s 后第二帧（毛线团应已翻动 ≥1 次）
				return
			_stage = 3
			var img := get_viewport().get_texture().get_image()
			img.save_png("%s/diag_tree_ingame_t2.png" % SHOT_DIR)
			var diff := _diff_pixels(_shot1, img)
			print("[DiagTreeIngame] shot2 saved, diff_pixels=%d" % diff)
			if diff < 2000:
				print("[FAIL] 游戏内两帧几乎无差异，树叶未翻动")
				get_tree().quit(1)
				return
			# 性能与梯度核查：平均 FPS + 全图树数 + 净空带无树
			var trees: Array = get_tree().get_nodes_in_group("resource_node").filter(
				func(n: Node) -> bool: return n.get("resource_type") == 0)
			var min_dist := 1e12
			var spawn_x := 0.0
			for t: Node2D in trees:
				min_dist = minf(min_dist, absf(t.global_position.x - spawn_x))
			print("[DiagTreeIngame] trees=%d avg_fps=%.1f nearest_tree_to_spawn=%.0fpx" %
				[trees.size(), 60.0 / maxf(_delta_acc / float(_frames), 0.0001), min_dist])
			# 净空线：土路半宽 1280 + 净空 960 = 2240（2026-09-06 "略近一段"版梯度）
			if min_dist < 2240.0:
				print("[FAIL] 净空带内仍有树（最近 %.0fpx < 2240px）——梯度未生效" % min_dist)
				get_tree().quit(1)
				return
			var stones: int = get_tree().get_nodes_in_group("resource_node").filter(
				func(n: Node) -> bool: return n.get("resource_type") != 0).size()
			print("[DiagTreeIngame] rocks=%d rock_per_tree=%.2f（用户预期：远低于 1）" %
				[stones, float(stones) / maxf(float(trees.size()), 1.0)])
			print("[PASS] 游戏内毛线团树渲染 + 实时翻动 + 净空梯度验证通过")
			get_tree().quit(0)


func _process_wrap_unused() -> void:
	pass


func _find_tree() -> Node2D:
	# 找 |x| 最大（离出生点最远=满密度林区）的 WOOD 树
	var best: Node2D = null
	for n in get_tree().get_nodes_in_group("resource_node"):
		if n is Node2D and not n.is_depleted() and n.resource_type == 0:
			if best == null or absf((n as Node2D).global_position.x) > absf(best.global_position.x):
				best = n
	return best


func _diff_pixels(a: Image, b: Image) -> int:
	if a == null:
		return 999999
	var na := a.get_data()
	var nb := b.get_data()
	var n := mini(na.size(), nb.size())
	var count := 0
	for i in range(0, n, 4):
		if absf(float(na[i]) - float(nb[i])) > 12.0 or absf(float(na[i + 1]) - float(nb[i + 1])) > 12.0:
			count += 1
	return count
