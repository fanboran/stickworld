class_name BattleSim
extends RefCounted
## D 刀：数据化批模拟内核 —— 参战 AI 单位的模拟状态离开场景树，进 SoA 扁平数组，
## 系统以紧凑循环批量推进；场景树里的 StickmanEntity 降级为渲染/受击代理。
##
## 详见 docs/项目/交接/战斗规模化30fps-进度与交接.md §十（整体迁移版设计）。
##
## 迁移范围（96v96 每刻的绝对大头）：
##   - 移动积分 + 边界 clamp（替代 move_and_slide：单位层互不碰撞——旧链单位间
##     的物理互撞正是 bodies-ghost 实验证明的实体物理链大头；站位由分离修正维持）
##   - 群体分离（替代逐单位 query_neighbors Dictionary 分配风暴：每刻一次网格
##     重建 + 内联邻域循环，普通 Array 引用语义——PackedArray 存容器是值拷贝）
##   - 击退冲量衰减
##   - 武器冷却推进 + 命中帧（strike）计时 + 远程放箭计时（替代 192 个
##     WeaponMount._physics_process 与 rig 动画位置轮询——sim 是时序权威，
##     渲染侧攻击动画只是观感）
## 不迁移（保持 Node 侧）：
##   - AI 决策/行为状态机（低频决策，行为库与实体深度耦合）
##   - DamagePipeline / 箭矢弹道 / 状态效果 / 士气 / 存血量（低频事件链，
##     HealthComponent 仍是血量权威）
##   - 附身单位（玩家交互链不动，不注册 sim）
##
## 教训落实（§十 重开必读）：
##   - 整链一次切换（移动+分离+冷却+命中同批循环），A/B 开关保底回退
##   - 邻域遍历内联循环，禁止 Callable 回调
##   - 网格 cell 用普通 Array（引用语义）
##   - SoA 用 PackedFloat32Array/PackedInt32Array；需要引用语义的（实体表/
##     strike 表/网格 cell）用普通 Array/Dictionary

## 分离检测半径（与 StickmanEntity.SEPARATION_RADIUS 同值——渲染代理侧常量
## 不便静态读取，战斗单位体型一致，取同值）
const SEPARATION_RADIUS: float = 54.0
## 静态分离单刻位置修正上限（与 MAX_SEPARATION_CORRECTION 同值）
const MAX_SEPARATION_CORRECTION: float = 3.0
## 击退衰减（与 KNOCKBACK_DECAY 同值）
const KNOCKBACK_DECAY: float = 700.0
## 空间网格 cell（与 map_base.GRID_CELL 同值）
const GRID_CELL: float = 64.0
## 分离分频（与实体侧 _sep_rate_div=2 同频：30Hz 物理下 15Hz 分离）
const SEP_RATE_DIV: int = 2

# ─────────────────────────────── SoA 数据 ────────────────────────────────
## 位置（权威；每刻积分后写回实体）
var pos_x := PackedFloat32Array()
var pos_y := PackedFloat32Array()
## AI 意图速度（px/s，实体侧 ai_move/加速曲线算好后写入；0=停）
var intent_x := PackedFloat32Array()
var intent_y := PackedFloat32Array()
## 击退冲量速度（px/s，随刻线性衰减）
var kb_x := PackedFloat32Array()
var kb_y := PackedFloat32Array()
## 阵营（0=未参战不注册；1/2=参战）
var faction := PackedInt32Array()
## 武器冷却剩余（s）
var cooldown := PackedFloat32Array()
## foot_offset（Y clamp 用，脚部参考系对齐旧链 global_position.y 语义）
var foot_off := PackedFloat32Array()
## 待结算近战 strike 槽下标（-1=无）；对应 _strikes 引用表
var strike_slot := PackedInt32Array()
## strike 已推进时长（s，发起后累计——含动画起播宽限语义）
var strike_elapsed := PackedFloat32Array()
## 待结算远程放箭计时（-1=无）：到点触发 _strikes 槽里的远程结算
var ranged_timer := PackedFloat32Array()

