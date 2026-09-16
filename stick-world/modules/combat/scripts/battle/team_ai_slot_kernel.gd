extends RefCounted
## 任务槽内核 -- team_ai.gd 拆分件（W2 胖文件拆分，行为直搬；A2 · C3/C4/C5）。
##
## 职责：CoH 槽内核的全部决策消费面——
##   - C5 攻击百分比四规则评分（recalculate_attack_pct，含胜利目标规则钩子）；
##   - 基地威胁值（threat_at_base，规则二取数）；
##   - 攻击槽创建/维持门禁与 GARRISON 重评条件（咬合③：两内核共享同一优先序）；
##   - 槽同步生命周期（update_task_board：超时杀槽/重评分 → 攻防槽同步 → 脏槽重定向）；
##   - 攻击槽目标定位（C4 四因子 argmax，经 TaskBoard.pick_target）。
##
## 拆分纪律：本类持宿主回引（_host）；任务槽板实例（_task_board）、观测缓存
## （_cached_attack_pct）、快照与姿态状态全在宿主——本类只计算与同步，决策编排
## （何时调本类）留宿主 stance_update。公共查询经宿主壳转发
## （recalculate_attack_percentage / threat_at_base，测试直调面）。
##
## 消费方：TeamAi 姿态编排（宿主壳转发）。依赖同伴：team_ai_squad_query
## （原子单元数/分组取数）、team_ai_order_emitter（脏槽重定向重发）——装配序
## query/emitter 先于本类，依赖无环（emitter/hooks 不回依本类）。

## 同模块任务槽板（显式 preload，headless 防御惯例 §七.3；KIND_ATTACK/KIND_DEFEND 消费）
const ScriptTaskBoard := preload("res://modules/combat/scripts/battle/task_board.gd")

## 宿主 TeamAi 回引（任务槽板/快照/姿态/参数档案/时钟全在宿主）
var _host: Variant = null
## 同伴：小队/编制视图取数（原子单元数、分组）
var _squads: Variant = null
## 同伴：号令下发（脏槽重定向重发）
var _emitter: Variant = null


## 装配：注入宿主回引与同伴（TeamAi.setup 内调用；query/emitter 须先装配）
func setup(host: Variant, squads: Variant, emitter: Variant) -> void:
	_host = host
	_squads = squads
	_emitter = emitter


## 槽内核是否在决策位（咬合③：开关 + 板实例双检；false 走 SWL 退化路径）
func is_enabled() -> bool:
	return _host._task_board != null and bool(_host._p.get("slot_kernel_enabled", true))


## C5 攻击百分比（CoH state_analysis.recalculate_attackpercentage 同构，四规则
## 优先级高→低；返回 0~1 = 应处进攻位的战斗小队比例）：
##   规则一 胜利目标危急（vp_rule_enabled，缺省关闭【提案/待定】——开放问题#1
##          战役域无 VP 等价物；旗/区域控制接入后实现"票数危急抬升、我方占优
##          翻转防守"语义，本批仅留参数开关位）
##   规则二 基地威胁封顶（硬帽，最后施加）：threat_at_base 超阈 →
##          pct ≤ max(100 - threat, floor)/100
##   规则三 基调（单一参数曲线，难度分档已裁决移除·开放问题#3）：门禁未开 = 0；
##          开门禁后 baseline + 每分钟递增，封顶 max
##   规则四 军力优势递增：归一化优势超起点 → 按增益抬升，同受 max 封顶
func recalculate_attack_pct() -> float:
	# 规则三（基调）：开局攻击门禁未过 → 0（CoH start_attack_time 前攻击% = 0）
	if not _host._attack_gate_open():
		return 0.0
	var pct: float = float(_host._p["attack_pct_baseline"])
	var minutes: float = maxf(_host._now() - _host._attack_deadline, 0.0) / 60.0
	pct += float(_host._p["attack_pct_growth_per_min"]) * minutes
	pct = minf(pct, float(_host._p["max_attack_percentage"]))
	# 规则四（军力优势递增）：归一化优势 = (我-敌)/(我+敌)，超起点按增益抬升
	var total: float = _host._own_strength + _host._enemy_strength
	if total > 0.0:
		var adv: float = (_host._own_strength - _host._enemy_strength) / total
		if adv > float(_host._p["superiority_ratio_floor"]):
			pct += (adv - float(_host._p["superiority_ratio_floor"])) * float(_host._p["superiority_gain"])
			pct = minf(pct, float(_host._p["max_attack_percentage"]))
	# 规则二（基地威胁封顶）：硬帽最后施加，危巢之下不出兵
	var threat: float = threat_at_base()
	if threat > float(_host._p["base_threat_threshold"]):
		pct = minf(pct, maxf(100.0 - threat, float(_host._p["base_threat_floor"])) / 100.0)
	# 规则一（胜利目标危急）：开放问题#1 缺省关闭；开关位与实现钩子留待 VP 等价物
	if bool(_host._p.get("vp_rule_enabled", false)):
		pct = apply_victory_objective_rule(pct)
	return clampf(pct, 0.0, 1.0)


