extends RefCounted
## 班内聚拢/对齐（Boids 三力裁剪的第二、三力）——static 函数库（无实例状态）。
##
## 三力分工（创始人裁决）：分离力（防挤，units 侧椭圆分离，另行施工）｜
## 聚拢弹簧（本文件，防散伙）｜对齐（本文件轻量版，防排头狂奔排尾散步）。
##
## 聚拢弹簧核心 = 死区设计（防沙丁鱼的关键）：单位距本班质心 ≤ 班散布半径时
## **零施力**（不吸站好的），超出到质心距离才产生回拉力，随超出距离线性增强、
## 上限封顶（防磁铁）。质心/班均速按 400ms 节流缓存（挂宿主 squad 字典），
## 消费方逐帧查询不重算。
##
## 门控（战斗走位优先）：
##   - 接战中（behavior == "attack"）回拉减半（COHESION_ENGAGED_SCALE）；
##   - 撤退/避战中（"retreat"/"seek_cover"）不受聚拢不对齐（避战优先）；
##   - 班均速低于死区（站桩）不对齐，防站桩抖动。
##
## 输出 = 转向建议（Vector2，加速度量纲），消费方（entity_motion 集成，见收线
## 报告清单）叠加到既有转向通道，**不直改位置**。数值全部【提案/待定·待实测校准】，
## 单一真相源在 api.gd（本库经 api 读，api 不回引本库，无环）。

const _Api := preload("res://modules/formation/api.gd")

## 缓存节流（ms）：质心/班均速刷新间隔
const CACHE_TTL_MS: int = 400
## 避战态行为名（不受聚拢不对齐；口径见 ai_controller 行为注册）
const AVOID_BEHAVIORS: Array = ["retreat", "seek_cover"]
## 接战态行为名（回拉减半）
const ENGAGED_BEHAVIOR: String = "attack"


## 班散布半径（px）：按班现有人数线性放宽——8 人班取基准，班越大越宽
static func squad_spread_radius(members: int) -> float:
	var base: float = _Api.COHESION_SPREAD_RADIUS_BASE
	var per: float = _Api.COHESION_SPREAD_RADIUS_PER_MEMBER
	return base + per * float(maxi(members - 8, 0))


## 刷新（节流）并取班聚拢缓存：{"centroid", "avg_vel", "members"}；
## 班不存在/无存活成员返回 {}。缓存留宿主 squad["cohesion_cache"]。
static func refresh_cache(host, squad_id: String) -> Dictionary:
	if not host._squads.has(squad_id):
		return {}
	var squad: Dictionary = host._squads[squad_id]
	var now: int = Time.get_ticks_msec()
	var cache: Dictionary = squad.get("cohesion_cache", {})
	if not cache.is_empty() and now - int(cache.get("at", -10000)) < CACHE_TTL_MS:
		return cache
	var centroid := Vector2.ZERO
	var avg_vel := Vector2.ZERO
	var members: Array = []
	for u in squad["units"]:
		if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
			centroid += u.global_position
			if "velocity" in u:
				avg_vel += u.velocity
			members.append(u)
	var n: int = members.size()
	if n == 0:
		return {}
	centroid /= float(n)
	avg_vel /= float(n)
	cache = {
		"centroid": centroid,
		"avg_vel": avg_vel,
		"members": n,
		"at": now,
	}
	squad["cohesion_cache"] = cache
	return cache


## 单位聚拢-对齐合成转向建议：Vector2.ZERO = 无施力（死区内/避战中/无班）。
static func squad_steer(host, squad_id: String, unit: Node) -> Vector2:
	var cache := refresh_cache(host, squad_id)
	if cache.is_empty() or unit == null or not is_instance_valid(unit):
		return Vector2.ZERO
	# 行为门控：避战/溃散优先，聚拢与对齐全部让位
	var behavior := ""
	if unit.has_method("get_current_behavior"):
		behavior = String(unit.get_current_behavior())
	if behavior in AVOID_BEHAVIORS:
		return Vector2.ZERO
	var steer := Vector2.ZERO
	# ── 聚拢弹簧：死区外线性回拉、上限封顶 ──
	var centroid: Vector2 = cache["centroid"]
	var to_centroid: Vector2 = centroid - unit.global_position
	var dist: float = to_centroid.length()
	var spread: float = squad_spread_radius(int(cache["members"]))
	var over: float = dist - spread
	if over > 0.0 and dist > 0.001:
		var pull: float = minf(over * _Api.COHESION_PULL_PER_PX, _Api.COHESION_PULL_MAX)
		if behavior == ENGAGED_BEHAVIOR:
			pull *= _Api.COHESION_ENGAGED_SCALE  # 接战中减半：战斗走位优先
		steer += to_centroid / dist * pull
	# ── 对齐（轻量）：行军速度向班均值收敛（站桩不对齐防抖；接战不对齐保走位）──
	var avg_vel: Vector2 = cache["avg_vel"]
	if behavior != ENGAGED_BEHAVIOR and avg_vel.length() > _Api.COHESION_AVG_SPEED_DEADZONE \
			and "velocity" in unit:
		steer += (avg_vel - unit.velocity) * _Api.ALIGNMENT_STEER_SCALE
	return steer
