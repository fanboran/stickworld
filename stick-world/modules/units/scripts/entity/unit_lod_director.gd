class_name UnitLodDirector
extends Node
## 战斗级单位 LOD 调度器 —— 按相机距离给参战单位分档节流表现层。
##
## 背景：48v48 混战的主渲染成本在每单位的动画处理（AnimationTree 采样 ~21 条
## 骨骼轨道 + 4×TwoBoneIK + ProceduralOverlay 每帧叠加 + 血条每帧重绘）。
## 本调度器以 10Hz 重算每单位的三档归属，实体侧 set_perf_tier 据此降低
## 动画/叠加/血条更新频率、隐藏离屏单位，物理与战斗逻辑不受影响。
##
## 三档（名义区）：
##   T0 近景：视口矩形外扩 20% 以内 且 距相机 < 1500px → 动画频率按密度自适应
##     （存活跟踪单位数 N：N ≤ 24 → 60Hz 全速；25 ≤ N ≤ 48 → 30Hz；N > 48 → 20Hz。
##      密度越高单帧动画采样成本越高，近景也需让路；N ≤ 24 与未接入 LOD 等价）
##   T1 中景：视口矩形外扩 60% 以内 或 距离 < 2600px → 动画/叠加 15Hz、血条 10Hz
##   T2 远景：更远 → rig 隐藏、血条隐藏、动画/叠加 5Hz（不暂停，状态照常推进）
##   T1/T2 频率固定；hz 换算策略只在 director（唯一策略源），实体侧仅透传。
##
## 滞回：升/降档需越过阈值 15% 边际（"深入区"收紧 15%，"守住区"放宽 15%），
## 防止单位在阈值附近来回抖档。
##
## 事件驱动链（命中帧 → 武器结算）由 rig 侧轮询播放位置实现，与采样频率解耦：
## 节流后事件最多晚 1 个节拍触发（15Hz ≤ 66ms、5Hz ≤ 200ms），不丢失、不重发。
##
## 挂载与自动发现：由 SystemSetup 装配挂到 GameRoot（节点名 UnitLodDirector），
## setup(game_root) 后每拍自动发现——地图经 GameRoot.get_current_map() 解析，
## 地图实例变更时重解析 map.find_child("EntityHost", true, false) 并缓存宿主
## 引用、重置档位状态；单位集每拍从缓存宿主的子节点刷新（演练场/攻城波次等
## 晚于地图装配的刷兵下一拍自动纳入，递归 find_child 只付在换绑时）；相机每拍
## 取 game_root 视口激活相机。地图未加载 / 无相机（headless 测试）时空转，
## 单位保持默认全速（零行为变化）。

## 视口外扩 20% 内 且 距离 < NEAR_DIST → T0
const NEAR_RECT_MARGIN: float = 0.20
const NEAR_DIST: float = 1500.0
## 视口外扩 60% 内 或 距离 < MID_DIST → T1（其余 T2）
const MID_RECT_MARGIN: float = 0.60
const MID_DIST: float = 2600.0
## 换档滞回边际（15%）：深入区/守住区阈值相对名义区的偏移比例
const HYSTERESIS: float = 0.15
## 重新分档节拍（s）：单位数 ≤128 时遍历成本可忽略
const RETIER_INTERVAL: float = 0.1

## T0 密度自适应分档（存活跟踪单位数 N → T0 动画频率，hz 策略唯一真相源）
const HZ_T0_SPARSE: float = 60.0  ## N ≤ 24：全速（与未接入 LOD 等价）
const HZ_T0_MID: float = 30.0     ## 25 ≤ N ≤ 48
const HZ_T0_DENSE: float = 20.0   ## N > 48
const DENSITY_SPARSE: int = 24
const DENSITY_DENSE: int = 48
## T1/T2 固定频率（Hz）
const HZ_T1: float = 15.0
const HZ_T2: float = 5.0

## 性能档位（与 StickmanEntity.set_perf_tier 对齐）
enum Tier {
	NEAR = 0,   ## 近景：密度自适应频率
	MID = 1,    ## 中景：15Hz
	FAR = 2,    ## 远景/离屏：5Hz + 隐藏
}