## C5 规则一实现钩子（vp_rule_enabled=true 时消费）：本作战役域尚无 VP 等价物
## （开放问题#1【提案/待定】），接入旗/区域控制后在此映射"危急度抬升 / 我方占优
## 翻转防守"。当前恒返输入值（关闭语义）。
func apply_victory_objective_rule(pct: float) -> float:
	return pct


## 基地威胁值（0-100 口径，CoH threat_at_base 语义映射）：锚点半径内（enemy_close_dist）
## 敌军力量 / 本方初始力量基线 × 100；基线缺失/为零 → 0（无基准不判威胁）。
func threat_at_base() -> float:
	if _host._initial_own_strength <= 0.0:
		return 0.0
	return _host._enemy_strength_near_base / _host._initial_own_strength * 100.0


## 攻击槽创建/维持门禁（SWL 比例条件的槽语义转写，咬合③）：
## 创建 = 开局门禁过 ∧ ratio ≥ attack_enter（SWL enter 条件，驻守期同判）；
## 维持 = ATTACK 态 ∧ ratio > attack_exit（SWL 滞回带——带内不塌槽，姿态不抖）。
func slot_attack_intent_open() -> bool:
	if not _host._attack_gate_open():
		return false
	var ratio: float = _host.balance_of_powers_ratio()
	if ratio >= float(_host._p["attack_enter"]):
		return true
	return _host._stance == _host.STANCE_ATTACK and ratio > float(_host._p["attack_exit"])


## GARRISON 重评进攻条件（两内核同判入口）：槽内核 = 存在攻击槽（驻守期建槽
## 门禁 = SWL enter 条件，与旧 garrison_reeval 口径逐位一致）；退化路径 = 原逻辑。
func garrison_reeval_attack_open() -> bool:
	if is_enabled():
		return _host._task_board.has_attack_slots()
	return _host._attack_gate_open() and _host.balance_of_powers_ratio() >= float(_host._p["attack_enter"])


## 槽同步 + 生命周期（每决策周期一次，CoH strategy_military.execute 同构）：
##   1) 目标超时杀槽/重评分（tick 先行——集结超时杀掉的槽当拍由 sync 重建，
##      无"攻击槽真空拍"窗口，防姿态振荡）；
##   2) 攻/防槽同步：期望进攻槽数 = ceil(attack% × 原子单元数)，防守 = 余量
##      （只增删空槽，从不指定小队——匹配归 match_groups 执行侧）；
##   3) 重定向脏槽重发号令（进攻小队向新目标推进）。
func update_task_board() -> void:
	if _host._task_board == null:
		return
	var dirty: Array = _host._task_board.tick(_host._now(), on_slot_retarget)
	var atomic: int = _squads.count_atomic_units()
	var desired: int = 0
	if atomic > 0:
		var pct: float = recalculate_attack_pct()
		_host._cached_attack_pct = pct  # W1：决策节拍刷新观测缓存（get_attack_percentage 消费）
		if pct > 0.0 and slot_attack_intent_open():
			desired = mini(int(ceil(pct * float(atomic))), atomic)
	# 攻击槽目标 = 评分最优敌位（新建槽定位用；现存槽不重定位，防逐拍振荡）
	var attack_target: Vector2 = attack_slot_target(null)
	_host._task_board.sync_slots(ScriptTaskBoard.KIND_ATTACK, desired, attack_target, _host._own_centroid, _host._now())
	_host._task_board.sync_slots(ScriptTaskBoard.KIND_DEFEND, maxi(atomic - desired, 0), _host._own_centroid, _host.get_garrison_anchor(), _host._now())
	if not dirty.is_empty() and is_enabled():
		_emitter.issue_retarget_orders(dirty)


## 槽目标重定位回调（TaskBoard.tick 目标超时消费；slot 为 TaskBoard.TaskSlot）
func on_slot_retarget(slot: Variant) -> Vector2:
	if slot != null and int(slot.kind) == ScriptTaskBoard.KIND_ATTACK:
		return attack_slot_target(slot)
	return _host._own_centroid


## 攻击槽目标定位（C4 四因子 argmax）：候选 = 敌方存活军事单位位置 + 敌方质心
## （去重）；评分参照 = 本方质心（squad 口径）/ 本方锚点（base 口径）/ 敌方力量
## 快照；惯性参照 = 槽现目标（重评分防振荡）。无候选 → 敌方质心（旧 ATTACK 语义）。
func attack_slot_target(slot: Variant) -> Vector2:
	var candidates: Array = []
	for e in _host._enemy_units_snapshot:
		var pos: Vector2 = e.get("pos", Vector2.INF)
		if pos.is_finite() and not candidates.has(pos):
			candidates.append(pos)
	if not _host._enemy_units_snapshot.is_empty() and not candidates.has(_host._enemy_centroid):
		candidates.append(_host._enemy_centroid)
	if candidates.is_empty():
		return _host._enemy_centroid
	var ctx := {
		"squad_pos": _host._own_centroid,
		"base_pos": _host.get_garrison_anchor(),
		"enemies": _host._enemy_units_snapshot,
		"own_strength": _host._own_strength,
		"last_target": slot.target if slot != null else Vector2.INF,
	}
	return _host._task_board.pick_target(candidates, ctx)
