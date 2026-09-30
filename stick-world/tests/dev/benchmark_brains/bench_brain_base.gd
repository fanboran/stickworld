extends RefCounted
## 自对弈 Benchmark 选手基类 —— 算法（选手）与战场之间的唯一通道。
##
## 协议（子类只须覆写 brain_name / setup / tick）：
##   setup()            开战前一次：读 ctx 缓存自己的编制/旗点
##   tick(dt)           每 0.5s 一次：观察 ctx 里的战场快照 → 输出决策
##   brain_name()       选手名（报分用）
##
## 自由度分层（创始人 2026-09-30 定的封装口径）：
##   个人级 —— unit_order()：对单个单位下覆盖令（单位自己还在打仗，同时接令执行）
##   编制级 —— squad_order()：对班下号令（走 TacticalOrders，传播链照旧）
##   观察级 —— snapshot()/flags()：拿到双方兵力/士气/位置/旗点的只读快照
## 输入=战场信息，输出=决策；不同岗位（矛/剑/弓/杖/祭司、班长/排长）的
## 决策差异由选手自己在这两层命令里表达，或配合 behavior_profiles 参数表。
##
## 留档原因（创始人原话）：攻击模组变化后重新训练不得从头造轮子——本文件
## 与 diag_arena_benchmark_driver.gd 就是那套训练设施，选手脚本放
## tests/dev/benchmark_brains/ 下，胜负判定与换边轮换由 driver 统一执行。

## ctx 由 driver 注入：{battle, arena, faction}
var ctx: Dictionary = {}


func brain_name() -> String:
	return "unnamed_brain"


func setup() -> void:
	pass


func tick(_dt: float) -> void:
	pass


## ── 观察级 ──
## 己方存活单位（未死未溃）节点数组
func my_units() -> Array:
	return _alive_units(ctx.faction)


func enemy_units() -> Array:
	return _alive_units(1 - int(ctx.faction))


## 战场快照（只读，值拷贝）：{pos, hp_ratio, morale_ratio, routed}
func snapshot(units: Array) -> Array:
	var out: Array = []
	for u in units:
		var hp: Node = u.get_health() if u.has_method("get_health") else null
		if hp == null or hp.is_dead():
			continue
		out.append({
			"node": u,
			"pos": (u as Node2D).global_position,
			"hp_ratio": hp.get_health_ratio() if hp.has_method("get_health_ratio") else 1.0,
			"morale_ratio": float(hp.morale) / float(hp.max_morale) if "morale" in hp and hp.max_morale > 0 else 1.0,
			"routed": hp.is_routed(),
		})
	return out


## 有效战力（未死未溃单位数）——与 driver 的胜负判定同口径
func effective_strength(faction: int) -> int:
	return _alive_units(faction).size()


## 夺点状态只读数组（夺点系统未接线时返回空——选手须兼容无旗战场）
func flags() -> Array:
	var out: Array = []
	var arena: Node = ctx.arena
	var stack: Array = [arena]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.has_method("get_capture_state"):
			out.append(n.get_capture_state())
		stack.append_array(n.get_children())
	return out


## ── 命令级 ──
## 个人级覆盖令：单位自己继续打仗，同时收到令会执行一定动作（有自由度：
## 单位怎么执行/是否转授下级，由其 AI 档案决定——这正是被迭代演化的点）
func unit_order(unit: Node, order: String, params: Dictionary = {}) -> void:
	if unit != null and unit.has_method("set_order"):
		unit.call("set_order", order, params)


## 编制级号令：对班下指令（走 TacticalOrders 既有号令与传播链）
func squad_order(order: String, params: Dictionary = {}) -> void:
	var orders: Node = ctx.get("tactical_orders")
	if orders != null and orders.has_method("issue"):
		orders.callv("issue", [order, params])


func _alive_units(faction: int) -> Array:
	var battle: Node = ctx.battle
	var arr: Array = battle.get("_units_attacker" if faction == 0 else "_units_defender")
	var out: Array = []
	if arr == null:
		return out
	for u in arr:
		if not is_instance_valid(u):
			continue
		var hp: Node = u.get_health() if u.has_method("get_health") else null
		if hp != null and not hp.is_dead() and not hp.is_routed():
			out.append(u)
	return out
