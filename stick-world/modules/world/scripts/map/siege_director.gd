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
## 城墙弓箭手数
@export var archer_count: int = 4

var _map: Node2D = null
var _wall: SiegeWall = null
var _root: Node = null            # GameRoot（取单位场景/CombatApi）
var _wave_timer: float = 0.0
var _wave_num: int = 0
var _started: bool = false
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


## 我方布防：弓箭手上墙（墙顶约束），存活的守军并入场守方阵营由首战统一注册。
func _deploy_garrison() -> void:
	if _map == null or _wall == null:
		return
	var scene: PackedScene = _stickman_scene()
	if scene == null:
		return
	var slots: Array[float] = _wall.get_archer_slots()
	var platform_local_y: float = _wall.get_platform_y()
	var platform_world_y: float = _wall.global_position.y + platform_local_y
	var placed := 0
	for slot_x in slots:
		if placed >= archer_count:
			break
		var pos := Vector2(_wall.global_position.x + slot_x, platform_world_y)
		var u: Node2D = _map.spawn_entity(scene, pos)
		if u == null:
			continue
		if u.get("foot_offset") != null:
			u.global_position.y = platform_world_y - u.foot_offset
		# 弓箭手：spawn 当帧设武器类型（WeaponMount 的 _reload_weapons 是
		# deferred 的，此刻设置仍在其前，帧末统一重载生效）
		if u.get("weapon_mount") != null:
			u.weapon_mount.weapon_type = WeaponMount.WeaponType.BOW
		# 墙顶承重线约束：y 活动带压到垛口平台，防 AI 走位坠墙
		if u.has_method("set_ground_constraints"):
			u.set_ground_constraints(platform_world_y, platform_world_y + 8.0,
					_map.map_left, _map.map_right)
		if u.has_method("set_possessed"):
			u.set_possessed(false)
		_set_body_color(u, Color(0.25, 0.42, 0.80))
		u.set_meta("siege_slot_x", pos.x)
		_garrison.append(u)
		placed += 1
	print_verbose("[SiegeDirector] 布防完成: 弓箭手 %d/%d 上墙" % [placed, archer_count])


func _process(delta: float) -> void:
	if _map == null or _wall == null:
		return
	_clamp_garrison()
	_wave_timer += delta
	var due: float = first_wave_delay if not _started else wave_interval
	if _wave_timer < due:
		return
	_wave_timer = 0.0
	_started = true
	_spawn_wave()


## 驻守钳制：弓箭手驻垛口位不追敌（战斗 AI 的接敌/风筝会让远程沿墙顶
## 横向飘走——y 被 ground 约束锁定后表现为"空中横移"）。x 偏移超带宽拉回。
const SLOT_CLAMP := 24.0

func _clamp_garrison() -> void:
	for g in _garrison:
		if not is_instance_valid(g) or (g.has_method("is_dead") and g.is_dead()):
			continue
		if not g.has_meta("siege_slot_x"):
			continue
		var slot_x: float = float(g.get_meta("siege_slot_x"))
		var off: float = g.global_position.x - slot_x
		if absf(off) > SLOT_CLAMP:
			g.global_position.x = slot_x + signf(off) * SLOT_CLAMP


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
		_set_body_color(e, Color(0.82, 0.22, 0.22))
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
## 不按染色判定——实体上无 body_color 字段，靠导演自己登记的花名册最可靠。
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


func _set_body_color(u: Node2D, color: Color) -> void:
	# 染色方式与 initial_content.set_unit_body_color 同径：找身体绘制节点
	# （兼容 rig 子节点名差异，找不到就跳过——只影响辨识不影响玩法）
	var candidates: Array = []
	if u.get("rig") != null:
		candidates.append(u.rig)
	for child in u.get_children():
		candidates.append(child)
	for c in candidates:
		if c != null and is_instance_valid(c) and ("body_color" in c):
			c.body_color = color
			return
	# 实体级 body_color 备选（部分消费方读实体字段）
	if "body_color" in u:
		u.body_color = color


## 已刷波数（验证脚本用）
func get_wave_num() -> int:
	return _wave_num
