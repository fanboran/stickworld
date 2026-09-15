extends PanelContainer
## L1 班组卡（W2 · docs/设计/UI/组织界面与AI状态接线-总体方案.md §3.2.A）。
##
## 落位：ContextPanel 的 SquadInspector 槽；BATTLE 模式框选小队（选中单位能解析出
## 所属 L1 编制）时显示，选择清空/小队消亡即收起。
##
## 只答三问（信息密度服从管理层级 §1.3，L1 稀疏大字，不做字段堆砌）：
##   现在怎么样 → 头部状态徽标（org state × 成员行为聚合）+ 成员行士气微型条/单兵状态
##   在干什么   → 号令栏（EventBus.order_issued）+ 相位徽标（A5 计划 get_phase_name 直译）
##   听谁的     → 班长栏（指挥官 + get_squad_authority 权威值/星级）
##              + 权威值择班表达（UI-W4a §3.3①）：本班权威/星级 + 邻近可投奔班权威对比
##              +「N 人有意转投 X 班」提示条。全部走真实查询——邻近班逐个
##                get_squad_authority，择优用 should_switch_squad 滞回判定（R4 内核），
##                N 统计本班通过「不该动的别动」守卫且落在候选半径内的成员数；
##                查询缺口（无战斗侧/无权威出口）即整块隐藏，不显示占位噪声。
##
## 数据来源与降级（方案 §2.0/§3.2.A：**全部 duck 探测，绝不倒逼战斗侧改结构**；
## 查询不可用即跳过该行/该角标，不显示占位噪声）：
##   成员/班长/权威/名称 → FormationSystem 既有查询（get_squad_units / get_squad_leader /
##        get_squad_authority / get_squad_name / get_unit_squad）；解析不出小队即整卡收起；
##   权威对比/转投意向 → 组织相邻班（同父 L1 兄弟班，散兵退化为编队全部战斗班）
##        逐个 get_squad_authority + should_switch_squad，全部真实查询；
##   角色/相位 → squad_phase_plan 经宿主私有表 duck 取用（debug_info_panel.gd 先例），
##        刷新走 phase_changed / roles_reassigned 两信号（A5/W1 已补，不逐帧轮询）；
##   士气/单兵状态 → 单位侧只读口 get_health().get_morale_ratio()/is_routed()、
##        get_status_effects().has_suppressed()/has_effect(HEAL|STUN)；组件缺失跳过；
##   组织态 FORMING 招兵位 → organization_api.get_organization().state；
##   号令 → EventBus.order_issued（瞬时事件：换绑小队即清空，无存量查询口——见交接遗留）。
## 例外：士气流/权威值等缓变值走 POLL_INTERVAL 低频节拍（team_ai_hud 同惯例），
## 相位/角色/号令/编制变动全部信号驱动。
##
## 核心操作只用既有 API：任命班长（FormationSystem.assign_leader → 组织侧
## assign_commander）、移出班组（FormationSystem.remove_unit）；「放大到指挥链视图」
## 本批只留禁用入口（W3 批次）。
##
## 装配：SystemSetup 挂 UIRoot「ContextPanel/SquadInspector」槽并注入 GameRoot。
## 场景（squad_card.tscn）是布局唯一真相源；本脚本只装配内容与 token 样式。
##
## 子域索引（拆分后；两助手经 _ensure_helpers 在 _ready/setup 双入口幂等补线）：
##   取数语义（全 duck 系统查询/框选解析/号令波及/徽标聚合 + 单兵 static 探测）
##     → squad_card_data.gd（取数助手，_host 回引现读本文件状态）；
##   权威值择班表达 + 权威对比取数（AuthCompare 子树渲染/邻近班私有取数）
##     → squad_card_authority.gd（UI-W4a 对比块助手，setup(host, data) 注入）。
##   本文件保留：全部状态、全部语义常量、公共 API、引擎回调、相位计划接线
##   （_current_plan/_capture_plan）、区块渲染与核心操作。
## 区块渲染留宿主的论据：各 _refresh_* 与 20 个 @onready 节点引用及三组可变状态
## （_rows/_member_sig/_selected_unit）读写交织，属场景装配职责，拆出无边界收益。

