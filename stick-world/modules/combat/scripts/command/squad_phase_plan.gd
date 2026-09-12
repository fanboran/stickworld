class_name SquadPhasePlan
extends RefCounted
## 小队相位计划 v1（A5 · 设计文档12号 C8，CoH squadai 相位计划简化直译、原创代码）。
##
## CoH 逆向锚点（docs/审计/英雄连AI逆向_2026-09-11.md §4.2 infantry-plan）：
##   交替掩护跃进 = Core 先跃进找掩体 → 全队还击等 2~4s → 两翼跟进（再等 2~3.5s）
##   → 循环；ACTION_WAIT_RANDOM 随机等待 = 去同步化。
## 简化（本批 v1 范围）：不做真实掩护几何（cover_system 掩体搜索留给 seek_cover
## 行为自身），核心组/两翼按批次轮流跃进到推进线即可；接敌反应把被压制/背敌成员
## 交给既有 seek_cover 行为（不新造掩体机制）。
##
## 角色分派 = 位置 × 素质双维（设计文档12号 咬合②）：
##   - 位置维：11b 编队槽位 slot.x（列序，小者靠前）——Core 取前列成员（前列优先）；
##     槽位基建复用 FormationSystem._assign_formation_slots 产物（零新增几何）。
##   - 素质维：get_unit_quality 代理（max_hp 简单代理【提案/待定】）——Scout 取
##     素质最高者（CoH ET_Scout = 蓝图 loadout 决定，本作改为素质选拔）。
##   - 双翼：余员按小队锚朝向的横向位置分左右（ET_RFlank / ET_LFlank 等价）。
##
## 相位机（PH_*）：CORE_LEAP（核心+Scout 跃进）→ CORE_WAIT（全队还击随机等待，
## 去同步）→ FLANK_LEAP（双翼跟进）→ FLANK_WAIT（随机等待）→ 推进跃进线进入下
## 一循环，直至跃进线抵达终点（末跳全员到位后计划完成转自主决策）。
##
## 架构对账（设计原则）：
##   - 原则④ 决策有节拍：本类无自转，tick 由宿主 FormationSystem 按
##     phase_tick_interval（L2 节拍 0.5s，与 SQUAD_DECISION_INTERVAL 同量级）驱动；
##   - 原则⑦ 一切数值进档案：全部参数经 setup 注入（默认值 DEFAULTS ←
##     BalanceConfig ai.squad_phase_plan.global 覆盖，config/ai/squad_phase_plan.tres）；
##   - 缺省关闭（phase_plan_enabled=false）= 零回归基线（A5 验收门）；
##     触发点 = 小队号令（TacticalOrders 下发 ADVANCE/SPRINT 时经
##     FormationSystem.notify_squad_order 激活，其余号令撤销）——最小侵入接法。
##   - 号令标记 phase_order=true：与跟队 follow_order 同构——只覆盖/回收自己的
##     号令，玩家与上级号令一律不打断。
##
## 用法（formation_system.gd 宿主）：
##   var plan := SquadPhasePlan.new()
##   plan.setup(self, _phase_plan_params)
##   plan.activate(squad_id, target)
##   plan.tick(delta)  # 宿主按节拍调用

# ─────────────────────────────── 常量 ────────────────────────────────
## 成员角色（CoH squadai ET_* 四类对位；本作分派规则见类头【提案/待定】）
const ROLE_CORE: String = "core"        ## 核心组：前列成员，第一波跃进
const ROLE_SCOUT: String = "scout"      ## 侦察：素质最高者，随核心组前出
const ROLE_RFLANK: String = "flank_r"   ## 右翼：锚朝向横向正侧（第二波）
const ROLE_LFLANK: String = "flank_l"   ## 左翼：锚朝向横向负侧（第二波）

## 相位枚举（infantry-plan 相位序直译；IDLE = 未激活）
const PH_IDLE: int = 0
const PH_CORE_LEAP: int = 1   ## 核心组+Scout 跃进中
const PH_CORE_WAIT: int = 2   ## 全队还击等待（随机去同步）
const PH_FLANK_LEAP: int = 3  ## 双翼跟进中
const PH_FLANK_WAIT: int = 4  ## 跟进后等待（随机去同步）

