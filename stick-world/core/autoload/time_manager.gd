extends Node
## 游戏时间流速控制 —— 引擎原语做总闸，自定义代码只保留速度缩放。
##
## 暂停/加速三种语义分层（详见 docs/技术/架构/UI运行时架构优化方案.md §二）：
##   - 硬暂停（空格/模态自动暂停/战斗自动暂停）→ 引擎 SceneTree.paused，
##     世界子树（process_mode PAUSABLE）整体冻结，零逐系统检查；
##   - 倍速（X1/X2/X4）→ 模拟系统统一经 sim_delta(delta) 取步长；
##   - 附身微操减速 → 倍速的一种预设值（X1），不新造机制。
##
## EventBus game_paused / game_resumed 保留为 UI 反应通道（"已暂停"提示、
## HUD 状态刷新），不再承担冻结职责。

# ─────────────────────────────── 速度枚举 ────────────────────────────────

enum Speed {
	PAUSED,   ## 完全暂停（引擎总闸 SceneTree.paused = true）
	X1,       ## 正常速度（1x）
	X2,       ## 2 倍速
	X4,       ## 4 倍速
}

# ─────────────────────────────── 状态 ───────────────────────────────────

var current_speed: Speed = Speed.X1

## 附身（possess）时是否自动降速为 X1。
var auto_slow_on_possess: bool = true


# ─────────────────────────────── 生命周期 ────────────────────────────────

## 启动时应用设置面板持久化项（附身自动减速）。
func _ready() -> void:
	# 暂停驱动方：引擎总闸由本单例翻转，翻转动作本身与信号发射不受暂停影响
	# （自动加载不在 game_root/ui_root 两棵子树内，无法随场景声明，此处为
	# 分层声明表的自动加载例外项）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 物理/逻辑 tick 30Hz（人群战斗性能核心：所有逐 tick 成本减半，速率语义按
	# delta 自动补偿）。project.godot 里的同名配置实测未生效（原因未明），
	# 此处运行时强制执行，单一真相源。
	Engine.physics_ticks_per_second = 30
	if ConfigManager:
		if ConfigManager.has_key("game/slow_on_possess"):
			auto_slow_on_possess = bool(ConfigManager.get_value("game/slow_on_possess"))
	if EventBus and EventBus.has_signal("battle_started"):
		EventBus.battle_started.connect(_on_battle_started)


## 战斗开始：若设置开启（game/auto_pause_battle，默认 true）则自动暂停，玩家手动恢复。
func _on_battle_started(_battle_id: String) -> void:
	if not ConfigManager:
		return
	var v: Variant = ConfigManager.get_value("game/auto_pause_battle")
	# 键未存储（从未应用过设置）时按默认 true 处理
	if v == null or bool(v):
		pause()


# ─────────────────────────────── 速度控制 ────────────────────────────────

## 设置当前时间流速。PAUSED 档翻转引擎总闸（SceneTree.paused）；
## 根据新旧速度状态发射 game_paused / game_resumed。
func set_speed(speed: Speed) -> void:
	if current_speed == speed:
		return

	var was_paused: bool = (current_speed == Speed.PAUSED)
	current_speed = speed
	var now_paused: bool = (current_speed == Speed.PAUSED)

	# 引擎总闸：世界子树（PAUSABLE）整体冻结/解冻；UIRoot/相机等 ALWAYS 子树不受影响
	if get_tree() != null:
		get_tree().paused = now_paused

	# 只在状态变化时发射信号
	if was_paused != now_paused:
		if now_paused:
			EventBus.game_paused.emit()
		else:
			EventBus.game_resumed.emit()


## 暂停游戏。
func pause() -> void:
	set_speed(Speed.PAUSED)


## 恢复游戏（恢复为 X1 速度）。
func resume() -> void:
	set_speed(Speed.X1)


## 切换暂停/恢复。
func toggle_pause() -> void:
	if current_speed == Speed.PAUSED:
		resume()
	else:
		pause()


## 当前是否处于暂停状态。
func is_paused() -> bool:
	return current_speed == Speed.PAUSED


# ─────────────────────────────── 模拟步长 ────────────────────────────────

## 模拟系统统一经此取步长（引擎 delta × 速度档因子）。
## 暂停冻结由引擎总闸负责——PAUSABLE 节点暂停期根本不会进入 tick，
## 本方法无需（也不应）再处理暂停语义。
func sim_delta(delta: float) -> float:
	return delta * speed_factor()


## 速度档因子：X1=1 / X2=2 / X4=4；PAUSED 返 0 兜底（正常情况下模拟节点已冻结，
## 不会走到这里）。
func speed_factor() -> float:
	match current_speed:
		Speed.X2:
			return 2.0
		Speed.X4:
			return 4.0
		Speed.PAUSED:
			return 0.0
		_:
			return 1.0
