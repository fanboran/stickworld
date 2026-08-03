extends Node
## 开发调试场景（dev_playtest）-- 一键直达任意测试状态，不进入正式游戏入口。
##
## 为什么存在：自动化测试（tests/）验证逻辑，但手动体验战斗要走完整流程
## （启动→村庄→编队→跨图→遭遇战）。本场景用启动参数直接组装目标状态，
## GameRoot 零改动（除 dev_enemy_count 字段）。
##
## 用法（命令行）：
##   godot --path stick-world res://tests/dev/dev_playtest.tscn -- --map battlefield --party 3 --enemies 4 --follow
##
## 参数：
##   --map <id>      目标地图（village_a 默认 / battlefield / road_a_b / village_b）
##   --party <N>     随行战斗班人数（跨图时自动携带；0 = 不带）
##   --enemies <N>   遭遇战敌方数量（默认 4，仅 battlefield 生效）
##   --follow        队伍自动开启"跟随玩家"
##
## 不进 CI（tests/run_all.ps1 不包含本场景）。

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")
const StickmanScene := preload("res://modules/units/scenes/stickman_entity.tscn")
const ScriptGameRoot := preload("res://modules/world/scripts/game_root.gd")

var _game_root: Node = null


func _ready() -> void:
	var args := _parse_args()
	_run(args)


# ─────────────────────────────── 参数解析 ────────────────────────────────

func _parse_args() -> Dictionary:
	var result := {"map": "village_a", "party": 0, "enemies": 4, "follow": false}
	# Godot 命令行：-- 之后的参数以空格分隔（--map battlefield）或 key=value 均可
	var raw: Array = OS.get_cmdline_user_args()
	var i: int = 0
	while i < raw.size():
		var tok: String = str(raw[i])
		if tok.begins_with("--"):
			var key: String = tok.trim_prefix("--")
			var val: String = "true"
			# key=value 形式
			if key.contains("="):
				var kv := key.split("=", true, 1)
				key = kv[0]
				val = kv[1]
			elif i + 1 < raw.size() and not str(raw[i + 1]).begins_with("--"):
				val = str(raw[i + 1])
				i += 1
			match key:
				"map":
					result["map"] = val
				"party":
					result["party"] = int(val)
				"enemies":
					result["enemies"] = int(val)
				"follow":
					result["follow"] = val == "true" or val == "1" or val == "yes"
		i += 1
	return result


# ─────────────────────────────── 主流程 ────────────────────────────────

func _run(args: Dictionary) -> void:
	# 实例化 GameRoot（正式主场景，含全部系统装配）
	_game_root = GameRootScene.instantiate()
	_game_root.set("dev_enemy_count", int(args["enemies"]))
	add_child(_game_root)
	# 等待初始村庄加载与实体生成
	for i in 10:
		await get_tree().process_frame

	# 在村庄生成随行战斗班（编队 + 可选跟随）
	if int(args["party"]) > 0:
		_spawn_party(int(args["party"]), bool(args["follow"]))

	# 直达目标地图（编队经快照机制自动携带到战场）
	if str(args["map"]) != "village_a":
		var sl: Node = _game_root.scene_loader
		if sl != null and sl.has_method("travel_to_map"):
			sl.travel_to_map(str(args["map"]), WorldAPI.TravelMode.WALK, WorldAPI.EntrySide.LEFT)
			for i in 6:
				await get_tree().process_frame

	print("[DevPlaytest] 就绪：map=%s party=%d enemies=%d follow=%s（按 Q 切换战斗模式，编制面板编队）" % [
		str(args["map"]), int(args["party"]), int(args["enemies"]), bool(args["follow"])
	])
	# headless 下（CI 验证场景可跑）2 秒后自动退出
	if DisplayServer.get_name() == "headless":
		await get_tree().create_timer(2.0).timeout
		get_tree().quit(0)


## 在村庄生成 N 个火柴人，编成战斗班（fp_combat_squad），可选开启跟随玩家。
func _spawn_party(count: int, follow: bool) -> void:
	var map: Node2D = _game_root.get_current_map()
	if map == null or not map.has_method("spawn_entity"):
		return
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	var units: Array = []
	for i in count:
		var x: float = map.map_left + 600.0 + 80.0 * i
		var e: Node2D = map.spawn_entity(StickmanScene, Vector2(x, spawn_y))
		if e == null:
			continue
		if e.get("foot_offset") != null:
			e.global_position.y = spawn_y - e.foot_offset
		if e.has_method("set_possessed"):
			e.set_possessed(false)
		if e.has_method("set_construction_manager") and _game_root.get_construction_manager() != null:
			e.set_construction_manager(_game_root.get_construction_manager())
		if e.has_method("set_formation_system") and _game_root.get_formation_system() != null:
			e.set_formation_system(_game_root.get_formation_system())
		units.append(e)
	if units.is_empty():
		return
	var formation: Node = _game_root.get_formation_system()
	if formation != null and formation.has_method("create_squad"):
		var squad_id: String = formation.create_squad(units, "先锋班", "fp_combat_squad")
		if follow and not squad_id.is_empty() and formation.has_method("set_squad_follow"):
			formation.set_squad_follow(squad_id, true)
	print("[DevPlaytest] 随行战斗班已生成：%d 人（跟随=%s）" % [units.size(), follow])
