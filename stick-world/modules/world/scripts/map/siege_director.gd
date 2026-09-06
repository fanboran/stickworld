class_name SiegeDirector
extends Node
## 守城战导演 —— 战场左端布防我方、右端按波次持续刷新敌人。
##
## 职责：
## - 开战布防：弓箭手上城墙（墙顶承重线约束活动范围，武器 BOW），其余守军在城内
## - 波次刷敌：每 wave_interval 秒从地图右端刷新一波进攻方（人数逐波递增、封顶），
##   经 BattleInstance.add_unit 并入当前战斗（首波经 CombatApi.start_battle 开战）
##
## 单位生成与兵种着色沿用 initial_content 的约定（StickmanEntity 场景 + 身体染色），
## 不重复造 spawn 管线。由守城地图（siege_map.gd）挂载并调用 setup()。

const StICKMAN_FALLBACK := preload("res://modules/units/scenes/stickman_entity.tscn")

## 波次节奏（秒）
@export var wave_interval: float = 25.0
## 首波人数 / 每波递增 / 人数封顶
@export var wave_base: int = 3
@export var wave_ramp: int = 1
@export var wave_cap: int = 9
## 首波前缓冲（秒）：给玩家落位时间
@export var first_wave_delay: float = 4.0
## 开战触发线（世界 x）：>0 时玩家越过此线才开波次计时（守城 Demo=玩家出镇赴墙）；
## <=0 进图即计时（独立守城地图用）。
@export var wave_trigger_x: float = -1.0
## 城墙弓箭手数
@export var archer_count: int = 4
## 波次敌军开关（守城模式开；自由出城模式关——墙上只有巡防弓手）
@export var waves_enabled: bool = true
## 守军地面小队开关（12v12 类：守城模式布一队混编在墙前列阵）
@export var squad_enabled: bool = true

var _map: Node2D = null
var _wall: SiegeWall = null
var _root: Node = null            # GameRoot（取单位场景/CombatApi）
var _wave_timer: float = 0.0
var _wave_num: int = 0
var _started: bool = false      # 首波已发
var _triggered: bool = false    # 开战计时已触发（触发线模式：玩家出镇置位）
var _rng := RandomNumberGenerator.new()
## 我方守军登记（弓箭手等由导演布防的单位；首波开战时作为守方名单）
var _garrison: Array = []
## 守城陷落标志（守军尽后置位；陷落波次直插城内）
var _breached: bool = false
## 城内目标 x（陷落推进终点；由地图 setup 注入硬地皮中心）
var city_target_x: float = 2400.0


func setup(map: Node2D, wall: SiegeWall) -> void:
	_map = map
	_wall = wall
	_rng.seed = 20260906
	# GameRoot 沿祖先链找（工具场景里实例名不定，不能按名字 "GameRoot" 查）
	var n: Node = _map
	while n != null:
		if "_combat_api" in n:
			_root = n
			break
		n = n.get_parent()
	# 等地图实体宿主就绪后再布防（地图 _ready 链条尾部）
	call_deferred("_deploy_garrison")
	if squad_enabled:
		call_deferred("_deploy_squad")


## 我方布防：巡墙弓箭手——贴墙立面上下来回跑动射击（人站在城墙上）。
## x 钳在墙面 8 格内，y 在垛口线下 patrol 带内正弦往返；武器 BOW。
func _deploy_garrison() -> void:
	if _map == null or _wall == null:
		return
	var scene: PackedScene = _stickman_scene()
	if scene == null:
		return
	var slots: Array[float] = _wall.get_archer_slots()
	var patrol: Vector2 = _wall.get_patrol_range()
	var placed := 0
	# 巡墙相位错开：上下交错，开局就是"在墙上跑动"的样子
	var phase_off: float = TAU / maxf(float(slots.size()), 1.0)
	for si in slots.size():
		if placed >= archer_count:
			break
		var spawn_y: float = patrol.y - 30.0
		var pos := Vector2(_wall.get_wall_x() + slots[si], spawn_y)
		var u: Node2D = _map.spawn_entity(scene, pos)
		if u == null:
			continue
		if u.get("foot_offset") != null:
			u.global_position.y = spawn_y - u.foot_offset
		if u.get("weapon_mount") != null:
			u.weapon_mount.weapon_type = WeaponMount.WeaponType.BOW
		# 巡墙约束：y 活动带 = 巡逻带（防 AI 走位坠墙），x 由钳制管
		if u.has_method("set_ground_constraints"):
			u.set_ground_constraints(patrol.x, patrol.y + 8.0,
					_map.map_left, _map.map_right)
		if u.has_method("set_possessed"):
			u.set_possessed(false)
		u.set_meta("siege_slot_x", pos.x)
		u.set_meta("siege_phase", phase_off * placed)
		_garrison.append(u)
		placed += 1
	print_verbose("[SiegeDirector] 布防完成: 巡墙弓箭手 %d/%d" % [placed, archer_count])