# ─────────────────────────────── 常量 ────────────────────────────────
## 相位徽标（键 = SquadPhasePlan 相位英文名，get_phase_name 直译；未登记名回退原样显示）
const PHASE_BADGES: Dictionary = {
	"core_leap": "跃进中·核心组先行",
	"core_wait": "还击中·两翼待发",
	"flank_leap": "跃进中·两翼跟进",
	"flank_wait": "还击中·整队待发",
}

## 号令中文名（镜像 TacticalOrders.OrderType：ADVANCE_ALL0 SPRINT1 HOLD2 RETREAT3
## TAKE_COVER4 RALLY5——按战斗域本地常量惯例，不 preload 宿主脚本换枚举依赖）
const ORDER_NAMES: Dictionary = {
	0: "前进", 1: "冲刺", 2: "坚守", 3: "后撤", 4: "找掩体", 5: "集结",
}
## 玩家直令档位（order_issued.source_tier：0 = 玩家现场指挥；>0 = 经编制逐层接力）
const ORDER_TIER_PLAYER: int = 0

## 单兵状态效果类型（镜像 StatusEffects.Type：BURN0 POISON1 SLOW2 STUN3 HEAL4
## SUPPRESSED5——压制走 has_suppressed 方法口，此处只需持续回复与眩晕两项）
const EFFECT_STUN: int = 3
const EFFECT_HEAL: int = 4

## 组织状态（镜像 OrganizationState.State：FORMING0 ACTIVE1 EXECUTING2 RESTING3 DISBANDED4）
const ORG_STATE_FORMING: int = 0
const ORG_STATE_DISBANDED: int = 4

## 状态徽标文案（org state × 成员行为聚合；不可判定 = 空，不显示徽标）
const STATUS_FORMING := "组建中"
const STATUS_ACTIVE := "活跃"
const STATUS_CONTACT := "接战"
const STATUS_RETREAT := "撤退中"

## 单位职责中文（fighter/builder/worker——战斗面板同口径）
const ROLE_ZH: Dictionary = {"fighter": "战士", "builder": "建造工", "worker": "工人"}

## 成员行显示上限（超出压成一行计数，防面板被长花名册淹没——§1.3 稀疏纪律）
const ROW_MAX: int = 8
## 缓变值轮询间隔（s；相位/角色/号令/编制变动均信号驱动，此处只兜士气流）
const POLL_INTERVAL: float = 0.25
## 每颗威望星代表的权威值（get_squad_authority 量纲：班长 1.0 + 指挥官 0.5 + 玩家 0.2）
const AUTHORITY_PER_STAR: float = 0.5

## 邻近可投奔班半径（px）缺省回落值：真值优先消费 formation 只读参数出口
## get_authority_switch_state().candidate_radius（档案 ai.formation_authority.global），
## 出口/字段缺失（formation 未注入或旧版无该口）才回落此常量，UI 数值不与档案脱钩。
const CANDIDATE_RADIUS: float = 800.0
## 权威对比列出上限（本班 + 前 N 名邻近班；L1 稀疏纪律，不堆全表）
const CANDIDATE_ROW_MAX: int = 3

const MemberRowScene: PackedScene = preload("res://modules/combat/ui/squad_member_row.tscn")
## 取数助手（全 duck 系统查询 + 单兵 static 探测；无 class_name，const preload 引用）
const SquadCardData: GDScript = preload("res://modules/combat/ui/squad_card_data.gd")
## 权威对比块助手（UI-W4a 择班表达渲染 + 邻近班私有取数）
const SquadCardAuthority: GDScript = preload("res://modules/combat/ui/squad_card_authority.gd")

# ─────────────────────────────── 引用 ────────────────────────────────
var _game_root: Node = null
var _selection: Node = null
var _formation: Node = null
var _org_api: Node = null

# ─────────────────────────────── 状态 ────────────────────────────────
## 当前绑定的 L1 小队（= L1 组织 id；空 = 未绑定）
var _squad_id: String = ""
## 手动绑定标记（show_squad 显式指定）：置位时轮询不做框选重绑（否则显式入口当帧被抢），
## 但任何选择变化信号都清除它——玩家框选永远优先
var _manual_bind: bool = false
## 成员行（上限 ROW_MAX；重建只在成员集合变化时发生）
var _rows: Array = []
## 成员集合签名（instance_id 序列，用于判断是否需要重建行）
var _member_sig: String = ""
## 选中成员（任命班长/移出班组的作用对象；点行切换）
var _selected_unit: Node = null
## 最近一次号令（order_type，-1 = 未知）与其发令档位
var _last_order_type: int = -1
var _last_order_tier: int = -1
## 已接线的相位计划（RefCounted，宿主私有表取用；换绑/失效即重取）
var _plan: Variant = null
## 轮询累积器
var _poll_acc: float = 0.0
## 取数助手（squad_card_data.gd 实例；状态留本文件，助手经 _host 回引现读）
var _data_part: RefCounted = null
## 权威对比块助手（squad_card_authority.gd 实例；setup(host, data) 注入）
var _auth_part: RefCounted = null