## 相位名（调试/测试断言）
const PHASE_NAMES: Dictionary = {
	PH_IDLE: "idle",
	PH_CORE_LEAP: "core_leap",
	PH_CORE_WAIT: "core_wait",
	PH_FLANK_LEAP: "flank_leap",
	PH_FLANK_WAIT: "flank_wait",
}

## 默认参数档案（原则⑦：配置真值镜像在 config/ai/squad_phase_plan.tres，
## 全部语义映射初值待实测校准；CoH 真值项已注明）
const DEFAULTS: Dictionary = {
	"phase_plan_enabled": false,  ## 缺省关闭 = 零回归基线（A5 验收门）
	"phase_tick_interval": 0.5,   ## L2 计划节拍（s；收敛红线：每层一个基础节拍）
	"role_core_ratio": 0.4,       ## 核心组比例（×小队人数，前列优先；CoH loadout 无真值，语义映射初值）
	"leap_step_ratio": 0.35,      ## 每轮跃进距离占剩余路程比例（CoH 70% 为成员间距语义，此处进度语义映射）
	"leap_min_dist": 120.0,       ## 单轮跃进最小距离（px）
	"leap_max_dist": 420.0,       ## 单轮跃进最大距离（px）
	"leap_timeout": 6.0,          ## 单相位移动超时（s；成员受阻也推进相位，防卡死）
	"arrive_tolerance": 48.0,     ## 到位死区（px；量级对齐 FormationSystem.FOLLOW_DEADZONE）
	"wait_core_min": 2.0,         ## 核心跃进后全队还击等待下限（s，CoH infantry-plan 2~4s 真值）
	"wait_core_max": 4.0,         ## 核心跃进后全队还击等待上限（s，CoH 真值）
	"wait_flank_min": 2.0,        ## 双翼跟进后等待下限（s，CoH infantry-plan 2~3.5s 真值）
	"wait_flank_max": 3.5,        ## 双翼跟进后等待上限（s，CoH 真值）
	"threat_window": 3.0,         ## 箭矢瞄准反应窗口（s；arrow_threat_time 登记新鲜度。A6 后分工：达真实压制门槛的成员由 _unit_suppressed 守卫跳过（禁令本体已锁死），本窗口保留为未压制成员的轻量找掩体反应）
	"back_enemy_radius": 260.0,   ## 背敌判定半径（px）
	"back_enemy_dot": -0.25,      ## 背敌半平面阈值（敌方向与推进方向点积小于此值 = 背后）
	"rng_seed": -1,               ## 随机源种子；-1 = randomize（生产去同步），测试传固定种子保确定
}

# ─────────────────────────────── 状态 ────────────────────────────────
## 宿主 FormationSystem（duck 引用：槽位/锚点/落点/接战判定/素质代理/号令通道）
var _host: Node = null
## 参数档案（DEFAULTS ← 覆盖注入；原则⑦）
var _p: Dictionary = {}
## 随机源（等待去同步掷骰；默认固定种子可测，生产 randomize）
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _squad_id: String = ""          ## 所属小队
var _final_target: Vector2 = Vector2.ZERO  ## 推进终点（号令目标点）
var _leap_line: Vector2 = Vector2.ZERO     ## 当前跃进线（本轮波次落点基准）
var _advance_dir: Vector2 = Vector2.RIGHT  ## 推进方向（终点 - 小队质心，退化 +x）
var _phase: int = PH_IDLE           ## 当前相位
var _phase_timer: float = 0.0       ## 当前相位已耗时（s）
var _wait_duration: float = 0.0     ## 当前等待相位总时长（进入等待时掷骰定局）
var _roles: Dictionary = {}         ## 成员角色：unit.get_instance_id() -> ROLE_*（每循环重排自愈掉员）
var _active: bool = false           ## 计划是否激活


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 装配：注入宿主与参数档案（覆盖键只认 DEFAULTS 已有键，未知键忽略防错字）。
func setup(host: Node, params: Dictionary = {}) -> void:
	_host = host
	_p = DEFAULTS.duplicate(true)
	for k in params.keys():
		if _p.has(k):
			_p[k] = params[k]
	var seed_v: int = int(_p.get("rng_seed", -1))
	if seed_v < 0:
		_rng.randomize()
	else:
		_rng.seed = seed_v


