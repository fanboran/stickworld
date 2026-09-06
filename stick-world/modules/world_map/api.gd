extends Node
## 战略图模块（world_map）公共接口契约 —— L1 单层版
##
## 外部模块只能通过本文件定义的信号和方法与本模块交互。
## 禁止跨模块直接引用 world_map 内部脚本的方法。
##
## 详见 docs/技术/架构/战略图架构.md §六 API 契约（L1 单层子集）
## 术语：战略图（看的地图，玩家不在其中）vs 场景图（玩家地图，玩家在其中）

# ===== 公共信号 =====

## 聚落被点击（左键）
@warning_ignore("unused_signal")
signal settlement_clicked(settlement_id: String)

## 聚落被双击（进入场景图）
@warning_ignore("unused_signal")
signal settlement_activated(settlement_id: String)

## 鼠标悬停变化
@warning_ignore("unused_signal")
signal region_hovered(tile_id: String, settlement_id: String)

# 战略图开/关通知走 EventBus.strategic_map_opened / strategic_map_closed（单一通道，勿在本地重复声明）


# ===== 内部引用 =====

var _data: L1WorldData = null
var _controller: Node = null
var _renderer: Node = null
var _camera: Node = null
var _is_initialized: bool = false

## 出生 L1 全局 label（Tab 默认/玩家出生所在；config/strategic_map 单份数据）
const BIRTH_L1_LABEL := 69
## 出生 L1 数据（initialize 加载，open_l1 回到出生时恢复）
var _birth_data: L1WorldData = null
## 当前加载的 L1（BIRTH_L1_LABEL = 出生；其他 = l1_packs）
var _current_l1_label: int = BIRTH_L1_LABEL

# ===== 快速旅行（P6/E3，总体设计 §5.10） =====

## 可达性状态码（get_travel_status 返回的 "code"）
const TRAVEL_OK := "OK"                  ## 可达（已到访 ∧ 路网连通 ∧ 未阻断）
const TRAVEL_SELF := "SELF"              ## 已在目标聚落（进城不构成旅行，双击直接进）
const TRAVEL_NO_SCENE := "NO_SCENE"      ## 无 map_id，场景图未开放
const TRAVEL_UNVISITED := "UNVISITED"    ## 未到访（须先亲自到达）
const TRAVEL_UNREACHABLE := "UNREACHABLE"  ## 路网不连通
const TRAVEL_BLOCKED := "BLOCKED"        ## 目标在不可通过区（P7 敌占区数据的消费点）
const TRAVEL_BATTLE := "BATTLE"          ## 战斗中禁止旅行

## 路网规划器（基于出生 L1 数据构建——玩家当前只可能在出生 L1 的 8 城邦间移动）
var _travel_planner: TravelPlanner = null
## 玩家当前所在聚落（默认出生聚落；set_player_map 命中时更新。开局在 demo 村等
## 战略图外场景时不命中，保持出生聚落——与玩家图钉默认锚同口径）
var _player_settlement_id: String = ""
## 不可通过区过滤钩子（func(settlement_id) -> bool；P7 政权敌占区数据接入点，当前恒空）
var _block_filter: Callable = Callable()
## 战斗中标志（battle_started/battle_ended 计数维护；战斗中禁用快速旅行）
var _battle_count: int = 0


# ===== 初始化 =====

## 由 strategic_map.tscn 根节点调用，注入内部组件引用
func setup(
	controller: Node,
	renderer: Node,
	camera: Node
) -> void:
	_controller = controller
	_renderer = renderer
	_camera = camera


