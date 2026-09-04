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
const _OpeningHintScript: GDScript = preload("res://modules/ui_global/scripts/overlays/opening_hint_overlay.gd")
const _BattleBannerScript: GDScript = preload("res://modules/ui_global/scripts/overlays/battle_banner.gd")

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
## 乱序完成登记：玩家不按引导顺序玩（先建好后采集等）时，未轮到的目标
## 完成事件先记账，推进到该目标时直接跳过——目标链永不卡死
var _pending_done: Dictionary = {}
## 村民气泡（世界内引导）：目标推进时村民"说话"
var _bubble: VillagerBubble = null


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
			"desc": "向右穿图到战场，Q 战斗模式左键砍杀敌人（1-5 换武器）；也可框选士兵右键下令", "target": 1.0},
	]
	# 读档启动：玩家已有进度，不重新引导（目标全达成、不弹胜利结算）
	if SaveManager != null and SaveManager.boot_load_slot >= 0:
		_skip_all_for_loaded_save()
		return
	_start_msec = Time.get_ticks_msec()
	_bind_signals()
	_advance()
	_play_opening_camera()
	# 开局中央大提示（6 秒淡出/任意键关）——比通知 feed 更显眼的首次引导
	# 开局中央大提示（6 秒淡出/任意键关）——比通知 feed 更显眼的首次引导
	if _ui_root != null:
		var opening: Control = UIKit.full_rect(_OpeningHintScript, "OpeningHint")
		if not _ui_root.add_to_slot("HudOverlay", opening):
			opening.queue_free()
	# 开局操作指引（30 秒反馈原则：进场 1 秒内告诉玩家基础操作）
	_notify("欢迎来到火柴人大战略", "WASD 移动 · E 采集/交互 · Q 战斗模式 · Tab 战略图 · ESC 暂停")


## 读档局：全部目标直接标记完成（不弹胜利、不发推进信号）
func _skip_all_for_loaded_save() -> void:
	_index = _quests.size()
	_victory_shown = true
	if _panel != null:
		for q in _quests:
			_panel.mark_done(String(q.title))
		_panel.show_all_done()


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

## 推进到下一个目标；已乱序完成的目标直接跳过；全部完成则触发胜利结算
func _advance() -> void:
	_index += 1
	while _index < _quests.size() and _pending_done.has(String(_quests[_index].id)):
		var skipped: Dictionary = _quests[_index]
		if _panel != null:
			_panel.mark_done(String(skipped.title))
		quest_completed.emit(String(skipped.id))
		_index += 1
	if _index >= _quests.size():
		_finish_all()
		return
	if _panel == null:
		return
	var q: Dictionary = _quests[_index]
	_panel.show_quest(String(q.title), String(q.desc), _progress_text(q))
	if EventBus != null and EventBus.has_signal("quest_advanced"):
		EventBus.quest_advanced.emit(String(q.id))
	_update_battle_arrow(String(q.id))
	_villager_speak(String(q.id))
	# 采集类目标推进时立即检查一次（乱序期间可能已采够）
	if String(q.id) == "harvest" and _quest_progress(q) >= float(q.target):
		_complete_current()


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
	if AudioManager != null:
		AudioManager.play_event("quest_done")
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
	else:
		_pending_done["build"] = true


func _on_squad_created(_squad_id: String, _unit_ids: Array) -> void:
	_squad_count += 1
	if _is_current("squad"):
		_complete_current()
	else:
		_pending_done["squad"] = true


func _show_battle_banner(victory: bool) -> void:
	if _ui_root == null:
		return
	var banner: Control = _ui_root.get_node_or_null("HudOverlay/BattleBanner")
	if banner == null:
		banner = UIKit.full_rect(_BattleBannerScript, "BattleBanner")
		if not _ui_root.add_to_slot("HudOverlay", banner):
			return
	banner.show_banner(victory)


func _on_battle_ended(_battle_id: String, victory: bool) -> void:
	_show_battle_banner(victory)
	# victory 语义 = 进攻方获胜；Demo 中玩家为歼灭战场守军的一方。
	# 若实测语义相反（防守方视角），仅需翻转此布尔。
	if victory:
		_battle_win_count += 1
	if _is_current("battle") and victory:
		_complete_current()
	elif victory:
		_pending_done["battle"] = true


func _is_current(quest_id: String) -> bool:
	return _index >= 0 and _index < _quests.size() and String(_quests[_index].id) == quest_id


# ─────────────────────────────── 开场运镜（Demo 电影感）────────────────────────────────