# ─────────────────────────────── 引用表（普通 Array/Dictionary）───────────────────────────────
## sid → StickmanEntity（引用语义；死亡淡出 queue_free 后由 unregister 清理）
var entities: Array = []
## 近战/远程待结算槽（sim 登记时打包武器参数，crossing 时回调 WeaponMount 结算）
## 元素：null（空槽）或 Dictionary（见 register_strike / register_ranged）
var _strikes: Array = []
var _free_slots: Array = []
## 空间网格：cell key → Array[int]（sid 列表，普通 Array 引用语义）
var _grid: Dictionary = {}
## 边界（由 BattleInstance.setup_sim 从 map 注入；Y 语义与旧链一致：
## 实体 y ∈ [ground_y - foot_offset, ground_bottom - foot_offset]）
var map_left: float = 0.0
var map_right: float = 8192.0
var ground_y: float = 450.0
var ground_bottom: float = 882.0
## 分离节拍计数（隔刻跑分离）
var _sep_counter: int = 0
## 是否启用（A/B 开关；BattleInstance 构造时决定，运行期不变）
var enabled: bool = true


## A/B 开关唯一裁决点：环境变量 STICK_BATTLE_SIM 优先（"0"=关/其余=开），
## 未设置时读 ProjectSettings sim/battle_sim（默认开）。
static func is_enabled() -> bool:
	var env := OS.get_environment("STICK_BATTLE_SIM")
	if not env.is_empty():
		return env != "0"
	return bool(ProjectSettings.get_setting("sim/battle_sim", true))


## 注入战场边界（BattleInstance.setup_sim 调用，值来自 map）
func set_bounds(p_left: float, p_right: float, p_gy: float, p_gb: float) -> void:
	map_left = p_left
	map_right = p_right
	ground_y = p_gy
	ground_bottom = p_gb


## 注册参战单位，返回 sid（<0 = 注册失败）。
## 附身单位不进 sim（玩家交互链不动）；注册即接管移动/冷却/命中时序。
func register_unit(unit: Node, p_faction: int) -> int:
	if unit == null or not is_instance_valid(unit):
		return -1
	if unit.has_method("is_possessed") and unit.is_possessed():
		return -1
	var sid: int = entities.size()
	entities.append(unit)
	pos_x.append(unit.global_position.x)
	pos_y.append(unit.global_position.y)
	intent_x.append(0.0)
	intent_y.append(0.0)
	kb_x.append(0.0)
	kb_y.append(0.0)
	faction.append(p_faction)
	cooldown.append(0.0)
	var fo: float = float(unit.get("foot_offset")) if "foot_offset" in unit else 45.0
	foot_off.append(fo)
	strike_slot.append(-1)
	strike_elapsed.append(0.0)
	ranged_timer.append(-1.0)
	_strikes.append(null)
	unit.set_meta("battle_sim_sid", sid)
	return sid


## 注销（尸体淡出 queue_free 的 _exit_tree 路径 / 战斗结束清场）。
## SoA 不做紧凑收缩（战斗时长内注销量有限，墓位零成本）；entity 引用置 null，
## 批循环跳过 null 与 freed。
func unregister_unit(unit: Node) -> void:
	if unit == null or not unit.has_meta("battle_sim_sid"):
		return
	var sid: int = int(unit.get_meta("battle_sim_sid"))
	unit.remove_meta("battle_sim_sid")
	if sid < 0 or sid >= entities.size():
		return
	_drop_strike(sid)
	entities[sid] = null


func _drop_strike(sid: int) -> void:
	var slot: int = strike_slot[sid]
	if slot >= 0 and slot < _strikes.size() and _strikes[slot] != null:
		var info: Dictionary = _strikes[slot]
		if int(info.get("owner_sid", -1)) == sid:
			_strikes[slot] = null
			_free_slots.append(slot)
	strike_slot[sid] = -1
	ranged_timer[sid] = -1.0


# ─────────────────────────────── 意图 / 击退 / 冷却 API ────────────────────────────────

## AI 意图速度写入（实体侧 _apply_movement 算好总速度后调用）。
func set_intent(sid: int, vel: Vector2) -> void:
	intent_x[sid] = vel.x
	intent_y[sid] = vel.y


## 击退冲量注入（受击方向 × 力度；实体 apply_hit_reaction 的 sim 转发）。
func add_knockback(sid: int, vel: Vector2) -> void:
	kb_x[sid] = vel.x
	kb_y[sid] = vel.y