## 宿主 GameRoot（自动发现单位集与相机；弱类型 Node，units 侧不硬依赖 world 类）
var _game_root: Node = null
## 当前绑定的地图实例（实例变更 → 重解析 EntityHost + 重置档位状态）
var _map: Node2D = null
## 当前地图的 EntityHost（地图换绑时经 find_child 解析并缓存）
var _host: Node = null
## 单位集快照（每拍从 _host 子节点刷新，仅收实现 LOD 契约的单位）
var _units: Array = []
## 分档计时器
var _timer: float = 0.0
## 每单位当前档位（instance_id -> Tier）
var _tiers: Dictionary = {}
## 每单位当前下发频率（instance_id -> hz；T0 频率随密度 N 变化需重新下发）
var _hzs: Dictionary = {}


## 注入宿主 GameRoot（自动发现模式：地图/单位集/相机均由本节点每拍自取）。
func setup(game_root: Node) -> void:
	_game_root = game_root
	_map = null
	_host = null
	_units.clear()
	_tiers.clear()
	_hzs.clear()
	_timer = 0.0


func _physics_process(delta: float) -> void:
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = RETIER_INTERVAL
	_retier()


## 退出时把存活单位全部置回近景全速档（rig 可见性/血条显示还原，hz 缺省=全速）。
## 死者跳过：尸体血条已由 _on_died 隐藏，恢复显示会"尸体复活血条"。
func _exit_tree() -> void:
	for u in _units:
		if not _is_trackable(u):
			continue
		if u.has_method("set_perf_tier"):
			u.set_perf_tier(Tier.NEAR)
	_units.clear()
	_tiers.clear()
	_hzs.clear()
	_map = null
	_host = null


# ─────────────────────────────── 自动发现 ────────────────────────────────

## 一轮自动发现 + 分档：相机 → 地图换绑 → 单位集刷新 → 密度定频 → 逐单位分档。
func _retier() -> void:
	if _game_root == null or not is_instance_valid(_game_root):
		return
	# 相机：每拍取视口激活相机（地图切换会换相机；headless 取不到 → 空转）
	var vp: Viewport = _game_root.get_viewport()
	var cam: Camera2D = vp.get_camera_2d() if vp != null else null
	if cam == null or not is_instance_valid(cam):
		return
	# 地图换绑：实例变更时重解析 EntityHost 宿主并重置档位状态
	_rebind_map()
	# 单位集刷新（每拍）：晚于地图装配的刷兵（演练场/攻城波次）下一拍自动纳入
	_refresh_units()
	if _units.is_empty():
		return
	# T0 密度自适应：按存活跟踪单位数 N 定近景频率
	var n: int = 0
	for u in _units:
		if _is_trackable(u):
			n += 1
	var t0_hz: float = _t0_hz(n)
	var vp_size: Vector2 = cam.get_viewport().get_visible_rect().size
	var center: Vector2 = cam.get_screen_center_position()
	var zoom: Vector2 = cam.get_zoom()
	for u in _units:
		if not _is_trackable(u):
			continue
		# 附身单位是玩家视点所在身体，恒近景全速（玩家逻辑优先于 LOD）
		if u.has_method("is_possessed") and u.is_possessed():
			_apply_tier(u, Tier.NEAR, t0_hz)
			continue
		var pos: Vector2 = u.global_position
		var cur: int = int(_tiers.get(u.get_instance_id(), Tier.NEAR))
		var new_tier: int = _tier_with_hysteresis(cur, pos, center, vp_size, zoom)
		_apply_tier(u, new_tier, _tier_hz(new_tier, t0_hz))


## 地图换绑：map 实例变更（含 null ↔ 非 null）时重解析 EntityHost 并清档位状态。
## find_child（递归）只在换绑时执行，宿主引用缓存到下一换绑。
func _rebind_map() -> void:
	var map: Node2D = null
	if _game_root.has_method("get_current_map"):
		map = _game_root.get_current_map()
	if map == _map:
		return
	_map = map
	_host = null
	_units.clear()
	_tiers.clear()
	_hzs.clear()
	if map != null:
		_host = map.find_child("EntityHost", true, false)