## 初始化战略图（加载 L1 世界数据）
## json_path: l1_world.json 的 res:// 路径
## base_dir: 含 l1_base.png / l1_mask.png 的目录
## [P] setup 已调用
## [Q] L1WorldData 加载完成，渲染器/相机就绪
func initialize(json_path: String, base_dir: String) -> void:
	_birth_data = L1WorldData.load_from(json_path, base_dir)
	_data = _birth_data
	_current_l1_label = BIRTH_L1_LABEL
	_is_initialized = _data != null and _data.base_texture != null
	if _is_initialized:
		if _renderer != null and _renderer.has_method("set_data"):
			_renderer.set_data(_data)
		if _camera != null and _camera.has_method("set_data"):
			_camera.set_data(_data)
		# 快速旅行（P6）：路网图基于出生 L1 数据（8 城邦 MST 全连通）
		_player_settlement_id = _birth_data.spawn_settlement_id
		_travel_planner = TravelPlanner.new()
		_travel_planner.setup(_birth_data.roads)
	# C2 blob 实时变动：建设系统广播 settlement_updated -> 当前/出生数据中该聚落
	# 规模刷新 + 当前视图单城重算（L2/L3 为烘焙静态层，本局规模不变不重算）
	if EventBus != null:
		if not EventBus.settlement_updated.is_connected(_on_settlement_updated):
			EventBus.settlement_updated.connect(_on_settlement_updated)
		# 战斗中禁用快速旅行（计数维护：多场并发战斗全结束才解除）
		if not EventBus.battle_started.is_connected(_on_battle_started):
			EventBus.battle_started.connect(_on_battle_started)
		if not EventBus.battle_ended.is_connected(_on_battle_ended):
			EventBus.battle_ended.connect(_on_battle_ended)


func _on_battle_started(_battle_id: String) -> void:
	_battle_count += 1


func _on_battle_ended(_battle_id: String, _victory: bool) -> void:
	_battle_count = maxi(0, _battle_count - 1)


## 战斗中（任一战斗未结束）快速旅行禁用（GDD 约定，§5.10）
func is_battle_active() -> bool:
	return _battle_count > 0


## settlement_updated 订阅：更新内存规模 + 当前 L1 视图 blob 单城重算
func _on_settlement_updated(settlement_id: String, population_score: float) -> void:
	for data in [_data, _birth_data]:
		if data == null:
			continue
		var sref: SettlementRef = data.get_settlement(settlement_id)
		if sref == null:
			continue
		sref.population_score = clampf(population_score, 0.0, 1.0)
		if data == _data and _renderer != null and _renderer.has_method("invalidate_blob"):
			_renderer.invalidate_blob(settlement_id)


func is_initialized() -> bool:
	return _is_initialized


## 加载指定老 L1 的地图数据（L2 点击 L1 下钻用）
## l1_label: 老 L1 全局 label（1..69），数据在 config/strategic_map/l1_packs/l1_%03d/l1_world.json
## 成功后替换当前数据（renderer/camera 同步切换），返回是否成功
func open_l1(l1_label: int) -> bool:
	var data: L1WorldData = null
	if l1_label == BIRTH_L1_LABEL:
		# 出生 L1 用 config/strategic_map 单份数据（非 l1_packs，保持 Tab 原有显示）
		data = _birth_data
	else:
		var dir_name := "l1_%03d" % l1_label
		var base_dir := "res://config/strategic_map/l1_packs/%s" % dir_name
		var json_path := "%s/l1_world.json" % base_dir
		if not FileAccess.file_exists(json_path):
			push_error("[StrategicMapAPI] L1 数据缺失: %s" % json_path)
			return false
		data = L1WorldData.load_from(json_path, base_dir)
	if data == null or data.base_texture == null:
		push_error("[StrategicMapAPI] L1 加载失败: %s" % l1_label)
		return false
	_data = data
	_current_l1_label = l1_label
	if _renderer != null and _renderer.has_method("set_data"):
		_renderer.set_data(data)
	if _camera != null and _camera.has_method("set_data"):
		_camera.set_data(data)
	return true


## 确保数据为指定 L1（Tab 打开用）：已是则不动返回 false，否则重载并返回 true（供控制器重置视角适配新 context）
func ensure_player_l1(l1_label: int) -> bool:
	if _current_l1_label == l1_label:
		return false
	return open_l1(l1_label)


## 当前加载的 L1 全局 label（BIRTH_L1_LABEL = 出生）
func get_current_l1_label() -> int:
	return _current_l1_label


## 玩家位置动态接线（F2/C1，总体设计 §5.6）：玩家所在场景图 map_id → 反查聚落。
## P6 增强：命中即记录到访（WorldState.visited_settlements）+ 更新玩家所在聚落
## （快速旅行路网起点）。聚落判定以出生 L1 数据为权威（玩家只可能在 8 城邦场景内）；
## 图钉/地块描边等视图标记仍按当前 _data 更新（下钻其他 L1 时不命中，标记保持）。
func set_player_map(map_id: String) -> bool:
	if map_id.is_empty() or _renderer == null or _birth_data == null:
		return false
	var hit: SettlementRef = null
	for tile in _birth_data.tiles:
		var s = tile.settlement
		if s != null and s.map_id == map_id:
			hit = s
			break
	if hit == null:
		return false
	# P6：到达即到访 + 移动快速旅行起点
	_player_settlement_id = hit.settlement_id
	WorldState.visited_settlements[hit.settlement_id] = true
	if _data != null:
		for tile in _data.tiles:
			if tile.settlement != null and tile.settlement.map_id == map_id:
				if _renderer.has_method("set_current_tile"):
					_renderer.set_current_tile(tile.tile_id)
				if _renderer.has_method("set_player_pin"):
					_renderer.set_player_pin(tile.settlement.position)
				break
	return true