## 激活计划（小队收到推进类号令时由宿主调用；重复调用 = 重定目标并复位相位，
## 任务槽重定向/玩家改令均自然刷新）。
func activate(squad_id: String, target: Vector2) -> void:
	_squad_id = squad_id
	_final_target = target
	_active = true
	_enter(PH_CORE_LEAP)


## 停用计划（收到非推进号令/计划完成/小队解散）。只停相位机，不回收已下发的
## 成员号令——成员 move 自行到位后转自主决策，与 ADVANCE_ALL 既有语义一致。
func deactivate() -> void:
	_active = false
	_phase = PH_IDLE
	_roles.clear()
	_phase_timer = 0.0


# ─────────────────────────────── 查询（测试/调试）────────────────────────────────

func is_active() -> bool:
	return _active


func get_phase() -> int:
	return _phase


func get_phase_name() -> String:
	return str(PHASE_NAMES.get(_phase, "unknown"))


func get_roles() -> Dictionary:
	return _roles.duplicate()


func get_role_of(unit: Node) -> String:
	if unit == null or not is_instance_valid(unit):
		return ""
	return str(_roles.get(unit.get_instance_id(), ""))


func get_leap_line() -> Vector2:
	return _leap_line


func get_final_target() -> Vector2:
	return _final_target


# ─────────────────────────────── 角色分派（位置 × 素质双维）────────────────────────────────

## 成员角色分派（纯函数，测试直调）：
##   units    存活成员数组（Node2D，global_position 有效）
##   slots    11b 编队槽位：iid -> Vector2i(col, row)（FormationSystem.get_squad_slots）
##   anchor   小队锚 {"centroid": Vector2, "facing": Vector2}（FormationSystem.get_squad_anchor）
##   quality_of  素质回调：unit -> float（FormationSystem.get_unit_quality；无效回退 1.0）
## 规则【提案/待定】：
##   1) Core = core_ratio × 人数（clamp 1..n），按 字典序（slot.x 升序 → 素质降序
##      → 入队序）取前列——位置维优先，素质只作同列 tie-break；
##   2) Scout = 余员中素质最高（并列取 slot.x 小者再取入队序）——素质维优先；
##   3) 双翼 = 其余成员按锚朝向横向位置分侧（横向点积 ≥0 右翼 / <0 左翼）。
## 返回 iid -> ROLE_*。空队返回空字典。
func assign_roles(units: Array, slots: Dictionary, anchor: Dictionary, quality_of: Callable) -> Dictionary:
	var roles: Dictionary = {}
	var n: int = units.size()
	if n == 0:
		return roles
	var facing: Vector2 = anchor.get("facing", Vector2.RIGHT)
	var perp := Vector2(-facing.y, facing.x)
	var centroid: Vector2 = anchor.get("centroid", Vector2.ZERO)
	var core_count: int = clampi(roundi(float(n) * float(_p.get("role_core_ratio", 0.4))), 1, n)
	# 评分项打包（一次取数；slot 缺失 = 极后列，素质/入队序兜底）
	var scored: Array = []
	for i in n:
		var u: Node = units[i]
		var slot: Vector2i = slots.get(u.get_instance_id(), Vector2i(1 << 20, 0))
		var q: float = 1.0
		if quality_of.is_valid():
			q = float(quality_of.call(u))
		var lat: float = 0.0
		if u is Node2D:
			lat = (u as Node2D).global_position.dot(perp) - centroid.dot(perp)
		scored.append({"u": u, "idx": i, "slot_x": int(slot.x), "q": q, "lat": lat})
	# 1) Core：前列优先（slot.x 升序），同列素质降序，再入队序——位置维主导
	var core_sorted: Array = scored.duplicate()
	core_sorted.sort_custom(func(a, b) -> bool:
		if int(a.slot_x) != int(b.slot_x):
			return int(a.slot_x) < int(b.slot_x)
		if float(a.q) != float(b.q):
			return float(a.q) > float(b.q)
		return int(a.idx) < int(b.idx))
	for i in mini(core_count, core_sorted.size()):
		roles[core_sorted[i].u.get_instance_id()] = ROLE_CORE
	# 2) Scout：余员素质最高（并列 slot.x 小者优先，再入队序）——素质维主导
	var rest: Array = core_sorted.slice(core_count)
	rest.sort_custom(func(a, b) -> bool:
		if float(a.q) != float(b.q):
			return float(a.q) > float(b.q)
		if int(a.slot_x) != int(b.slot_x):
			return int(a.slot_x) < int(b.slot_x)
		return int(a.idx) < int(b.idx))
	if not rest.is_empty():
		roles[rest[0].u.get_instance_id()] = ROLE_SCOUT
	# 3) 双翼：余员按横向位置分侧
	for i in range(1, rest.size()):
		var e: Dictionary = rest[i]
		roles[e.u.get_instance_id()] = ROLE_RFLANK if float(e.lat) >= 0.0 else ROLE_LFLANK
	return roles