## 巡墙驱动：y 正弦往返（相位错开）+ x 钳回墙面（AI 接敌/风筝会横移）
func _clamp_garrison(delta: float) -> void:
	if _garrison.is_empty() or _wall == null:
		return
	var patrol: Vector2 = _wall.get_patrol_range()
	var mid_y: float = (patrol.x + patrol.y) * 0.5
	var amp: float = (patrol.y - patrol.x) * 0.5
	_patrol_t += delta
	for g in _garrison:
		if not is_instance_valid(g) or (g.has_method("is_dead") and g.is_dead()):
			continue
		if not g.has_meta("siege_slot_x"):
			continue
		var slot_x: float = float(g.get_meta("siege_slot_x"))
		var ph: float = float(g.get_meta("siege_phase", 0.0))
		var off: float = g.global_position.x - slot_x
		if absf(off) > SLOT_CLAMP:
			g.global_position.x = slot_x + signf(off) * SLOT_CLAMP
		# 垂直巡墙：慢速往返（周期 ~9s），被击退/走位后拉回巡逻线
		var target_y: float = mid_y + sin(_patrol_t * 0.7 + ph) * amp
		g.global_position.y = lerpf(g.global_position.y, target_y, minf(delta * 3.0, 1.0))


var _patrol_t: float = 0.0
## 驻位水平钳制带宽（墙面 8 格内的小幅让位）
const SLOT_CLAMP := 20.0


## 守军地面小队（12v12 类）：墙前列阵的混编队（剑/矛/弓），并入守方名单。
func _deploy_squad() -> void:
	if _map == null or _wall == null or _root == null:
		return
	var scene: PackedScene = _stickman_scene()
	if scene == null:
		return
	var spawn_y: float = _map.ground_y + (_map.ground_bottom - _map.ground_y) * 0.5
	var base_x: float = _wall.get_wall_x() + 320.0
	# [兵种武器, 距墙 x 偏移]——矛兵顶前排、剑兵次之、弓手后排
	var loadout: Array = [
		[WeaponMount.WeaponType.SPEAR, 60.0], [WeaponMount.WeaponType.SPEAR, 120.0],
		[WeaponMount.WeaponType.SWORD, 180.0], [WeaponMount.WeaponType.SWORD, 240.0],
		[WeaponMount.WeaponType.SWORD, 300.0], [WeaponMount.WeaponType.BOW, 380.0],
	]
	for entry in loadout:
		var pos := Vector2(base_x + entry[1], spawn_y)
		var u: Node2D = _map.spawn_entity(scene, pos)
		if u == null:
			continue
		if u.get("foot_offset") != null:
			u.global_position.y = spawn_y - u.foot_offset
		if u.get("weapon_mount") != null:
			u.weapon_mount.weapon_type = entry[0]
		if u.has_method("set_possessed"):
			u.set_possessed(false)
		_garrison.append(u)
	print_verbose("[SiegeDirector] 守军小队布阵: %d 人" % loadout.size())


func _process(delta: float) -> void:
	if _map == null or _wall == null:
		return
	_clamp_garrison(delta)
	if not waves_enabled:
		return
	# 开战触发线：玩家未出镇（未越过触发线）不计时——开局采集/建造流程不被攻打
	if not _triggered and wave_trigger_x > 0.0:
		var host: Node2D = _map.get_node_or_null("EntityHost") as Node2D
		var in_position := false
		if host != null:
			for u in host.get_children():
				if is_instance_valid(u) and u.has_method("is_possessed") and u.is_possessed():
					in_position = u.global_position.x >= wave_trigger_x
					break
		if not in_position:
			return
		print("[SiegeDirector] 玩家已赴城墙，敌军斥候现身……")
	_triggered = true
	_wave_timer += delta
	var due: float = first_wave_delay if not _started else wave_interval
	if _wave_timer < due:
		return
	_wave_timer = 0.0
	_started = true
	_spawn_wave()


