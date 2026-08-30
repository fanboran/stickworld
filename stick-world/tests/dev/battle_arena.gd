extends Node
## 战斗演练场（观察用，非 CI 测试）：双方各 12 个混编士兵自动互殴。
##
## 用途：肉眼观察战斗画面自然度——站姿/走姿/挥砍/受击/死亡/武器跟腕/阵营对抗。
## 入口：主菜单「战斗演练」→「大乱斗观察场」。
##
## 热键：ESC 返回主菜单 · R 重新开局 · 空格 暂停/继续（TimeManager 速度）。
## 编队：左方（攻方）剑×6 矛×3 弓×2 杖×1；右方（守方）同编队镜像。

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _MainMenuScene := "res://modules/ui_global/scenes/menus/main_menu.tscn"

## 每方编队（weapon_type 序号：0 剑 1 矛 2 弓 3 镐 4 杖）
const COMPOSITION: Array[int] = [0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 4]
const TEAM_SIZE := 12
## 左右两团的出生中心 x（相对地图中线）与团内散布
const TEAM_OFFSET_X := 420.0
const SPREAD_X := 55.0
const SPREAD_Y := 26.0

var _game_root: Node = null
var _left_alive_label: Label = null
var _right_alive_label: Label = null
var _hint_label: Label = null
var _attacker: Array = []
var _defender: Array = []


func _ready() -> void:
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)
	_build_hud()
	_spawn_and_start.call_deferred()


func _spawn_and_start() -> void:
	# 等默认村图装配完成
	for i in 10:
		await get_tree().process_frame
	# 切到空旷战场地图（village 是玩家村，建筑/资源点干扰观察）
	var loader: Node = _game_root.get("scene_loader")
	if loader != null and loader.has_method("load_map"):
		loader.load_map("battlefield")
		# 等新图装配（旧图延迟销毁，get_current_map 稳定到 battlefield 再继续）
		for i in 20:
			await get_tree().process_frame
			var m: Node2D = _game_root.get_current_map()
			if m != null and "battlefield" in str(m.scene_file_path):
				break
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		push_error("[Arena] 地图未加载")
		return
	# 清空地图自带单位（battlefield 预置的双方阵营兵 + 默认附身玩家）——
	# 演练场只保留自己刷的 24 个演练单位，保证"12v12"与观察画面纯净
	for e in map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 3:
		await get_tree().process_frame
	# 接管相机：停用 camera_rig 的自动跟随（它每帧把相机拉回玩家位置）
	var rig: Node = _game_root.get("camera_rig")
	if rig != null:
		rig.set_process(false)
		rig.set_physics_process(false)
	var mid_x: float = (map.map_left + map.map_right) * 0.5
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	for i in TEAM_SIZE:
		var lt := _spawn_unit(map, Vector2(mid_x - TEAM_OFFSET_X + (i % 6) * SPREAD_X,
				spawn_y + (i / 6) * SPREAD_Y))
		if lt != null:
			_set_weapon(lt, COMPOSITION[i])
			_attacker.append(lt)
		var rt := _spawn_unit(map, Vector2(mid_x + TEAM_OFFSET_X - (i % 6) * SPREAD_X,
				spawn_y + (i / 6) * SPREAD_Y))
		if rt != null:
			_set_weapon(rt, COMPOSITION[i])
			_defender.append(rt)
		await get_tree().process_frame
	var battle: Node = _game_root.start_test_battle(_attacker, _defender)
	print("[Arena] 战斗开始: battle=", battle, " 左 %d 人 vs 右 %d 人" % [_attacker.size(), _defender.size()])
	# 拉远相机看全场（camera_rig 已停用，直接设 Camera2D.zoom）
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null:
		cam.zoom = Vector2(0.55, 0.55)
	if cam != null:
		cam.global_position = Vector2(mid_x, spawn_y)
		_follow_center.call_deferred(cam)


## 相机跟随战场质心（单位散开后画面不丢人）
func _follow_center(cam: Camera2D) -> void:
	while is_inside_tree():
		var all: Array = _attacker + _defender
		var sum := Vector2.ZERO
		var n := 0
		for u in all:
			if is_instance_valid(u) and not u.is_dead():
				sum += u.global_position
				n += 1
		if n > 0 and cam != null:
			cam.global_position = sum / n
		await get_tree().create_timer(0.5).timeout


## 设主手武器类型（weapon_type 在 WeaponMount 上，不在 entity）
func _set_weapon(e: Node2D, wtype: int) -> void:
	var wm: Node = e.get_node_or_null("WeaponMount")
	if wm != null:
		wm.weapon_type = wtype


func _spawn_unit(map: Node2D, pos: Vector2) -> Node2D:
	var e: Node2D = map.spawn_entity(_StickmanScene, pos)
	if e == null:
		return null
	if e.get("foot_offset") != null:
		e.global_position.y = pos.y - e.foot_offset
	if e.has_method("set_possessed"):
		e.set_possessed(false)
	# 防初始化竞态：hp 未就绪（<=0 会拖累战斗胜负判定）则自愈满血
	var hc = e.get("health_component")
	if hc != null and float(hc.get("hp")) <= 0.0:
		hc.set("hp", hc.get("max_hp"))
	return e


func _process(_delta: float) -> void:
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().change_scene_to_file(_MainMenuScene)
			KEY_R:
				get_tree().reload_current_scene()
			KEY_SPACE:
				_toggle_pause()


func _toggle_pause() -> void:
	if TimeManager == null:
		return
	if TimeManager.current_speed == TimeManager.Speed.PAUSED:
		TimeManager.set_speed(TimeManager.Speed.X1)
	else:
		TimeManager.set_speed(TimeManager.Speed.PAUSED)


# ─────────────────────────────── HUD ────────────────────────────────

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ArenaHud"
	layer.layer = 50
	add_child(layer)
	_left_alive_label = _make_label(layer, Vector2(16, 16), Color(0.55, 0.75, 1.0))
	_right_alive_label = _make_label(layer, Vector2(16, 42), Color(1.0, 0.62, 0.55))
	_hint_label = _make_label(layer, Vector2(16, 72), Color(0.8, 0.8, 0.8))
	_hint_label.text = "演练场：ESC 返回主菜单 · R 重开 · 空格 暂停/继续"


func _make_label(layer: CanvasLayer, pos: Vector2, color: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", color)
	layer.add_child(l)
	return l


func _update_hud() -> void:
	if _left_alive_label == null:
		return
	# 部队尚未生成完（数组为空）不能判胜负——空集双 0 会误显示"战斗结束"
	if _attacker.is_empty() or _defender.is_empty():
		_left_alive_label.text = "蓝方（攻）集结中"
		_right_alive_label.text = "红方（守）集结中"
		_hint_label.text = "演练场：ESC 返回主菜单 · R 重开 · 空格 暂停/继续"
		return
	var la := _count_alive(_attacker)
	var ra := _count_alive(_defender)
	_left_alive_label.text = "蓝方（攻）存活 %d / %d" % [la, _attacker.size()]
	_right_alive_label.text = "红方（守）存活 %d / %d" % [ra, _defender.size()]
	if la == 0 or ra == 0:
		_hint_label.text = "战斗结束：%s 获胜 —— R 重开" % ("蓝方" if ra == 0 else "红方")
	else:
		_hint_label.text = "演练场：ESC 返回主菜单 · R 重开 · 空格 暂停/继续"


func _count_alive(units: Array) -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u) and u.get("health_component") != null \
				and not u.health_component.is_dead():
			n += 1
	return n