# ─────────────────────────────── 相位机（宿主节拍驱动）────────────────────────────────

## 计划节拍推进（宿主按 phase_tick_interval 调用；原则④ 决策有节拍，无自转）。
## 每拍：先接敌反应（被压制/背敌 → seek_cover），再推进当前相位。
func tick(delta: float) -> void:
	if not _active:
		return
	var units := _alive_members()
	if units.is_empty():
		deactivate()
		return
	_contact_reaction(units)
	_phase_timer += delta
	match _phase:
		PH_CORE_LEAP:
			_tick_leap(units, true)
		PH_CORE_WAIT:
			if _phase_timer >= _wait_duration:
				_enter(PH_FLANK_LEAP)
		PH_FLANK_LEAP:
			_tick_leap(units, false)
		PH_FLANK_WAIT:
			if _phase_timer >= _wait_duration:
				_enter(PH_CORE_LEAP)  # 新循环：重排角色 + 推进跃进线
		_:
			pass


## 相位进入（统一出口：计时复位 + 相位级一次性工作）。
func _enter(phase: int) -> void:
	_phase = phase
	_phase_timer = 0.0
	match phase:
		PH_CORE_LEAP:
			_reassign_roles()   # 掉员自愈：每个推进循环按存活成员重排角色
			_advance_leap_line()
		PH_CORE_WAIT:
			_roll_wait(true)
		PH_FLANK_WAIT:
			_roll_wait(false)
		_:
			pass


## 单波次跃进推进（core_wave=true 核心+Scout / false 双翼）：
##   - 波次成员逐一取 11b 槽位落点（get_squad_dest mode="formation"，复用槽位基建）；
##   - 守卫成员（士气行为/接战/他人号令）本拍不打断；同目标号令不重发（防重入）；
##   - 全员到位（或移动超时）→ 进入等待相位；末跳（跃进线即终点）完成 → 计划完成。
func _tick_leap(units: Array, core_wave: bool) -> void:
	var wave_roles: Array = [ROLE_CORE, ROLE_SCOUT] if core_wave else [ROLE_RFLANK, ROLE_LFLANK]
	var tolerance: float = float(_p.get("arrive_tolerance", 48.0))
	var all_set: bool = true
	for u in units:
		var role := get_role_of(u)
		if not (role in wave_roles):
			continue
		var dest: Vector2 = _host.get_squad_dest(_squad_id, u, _leap_line, "formation")
		if u.global_position.distance_to(dest) <= tolerance:
			continue  # 已到位
		all_set = false
		if _member_guarded(u):
			continue  # 接战/士气行为/玩家号令：本拍不打断（超时兜底推进相位）
		if _ordered_to(u, dest):
			continue  # 号令在途且目标未变，防重入重播
		_issue_move(u, dest)
	# 相位推进：全员到位 或 超时（成员受阻不无限拖相位）
	if all_set or _phase_timer >= float(_p.get("leap_timeout", 6.0)):
		if core_wave:
			_enter(PH_CORE_WAIT)
		elif _leap_line_at_final():
			deactivate()  # 末跳到位：计划完成，成员转自主决策
		else:
			_enter(PH_FLANK_WAIT)


# ─────────────────────────────── 接敌反应（reaction-plan 等价面）────────────────────────────────

