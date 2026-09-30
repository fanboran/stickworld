class_name CapturePoint
extends RefCounted
## 夺点 —— 位置 + 半径 + 归属方 + 占领进度的纯逻辑结算原子（无节点 / 无渲染）。
##
## 夺点驱动宏观意图的结算底座（观察场夺点 v1）：班长意图规划器每节拍喂一次
## 「半径内各阵营人数」，本类按下列规则结算（世界盒子 W8 城池拉锯的同构简化版）：
##   - 半径内只有一方单位 → 该方按 CAPTURE_RATE_PER_SECOND 积分（整十口径，进度 0→100）；
##   - 双方都在场 → 冻结互消（进度不动，谁也别想边打边占）；
##   - 无人 / 己方驻留己方点 → 维持现状（进度不回退，拉锯残留语义，待实测校准）；
##   - 进度满 → 易主（归属 = 占领方，进度清零），发 capture_owner_changed 模块信号。
##
## 信号消费：观察场控制面板（battle_arena）连 capture_owner_changed 即时刷旗点状态行；
## Benchmark 选手基类经 get_capture_state() 只读探测旗点；后续出征/领地域（W8）
## 消费同一信号接入领地循环。
##
## 依赖纪律：纯 RefCounted 零出向——不依赖任何模块 / autoload，数据全部由调用方喂入。

# ─────────────────────────────── 常量 ────────────────────────────────
## 占领积分速率（每秒；整十口径——0→100 约 5 秒）【待实测校准】
const CAPTURE_RATE_PER_SECOND: int = 20
## 进度满值（整十；到顶即易主）
const PROGRESS_MAX: int = 100

# ─────────────────────────────── 信号 ────────────────────────────────
## 易主信号（from/to 阵营，0 = 无主；tactics 模块 api 信号，消费方连实例）
signal capture_owner_changed(point_id: String, from_faction: int, to_faction: int)

# ─────────────────────────────── 状态 ────────────────────────────────
## 标识 id（观察场用 capture_left/center/right；技术 id 不受游戏内命名口径约束）
var point_id: String = ""
## 世界坐标（行走带内）
var position: Vector2 = Vector2.ZERO
## 占领半径（px）
var radius: float = 0.0
## 归属方（0 = 无主 / 1 = 进攻方 / 2 = 防守方）
var owner_faction: int = 0
## 占领进度（0 ~ PROGRESS_MAX）
var progress: float = 0.0
## 上次结算是否争夺（双方同在半径内 = 冻结互消态）
var contested: bool = false
## 上次结算的在场人数快照 {faction: int}（只读消费经 get_holders）
var _holders: Dictionary = {}


## 装配（调用方创建后一次性调用；initial_owner 默认无主）
func setup(id: String, pos: Vector2, r: float, initial_owner: int = 0) -> void:
	point_id = id
	position = pos
	radius = maxf(r, 0.0)
	owner_faction = initial_owner
	progress = 0.0
	_holders = {}


## 结算一拍（意图规划器节拍驱动；faction_counts = {faction: 半径内人数}）。
## 后置：进度 / 归属按头部规则推进；易主时发 capture_owner_changed。
func tick(delta: float, faction_counts: Dictionary) -> void:
	# 在场快照重建（人数 > 0 的阵营才算在场）
	_holders = {}
	for f in faction_counts:
		var n := int(faction_counts[f])
		if n > 0:
			_holders[f] = n
	contested = _holders.size() >= 2
	# 冻结互消（双方在场）/ 无人维持：进度一律不动
	if _holders.size() != 1:
		return
	var holder: int = _holders.keys()[0]
	# 己方驻留己方已占点：无事可结
	if holder == owner_faction:
		return
	progress = minf(progress + float(CAPTURE_RATE_PER_SECOND) * delta, float(PROGRESS_MAX))
	if progress >= float(PROGRESS_MAX):
		var from := owner_faction
		owner_faction = holder
		progress = 0.0
		capture_owner_changed.emit(point_id, from, owner_faction)


# ─────────────────────────────── 只读查询 ────────────────────────────────

func get_point_id() -> String:
	return point_id


func get_position() -> Vector2:
	return position


func get_radius() -> float:
	return radius


func get_owner_faction() -> int:
	return owner_faction


func get_progress() -> float:
	return progress


func is_contested() -> bool:
	return contested


## 在场人数快照（只读副本；{faction: int}）
func get_holders() -> Dictionary:
	return _holders.duplicate()


## 旗点状态快照（Benchmark 选手基类按此方法名探测旗点；只读值拷贝）：
## {id, pos, radius, owner_faction, progress, contested}
func get_capture_state() -> Dictionary:
	return {
		"id": point_id,
		"pos": position,
		"radius": radius,
		"owner_faction": owner_faction,
		"progress": progress,
		"contested": contested,
	}
