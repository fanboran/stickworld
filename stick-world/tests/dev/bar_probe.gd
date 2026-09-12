extends Node2D
## 血条/圆点 观感对比特写（无角色）：上半区 = 原版 indicator 自绘（main 观感），
## 下半区 = CrowdRenderer 血条桶（数据模式真实链路）。同屏同状态并排对比。
## 用法：godot --path . res://tests/dev/bar_probe.tscn（1.2s 自动截图退出）
## 身体桶/阴影桶/武器桶 MMI 在此隐藏——只留 CrowdDots/CrowdBars。

const CrowdRenderer := preload("res://modules/units/scripts/rig/crowd_renderer.gd")
const Indicator := preload("res://modules/units/scripts/entity/health_bar_indicator.gd")

const RATIOS := [1.0, 0.8, 0.6, 0.4, 0.2, 0.05]
const ROW_RICH_A := 120.0
const ROW_RICH_B := 240.0
const ROW_CROWD_A := 420.0
const ROW_CROWD_B := 540.0

var _crowd: RefCounted = null
var _elapsed: float = 0.0


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
	var cam := Camera2D.new()
	cam.position = Vector2(330, 330)
	cam.zoom = Vector2(2.0, 2.0)
	add_child(cam)
	cam.make_current()
	_crowd = CrowdRenderer.new()
	_crowd.setup(self, 340.0, 620.0)
	# 桶侧对比区：两行 × 两阵营 × 6 血量态
	for faction in 2:
		for r in RATIOS.size():
			_spawn(Vector2(90 + r * 96, ROW_CROWD_A if faction == 0 else ROW_CROWD_B),
					faction + 1, RATIOS[r], true)
	# 原版自绘对比区：同款状态（不 register，走 _draw）
	for faction in 2:
		for r in RATIOS.size():
			_spawn(Vector2(90 + r * 96, ROW_RICH_A if faction == 0 else ROW_RICH_B),
					faction + 1, RATIOS[r], false)
	# 只留血条桶：身体 4 桶/阴影/武器 MMI 全部隐藏（对比场景无角色）
	var layer := get_node("CrowdLayer")
	for c in layer.get_children():
		if c.name in ["CrowdDots", "CrowdBars"]:
			continue
		c.visible = false


func _spawn(pos: Vector2, faction: int, ratio: float, use_crowd: bool) -> void:
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
	if ratio == 1.0:
		if use_crowd:
			_crowd_first = ind
		else:
			_rich_first = ind
	ind._max_hp = 100.0
	ind._ratio = ratio
	ind._faction = faction
	ind._ever_damaged = ratio < 1.0
	ind._trail_ratio = 1.0
	ind._expand = 1.0 if ratio < 1.0 else 0.0
	if use_crowd:
		ind.set_crowd_data_mode(true)
		_crowd.register_unit(unit)
	print("[bar-probe] spawn ratio=", ratio, " pos=", pos, " ind_pos=", ind.position,
			" visible=", ind.visible, " shown=", ind._shown, " expand=", ind._expand,
			" ever=", ind._ever_damaged, " ever_ratio=", ind._ratio,
			" ai_found=", unit.get_node_or_null("AIController") != null,
			" ai_has_m=", unit.get_node_or_null("AIController") != null and unit.get_node_or_null("AIController").has_method("is_under_threat"))


var _rich_first: Node = null
var _crowd_first: Node = null


func _process(delta: float) -> void:
	_crowd.tick(delta)
	_elapsed += delta
	if _elapsed > 1.2:
		if _rich_first != null:
			print("[bar-probe] rich shown=", _rich_first._shown, " expand=", _rich_first._expand,
					" ratio=", _rich_first._ratio, " visible=", _rich_first.visible,
					" in_tree=", _rich_first.is_visible_in_tree(), " in_combat=", _rich_first._in_combat,
					" processing=", _rich_first.is_processing(), " timer=", _rich_first._threat_timer)
		if _crowd_first != null:
			var st: Dictionary = _crowd_first.get_bar_state()
			print("[bar-probe] crowd st=", st)
			print("[bar-probe] dots ic=", _crowd._dot_mm.instance_count, " cap=", _crowd._dot_cap,
					" buf0=", _crowd._dot_buf.slice(0, 16))
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://tests/dev/bar_probe_out.png")
		get_tree().quit()