## 被压制/背敌成员 → 找掩体（既有 seek_cover 行为，不新造掩体机制）：
##   - 真实压制态（A6 · C9 落地替换 A5 代理）：达压制门槛的成员已在 L1 被
##     StatusEffects.SUPPRESSED 禁令锁死（压制蹲伏/停滞 = pinned-reaction 本体），
##     本反应跳过、不叠加 seek_cover 号令——禁令期号令会被 ai_controller 挂起；
##   - 轻量反应（既有代理保留）：arrow_threat_time 窗口内被瞄准登记（真实战况
##     信号，消费未达压制门槛的瞄射/擦伤成员）；
##   - 背敌：推进方向反半平面 back_enemy_radius 内有存活敌人（reaction-plan
##     DT_AWAY_FROM_TARGET 语义映射）。
## 守卫成员（士气行为/接战中/他人号令）不介入——接战成员交还战斗行为。
func _contact_reaction(units: Array) -> void:
	var now_real: float = Time.get_ticks_msec() / 1000.0
	var window: float = float(_p.get("threat_window", 3.0))
	var radius: float = float(_p.get("back_enemy_radius", 260.0))
	var back_dot: float = float(_p.get("back_enemy_dot", -0.25))
	var dir := _advance_dir
	for u in units:
		if _member_guarded(u):
			continue
		if _unit_suppressed(u):
			continue  # 真实压制态：禁令已在 L1 锁死（A6 替换 A5 被压制代理）
		var ai: Node = _ai_of(u)
		if ai == null or not ai.has_method("set_order"):
			continue
		var triggered := false
		if "arrow_threat_time" in u and now_real - float(u.get("arrow_threat_time")) < window:
			triggered = true
		if not triggered and u is Node2D:
			for e in _enemies_of(u):
				if e == null or not is_instance_valid(e):
					continue
				if e.has_method("is_dead") and e.is_dead():
					continue
				var to_e: Vector2 = (e as Node2D).global_position - (u as Node2D).global_position
				if to_e.length() > radius:
					continue
				if to_e.normalized().dot(dir) < back_dot:
					triggered = true
					break
		if triggered:
			ai.set_order("seek_cover", {"phase_order": true})


# ─────────────────────────────── 内部 ────────────────────────────────

## 存活成员列表（宿主取数 + 有效性过滤；不持跨拍缓存防 freed 悬挂）。
func _alive_members() -> Array:
	var result: Array = []
	if _host == null or not is_instance_valid(_host) or not _host.has_method("get_squad_units"):
		return result
	for u in _host.get_squad_units(_squad_id):
		if u == null or not is_instance_valid(u):
			continue
		if u.has_method("is_dead") and u.is_dead():
			continue
		result.append(u)
	return result


## 角色重排（掉员自愈入口，每推进循环一次）。
func _reassign_roles() -> void:
	var slots: Dictionary = {}
	var anchor: Dictionary = {"centroid": Vector2.ZERO, "facing": Vector2.RIGHT}
	if _host != null and is_instance_valid(_host):
		if _host.has_method("get_squad_slots"):
			slots = _host.get_squad_slots(_squad_id)
		if _host.has_method("get_squad_anchor"):
			anchor = _host.get_squad_anchor(_squad_id)
	_roles = assign_roles(_alive_members(), slots, anchor, Callable(self, "_quality_of"))


## 素质回调桥（assign_roles → 宿主素质代理；宿主缺失回退 1.0 平权）。
func _quality_of(u: Node) -> float:
	if _host != null and is_instance_valid(_host) and _host.has_method("get_unit_quality"):
		return float(_host.get_unit_quality(u))
	return 1.0


## 推进跃进线：步长 = clamp(剩余路程 × leap_step_ratio, min, max)；
## 剩余路程不足一步 → 跃进线直接钉在终点（末跳）。
func _advance_leap_line() -> void:
	var centroid := Vector2.ZERO
	var n: int = 0
	for u in _alive_members():
		centroid += (u as Node2D).global_position
		n += 1
	if n > 0:
		centroid /= float(n)
	var to_target := _final_target - centroid
	var remaining := to_target.length()
	_advance_dir = to_target.normalized() if remaining > 1.0 else Vector2.RIGHT
	var step: float = clampf(remaining * float(_p.get("leap_step_ratio", 0.35)),
			float(_p.get("leap_min_dist", 120.0)), float(_p.get("leap_max_dist", 420.0)))
	if remaining <= step + float(_p.get("arrive_tolerance", 48.0)):
		_leap_line = _final_target
	else:
		_leap_line = centroid + _advance_dir * step


