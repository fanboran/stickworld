extends RefCounted
## 编队几何助手 —— 从 formation_system.gd 拆出的 static 函数库（无实例状态）。
##
## 职责（SWL Formation 直译，11b）：
## - member_facing：成员面向轴向（±x，槽位成本评估用）；
## - slot_world：槽位世界坐标（前列贴 base_pos，后列沿行进方向反侧退 row_gap×col，
##   同列以 base_pos 为中心沿垂直方向展开）；
## - assign_formation_slots：槽位分配/重算（Add/Remove 等价全队重算 +
##   FilterDownARandomRow 等价列收缩 + ShouldSwitchUnitsInFormation 贪心互换）。
##
## 纪律：几何参数（units_per_column/spread_spacing/row_gap）显式传参——宿主的
## SPREAD_SPACING/ROW_GAP 是 var（balance 可覆盖），宿主壳每次调用传当前值，
## 本库不缓存参数快照。槽位状态（_squads[].slots）留宿主，经 host 动态回引读写。

## 成员面向轴向（±x；槽位成本评估用。实体有 get_facing 用真值，桩/无朝向回退 +x）
static func member_facing(u: Node) -> Vector2:
	if u != null and u.has_method("get_facing"):
		return Vector2.LEFT if int(u.get_facing()) < 0 else Vector2.RIGHT
	return Vector2.RIGHT


## 槽位世界坐标（SWL GetFormationXOffset 的列位移等价）：
## 前列贴 base_pos，后列沿行进方向反侧退 row_gap×col；
## 同列以 base_pos 为中心沿垂直方向展开（间距 spread_spacing）。
static func slot_world(slot: Vector2i, base_pos: Vector2, facing: Vector2,
		units_per_column: int, spread_spacing: float, row_gap: float) -> Vector2:
	var perp := Vector2(-facing.y, facing.x)
	var lateral: float = (float(slot.y) - float(units_per_column - 1) * 0.5) * spread_spacing
	return base_pos - facing * (float(slot.x) * row_gap) + perp * lateral


## 编队槽位分配/重算（核心入口，成员增减/死亡时调用；host = FormationSystem 宿主）：
##   - Add/Remove 等价：全队槽位重算，索引序 = 入队序（小队单兵种同质，
##     入队序即 SWL formationOrder 组序等价）
##   - FilterDownARandomRow 等价：列数 = ceil(人数/units_per_column) 随减员自动
##     收缩、不留空列（SWL 按随机整行滤除；此处确定性重排，观感待实测校准）
##   - ShouldSwitchUnitsInFormation 直译：贪心互换——互换两成员槽位后"人到槽"
##     总行走距离缩短则换（前排让给更近的人，减少行军穿插）；锚 = 小队质心，
##     朝向 = 平均面向（经宿主 _squad_anchor 取统一参考系）
static func assign_formation_slots(host, squad_id: String,
		units_per_column: int, spread_spacing: float, row_gap: float) -> void:
	if not host._squads.has(squad_id):
		return
	var squad: Dictionary = host._squads[squad_id]
	var alive: Array = []
	for u in squad["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			alive.append(u)
	if alive.is_empty():
		squad["slots"] = {}
		return

	var slots: Dictionary = {}
	for i in alive.size():
		slots[alive[i].get_instance_id()] = Vector2i(
				floori(float(i) / float(units_per_column)), i % units_per_column)
	# ShouldSwitchUnitsInFormation 直译：贪心互换（锚/朝向以当前参考系评估）
	var anch: Dictionary = host._squad_anchor(squad_id)
	var centroid: Vector2 = anch["centroid"]
	var facing: Vector2 = anch["facing"]
	var improved: bool = true
	var guard: int = 0
	while improved and guard < 8:  # 人数 ≤12，两两互换最多数轮收敛
		guard += 1
		improved = false
		for a in range(alive.size()):
			for b in range(a + 1, alive.size()):
				var ua: Node = alive[a]
				var ub: Node = alive[b]
				var sa: Vector2i = slots[ua.get_instance_id()]
				var sb: Vector2i = slots[ub.get_instance_id()]
				var cost_before: float = \
						ua.global_position.distance_to(slot_world(sa, centroid, facing, units_per_column, spread_spacing, row_gap)) \
						+ ub.global_position.distance_to(slot_world(sb, centroid, facing, units_per_column, spread_spacing, row_gap))
				var cost_after: float = \
						ua.global_position.distance_to(slot_world(sb, centroid, facing, units_per_column, spread_spacing, row_gap)) \
						+ ub.global_position.distance_to(slot_world(sa, centroid, facing, units_per_column, spread_spacing, row_gap))
				if cost_after + 1.0 < cost_before:  # 1px 门槛防等距抖动
					slots[ua.get_instance_id()] = sb
					slots[ub.get_instance_id()] = sa
					improved = true
	squad["slots"] = slots