## 开场：相机从远景（zoom 0.45）缓推到玩家（正常 zoom），2.6s——"从大战略落向个体"
## 的开场叙事，暗合 GDD 尺度跃迁支柱。期间输入不受影响（运镜只动相机）。
func _play_opening_camera() -> void:
	var root: Node = get_parent()
	var cam: Node2D = root.get_node_or_null("CameraRig") if root != null else null
	var player: Node2D = null
	if root != null and root.has_method("get_player_entity"):
		player = root.get_player_entity()
	if cam == null or player == null or not cam.has_method("set_user_zoom_raw"):
		return
	var normal_zoom: float = cam.user_zoom if "user_zoom" in cam else 1.0
	cam.set_user_zoom_raw(0.45)
	var tw := cam.create_tween()
	tw.tween_interval(0.35)
	tw.tween_method(func(v: float) -> void: cam.set_user_zoom_raw(v), 0.45, normal_zoom, 2.2)		.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)


# ─────────────────────────────── 村民气泡（世界内引导）────────────────────────────────

## 台词表：每个目标由村民之口说出（引导世界内化，而非纯 UI 弹窗）
const _VILLAGER_LINES: Dictionary = {
	"harvest": "村里的储备快见底了，东边的树和石头都能采！按住 E 别松手～",
	"build": "材料够了就盖点什么吧！点右下角「建造」，选好后靠近敲几下。",
	"squad": "人多力量大。顶栏「编制」把伙伴们编成一队，跟我们一起干！",
	"battle": "东边战场打起来了！带弟兄们过去，Q 切战斗模式，跟他们拼了！",
}

func _villager_speak(quest_id: String) -> void:
	if not _VILLAGER_LINES.has(quest_id):
		return
	if _bubble == null or not is_instance_valid(_bubble):
		var npc := _find_any_villager()
		if npc == null:
			return
		_bubble = VillagerBubble.new()
		_bubble.name = "VillagerBubble"
		npc.add_child(_bubble)
	_bubble.speak(String(_VILLAGER_LINES[quest_id]), 4.5)

## 找一个非附身村民（气泡宿主；NPC 生成晚于装配，惰性+失败静默）
func _find_any_villager() -> Node2D:
	var root: Node = get_parent()
	var map: Node2D = root.get_current_map() if root != null and root.has_method("get_current_map") else null
	if map == null or not map.has_method("get_entities"):
		return null
	for e in map.get_entities():
		var ent := e as Node2D
		if ent != null and is_instance_valid(ent) and ent.has_method("is_possessed") 				and not ent.is_possessed() and ent.has_method("is_dead") and not ent.is_dead():
			return ent
	return null


# ─────────────────────────────── 战场方向指示 ────────────────────────────────

## 战斗目标激活时屏幕右缘呼吸箭头（"向右行军去战场"的空间引导）
var _battle_arrow: Control = null

func _update_battle_arrow(quest_id: String) -> void:
	if quest_id == "battle":
		_show_battle_arrow()
	else:
		_hide_battle_arrow()

func _show_battle_arrow() -> void:
	if _battle_arrow != null and is_instance_valid(_battle_arrow):
		return
	if _ui_root == null:
		return
	_battle_arrow = Control.new()  # 非 UI 根，纯承载容器（子节点自理 anchor）
	_battle_arrow.name = "BattleArrow"
	_battle_arrow.set_anchors_preset(Control.PRESET_FULL_RECT)
	_battle_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lbl := Label.new()
	lbl.text = "▶ 战场"
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", Color(1.0, 0.62, 0.3))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	lbl.add_theme_constant_override("outline_size", 5)
	lbl.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	lbl.offset_left = -110.0
	lbl.offset_right = -24.0
	lbl.offset_top = -20.0
	lbl.offset_bottom = 20.0
	_battle_arrow.add_child(lbl)
	var tw := lbl.create_tween().set_loops()
	tw.tween_property(lbl, "modulate:a", 0.35, 0.7)
	tw.tween_property(lbl, "modulate:a", 1.0, 0.7)
	if not _ui_root.add_to_slot("HudOverlay", _battle_arrow):
		_battle_arrow.queue_free()
		_battle_arrow = null

func _hide_battle_arrow() -> void:
	if _battle_arrow != null and is_instance_valid(_battle_arrow):
		_battle_arrow.queue_free()
	_battle_arrow = null


# ─────────────────────────────── 胜利结算 ────────────────────────────────

func _show_victory() -> void:
	if _ui_root == null:
		_notify("全部目标完成", "Demo 阶段目标全部达成，继续自由游玩！")
		return
	var overlay: Control = UIKit.full_rect(_VictoryOverlayScript, "VictoryOverlay")
	if not _ui_root.add_to_slot("ModalOverlay", overlay):
		overlay.queue_free()
		return
	if AudioManager != null:
		AudioManager.play_event("battle_ended_win")
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
