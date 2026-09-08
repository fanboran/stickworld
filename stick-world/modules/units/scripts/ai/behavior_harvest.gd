class_name BehaviorHarvest
extends BehaviorBase
## 采集行为族 -- 泛化工作循环（小镇生活批次 2，愿景锚点
## docs/设计/系统/12-小镇生活与美术.md §三"工作是世界内可观察的行为"）。
##
## 循环：寻位（资源点/工位）→ 移动 → 劳作（play_attack 动画钩子，cycle 节拍）
## → 产物经 ResourcesApi 入账 → 回到劳作。与玩家手采并存（同资源点同入账通道）。
##
## 两种模式（按职业档案 work_site_def 分流，档案字段契约见
## modules/town_life/scripts/profession_registry.gd 类头）：
##   - 资源点模式（work_site_def 空，伐木工/矿工）：找最近未枯竭且产物匹配的
##     resource_node（鸭子协议 get_resource_id()/harvest()/is_depleted），
##     每拍 harvest 一次，实际采得量 produce 入账；采空转寻下一处。
##   - 工位模式（work_site_def 非空，铁匠）：经 TownLifeAPI.get_work_site 寻位
##     （批次 3）：建筑组内 def 匹配且存活的建筑 WorkSlots 真槽位优先，无匹配
##     建筑降级占位定点（ProfessionRegistry.PLACEHOLDER_WORK_SITES [提案/待定]）；
##     劳作中建筑被毁自动重寻位。每拍 consume 原料 → produce 产出（"矿→锭"
##     转化链；原料不足空拍等待）。
##
## 工作节律（批次 3 [提案/待定] 7~19 时在岗）：update 检查 TownLifeAPI.
## is_work_time()，休息时段劳作收尾 finish（决策层同检，回 idle/wander 休息态）。
##
## params：
##   - profession: Dictionary  职业档案覆盖（可选；缺省经 TownLifeAPI 按
##     entity.get_profession() 自查。单测/特殊派工可显式传入）
##
## 注入：resources_api 可显式注入（单测桩）；缺省经 ResourcesApi 节点
## （current_scene 下具名 find_child，同 interaction_controller 先例）。
## 本行为不引用 world/town_life 内部类，跨模块只走鸭子协议与 TownLifeAPI 契约。
##
## 结束条件：无职业 / 无工位配置 / 无匹配资源点（决策层回 idle，稍后重试）。
## 遇战斗/号令被抢占正常 exit（AIController 决策次序处理）。


# ─────────────────────────────── 常量 ────────────────────────────────
## 到达阈值（距目标小于此值视为到位，同 BehaviorWork 口径）
const ARRIVE_THRESHOLD: float = 24.0
## 工位 Y 相对实体地面线的下移（同 BehaviorWork.WORK_OFFSET_Y，站位在地面带内）
const WORK_OFFSET_Y: float = 40.0
## 入账 region（与玩家手采 HARVEST_REGION 同账）
const HARVEST_REGION: String = "test_region"
## 产出来源标记（ResourcesApi.produce 的 source 参数，经济流水溯源用）
const SOURCE_NPC := "村民劳作"
## 原料消耗来源标记
const SOURCE_NPC_CONSUME := "村民打铁备料"


enum Mode { RESOURCE, WORKSITE }
enum Phase { TO_TARGET, WORKING }

# ─────────────────────────────── 运行时 ────────────────────────────────
## 职业档案（professions.tres 行）
var _prof: Dictionary = {}
## 模式
var _mode: int = Mode.RESOURCE
## 阶段
var _phase: int = Phase.TO_TARGET
## 当前资源点（资源点模式）
var _node: Node2D = null
## 工位目标点（工位模式；Y 已按实体地面线补齐）
var _site_pos: Vector2 = Vector2.ZERO
## 工位所在建筑（工位模式；null = 占位工位，无存活校验）
var _site_building: Node2D = null
## 拍计时器
var _cycle_timer: float = 0.0
## ResourcesApi（显式注入优先；缺省惰性查节点）
var resources_api: Variant = null


func _ready() -> void:
	behavior_name = "harvest"


func enter(previous: String, params: Dictionary) -> void:
	super.enter(previous, params)
	_prof = params.get("profession", {}) if params.get("profession", {}) is Dictionary else {}
	if _prof.is_empty():
		_prof = _load_profession()
	if _prof.is_empty():
		finish()  # 无职业/待业：回 idle（决策层不再尝试采集）
		return
	if not _locate():
		finish()


