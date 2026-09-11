extends Node
## 暂停原语化功能验证（批次 A 验收辅助，跑完即删）：
##   1. set_speed(PAUSED) 翻转引擎总闸 SceneTree.paused
##   2. PAUSABLE 节点暂停期停 tick，ALWAYS 节点继续 tick
##   3. game_paused/game_resumed 信号发射
##   4. sim_delta/speed_factor 倍速步长
##   5. 栈式恢复（模态语义）：X2 → 暂停 → 回 X2
## 运行：godot --headless --path stick-world res://tests/dev/verify_pause_gate.tscn

var _phase: int = 0
var _frames: int = 0
var _paused_signals: int = 0
var _resumed_signals: int = 0
var _ok_count: int = 0
var _failures: Array[String] = []

var _world: Node
var _always: Node


func _ready() -> void:
	# 验证器自身必须 ALWAYS：pause 后 PAUSABLE 节点（含本脚本）的 _process 一并冻结，
	# 否则采样阶段永远走不到——这本身就是换闸语义的直接证明
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 探针挂 tree root（不挂本节点下——本节点由场景实例化，属测试场景子树）
	print("=== 暂停闸功能验证开始 ===")
	EventBus.game_paused.connect(func(): _paused_signals += 1)
	EventBus.game_resumed.connect(func(): _resumed_signals += 1)

	# 世界子树模拟节点（默认 INHERIT→PAUSABLE）与 ALWAYS 节点各一，挂 root 下
	_world = Node.new()
	_world.set_script(load("res://tests/dev/verify_pause_probe_world.gd"))
	get_tree().root.add_child.call_deferred(_world)
	_always = Node.new()
	_always.set_script(load("res://tests/dev/verify_pause_probe_always.gd"))
	_always.process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().root.add_child.call_deferred(_always)


func _process(_delta: float) -> void:
	_frames += 1
	match _phase:
		0:  # 基线：未暂停，两节点都在 tick
			if _frames < 5:
				return
			_check(_world.ticks > 0, "基线：PAUSABLE 节点在 tick（%d）" % _world.ticks)
			_check(_always.ticks > 0, "基线：ALWAYS 节点在 tick（%d）" % _always.ticks)
			_check(not TimeManager.is_paused(), "基线：is_paused=false")
			_check(not get_tree().paused, "基线：引擎闸未触发")
			# → X2 校验倍速步长
			TimeManager.set_speed(TimeManager.Speed.X2)
			_check(absf(TimeManager.speed_factor() - 2.0) < 0.001, "X2 档 speed_factor=2")
			_check(absf(TimeManager.sim_delta(0.1) - 0.2) < 0.0001, "X2 档 sim_delta(0.1)=0.2")
			_phase = 1
			_frames = 0
		1:  # → 暂停
			TimeManager.pause()
			_phase = 2
			_frames = 0
			_world.set("ticks", 0)
			_always.set("ticks", 0)
		2:  # 暂停期采样
			if _frames < 10:
				return
			_check(TimeManager.is_paused(), "暂停：is_paused=true")
			_check(get_tree().paused, "暂停：引擎总闸 SceneTree.paused=true")
			_check(_paused_signals == 1, "暂停：game_paused 发射 1 次（%d）" % _paused_signals)
			_check(_world.ticks == 0, "暂停：PAUSABLE 节点冻结（tick=%d）" % _world.ticks)
			_check(_always.ticks > 0, "暂停：ALWAYS 节点继续 tick（%d）" % _always.ticks)
			_check(absf(TimeManager.sim_delta(0.1)) < 0.0001, "暂停：sim_delta=0（兜底）")
			TimeManager.set_speed(TimeManager.Speed.X2)  # 模态栈恢复语义：回原速度
			_phase = 3
			_frames = 0
		3:  # 恢复期采样：世界复活、信号、速度回到 X2（非 X1）
			if _frames < 10:
				return
			_check(not get_tree().paused, "恢复：引擎总闸已复位")
			_check(_resumed_signals == 1, "恢复：game_resumed 发射 1 次（%d）" % _resumed_signals)
			_check(_world.ticks > 0, "恢复：PAUSABLE 节点复活（tick=%d）" % _world.ticks)
			_check(TimeManager.current_speed == TimeManager.Speed.X2, "恢复：速度档回 X2（栈语义）")
			_finish()



func _finish() -> void:
	print("=== 汇总：%d 项断言，%d 失败 ===" % [_ok_count + _failures.size(), _failures.size()])
	if _failures.is_empty():
		print("=== 暂停闸功能验证：全部通过 ===")
		get_tree().quit(0)
	else:
		for f in _failures:
			print("[FAIL] " + f)
			get_tree().quit(1)


func _check(cond: bool, label: String) -> void:
	if cond:
		_ok_count += 1
		print("[OK] " + label)
	else:
		_failures.append(label)
