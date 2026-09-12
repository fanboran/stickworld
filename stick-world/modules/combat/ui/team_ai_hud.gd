extends VBoxContainer
## TeamAi 状态 HUD（W1 观测接线批 · 组织界面与AI状态接线总体方案 §2.2，调试向）。
##
## 阵营级 AI 姿态可观测面：攻/防双方各一行——姿态徽标（驻守/防守/进攻/溃退）
## + reason 一行 + attack% + 攻/防任务槽占用 + 开战攻击倒计时。
## 数据来源（方案 §2.0/§2.2）：
##   - 信号驱动：EventBus.team_ai_stance_changed（姿态变更即刷，不逐帧轮询）；
##   - 查询兜底：低频轮询（POLL_INTERVAL）刷新 attack%（get_attack_percentage
##     缓存查询，不重跑四规则）/ 任务槽占用 / 攻击倒计时；TeamAi 未注册的阵营
##     显示"未启用"（注册制闸门的直接观测）。
##   - 全程 duck 探测（has_method），查询不可用跳过该段——调试 UI 不倒逼战斗侧。
## 显隐走 DebugApi drawer "team_ai_hud"（F3 开关族，惯例默认可见；开关注册在
## SystemSetup.register_debug_drawers）。装配：SystemSetup 挂 HudOverlay 槽并
## 注入 BattleDirector 引用；场景是布局唯一真相源（骨架见 team_ai_hud.tscn）。

## 同模块档案引用（combat 域内，取姿态/槽型常量唯一真相源）
const ScriptTeamAi := preload("res://modules/combat/scripts/battle/team_ai.gd")
const ScriptTaskBoard := preload("res://modules/combat/scripts/battle/task_board.gd")

## 阵营常量（对齐 BattleInstance.FACTION_*：本地常量避免反向依赖宿主，ai_controller 先例）
const FACTION_ATTACKER: int = 1
const FACTION_DEFENDER: int = 2

## DebugApi drawer 开关名（F3 族）
const DRAWER_NAME := "team_ai_hud"
## 查询兜底轮询间隔（s）：远慢于 TeamAi 决策节拍（1s），只兜信号外的缓变数据
const POLL_INTERVAL: float = 0.25

## 姿态徽标文案（下标 = TeamAi.STANCE_* 枚举序）
const STANCE_NAMES: Array[String] = ["驻守", "防守", "进攻", "溃退"]

@onready var _stance_labels: Array = [$AtkRow/Row/Stance, $DefRow/Row/Stance]
@onready var _info_labels: Array = [$AtkRow/Row/Info, $DefRow/Row/Info]

## BattleDirector 引用（SystemSetup 装配注入；活跃战斗经 get_active_battles 查询）
var _director: Node = null
## 轮询累积器
var _poll_acc: float = 0.0


## 装配注入（SystemSetup 挂槽后调用；director 允许 null = 行显示无数据）
func setup(battle_director: Node) -> void:
	_director = battle_director
	if is_inside_tree():
		_refresh()


func _ready() -> void:
	_update_visibility()
	if DebugApi:
		if not DebugApi.visibility_changed.is_connected(_on_debug_visibility_changed):
			DebugApi.visibility_changed.connect(_on_debug_visibility_changed)
		if not DebugApi.drawer_enabled_changed.is_connected(_on_drawer_enabled_changed):
			DebugApi.drawer_enabled_changed.connect(_on_drawer_enabled_changed)
		if EventBus != null and EventBus.has_signal("team_ai_stance_changed") \
				and not EventBus.team_ai_stance_changed.is_connected(_on_stance_changed):
			EventBus.team_ai_stance_changed.connect(_on_stance_changed)
	_refresh()


func _process(delta: float) -> void:
	# 隐藏即整帧跳过（F3 关闭后零成本，debug_info_panel 同惯例）
	if not visible:
		return
	_poll_acc += delta
	if _poll_acc >= POLL_INTERVAL:
		_poll_acc = 0.0
		_refresh()


# ─────────────────────────────── 刷新 ────────────────────────────────

## 信号驱动刷新（EventBus.team_ai_stance_changed）：姿态变更即刷当前战斗两行。
## battle_id 不匹配（多战场扩展期）忽略，等轮询兜底对齐。
func _on_stance_changed(battle_id: String, _faction: int, _from: int, _to: int, _reason: String) -> void:
	var bi: Node = _current_battle()
	if bi != null and bi.has_method("get_battle_id") and str(bi.get_battle_id()) == battle_id:
		_refresh()