# ─────────────────────────────── 节点引用 ────────────────────────────────
@onready var _name_label: Label = $Body/Header/SquadName
@onready var _status_chip: PanelContainer = $Body/Header/StatusChip
@onready var _status_label: Label = $Body/Header/StatusChip/Status
@onready var _order_label: Label = $Body/OrderRow/Order
@onready var _phase_label: Label = $Body/Phase
@onready var _members_box: VBoxContainer = $Body/Members
@onready var _overflow_label: Label = $Body/Overflow
@onready var _leader_label: Label = $Body/Commander/Leader
@onready var _stars_box: HBoxContainer = $Body/Commander/Stars
@onready var _authority_label: Label = $Body/Commander/Authority
@onready var _auth_compare: VBoxContainer = $Body/AuthCompare
@onready var _auth_title: Label = $Body/AuthCompare/AuthTitle
@onready var _auth_rows: VBoxContainer = $Body/AuthCompare/AuthRows
@onready var _defect_hint: PanelContainer = $Body/AuthCompare/DefectHint
@onready var _defect_label: Label = $Body/AuthCompare/DefectHint/DefectLabel
@onready var _forming_row: HBoxContainer = $Body/Forming
@onready var _forming_label: Label = $Body/Forming/FormingLabel
@onready var _forming_bar: ProgressBar = $Body/Forming/FormingBar
@onready var _actions_a: HBoxContainer = $Body/Actions/ActionsA
@onready var _actions_b: HBoxContainer = $Body/Actions/ActionsB

var _assign_btn: Button = null
var _remove_btn: Button = null
var _chain_btn: Button = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 子域助手幂等补线（_ready/setup 双入口调用）：_ready 先于 setup 时 EventBus 信号
## 可能早到触发取数路径，助手必须已就绪——原单文件实现经空选择降级天然安全，
## 拆分后由本函数保持等价鲁棒性（已就绪即跳过，重复调用零副作用）。
func _ensure_helpers() -> void:
	if _data_part == null:
		_data_part = SquadCardData.new()
		_data_part.setup(self)
	if _auth_part == null:
		_auth_part = SquadCardAuthority.new()
		_auth_part.setup(self, _data_part)


func _ready() -> void:
	_ensure_helpers()
	_apply_tokens()
	_build_actions()
	_connect_signals()
	hide_card()


## 装配注入（SystemSetup 挂槽后调用）：GameRoot 引用 + 各系统 duck 取用
func setup(game_root: Node) -> void:
	_ensure_helpers()
	_game_root = game_root
	_selection = game_root.get_selection_system() if game_root.has_method("get_selection_system") else null
	_formation = game_root.get_formation_system() if game_root.has_method("get_formation_system") else null
	_org_api = game_root.get_organization_api() if game_root.has_method("get_organization_api") else null
	_rebind_from_selection()


func _process(delta: float) -> void:
	# 收起状态零成本（F3/无选中时整帧跳过，team_ai_hud 同惯例）
	if not visible or _squad_id.is_empty():
		return
	_poll_acc += delta
	if _poll_acc < POLL_INTERVAL:
		return
	_poll_acc = 0.0
	# 框选权威：手动绑定（show_squad）时不做重绑兜底，选择变化信号自会解除手动态
	if not _manual_bind and _data_part._squad_from_selection() != _squad_id:
		_rebind_from_selection()  # 选择已变（信号丢失兜底）
		return
	if not _data_part._squad_exists():
		hide_card()               # 小队消亡（解散）
		return
	_refresh()


# ─────────────────────────────── 公共 API ────────────────────────────────

## 外部宿主直接指定班组（OrgPanel 选中 L1 组织等后续入口用；传入无效 id 即收起）。
## 手动绑定期间轮询不抢绑（选择变化信号会解除手动态）——本批唯一触发源是框选，
## 见交接遗留：OrgPanel 侧待其选中信号落地后一行接上。
func show_squad(squad_id: String) -> void:
	if squad_id.is_empty():
		hide_card()
		return
	_manual_bind = true
	_bind(squad_id)


