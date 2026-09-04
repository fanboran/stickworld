extends Node
## 求职 Demo 目标链 —— 四阶段引导（采集→建造→编队→战斗）+ 胜利结算。
##
## 存在意义：Demo 阶段给陌生玩家一条"10 分钟能走完的目标线"，把自由沙盒收束成
## 有头有尾的章节体验（创始人诉求：HR 打开知道要干什么）。
##
## 全事件驱动零轮询：
## - 采集：ResourcesApi.resource_changed（基线法累计，避免把开局初始资源算成进度）
## - 建造：ConstructionApi.building_completed
## - 编队：EventBus.squad_created
## - 战斗：EventBus.battle_ended（victory=true）
##
## 由 SystemSetup 在资源系统 deferred 装配之后创建（保证初始资源已发放、
## 基线快照正确），UI 部件 QuestPanel / VictoryOverlay 均由本组件驱动。

signal quest_completed(quest_id: String)
signal all_completed

const _QuestPanelScript: GDScript = preload("res://modules/ui_global/scripts/hud/quest_panel.gd")
const _VictoryOverlayScript: GDScript = preload("res://modules/ui_global/scripts/overlays/victory_overlay.gd")

var _quests: Array = []
var _index: int = -1
var _panel: Control = null
var _resources_api: Node = null
var _construction_api: Node = null
var _ui_root: Node = null

## 采集进度基线（setup 时刻的库存，进度 = 当前库存 - 基线）
var _wood_baseline: float = 0.0
## 统计
var _start_msec: int = 0
var _harvest_total: float = 0.0
var _build_count: int = 0
var _squad_count: int = 0
var _battle_win_count: int = 0
var _victory_shown: bool = false


## 由 SystemSetup 装配调用（此时初始资源已发放，基线安全）
func setup(panel: Control, resources_api: Node, construction_api: Node, ui_root: Node) -> void:
	_panel = panel
	_resources_api = resources_api
	_construction_api = construction_api
	_ui_root = ui_root
	_quests = [
		{"id": "harvest", "title": "采集资源",
			"desc": "WASD 移动，靠近树木或岩石，按 E 采集", "target": 60.0},
		{"id": "build", "title": "建造一座建筑",
			"desc": "右下角「建造」→ 选建筑 → 左键放置 → 靠近按 E 施工", "target": 1.0},
		{"id": "squad", "title": "组建一个编队",
			"desc": "顶栏「编制」创建编队（或 Q 切战斗模式框选士兵）", "target": 1.0},
		{"id": "battle", "title": "赢得一场战斗",
			"desc": "带士兵向右行军穿过道路，在战场消灭全部敌人", "target": 1.0},
	]
	_start_msec = Time.get_ticks_msec()
	_bind_signals()
	_advance()


# ─────────────────────────────── 信号绑定 ────────────────────────────────

func _bind_signals() -> void:
	if _resources_api != null and _resources_api.has_signal("resource_changed"):
		_resources_api.resource_changed.connect(_on_resource_changed)
		_wood_baseline = float(_resources_api.get_stock("res_wood", ""))
	if _construction_api != null and _construction_api.has_signal("building_completed"):
		_construction_api.building_completed.connect(_on_building_completed)
	if EventBus != null:
		if EventBus.has_signal("squad_created"):
			EventBus.squad_created.connect(_on_squad_created)
		if EventBus.has_signal("battle_ended"):
			EventBus.battle_ended.connect(_on_battle_ended)


# ─────────────────────────────── 目标推进 ────────────────────────────────

## 推进到下一个目标；全部完成则触发胜利结算
func _advance() -> void:
	_index += 1
	if _index >= _quests.size():
		_finish_all()
		return
	if _panel == null:
		return
	var q: Dictionary = _quests[_index]
	_panel.show_quest(String(q.title), String(q.desc), _progress_text(q))


func _progress_text(q: Dictionary) -> String:
	if String(q.id) == "harvest":
		return "木材 %d / %d" % [int(_quest_progress(q)), int(q.target)]
	return ""


func _quest_progress(q: Dictionary) -> float:
	match String(q.id):
		"harvest":
			if _resources_api == null:
				return 0.0
			return maxf(0.0, float(_resources_api.get_stock("res_wood", "")) - _wood_baseline)
	return 0.0


func _complete_current() -> void:
	if _index < 0 or _index >= _quests.size():
		return
	var q: Dictionary = _quests[_index]
	if _panel != null:
		_panel.mark_done(String(q.title))
	_notify("目标完成", "✓ %s" % String(q.title))
	quest_completed.emit(String(q.id))
	_advance()


func _finish_all() -> void:
	if _victory_shown:
		return
	_victory_shown = true
	all_completed.emit()
	if _panel != null:
		_panel.show_all_done()
	_show_victory()


# ─────────────────────────────── 事件处理 ────────────────────────────────

func _on_resource_changed(resource_id: String, _amount: float, delta: float, _region_id: String) -> void:
	# 统计累计采集（只算增量，含建造清场回收）
	if resource_id == "res_wood" and delta > 0.0:
		_harvest_total += delta
	# 当前是采集目标时刷新进度
	if _index >= 0 and _index < _quests.size() and String(_quests[_index].id) == "harvest":
		var q: Dictionary = _quests[_index]
		if _panel != null:
			_panel.show_quest(String(q.title), String(q.desc), _progress_text(q))
		if _quest_progress(q) >= float(q.target):
			_complete_current()


func _on_building_completed(_building_id: String, _region_id: String) -> void:
	_build_count += 1
	if _is_current("build"):
		_complete_current()


func _on_squad_created(_squad_id: String, _unit_ids: Array) -> void:
	_squad_count += 1
	if _is_current("squad"):
		_complete_current()


func _on_battle_ended(_battle_id: String, victory: bool) -> void:
	# victory 语义 = 进攻方获胜；Demo 中玩家为歼灭战场守军的一方。
	# 若实测语义相反（防守方视角），仅需翻转此布尔。
	if victory:
		_battle_win_count += 1
	if _is_current("battle") and victory:
		_complete_current()


func _is_current(quest_id: String) -> bool:
	return _index >= 0 and _index < _quests.size() and String(_quests[_index].id) == quest_id


# ─────────────────────────────── 胜利结算 ────────────────────────────────

func _show_victory() -> void:
	if _ui_root == null:
		_notify("全部目标完成", "Demo 阶段目标全部达成，继续自由游玩！")
		return
	var overlay: Control = UIKit.full_rect(_VictoryOverlayScript, "VictoryOverlay")
	if not _ui_root.add_to_slot("ModalOverlay", overlay):
		overlay.queue_free()
		return
	var elapsed_sec: float = (Time.get_ticks_msec() - _start_msec) / 1000.0
	var minutes: int = int(elapsed_sec) / 60
	var seconds: int = int(elapsed_sec) % 60
	overlay.show_victory({
		"time_text": "%d 分 %02d 秒" % [minutes, seconds],
		"harvest": int(_harvest_total),
		"builds": _build_count,
		"squads": _squad_count,
		"battles": _battle_win_count,
	})
	_notify("第一章完成", "阶段目标全部达成")


# ─────────────────────────────── 工具 ────────────────────────────────

func _notify(title: String, body: String, level: String = "info") -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit(title, body, level)
