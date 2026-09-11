extends RefCounted
## 传输层 v1：抽象传播（架构文档 §4.2，3-P 定稿）。
##
## 延迟的唯一来源 = 消息在两个指挥官之间物理传播的时间（GDD §4.4）：
## 延迟 = 传播距离 ÷ 媒介速度。层级数本身不产生延迟（§8.5 的 base×tier_diff
## 抽象公式退役）。职责三分之一：算**每跳传播秒数**；不执行（combat 接力）、
## 不出计划（dispatcher）、不解单位。
##
## 可替换实现：v2 信使任务（边界外）替换本实现，接口不变。
##
## 跨模块三 provider 由装配层（system_setup）注入——organization 保持零出向依赖：
##   position_provider(org_id) -> Variant      Vector2=该组织指挥官实体坐标（同图）；
##                                             Vector2.INF = 不在当前图/无指挥官实体
##   player_position_provider() -> Vector2     玩家附身实体坐标；未附身=相机视野中心
##   region_distance_provider(from_loc, to_loc) -> float  跨图驻地距离（米/px）；-1=未知对
##
## location 来源实施补全（3-F1）：决策树②需要「两组织 location 比较」，location 是
## 组织自有数据——由 manager 内部接线 set_location_provider，不占装配层三 provider 面。

## 传令兵速度默认值 px/s（= var_run_speed 同量级：传令兵就是跑步的火柴人；
## 与 var_transport_speed 物流载具无关）。常规走 balance.variables 行覆盖（api.setup 消费）。
const DEFAULT_COURIER_SPEED: float = 208.0
## 跨图 fallback 距离 px（region_distance_provider 未命中/未注入时的常数）
const DEFAULT_CROSS_MAP_DISTANCE: float = 2000.0

var _position_provider: Callable = Callable()
var _player_position_provider: Callable = Callable()
var _region_distance_provider: Callable = Callable()
var _location_provider: Callable = Callable()
var _courier_speed: float = DEFAULT_COURIER_SPEED
var _fallback_cross_map_distance: float = DEFAULT_CROSS_MAP_DISTANCE


## 注入装配层三 provider（system_setup 调用）
func setup(position_provider: Callable, player_position_provider: Callable,
		region_distance_provider: Callable) -> void:
	_position_provider = position_provider
	_player_position_provider = player_position_provider
	_region_distance_provider = region_distance_provider


## location 查询接线（manager 内部注入：组织自有数据，非装配层职责）
func set_location_provider(provider: Callable) -> void:
	_location_provider = provider


## 测试快进注入口（常规速度走 BalanceConfig 经 api.setup 覆盖）
func set_courier_speed(speed: float) -> void:
	_courier_speed = speed


## 跨图 fallback 距离注入口（常规走 balance.variables 行覆盖）
func set_fallback_distance(distance: float) -> void:
	_fallback_cross_map_distance = distance


## 一跳传播秒数（§4.2.1 取距决策树，首中即返，全确定性）：
## ③ courier_speed ≤ 0（测试快进）→ 恒 0（短路，距离都不算）
## ① 双方均有实体坐标（同图）→ 直线距离 ÷ courier_speed
## ② 任一方 INF（跨图/无实体）→ location 相同（含同为 ""）→ 0（同驻地传令忽略不计）；
##    不同 → region_distance_provider：≥0 → 该距离 ÷ 速度；-1/未注入 → fallback 常数 ÷ 速度
func delivery_time(from_org_id: String, to_org_id: String) -> float:
	if _courier_speed <= 0.0:
		return 0.0
	var from_pos: Variant = _resolve_position(from_org_id, true)
	var to_pos: Variant = _resolve_position(to_org_id, false)
	if _is_real_position(from_pos) and _is_real_position(to_pos):
		return from_pos.distance_to(to_pos) / _courier_speed

	# 跨图/无实体分支：location 比较（provider 未接线按空串处理 = 同驻地）
	var from_loc := _resolve_location(from_org_id, true)
	var to_loc := _resolve_location(to_org_id, false)
	if from_loc == to_loc:
		return 0.0
	if not _region_distance_provider.is_valid():
		return _fallback_cross_map_distance / _courier_speed
	var result: Variant = _region_distance_provider.call(from_loc, to_loc)
	if not (result is float or result is int):
		return _fallback_cross_map_distance / _courier_speed
	var distance := float(result)
	if distance < 0.0:
		return _fallback_cross_map_distance / _courier_speed
	return distance / _courier_speed


## 取一方位置：from_org == ""（玩家源）走 player_position_provider（无参签名），
## 其余走 position_provider(org_id)。provider 未接线/异常按 Vector2.INF 处理（走跨图分支，不掺假距离）。
func _resolve_position(org_id: String, is_player_source: bool) -> Variant:
	if is_player_source and org_id == "":
		if not _player_position_provider.is_valid():
			return Vector2.INF
		var player_pos: Variant = _player_position_provider.call()
		return player_pos if player_pos is Vector2 else Vector2.INF
	if not _position_provider.is_valid():
		return Vector2.INF
	var result: Variant = _position_provider.call(org_id)
	return result if result is Vector2 else Vector2.INF


## 取一方驻地：玩家源（from_org == ""）无驻地 = ""（决策树「含同为空串」口径）
func _resolve_location(org_id: String, is_player_source: bool) -> String:
	if is_player_source and org_id == "":
		return ""
	if not _location_provider.is_valid():
		return ""
	var result: Variant = _location_provider.call(org_id)
	return str(result) if result != null else ""


## Vector2.INF / 非有限值 = 不可用坐标（跨图或无实体）
func _is_real_position(pos: Variant) -> bool:
	return pos is Vector2 and (pos as Vector2).is_finite()