## 收起班组卡（选择清空/小队消亡/切换模式）
func hide_card() -> void:
	_capture_plan(null)
	_squad_id = ""
	_manual_bind = false
	_selected_unit = null
	_member_sig = ""
	_last_order_type = -1
	_last_order_tier = -1
	if _auth_compare != null:
		_auth_compare.visible = false
	visible = false
	set_process(false)


## 是否正在显示某班组（测试/宿主查询）
func is_showing_squad() -> bool:
	return visible and not _squad_id.is_empty()


## 当前绑定的班组 id（测试查询）
func get_bound_squad() -> String:
	return _squad_id


# ─────────────────────────────── 绑定与信号 ────────────────────────────────

## 框选解析（_squad_from_selection）在 squad_card_data.gd，此处只做绑定分诊。
func _rebind_from_selection() -> void:
	var sid := _data_part._squad_from_selection()
	if sid.is_empty():
		hide_card()
		return
	_bind(sid)


## 绑定小队（换绑即复位号令与选中——号令是瞬时事件，换班后无存量可查）
func _bind(squad_id: String) -> void:
	if squad_id != _squad_id:
		_squad_id = squad_id
		_selected_unit = null
		_member_sig = ""
		_last_order_type = -1
		_last_order_tier = -1
	visible = true
	set_process(true)
	_refresh()


func _connect_signals() -> void:
	if EventBus != null:
		if EventBus.has_signal("selection_changed") and not EventBus.selection_changed.is_connected(_on_selection_changed):
			EventBus.selection_changed.connect(_on_selection_changed)
		if EventBus.has_signal("order_issued") and not EventBus.order_issued.is_connected(_on_order_issued):
			EventBus.order_issued.connect(_on_order_issued)
		if EventBus.has_signal("commander_assigned") and not EventBus.commander_assigned.is_connected(_on_commander_assigned):
			EventBus.commander_assigned.connect(_on_commander_assigned)
		if EventBus.has_signal("squad_created") and not EventBus.squad_created.is_connected(_on_squad_created):
			EventBus.squad_created.connect(_on_squad_created)
	if _formation != null:
		for sig in [&"squad_created", &"squad_disbanded"]:
			if _formation.has_signal(sig) and not _formation.is_connected(sig, _on_squad_changed):
				_formation.connect(sig, _on_squad_changed)


func _on_selection_changed(_unit_ids: Array) -> void:
	_manual_bind = false  # 玩家框选优先，解除手动绑定
	_rebind_from_selection()


func _on_order_issued(order_type: int, target_squad_id: String, source_tier: int) -> void:
	if _squad_id.is_empty() or not _data_part._order_reaches(target_squad_id):
		return
	_last_order_type = order_type
	_last_order_tier = source_tier
	_refresh()


func _on_commander_assigned(squad_id: String, _unit_id: int) -> void:
	if squad_id == _squad_id:
		_refresh()


func _on_squad_created(_a = null, _b = null) -> void:
	# 编制变动可能把选中单位纳编 → 重解析（当前无班则挂上，已有班则保持）
	if _data_part._squad_from_selection() != _squad_id:
		_rebind_from_selection()


func _on_squad_changed(_a = null, _b = null) -> void:
	_on_squad_created()


## 相位/角色信号（计划对象信号，换绑时重连）
func _on_plan_phase_changed(squad_id: String, _from: int, _to: int) -> void:
	if squad_id == _squad_id:
		_refresh()


func _on_plan_roles_reassigned(squad_id: String) -> void:
	if squad_id == _squad_id:
		_refresh()


## 号令波及判定（_order_reaches）在 squad_card_data.gd（号令语义取数的一部分）。


# ─────────────────────────────── 刷新 ────────────────────────────────

func _refresh() -> void:
	if _squad_id.is_empty():
		return
	var units := _data_part._alive_units()
	_refresh_header(units)
	_refresh_order()
	_refresh_phase()
	_refresh_members(units)
	_refresh_commander()
	_auth_part._refresh_authority_compare(units)
	_refresh_forming()
	_refresh_actions()