func get_data() -> L1WorldData:
	return _data


# ===== 快速旅行（P6/E3）=====

## 设置不可通过区过滤钩子（func(settlement_id: String) -> bool）。
## P7 政权敌占区数据的注入点：返回 true 的聚落从路网中移除（不可穿过/停留）。
func set_block_filter(filter: Callable) -> void:
	_block_filter = filter


## 玩家当前所在聚落（未进城时 = 出生聚落）
func get_player_settlement() -> String:
	return _player_settlement_id


## 路网规划器（测试/调试用）
func get_travel_planner() -> TravelPlanner:
	return _travel_planner


## 到访判定：出生聚落恒已到访（不依赖开局加载时序——玩家开局在 demo 村等
## 战略图外场景时出生城也必须可达），其余查 WorldState 到访表
func is_visited_settlement(settlement_id: String) -> bool:
	if _birth_data != null and settlement_id == _birth_data.spawn_settlement_id:
		return true
	return WorldState.visited_settlements.has(settlement_id)


## 阻断集合物化：遍历路网节点应用过滤钩子（P7 前 hook 恒空 → 开销为零字典）
func _blocked_set() -> Dictionary:
	var blocked: Dictionary = {}
	if not _block_filter.is_valid() or _travel_planner == null:
		return blocked
	for sid in _travel_planner.get_nodes():
		if bool(_block_filter.call(sid)):
			blocked[sid] = true
	return blocked


## 快速旅行可达性判定（创始人拍板语义：已到访 ∧ 路网连通 ∧ 未被不可通过区切断，
## 总体设计 §5.10）。返回：
##   {"code": TRAVEL_* 状态码, "reason": String(中文说明，空=可达),
##    "path": Array[途经聚落序], "length_px": float, "hops": int(中间站数),
##    "roads": Array[途经道路条目]}
func get_travel_status(settlement_id: String) -> Dictionary:
	var result := {
		"code": TRAVEL_NO_SCENE, "reason": "", "path": [], "length_px": 0.0,
		"hops": 0, "roads": [],
	}
	if not _is_initialized or _travel_planner == null:
		result["reason"] = "世界数据未加载"
		return result
	var settlement: SettlementRef = get_settlement_ref(settlement_id)
	if settlement == null:
		result["reason"] = "聚落不存在"
		return result
	if settlement.map_id.is_empty():
		result["reason"] = "未开放进入"
		return result
	if is_battle_active():
		result["code"] = TRAVEL_BATTLE
		result["reason"] = "战斗中禁止旅行"
		return result
	if settlement_id == _player_settlement_id:
		result["code"] = TRAVEL_SELF
		return result
	if not is_visited_settlement(settlement_id):
		result["code"] = TRAVEL_UNVISITED
		result["reason"] = "尚未到访（须先亲自到达）"
		return result
	var blocked := _blocked_set()
	if blocked.has(settlement_id):
		result["code"] = TRAVEL_BLOCKED
		result["reason"] = "目标在不可通过区"
		return result
	var route := _travel_planner.find_path(_player_settlement_id, settlement_id, blocked)
	if route["path"].is_empty():
		result["code"] = TRAVEL_UNREACHABLE
		result["reason"] = "路网不连通"
		return result
	result["code"] = TRAVEL_OK
	result["path"] = route["path"]
	result["length_px"] = route["length_px"]
	result["hops"] = int((route["path"] as Array).size()) - 2
	result["roads"] = route["roads"]
	return result


## 执行快速旅行（调试期免费即时；途经路径高亮由控制器在调用前展示）。
## 重新校验可达性（弹窗停留期间状态可能变化），失败返回 false 并 push 原因。
func fast_travel_to(settlement_id: String) -> bool:
	var status := get_travel_status(settlement_id)
	if status["code"] != TRAVEL_OK:
		push_warning("[WorldMapApi] 快速旅行被拒绝（%s：%s）" % [settlement_id, status["reason"]])
		return false
	return enter_settlement(settlement_id, WorldAPI.TravelMode.FAST_TRAVEL)