## 读当前位置（AI/武器 sim 模式距离判定用）
func get_pos(sid: int) -> Vector2:
	return Vector2(pos_x[sid], pos_y[sid])


## 冷却读写（WeaponMount sim 模式的冷却真相源）
func get_cooldown(sid: int) -> float:
	return cooldown[sid]


func set_cooldown(sid: int, t: float) -> void:
	cooldown[sid] = t


## 邻域查询：返回半径内存活邻居 sid（PackedInt32Array，含死者过滤——
## 死者不再参与推挤/感知）。AI 侧分离/威胁计数消费；无 Callable，一次分配。
func query_neighbor_ids(pos: Vector2, radius: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var min_c := Vector2i(floori((pos.x - radius) / GRID_CELL), floori((pos.y - radius) / GRID_CELL))
	var max_c := Vector2i(floori((pos.x + radius) / GRID_CELL), floori((pos.y + radius) / GRID_CELL))
	for cy in range(min_c.y, max_c.y + 1):
		for cx in range(min_c.x, max_c.x + 1):
			var cell: Variant = _grid.get(Vector2i(cx, cy))
			if cell == null:
				continue
			for sid_v: int in cell:
				var sid: int = sid_v
				if not _sid_alive(sid):
					continue
				var dx: float = pos_x[sid] - pos.x
				if dx > radius or dx < -radius:
					continue
				var dy: float = pos_y[sid] - pos.y
				if dy > radius or dy < -radius:
					continue
				if dx * dx + dy * dy > radius * radius:
					continue
				out.append(sid)
	return out


## 分离软引导推力（旧链 StickmanEntity._apply_separation 的 sim 版）：
## 半径内存活邻居的归一化反向权重和（1 - dist/radius 线性），循环内联在本方法——
## 替代旧链逐邻居 Node 遍历与中间数组分配。
func separation_push(sid: int, radius: float) -> Vector2:
	var px: float = pos_x[sid]
	var py: float = pos_y[sid]
	var total_x: float = 0.0
	var total_y: float = 0.0
	var radius_sq: float = radius * radius
	var min_cx := floori((px - radius) / GRID_CELL)
	var max_cx := floori((px + radius) / GRID_CELL)
	var min_cy := floori((py - radius) / GRID_CELL)
	var max_cy := floori((py + radius) / GRID_CELL)
	for cy in range(min_cy, max_cy + 1):
		for cx in range(min_cx, max_cx + 1):
			var cell: Variant = _grid.get(Vector2i(cx, cy))
			if cell == null:
				continue
			for oid_v: int in cell:
				var oid: int = oid_v
				if oid == sid or not _sid_alive(oid):
					continue
				var dx: float = px - pos_x[oid]
				var dy: float = py - pos_y[oid]
				var d_sq: float = dx * dx + dy * dy
				if d_sq >= radius_sq or d_sq <= 0.0:
					continue
				var dist: float = sqrt(d_sq)
				var w: float = 1.0 - dist / radius
				total_x += dx / dist * w
				total_y += dy / dist * w
	return Vector2(total_x, total_y)


## 读邻居阵营（批量感知用）
func get_faction(sid: int) -> int:
	return faction[sid]


## sid 活性检查（引用存在且有效且未死；异常释放路径的防御）
func _sid_alive(sid: int) -> bool:
	var e: Node = entities[sid]
	if e == null or not is_instance_valid(e):
		return false
	return not e.is_dead()


# ─────────────────────────────── 攻击登记 ────────────────────────────────

## 登记近战 strike（WeaponMount.perform_attack sim 分支调用）。
## 结算时回调 weapon.sim_strike_now()（复用旧结算链：AOE/mood/hitstop）。
## hit_time 由登记方解析为绝对秒（Hit 事件真值；无事件数据时按动画时长 ×
## fallback 比例换算）——sim 无动画进度概念，只收绝对秒。
func register_strike(sid: int, weapon: Node, hit_time: float) -> void:
	_drop_strike(sid)
	var slot: int = _alloc_slot()
	_strikes[slot] = {
		"owner_sid": sid,
		"weapon": weapon,
		"hit_time": hit_time,
		"kind": "melee",
	}
	strike_slot[sid] = slot
	strike_elapsed[sid] = 0.0


## 登记远程延迟结算（弓放箭 / 杖施法）：delay 到点回调 weapon.sim_fire_now()。
func register_ranged(sid: int, weapon: Node, target: Node, delay: float) -> void:
	_drop_strike(sid)
	var slot: int = _alloc_slot()
	_strikes[slot] = {
		"owner_sid": sid,
		"weapon": weapon,
		"target": target,
		"kind": "ranged",
	}
	strike_slot[sid] = slot
	ranged_timer[sid] = delay


func _alloc_slot() -> int:
	if not _free_slots.is_empty():
		return _free_slots.pop_back()
	_strikes.append(null)
	return _strikes.size() - 1


# ─────────────────────────────── 批循环 ────────────────────────────────

## 每物理刻推进（BattleInstance._physics_process 开头调用）。
## 单 pass 顺序：分离 → 积分+击退+边界 → 冷却/strike → 写回。
func tick(delta: float) -> void:
	var n: int = entities.size()
	if n == 0:
		return
	_sep_counter += 1
	if _sep_counter % SEP_RATE_DIV == 0:
		_tick_separation()
	_tick_motion(delta)
	_tick_weapon(delta)
	_write_back(n)


## 分离：网格重建 + 内联邻域修正（soft-body 位置修正，与旧链
## _apply_static_separation 同语义：重叠一半互推、先累加再限幅、死者除外）。
func _tick_separation() -> void:
	_grid.clear()
	var n: int = entities.size()
	for sid in n:
		if not _sid_alive(sid):
			continue
		var key := Vector2i(floori(pos_x[sid] / GRID_CELL), floori(pos_y[sid] / GRID_CELL))
		var cell: Variant = _grid.get(key)
		if cell == null:
			cell = []
			_grid[key] = cell
		cell.append(sid)
	# 修正量累积到修正数组（写回在循环外，避免同刻先后读污染）
	var n_active: int = n
	if _sep_px_x.size() < n_active:
		_sep_px_x.resize(n_active)
		_sep_px_y.resize(n_active)
	var radius: float = SEPARATION_RADIUS
	var radius_sq: float = radius * radius
	for sid in n:
		if not _sid_alive(sid):
			continue
		var px: float = pos_x[sid]
		var py: float = pos_y[sid]
		_sep_px_x[sid] = 0.0
		_sep_px_y[sid] = 0.0
		var total_x: float = 0.0
		var total_y: float = 0.0
		var min_cx := floori((px - radius) / GRID_CELL)
		var max_cx := floori((px + radius) / GRID_CELL)
		var min_cy := floori((py - radius) / GRID_CELL)
		var max_cy := floori((py + radius) / GRID_CELL)
		for cy in range(min_cy, max_cy + 1):
			for cx in range(min_cx, max_cx + 1):
				var cell: Variant = _grid.get(Vector2i(cx, cy))
				if cell == null:
					continue
				for sid_v: int in cell:
					var oid: int = sid_v
					if oid == sid:
						continue
					var ox: float = pos_x[oid]
					var oy: float = pos_y[oid]
					var dx: float = px - ox
					var dy: float = py - oy
					var d_sq: float = dx * dx + dy * dy
					if d_sq >= radius_sq:
						continue
					var dist: float = sqrt(d_sq)
					if dist <= 0.001:
						# 完全重叠：固定向上推开（旧链同语义）
						total_y -= radius * 0.5
						continue
					# 重叠量的一半推给自己（对方同刻也推自己，双向合计推开重叠量）
					var w: float = (radius - dist) * 0.5 / dist
					total_x += dx * w
					total_y += dy * w
		if total_x != 0.0 or total_y != 0.0:
			var len_sq: float = total_x * total_x + total_y * total_y
			if len_sq > MAX_SEPARATION_CORRECTION * MAX_SEPARATION_CORRECTION:
				var inv: float = MAX_SEPARATION_CORRECTION / sqrt(len_sq)
				total_x *= inv
				total_y *= inv
			_sep_px_x[sid] = total_x
			_sep_px_y[sid] = total_y
	# 应用修正（边界 clamp 在 _tick_motion 统一做）
	for sid in n:
		if not _sid_alive(sid):
			continue
		var mx: float = _sep_px_x[sid]
		if mx == 0.0:
			continue
		pos_x[sid] += mx
		pos_y[sid] += _sep_px_y[sid]


var _sep_px_x := PackedFloat32Array()
var _sep_px_y := PackedFloat32Array()


## 运动：意图+击退积分、击退衰减、边界 clamp。
func _tick_motion(delta: float) -> void:
	var n: int = entities.size()
	var decay: float = KNOCKBACK_DECAY * delta
	var y_min_off := ground_y
	var y_max_off := ground_bottom
	for sid in n:
		if not _sid_alive(sid):
			continue
		var vx: float = intent_x[sid] + kb_x[sid]
		var vy: float = intent_y[sid] + kb_y[sid]
		if vx != 0.0:
			pos_x[sid] += vx * delta
		if vy != 0.0:
			pos_y[sid] += vy * delta
		# 击退衰减（线性，旧链同语义）
		var kbx: float = kb_x[sid]
		var kby: float = kb_y[sid]
		if kbx != 0.0 or kby != 0.0:
			var k_len: float = sqrt(kbx * kbx + kby * kby)
			if k_len <= decay:
				kb_x[sid] = 0.0
				kb_y[sid] = 0.0
			else:
				var k: float = (k_len - decay) / k_len
				kb_x[sid] = kbx * k
				kb_y[sid] = kby * k
		# 边界 clamp（Y 以脚部参考系，X 旧链同语义）
		var fo: float = foot_off[sid]
		var py: float = pos_y[sid]
		var y_min: float = y_min_off - fo
		var y_max: float = y_max_off - fo
		if py < y_min:
			pos_y[sid] = y_min
		elif py > y_max:
			pos_y[sid] = y_max
		var px: float = pos_x[sid]
		if px < map_left:
			pos_x[sid] = map_left
		elif px > map_right:
			pos_x[sid] = map_right


## 武器：冷却推进 + 近战 strike 命中帧 crossing + 远程放箭到点。
## crossing 回调 WeaponMount.sim_strike_now()（结算链复用旧代码）。
func _tick_weapon(delta: float) -> void:
	var n: int = entities.size()
	for sid in n:
		if not _sid_alive(sid):
			continue
		var cd: float = cooldown[sid]
		if cd > 0.0:
			cooldown[sid] = cd - delta if cd > delta else 0.0
		var slot: int = strike_slot[sid]
		if slot < 0:
			continue
		var info: Dictionary = _strikes[slot]
		if info == null:
			strike_slot[sid] = -1
			continue
		var w: Node = info["weapon"]
		if w == null or not is_instance_valid(w):
			_strikes[slot] = null
			_free_slots.append(slot)
			strike_slot[sid] = -1
			ranged_timer[sid] = -1.0
			continue
		if info["kind"] == "ranged":
			var rt: float = ranged_timer[sid]
			if rt > 0.0:
				ranged_timer[sid] = rt - delta if rt > delta else 0.0
			if rt <= 0.0:
				# 到点：远程结算（放箭/施法），清槽
				strike_slot[sid] = -1
				ranged_timer[sid] = -1.0
				_strikes[slot] = null
				_free_slots.append(slot)
				w.sim_fire_now()
		else:
			var el: float = strike_elapsed[sid] + delta
			strike_elapsed[sid] = el
			if el >= float(info["hit_time"]):
				# 命中帧到点（sim 为时序权威；渲染侧攻击动画只是观感）
				strike_slot[sid] = -1
				_strikes[slot] = null
				_free_slots.append(slot)
				w.sim_strike_now()


## 批量写回渲染代理：位置 / velocity（箭矢预判消费）/ z_index。
func _write_back(n: int) -> void:
	for sid in n:
		var e: Node = entities[sid]
		if e == null or not is_instance_valid(e) or e.is_dead():
			continue
		var px: float = pos_x[sid]
		var py: float = pos_y[sid]
		e.global_position = Vector2(px, py)
		e.velocity = Vector2(intent_x[sid] + kb_x[sid], intent_y[sid] + kb_y[sid])
		var zi: int = int(py * 0.1)
		if zi != e.z_index:
			e.z_index = zi