func update(delta: float) -> void:
	if is_finished() or _prof.is_empty():
		return
	if entity == null or not is_instance_valid(entity):
		finish()
		return
	# 征用离岗（批次 4 编队征用互斥）：职业被清空（编队时 FormationSystem
	# 置空）即时收工——劳作中的村民被征入伍不再继续干活；决策层
	# _try_harvest 同判职业空，不会重进劳作
	if entity.has_method("get_profession") and String(entity.get_profession()).is_empty():
		finish()
		return
	# 劳作节律（批次 3 [提案/待定]）：休息时段收工（决策层不再重进 harvest，
	# 村民回 idle/wander 休息态；时间未初始化的环境 is_work_time 恒真不受影响）
	if not TownLifeAPI.is_work_time():
		finish()
		return
	match _phase:
		Phase.TO_TARGET:
			_update_travel()
		Phase.WORKING:
			_update_working(delta)


func exit(next: String) -> void:
	super.exit(next)
	# 清理劳作现场：进度条隐藏（play_attack 为 oneshot 自动回切，无需解锁动画）
	if entity != null and is_instance_valid(entity):
		if entity.has_method("hide_action_progress"):
			entity.hide_action_progress()
		if entity.has_method("ai_stop"):
			entity.ai_stop()


# ─────────────────────────────── 寻位 ────────────────────────────────

## 寻位并进入移动阶段。返回 false = 无法寻位（行为结束）。
func _locate() -> bool:
	_cycle_timer = 0.0
	_node = null
	_site_pos = Vector2.ZERO
	_site_building = null
	var site_def := String(_prof.get("work_site_def", ""))
	if site_def.is_empty():
		_mode = Mode.RESOURCE
		_node = _find_resource_node()
		if _node == null:
			return false
	else:
		_mode = Mode.WORKSITE
		# 工位寻位（批次 3）：WorkSlots 真槽位优先，占位工位降级（TownLifeAPI 契约）
		var site: Dictionary = TownLifeAPI.get_work_site(entity, site_def)
		if site.is_empty():
			return false  # 无任何可用工位（无匹配建筑且占位表未覆盖）
		var pos: Vector2 = site.get("pos", Vector2(NAN, NAN))
		_site_building = site.get("building") as Node2D
		# Y 统一按实体地面线补齐（槽位/占位只消费 X，站位在地面带内可达，
		# 同 BehaviorHaul 取货点口径）
		var ground_y: float = float(entity.get("ground_y")) if "ground_y" in entity else 810.0
		_site_pos = Vector2(pos.x, ground_y + WORK_OFFSET_Y)
	_phase = Phase.TO_TARGET
	return true


## 找最近未枯竭且产物匹配的资源点（resource_node 组扫描，同玩家交互先例）。
func _find_resource_node() -> Node2D:
	var product := String(_prof.get("product", ""))
	if product.is_empty() or entity == null or not is_instance_valid(entity) \
			or entity.get_tree() == null:
		return null
	var best: Node2D = null
	var best_dist: float = INF
	for node in entity.get_tree().get_nodes_in_group("resource_node"):
		var rn := node as Node2D
		if rn == null or not is_instance_valid(rn) or not rn.is_inside_tree():
			continue
		if rn.has_method("is_depleted") and rn.is_depleted():
			continue
		if not rn.has_method("get_resource_id") or String(rn.get_resource_id()) != product:
			continue
		var d: float = rn.global_position.distance_to(entity.global_position)
		if d < best_dist:
			best_dist = d
			best = rn
	return best


# ─────────────────────────────── 移动 ────────────────────────────────

func _update_travel() -> void:
	var target := _current_target()
	# 目标中途失效（被清场/枯竭）：重新寻位
	if not _target_valid():
		if not _locate():
			finish()
		return
	var dist: float = entity.global_position.distance_to(target)
	if dist > ARRIVE_THRESHOLD:
		if entity.has_method("ai_move"):
			entity.ai_move((target - entity.global_position).normalized())
	else:
		if entity.has_method("ai_stop"):
			entity.ai_stop()
		_phase = Phase.WORKING
		_cycle_timer = 0.0


func _current_target() -> Vector2:
	return _node.global_position if _mode == Mode.RESOURCE else _site_pos