## 刷一波进攻方（右端列队入场），并入当前战斗（无战斗则首波开战）
func _spawn_wave() -> void:
	_wave_num += 1
	var count: int = mini(wave_base + (_wave_num - 1) * wave_ramp, wave_cap)
	var scene: PackedScene = _stickman_scene()
	if scene == null:
		return
	var spawn_y: float = _map.ground_y + (_map.ground_bottom - _map.ground_y) * 0.5
	var spawned: Array = []
	for i in count:
		# 从地图右缘外列队入场（稍散开防重叠），并轻微前后错位
		var x: float = _map.map_right + 40.0 - i * 55.0 + _rng.randf_range(-12.0, 12.0)
		var y: float = spawn_y + _rng.randf_range(-70.0, 70.0)
		var e: Node2D = _map.spawn_entity(scene, Vector2(x, y))
		if e == null:
			continue
		if e.get("foot_offset") != null:
			e.global_position.y = y - e.foot_offset
		if e.has_method("set_possessed"):
			e.set_possessed(false)
		e.set_meta("siege_attacker", true)
		spawned.append(e)
	if spawned.is_empty():
		return
	if _breached:
		_breach()
	else:
		_join_battle(spawned)
	print("[SiegeDirector] 第 %d 波敌军来袭: %d 人" % [_wave_num, spawned.size()])


## 并入当前战斗：地图上已有活动战斗则 add_unit(攻方)，否则以“守军 vs 首波”开战。
func _join_battle(new_attackers: Array) -> void:
	var api: Node = _combat_api()
	var battle: Node = _active_battle(api)
	var defenders: Array = _alive_blue_units()
	if battle != null and battle.has_method("add_unit"):
		for u in new_attackers:
			battle.add_unit(u, 1)   # FACTION_ATTACKER
		return
	if defenders.is_empty():
		# 守军已尽：守城陷落。不再开空战（守方无人战斗秒结），在场敌人
		# 改下"向城内推进"的号令（视觉上长驱直入），后续波次同样推进。
		_breach()
		return
	if api != null and api.has_method("start_battle"):
		api.start_battle(_map, new_attackers, defenders)


## 守城陷落：全场进攻方 set_order(move) 直插城内（town 大门 → 硬地皮中心）
func _breach() -> void:
	if _breached:
		return
	_breached = true
	print("[SiegeDirector] 守军已尽，城门失守！敌军涌入城内")
	var target := Vector2(city_target_x, _map.ground_y + 300.0)
	for u in _all_attackers():
		if is_instance_valid(u) and u.has_method("get_ai_controller"):
			var ai: Node = u.get_ai_controller()
			if ai != null and ai.has_method("set_order"):
				ai.set_order("move", {"target": target, "run": true})


func _all_attackers() -> Array:
	var host: Node2D = _map.get_node_or_null("EntityHost") as Node2D
	var result: Array = []
	if host == null:
		return result
	for u in host.get_children():
		# 进攻方 = 导演刷的红色敌人（spawn 时登记）
		if is_instance_valid(u) and u.has_meta("siege_attacker"):
			result.append(u)
	return result


## 当前地图的活动战斗（CombatApi → BattleDirector 链；BattleInstance 的地图引用在 _map）
func _active_battle(api: Node) -> Node:
	if api == null or not api.has_method("get_active_battles"):
		return null
	for b in api.get_active_battles():
		if is_instance_valid(b) and b.get("_map") == _map:
			return b
	return null


## 蓝方存活守军（导演布防的弓箭手 + 被附身的玩家）：首波开战时的守方名单。
## 不按外观判定——靠导演自己登记的花名册（garrison）+ 附身玩家。
func _alive_blue_units() -> Array:
	var result: Array = []
	for u in _garrison:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			result.append(u)
	var host: Node2D = _map.get_node_or_null("EntityHost") as Node2D
	if host != null:
		for u in host.get_children():
			if is_instance_valid(u) and u.has_method("is_possessed") and u.is_possessed() \
					and not (u.has_method("is_dead") and u.is_dead()):
				result.append(u)
	return result


func _stickman_scene() -> PackedScene:
	if _root != null and "_STICKMAN_ENTITY_SCENE" in _root:
		return _root._STICKMAN_ENTITY_SCENE
	return StICKMAN_FALLBACK


func _combat_api() -> Node:
	if _root != null and "_combat_api" in _root:
		return _root._combat_api
	return null


## 已刷波数（验证脚本用）
func get_wave_num() -> int:
	return _wave_num