## 头部：班名 + 状态徽标（org state × 成员行为聚合；不可判定则不显示徽标）
func _refresh_header(units: Array) -> void:
	_name_label.text = _data_part._squad_name()
	var badge := _data_part._status_badge(units)
	_status_chip.visible = not badge.is_empty()
	if badge.is_empty():
		return
	_status_label.text = badge
	_status_chip.modulate = _status_color(badge)


## 状态徽标聚合（_status_badge）在 squad_card_data.gd；此处只做徽标配色映射。
func _status_color(badge: String) -> Color:
	match badge:
		STATUS_FORMING:
			return StickTokens.INFO
		STATUS_CONTACT:
			return StickTokens.WARN
		STATUS_RETREAT:
			return StickTokens.DANGER
		_:
			return StickTokens.SUCCESS


## 号令栏：最近一次波及本班的号令（EventBus.order_issued 驱动；未知显示弱化占位）
func _refresh_order() -> void:
	if _last_order_type < 0:
		_order_label.text = "号令 —"
		_order_label.modulate = StickTokens.TEXT_FAINT
		return
	var name_txt := String(ORDER_NAMES.get(_last_order_type, "?"))
	var src := "玩家" if _last_order_tier == ORDER_TIER_PLAYER else "编制"
	_order_label.text = "号令 %s（%s）" % [name_txt, src]
	_order_label.modulate = StickTokens.TEXT


## 相位徽标：A5 相位计划 active 时显示（英文名直译；未登记名回退原样）
func _refresh_phase() -> void:
	var plan: Variant = _current_plan()
	if plan == null or not plan.has_method("get_phase_name"):
		_phase_label.visible = false
		return
	if plan.has_method("is_active") and not bool(plan.is_active()):
		_phase_label.visible = false
		return
	var raw := str(plan.get_phase_name())
	if raw.is_empty() or raw == "idle" or raw == "unknown":
		_phase_label.visible = false
		return
	_phase_label.text = str(PHASE_BADGES.get(raw, raw))
	_phase_label.visible = true


## 成员行：集合未变只更新数值（保住选中/悬停态），变化才重建
func _refresh_members(units: Array) -> void:
	var sig := SquadCardData.signature(units)
	var shown: int = mini(units.size(), ROW_MAX)
	if sig != _member_sig or _rows.size() != shown:
		_rebuild_rows()
		_member_sig = sig
	var roles := _data_part._roles_of_plan()
	for i in shown:
		var u: Node = units[i]
		var role := str(roles.get(u.get_instance_id(), ""))
		if role.is_empty():
			role = _data_part._role_of(u)
		_rows[i].set_data(u, role, SquadCardData.morale_of(u), SquadCardData.state_flags(u))
		_rows[i].set_selected(_selected_unit != null and is_instance_valid(_selected_unit) and u == _selected_unit)
	_overflow_label.visible = units.size() > ROW_MAX
	if _overflow_label.visible:
		_overflow_label.text = "还有 %d 人未列出" % (units.size() - ROW_MAX)


## 成员行重建（成员集合变化时）：行数 = min(存活人数, ROW_MAX)。
## 先 remove_child 再 queue_free——被队列释放的旧行当帧仍在树上，不摘会与新行同帧并排。
func _rebuild_rows() -> void:
	for child in _members_box.get_children():
		_members_box.remove_child(child)
		child.queue_free()
	_rows.clear()
	var units := _data_part._alive_units()
	var shown: int = mini(units.size(), ROW_MAX)
	for i in shown:
		var row: Node = MemberRowScene.instantiate()
		_members_box.add_child(row)
		row.pressed.connect(_on_member_pressed.bind(row))
		_rows.append(row)
	# 空班明确空态（FORMING 招兵中 / 全员阵亡两种语义分开，不塌成空白）
	if shown == 0:
		var hint := Label.new()
		hint.text = "尚未编入成员（招兵中）" if _data_part._org_state() == ORG_STATE_FORMING else "无存活成员"
		hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hint.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
		hint.modulate = StickTokens.TEXT_FAINT
		_members_box.add_child(hint)


