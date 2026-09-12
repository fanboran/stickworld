extends Node2D
## 血条/圆点 像素级 A/B 对比特写（无角色）：
##   --row=rich   原版 indicator 自绘（main 观感基准）
##   --row=crowd  CrowdRenderer 血条桶（数据模式真实链路）
## 两跑同布局同坐标，产物 tests/dev/bar_ab_rich.png / bar_ab_crowd.png，
## 经 tools/diff_png.py 逐像素比对（像素级验收闭环）。
##
## 确定性钉死（diff 归零的前提）：
## - _update_hz=0 冻结状态机（_shown/_anim_time/_wobble_seed 不再被改写）；
## - wobble seed 按列钉在预烘相位表（满血列恒 0——原版未掉血圆点即 seed 0
##   静止；掉血列钉 1..7 遍历全部相位组网格）；
## - 无 shader TIME 依赖（wobble 数值 CPU 预烘进网格）。
## 身体/阴影/武器 MMI 在此隐藏——只留血条 4 组桶。

const CrowdRenderer := preload("res://modules/units/scripts/rig/crowd_renderer.gd")
const BatchRig := preload("res://modules/units/scripts/rig/stickman_batch_rig.gd")
const Indicator := preload("res://modules/units/scripts/entity/health_bar_indicator.gd")

const RATIOS := [1.0, 0.8, 0.6, 0.4, 0.2, 0.05]
const ROW_A := 120.0
const ROW_B := 240.0

var _crowd: RefCounted = null
var _elapsed: float = 0.0
var _use_crowd := false


class FakeRig extends Node2D:
	var body_color := Color(0.156, 0.156, 0.156)
	var outline_color := Color(0.9, 0.9, 0.9)
	var _hook := Callable()
	func set_crowd_hook(c: Callable) -> void:
		_hook = c
	func is_crowd_proxied() -> bool:
		return _hook.get_object() != null


class FakeAI extends Node:
	func is_under_threat() -> bool:
		return true


class FakeBattle extends Node:
	func is_active() -> bool:
		return true


class FakeUnit extends Node2D:
	var _fake_battle := FakeBattle.new()
	func get_battle_instance() -> Node:
		return _fake_battle


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--row="):
			_use_crowd = a.get_slice("=", 1) == "crowd"
	var cam := Camera2D.new()
	cam.position = Vector2(330, 330)
	cam.zoom = Vector2(2.0, 2.0)
	add_child(cam)
	cam.make_current()
	if _use_crowd:
		_crowd = CrowdRenderer.new()
		_crowd.setup(self, 100.0, 300.0)
	# 两行 × 两阵营 × 6 血量态（满血点 + 5 档血量条）；两跑坐标一致
	for faction in 2:
		for r in RATIOS.size():
			_spawn(Vector2(90 + r * 96, ROW_A if faction == 0 else ROW_B),
					faction + 1, RATIOS[r], r)
	if _use_crowd:
		# 只留血条 6 组桶：身体 4 桶/阴影/武器 MMI 全部隐藏（对比场景无角色）
		var layer := get_node("CrowdLayer")
		for c in layer.get_children():
			if c.name.begins_with("CrowdBar") or c.name.begins_with("CrowdDot"):
				continue
			c.visible = false
	print("[bar-probe] mode=", "crowd" if _use_crowd else "rich")


func _spawn(pos: Vector2, faction: int, ratio: float, col: int) -> void:
	var unit := FakeUnit.new()
	unit.position = pos
	var rig := FakeRig.new()
	rig.name = "StickmanRig"
	var rig_host := Node2D.new()
	rig_host.name = "OutlineGroup"
	rig_host.add_child(rig)
	unit.add_child(rig_host)
	var ai := FakeAI.new()
	ai.name = "AIController"
	unit.add_child(ai)
	var ind := Node2D.new()
	ind.set_script(Indicator)
	ind.name = "HealthBar"
	unit.add_child(ind)
	add_child(unit)
	# 钉状态：满血列 seed=0（原版未掉血圆点静止），掉血列钉 1..7 遍历相位组
	var seed_k := 0
	if ratio < 1.0:
		seed_k = 1 + (faction * RATIOS.size() + col) % (BatchRig.WOBBLE_VARIANTS - 1)
	ind._max_hp = 100.0
	ind._ratio = ratio
	ind._faction = faction
	ind._ever_damaged = ratio < 1.0
	ind._trail_ratio = 1.0
	ind._expand = 1.0 if ratio < 1.0 else 0.0
	ind._shown = 1.0
	ind.modulate.a = 1.0
	ind._anim_time = 0.0
	ind._wobble_seed = seed_k
	ind._update_hz = 0.0  # 冻结状态机
	ind.queue_redraw()
	if _use_crowd:
		ind.set_crowd_data_mode(true)
		_crowd.register_unit(unit)


func _process(delta: float) -> void:
	if _use_crowd:
		_crowd.tick(delta)
	_elapsed += delta
	if _elapsed > 0.5:
		var img := get_viewport().get_texture().get_image()
		var tag := "crowd" if _use_crowd else "rich"
		img.save_png("res://tests/dev/bar_ab_%s.png" % tag)
		print("[bar-probe] saved bar_ab_%s.png" % tag)
		get_tree().quit()