## 跃进线是否已抵达终点（末跳判定）。
func _leap_line_at_final() -> bool:
	return _leap_line.distance_to(_final_target) <= 1.0


## 等待时长掷骰（ACTION_WAIT_RANDOM 去同步；进入等待相位时一次定局）。
func _roll_wait(core_wait: bool) -> void:
	var lo: float = float(_p.get("wait_core_min", 2.0)) if core_wait else float(_p.get("wait_flank_min", 2.0))
	var hi: float = float(_p.get("wait_core_max", 4.0)) if core_wait else float(_p.get("wait_flank_max", 3.5))
	_wait_duration = _rng.randf_range(minf(lo, hi), maxf(lo, hi))


## 成员是否处于真实压制态（A6 · C9 替换点落地：duck 查询 StatusEffects.SUPPRESSED；
## 组件缺失/压制未启用返回 false = 既有轻量代理语义原样，零回归）。
func _unit_suppressed(u: Node) -> bool:
	if u == null or not is_instance_valid(u) or not u.has_method("get_status_effects"):
		return false
	var se: Node = u.get_status_effects()
	if se == null or not is_instance_valid(se) or not se.has_method("has_suppressed"):
		return false
	return bool(se.has_suppressed())


## 成员 AI 控制器（duck；缺失返回 null）。
func _ai_of(u: Node) -> Node:
	if u == null or not is_instance_valid(u) or not u.has_method("get_ai_controller"):
		return null
	var ai: Node = u.get_ai_controller()
	if ai == null or not is_instance_valid(ai):
		return null
	return ai


## 成员是否处于"本拍不打断"守卫（与编队跟队 tick 同口径）：
##   士气驱动行为（retreat/seek_cover）/ 射程内接战（交还战斗行为）/ 玩家与上级号令。
func _member_guarded(u: Node) -> bool:
	var ai: Node = _ai_of(u)
	if ai == null:
		return true
	if ai.has_method("get_current_behavior") \
			and ai.get_current_behavior() in ["retreat", "seek_cover"]:
		return true
	if _host != null and is_instance_valid(_host) \
			and _host.has_method("_member_enemy_in_range") and _host._member_enemy_in_range(u):
		return true
	if ai.has_method("has_order") and ai.has_order():
		var params: Dictionary = {}
		if ai.has_method("get_ordered_params"):
			params = ai.get_ordered_params()
		if not bool(params.get("phase_order", false)):
			return true  # 非本计划号令（玩家/上级/跟队）一律不覆盖
	return false


## 成员是否已有同目标在途号令（防重入：不重复 travel 重播移动）。
func _ordered_to(u: Node, dest: Vector2) -> bool:
	var ai: Node = _ai_of(u)
	if ai == null or not ai.has_method("get_ordered_behavior"):
		return false
	if ai.get_ordered_behavior() != "move":
		return false
	var params: Dictionary = {}
	if ai.has_method("get_ordered_params"):
		params = ai.get_ordered_params()
	return params.get("target", Vector2.INF).distance_to(dest) <= float(_p.get("arrive_tolerance", 48.0))


## 波次跃进号令下发（engage_in_range：途中敌进射程即停下接战，与 ADVANCE_ALL 同语义）。
func _issue_move(u: Node, dest: Vector2) -> void:
	var ai: Node = _ai_of(u)
	if ai == null or not ai.has_method("set_order"):
		return
	ai.set_order("move", {
		"target": dest,
		"engage_in_range": true,
		"phase_order": true,  # 本计划号令标记（重入判定/守卫判定）
	})


## 成员所在战斗实例的敌方列表（duck；不可用返回空）。
func _enemies_of(u: Node) -> Array:
	if not u.has_method("get_battle_instance") or not u.has_method("get_faction"):
		return []
	var bi: Node = u.get_battle_instance()
	if bi == null or not is_instance_valid(bi) or not bi.has_method("get_enemies_of"):
		return []
	var faction: int = int(u.get_faction())
	if faction == 0:
		return []
	return bi.get_enemies_of(faction)