## 单位集每拍刷新：从缓存宿主取子节点快照，只收实现 LOD 契约的单位
## （有 set_perf_tier；非单位杂项不进集、不计密度）。宿主失效（极端时序）
## 时清空，待下轮地图换绑重建。
func _refresh_units() -> void:
	if _host == null or not is_instance_valid(_host):
		_units.clear()
		return
	_units.clear()
	for c in _host.get_children():
		if c is Node2D and not c.is_queued_for_deletion() and c.has_method("set_perf_tier"):
			_units.append(c)


## 单位是否可跟踪（引用有效、未挂删除队列、存活）。死者不计密度、不下发。
func _is_trackable(u: Node) -> bool:
	if u == null or not is_instance_valid(u) or u.is_queued_for_deletion():
		return false
	if u.has_method("is_dead") and u.is_dead():
		return false
	return true


# ─────────────────────────────── 频率策略（唯一真相源） ────────────────────────────────

## T0 密度分档：N ≤ 24 → 60Hz；25 ≤ N ≤ 48 → 30Hz；N > 48 → 20Hz。
func _t0_hz(n: int) -> float:
	if n <= DENSITY_SPARSE:
		return HZ_T0_SPARSE
	if n <= DENSITY_DENSE:
		return HZ_T0_MID
	return HZ_T0_DENSE


## 档位 → 动画频率（T0 密度自适应，T1/T2 固定）。
func _tier_hz(tier: int, t0_hz: float) -> float:
	match tier:
		Tier.MID:
			return HZ_T1
		Tier.FAR:
			return HZ_T2
		_:
			return t0_hz


# ─────────────────────────────── 分档 ────────────────────────────────

## 下发档位与频率（任一变化才调实体，防每拍重复 set）。
func _apply_tier(u: Node, tier: int, hz: float) -> void:
	var iid: int = u.get_instance_id()
	if int(_tiers.get(iid, Tier.NEAR)) == tier and float(_hzs.get(iid, -1.0)) == hz:
		return
	_tiers[iid] = tier
	_hzs[iid] = hz
	if u.has_method("set_perf_tier"):
		u.set_perf_tier(tier, hz)


## 名义分档（无滞回）：按规格三档条件直接判定。
func _tier_with_hysteresis(cur: int, pos: Vector2, center: Vector2,
		vp_size: Vector2, zoom: Vector2) -> int:
	var dist: float = pos.distance_to(center)
	match cur:
		Tier.NEAR:
			# 守住区（名义区放宽 15%）内保持近景；离开后按名义 T1/T2 区落档
			if _in_rect(pos, center, vp_size, zoom, NEAR_RECT_MARGIN * (1.0 + HYSTERESIS)) \
					and dist < NEAR_DIST * (1.0 + HYSTERESIS):
				return Tier.NEAR
			if _in_rect(pos, center, vp_size, zoom, MID_RECT_MARGIN) or dist < MID_DIST:
				return Tier.MID
			return Tier.FAR
		Tier.MID:
			# 深入区（名义区收紧 15%）才升近景；守住区内保持中景，否则落远景
			if _in_rect(pos, center, vp_size, zoom, NEAR_RECT_MARGIN * (1.0 - HYSTERESIS)) \
					and dist < NEAR_DIST * (1.0 - HYSTERESIS):
				return Tier.NEAR
			if _in_rect(pos, center, vp_size, zoom, MID_RECT_MARGIN * (1.0 + HYSTERESIS)) \
					or dist < MID_DIST * (1.0 + HYSTERESIS):
				return Tier.MID
			return Tier.FAR
		_:
			# 远景：深入中景区（名义区收紧 15%）才回升
			if _in_rect(pos, center, vp_size, zoom, MID_RECT_MARGIN * (1.0 - HYSTERESIS)) \
					or dist < MID_DIST * (1.0 - HYSTERESIS):
				return Tier.MID
			return Tier.FAR


## 单位是否在相机世界矩形（视口尺寸/zoom 换算，四边外扩 margin 比例）内。
func _in_rect(pos: Vector2, center: Vector2, vp_size: Vector2,
		zoom: Vector2, margin: float) -> bool:
	var half := vp_size / (zoom * 2.0) * (1.0 + margin)
	var rect := Rect2(center - half, half * 2.0)
	return rect.has_point(pos)