# ===== 查询 =====

## 根据屏幕坐标查询命中的聚落
## 返回 {"tile": L1TileDef, "settlement": SettlementRef}
func query_at_screen(screen_pos: Vector2) -> Dictionary:
	if _data == null or _camera == null:
		return {"tile": null, "settlement": null}
	var map_pos: Vector2 = _camera.screen_to_map(screen_pos)
	return _data.query_at_map_pos(map_pos)


## 获取聚落引用
func get_settlement_ref(settlement_id: String) -> SettlementRef:
	if _data == null:
		return null
	return _data.get_settlement(settlement_id)


## 获取所有地块（L1 多边形 + 聚落）
func get_tiles() -> Array:
	if _data == null:
		return []
	return _data.tiles


## 获取所有道路：[{"pts": PackedVector2Array, "tier": "DIRT"/"PAVED", "length_px": float}]
func get_roads() -> Array:
	if _data == null:
		return []
	return _data.roads


# ===== 选中 =====

func select(id: String) -> void:
	if _renderer != null and _renderer.has_method("select"):
		_renderer.select(id)


func deselect() -> void:
	if _renderer != null and _renderer.has_method("deselect"):
		_renderer.deselect()


func get_selected() -> String:
	if _renderer != null and _renderer.has_method("get_selected"):
		return _renderer.get_selected()
	return ""


# ===== 相机 =====

## 聚焦到指定地块中心
func camera_focus(id: String, animated: bool = true) -> void:
	if _camera != null and _camera.has_method("focus_on"):
		_camera.focus_on(id, animated)


func screen_to_map(screen_pos: Vector2) -> Vector2:
	if _camera != null and _camera.has_method("screen_to_map"):
		return _camera.screen_to_map(screen_pos)
	return screen_pos


func map_to_screen(map_pos: Vector2) -> Vector2:
	if _camera != null and _camera.has_method("map_to_screen"):
		return _camera.map_to_screen(map_pos)
	return map_pos


# ===== 地图模式（B4，MapModeManager）=====

## 设置地图模式（MapModeManager.Mode.TERRAIN / POLITICAL；跨视图全局生效并广播）
func set_map_mode(mode: int) -> void:
	MapModeManager.set_mode(mode)


## 当前地图模式（MapModeManager.Mode 枚举值）
func get_map_mode() -> int:
	return MapModeManager.current_mode


# ===== 政治属性（只读查询） =====

func get_state_color(state_id: String) -> Color:
	if _data == null:
		return Color.GRAY
	return _data.get_state_color(state_id)


func get_states() -> Dictionary:
	if _data == null:
		return {}
	return _data.states


# ===== 场景图切换 =====

## 进入聚落（关闭战略图，加载场景图）
## mode: WorldAPI.TravelMode（快速旅行 FAST_TRAVEL / 调试期步行 WALK 同为直达，
## E4/F6 步行道路场景接入后 WALK 走 RoadMap 流程）
## [P] settlement_id 存在且对应 map_id 已注册
## [Q] 发射 EventBus.travel_requested(map_id, mode)，关闭战略图 ModalOverlay
func enter_settlement(settlement_id: String, mode: int = WorldAPI.TravelMode.FAST_TRAVEL) -> bool:
	var settlement: SettlementRef = get_settlement_ref(settlement_id)
	if settlement == null:
		push_warning("[WorldMapApi] 聚落不存在: %s" % settlement_id)
		return false
	var map_id: String = settlement.map_id
	if map_id.is_empty():
		push_warning("[WorldMapApi] 聚落无 map_id（空聚落不可进入）: %s" % settlement_id)
		return false
	# 发射旅行请求 -> SceneLoader 监听并处理
	if EventBus != null:
		EventBus.travel_requested.emit(map_id, mode)
	# 关闭战略图
	close_strategic_map()
	return true


## 关闭战略图，返回之前的场景图。
## 关闭通知统一由控制器经 EventBus.strategic_map_closed 发射（controller.close 内），
## 此处兜底：控制器缺失时直接发信号，避免场景图输入永久暂停。
func close_strategic_map() -> void:
	if _controller != null and _controller.has_method("close"):
		_controller.close()
	elif EventBus != null:
		EventBus.strategic_map_closed.emit()