func _refresh() -> void:
	_refresh_row(0, FACTION_ATTACKER)
	_refresh_row(1, FACTION_DEFENDER)


func _refresh_row(row_idx: int, faction: int) -> void:
	if row_idx < 0 or row_idx >= STANCE_NAMES.size() or _stance_labels.is_empty():
		return
	var stance_label: Label = _stance_labels[row_idx]
	var info_label: Label = _info_labels[row_idx]
	var tai: Variant = _current_team_ai(faction)
	if tai == null:
		stance_label.text = "—"
		stance_label.modulate = Color(0.6, 0.6, 0.6, 0.9)
		info_label.text = "TeamAi 未启用"
		return
	# 姿态徽标（0=驻守/1=防守/2=进攻/3=溃退；越界回退"?"）
	var stance: int = int(tai.get_stance()) if tai.has_method("get_stance") else -1
	if stance >= 0 and stance < STANCE_NAMES.size():
		stance_label.text = STANCE_NAMES[stance]
		stance_label.modulate = _stance_color(stance)
	else:
		stance_label.text = "?"
		stance_label.modulate = Color(0.6, 0.6, 0.6, 0.9)
	# 详情行：reason · attack% · 槽占用 · 倒计时（各段 duck，缺查跳过）
	var parts: Array[String] = []
	if tai.has_method("get_stance_reason"):
		parts.append(str(tai.get_stance_reason()))
	if tai.has_method("get_attack_percentage"):
		parts.append("攻 %d%%" % roundi(float(tai.get_attack_percentage()) * 100.0))
	var board: Variant = tai.get_task_board() if tai.has_method("get_task_board") else null
	if board != null and board.has_method("slot_count"):
		parts.append("槽 %d·%d" % [board.slot_count(ScriptTaskBoard.KIND_ATTACK),
				board.slot_count(ScriptTaskBoard.KIND_DEFEND)])
	var remain: float = _attack_remain(tai)
	if remain > 0.0:
		parts.append("开战 %.1fs" % remain)
	info_label.text = " · ".join(parts)


## 开战攻击倒计时余量（s）：门禁截止 - 战斗秒；截止已过/不可查 = 0（不显示）。
func _attack_remain(tai: Variant) -> float:
	if not tai.has_method("get_attack_deadline"):
		return 0.0
	var bi: Node = _current_battle()
	if bi == null or not bi.has_method("get_duration"):
		return 0.0
	return float(tai.get_attack_deadline()) - float(bi.get_duration())


## 姿态徽标色（驻守=蓝 / 防守=绿 / 进攻=琥珀 / 溃退=红）
func _stance_color(stance: int) -> Color:
	match stance:
		ScriptTeamAi.STANCE_GARRISON:
			return Color(0.55, 0.75, 0.95, 1.0)
		ScriptTeamAi.STANCE_DEFEND:
			return Color(0.65, 0.9, 0.65, 1.0)
		ScriptTeamAi.STANCE_ATTACK:
			return Color(0.98, 0.75, 0.35, 1.0)
		ScriptTeamAi.STANCE_ROUT:
			return Color(0.95, 0.45, 0.4, 1.0)
	return Color(0.6, 0.6, 0.6, 0.9)


# ─────────────────────────────── 取数 ────────────────────────────────

## 当前活跃战斗（P0 单战场：取首个 is_active 的实例；无活跃 = null）
func _current_battle() -> Node:
	if _director == null or not is_instance_valid(_director) \
			or not _director.has_method("get_active_battles"):
		return null
	for b in _director.get_active_battles():
		if is_instance_valid(b) and b.has_method("is_active") and b.is_active():
			return b
	return null


func _current_team_ai(faction: int) -> Variant:
	var bi: Node = _current_battle()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_team_ai"):
		return null
	var tai: Variant = bi.get_team_ai(faction)
	if tai == null or not is_instance_valid(tai):
		return null
	return tai


# ─────────────────────────────── 显隐（F3 drawer 开关族）────────────────────────────────

func _on_debug_visibility_changed(_v: bool) -> void:
	_update_visibility()


func _on_drawer_enabled_changed(drawer_name: String, _enabled: bool) -> void:
	if drawer_name == DRAWER_NAME:
		_update_visibility()


func _update_visibility() -> void:
	if DebugApi:
		visible = DebugApi.is_visible() and DebugApi.is_drawer_enabled(DRAWER_NAME)