## 班长栏：指挥官 + 权威值（星级 + 数值；查询不可用则隐藏星级段）
func _refresh_commander() -> void:
	var leader: Node = null
	if _formation != null and _formation.has_method("get_squad_leader"):
		leader = _formation.get_squad_leader(_squad_id)
	if leader != null and is_instance_valid(leader) and not SquadCardData.is_dead(leader):
		_leader_label.text = "班长 %s" % SquadCardData.role_zh(leader)
		_leader_label.modulate = StickTokens.TEXT
	else:
		_leader_label.text = "班长空缺"
		_leader_label.modulate = StickTokens.WARN
	var authority := _data_part._authority()
	if is_nan(authority):
		_authority_label.text = ""
		_stars_box.visible = false
		return
	_authority_label.text = "威望 %.1f" % authority
	var level := clampi(int(round(authority / AUTHORITY_PER_STAR)), 0, _stars_box.get_child_count())
	for i in _stars_box.get_child_count():
		var star: TextureRect = _stars_box.get_child(i)
		star.modulate = StickTokens.ACCENT if i < level else StickTokens.TEXT_DISABLED
	_stars_box.visible = level > 0


## 权威值择班表达（UI-W4a §3.3①：_refresh_authority_compare/_scored_neighbors/
## _refresh_defect_hint/_switch_intent_count/_candidate_squads/_add_auth_row/_clear_rows）
## 与权威对比取数（_authority_of/_leader_of/_is_live_leader/_name_of/_parent_org/_tier_of）
## 下沉 squad_card_authority.gd；_candidate_radius 因测试契约留委托壳（文末）。


## FORMING 招兵进度位：真组建态（在册 FORMING 且尚未编入成员）时占位；
## 已编成班组不占这一行（进度值待兵营招兵接线后填入）。
func _refresh_forming() -> void:
	if _data_part._org_state() != ORG_STATE_FORMING or not _data_part._alive_units().is_empty():
		_forming_row.visible = false
		return
	_forming_row.visible = true
	_forming_label.text = "招兵进度 待兵营接线"
	_forming_bar.value = 0.0
	_forming_bar.modulate.a = 0.4


func _refresh_actions() -> void:
	var has_sel: bool = _selected_unit != null and is_instance_valid(_selected_unit)
	var is_leader := false
	if has_sel and _formation != null and _formation.has_method("get_squad_leader"):
		is_leader = (_formation.get_squad_leader(_squad_id) == _selected_unit)
	if _assign_btn != null:
		_assign_btn.disabled = not has_sel or is_leader or not _can_assign()
	if _remove_btn != null:
		_remove_btn.disabled = not has_sel \
				or _formation == null or not _formation.has_method("remove_unit")


func _can_assign() -> bool:
	if _formation != null and _formation.has_method("assign_leader"):
		return true
	return _org_api != null and _org_api.has_method("assign_commander")


# ─────────────────────────────── 核心操作 ────────────────────────────────

## 点成员行：切换选中（唯一选中，琥珀高亮 = 操作作用对象）
func _on_member_pressed(row: Node) -> void:
	if row == null or not is_instance_valid(row):
		return
	var u: Node = row.get("unit")
	if u == null or not is_instance_valid(u):
		return
	_selected_unit = null if _selected_unit == u else u
	_refresh()


## 任命班长（既有 assign_leader：组织侧 assign_commander + 本地班长跟踪 + 信号）
func _on_assign_pressed() -> void:
	if _selected_unit == null or not is_instance_valid(_selected_unit):
		return
	var ok := false
	if _formation != null and _formation.has_method("assign_leader"):
		ok = bool(_formation.assign_leader(_squad_id, _selected_unit))
	elif _org_api != null and _org_api.has_method("assign_commander"):
		var r: Dictionary = _org_api.assign_commander(_squad_id, str(_selected_unit.get_instance_id()))
		ok = bool(r.get("ok", false))
	if ok:
		_notify("已任命班长：%s" % SquadCardData.role_zh(_selected_unit))
	_refresh()


## 移出班组（既有 remove_unit：含组织侧 remove_stickman 与槽位重算）
func _on_remove_pressed() -> void:
	if _selected_unit == null or not is_instance_valid(_selected_unit):
		return
	if _formation == null or not _formation.has_method("remove_unit"):
		return
	_notify("已移出班组：%s" % SquadCardData.role_zh(_selected_unit))
	_formation.remove_unit(_selected_unit)
	_selected_unit = null
	_member_sig = ""
	_refresh()


# ─────────────────────── 相位计划接线 ────────────────────────