func _target_valid() -> bool:
	if _mode == Mode.WORKSITE:
		if _site_building == null:
			return true  # 占位工位恒有效（无建筑可失效）
		# 建筑存活校验（被毁/释放/非运营态 → 重新寻位：换建筑或降级占位）
		return is_instance_valid(_site_building) and _site_building.is_inside_tree() \
				and (not _site_building.has_method("is_operational") or _site_building.is_operational())
	return _node != null and is_instance_valid(_node) and _node.is_inside_tree() \
			and not (_node.has_method("is_depleted") and _node.is_depleted())


# ─────────────────────────────── 劳作 ────────────────────────────────

func _update_working(delta: float) -> void:
	# 劳作中途目标失效（资源点采空换树 / 建筑被毁换工位）：重新寻位
	if not _target_valid():
		if not _locate():
			finish()
		return
	if entity.has_method("ai_stop"):
		entity.ai_stop()
	# 面向劳作对象（挥击方向正确）
	if _mode == Mode.RESOURCE:
		face_position(_node.global_position)
	var cycle: float = maxf(float(_prof.get("cycle", 5.0)), 0.2)
	if _cycle_timer == 0.0:
		# 拍首：劳作动画钩子（按武器路由挥镐/挥剑，oneshot 播完自动回切）
		if entity.has_method("play_attack"):
			entity.play_attack()
	_cycle_timer += delta
	if entity.has_method("set_action_progress"):
		entity.set_action_progress(_cycle_timer / cycle)
	if _cycle_timer < cycle:
		return
	# 拍尾结算：产物入账
	_cycle_timer = 0.0
	if entity.has_method("hide_action_progress"):
		entity.hide_action_progress()
	_settle()


## 拍结算：资源点 harvest → produce；工位 consume → produce（转化链）。
func _settle() -> void:
	var api: Variant = _get_resources_api()
	if api == null or not api.has_method("produce"):
		return
	if _mode == Mode.RESOURCE:
		var qty := int(float(_prof.get("produce_amount", 20.0)))
		if qty <= 0:
			qty = 20
		# 实际采得量以资源点余量为准（与玩家手采同语义）；采空由下帧 _locate 换点
		var gained: int = _node.harvest(qty)
		if gained > 0:
			api.produce(String(_node.get_resource_id()), float(gained), HARVEST_REGION, SOURCE_NPC)
	else:
		var consume_res := String(_prof.get("consume_res", ""))
		var produce_amount: float = float(_prof.get("produce_amount", 6.0))
		if consume_res.is_empty():
			api.produce(String(_prof.get("product", "")), produce_amount, HARVEST_REGION, SOURCE_NPC)
			return
		var consume_amount: float = float(_prof.get("consume_amount", 0.0))
		var r: Dictionary = api.consume(consume_res, consume_amount, HARVEST_REGION, SOURCE_NPC_CONSUME)
		if bool(r.get("ok", false)):
			api.produce(String(_prof.get("product", "")), produce_amount, HARVEST_REGION, SOURCE_NPC)
		# 原料不足：空拍等待（站桩重试，矿工供给跟上后自动恢复产出）


# ─────────────────────────────── 内部 ────────────────────────────────

## 经 TownLifeAPI 契约读职业档案（实体待业返回 {}）。
func _load_profession() -> Dictionary:
	if entity == null or not is_instance_valid(entity):
		return {}
	if not entity.has_method("get_profession"):
		return {}
	return TownLifeAPI.get_profession(String(entity.get_profession()))


## ResourcesApi 获取：显式注入优先；缺省 current_scene 下具名查找
## （同 interaction_controller 先例，采集入库必须走模块 API）。
func _get_resources_api() -> Variant:
	if resources_api != null and is_instance_valid(resources_api):
		return resources_api
	if entity == null or not is_instance_valid(entity) or entity.get_tree() == null:
		return null
	var scene_root: Node = entity.get_tree().current_scene
	if scene_root != null:
		resources_api = scene_root.find_child("ResourcesApi", true, false)
	return resources_api


# ─────────────────────────────── 观测（测试/调试用）───────────────────────────────

## 当前模式（"resource"/"worksite"，集成测试与截图证据用）
func get_mode_name() -> String:
	return "resource" if _mode == Mode.RESOURCE else "worksite"


## 是否已到位劳作
func is_working() -> bool:
	return _phase == Phase.WORKING and not is_finished()


## 当前劳作目标资源点（资源点模式；无则 null）
func get_target_node() -> Node2D:
	return _node


## 当前工位所在建筑（工位模式；占位工位/资源点模式返回 null，测试/截图证据用）
func get_worksite_building() -> Node2D:
	return _site_building