## 相位计划对象（宿主私有表 duck：debug_info_panel.gd 已立先例；取到即接信号）
func _current_plan() -> Variant:
	if _formation == null or not "_squad_phase_plans" in _formation:
		return null
	var plans: Variant = _formation.get("_squad_phase_plans")
	if not (plans is Dictionary):
		return null
	var plan: Variant = (plans as Dictionary).get(_squad_id)
	if plan == null or not is_instance_valid(plan) or not plan.has_method("get_phase_name"):
		return null
	_capture_plan(plan)
	return plan


## 计划信号接线（换绑即断旧连新；相位/角色变更 = 信号驱动刷新，不轮询）
func _capture_plan(plan: Variant) -> void:
	if _plan == plan:
		return
	if _plan != null and is_instance_valid(_plan):
		if _plan.has_signal("phase_changed") and _plan.phase_changed.is_connected(_on_plan_phase_changed):
			_plan.phase_changed.disconnect(_on_plan_phase_changed)
		if _plan.has_signal("roles_reassigned") and _plan.roles_reassigned.is_connected(_on_plan_roles_reassigned):
			_plan.roles_reassigned.disconnect(_on_plan_roles_reassigned)
	_plan = plan
	if _plan == null or not is_instance_valid(_plan):
		_plan = null
		return
	if _plan.has_signal("phase_changed") and not _plan.phase_changed.is_connected(_on_plan_phase_changed):
		_plan.phase_changed.connect(_on_plan_phase_changed)
	if _plan.has_signal("roles_reassigned") and not _plan.roles_reassigned.is_connected(_on_plan_roles_reassigned):
		_plan.roles_reassigned.connect(_on_plan_roles_reassigned)


# ─────────────────────────────── 装配 ────────────────────────────────

## token 样式一次应用（字号/颜色只从 StickTokens 取，场景不写死视觉值）
func _apply_tokens() -> void:
	_name_label.add_theme_font_size_override("font_size", StickTokens.FONT_HUD)
	_status_label.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_order_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_phase_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_phase_label.modulate = StickTokens.ACCENT
	_leader_label.add_theme_font_size_override("font_size", StickTokens.FONT_HINT)
	_authority_label.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_auth_title.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_auth_title.modulate = StickTokens.TEXT_FAINT
	_defect_label.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_defect_label.modulate = StickTokens.WARN
	_overflow_label.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_overflow_label.modulate = StickTokens.TEXT_FAINT
	_forming_label.add_theme_font_size_override("font_size", StickTokens.FONT_TINY)
	_forming_label.modulate = StickTokens.TEXT_FAINT
	# 成员行容器：鼠标事件下透（行按钮自己收）——避免空白区吃掉世界框选
	_members_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overflow_label.mouse_filter = Control.MOUSE_FILTER_IGNORE


## 操作按钮（StickKit 装配：统一点击音 + hover 微缩放；场景只声明容器骨架）
func _build_actions() -> void:
	_assign_btn = StickKit.sketch_button(_actions_a, "任命班长", _on_assign_pressed,
			StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	_assign_btn.tooltip_text = "把选中成员任命为本班班长（组织侧同步任命指挥官）"
	_remove_btn = StickKit.sketch_button(_actions_a, "移出班组", _on_remove_pressed,
			StickKit.ButtonKind.DANGER, StickTokens.BTN_H_SM)
	_remove_btn.tooltip_text = "把选中成员移出本班（本人存活，仍在场上）"
	_chain_btn = StickKit.sketch_button(_actions_b, "放大到指挥链视图",
			Callable(), StickKit.ButtonKind.NORMAL, StickTokens.BTN_H_SM)
	_chain_btn.disabled = true
	_chain_btn.tooltip_text = "指挥链视图（W3 批次）——本批只留入口"


func _notify(msg: String) -> void:
	if EventBus != null and EventBus.has_signal("ui_notification"):
		EventBus.ui_notification.emit("班组", msg, "info")


# ─────────────────────── 测试契约委托壳 ────────────────────────

## 邻近可投奔班半径（px）：实现在 SquadCardAuthority._candidate_radius（duck 消费
## formation 只读参数出口 get_authority_switch_state().candidate_radius，缺则回落
## CANDIDATE_RADIUS）。测试契约：test_squad_card.gd 以 has_method/call 直呼宿主
## _candidate_radius，故保留委托壳转发（先幂等补线保助手就绪，行为与拆分前一致）。
func _candidate_radius() -> float:
	_ensure_helpers()
	return _auth_part._candidate_radius()
