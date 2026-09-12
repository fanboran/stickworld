extends Node2D
## CrowdRenderer 最小复现（v2）：真实战斗实体 ×2，近 zoom 截图。
## 用法：godot --path . res://tests/dev/crowd_probe.tscn（1s 后自动截图退出）

const EntityScene := preload("res://modules/units/scenes/stickman_entity.tscn")
const CrowdRenderer := preload("res://modules/units/scripts/rig/crowd_renderer.gd")

var _crowd: RefCounted = null
var _slots: Array = []
var _elapsed: float = 0.0


func _ready() -> void:
	_crowd = CrowdRenderer.new()
	_crowd.setup(self, 400.0, 700.0)
	# 复现 battle 时序：先渲染两帧（instance_count=0 的 MMI 进过裁剪）再注册——
	# 验证「2D MultiMesh 首帧渲染后改 count 不刷新剔除盒」的引擎缓存假设
	await get_tree().process_frame
	await get_tree().process_frame
	for i in 2:
		var e: Node2D = EntityScene.instantiate()
		e.position = Vector2(500 + i * 120, 500)
		add_child(e)
		if e.has_method("set_possessed"):
			e.set_possessed(false)
		var slot: Dictionary = _crowd.register_unit(e)
		if slot.is_empty():
			push_error("[crowd_probe] register 失败 unit=%d" % i)
			get_tree().quit(1)
			return
		_slots.append(slot)
		var rig: Node = e.get_node("RigHost/OutlineGroup/StickmanRig")
		if rig == null:
			rig = e.get_node("OutlineGroup/StickmanRig")
		rig.play("walk")
		print("[crowd_probe] unit=%d rig=%s scale=%s" % [i, rig, rig.scale])
	# 复现 battle 观察条件：远 zoom 相机（战场全景缩放）
	var cam := Camera2D.new()
	cam.position = Vector2(560, 500)
	cam.zoom = Vector2(0.35, 0.35)
	add_child(cam)
	cam.make_current()


func _physics_process(delta: float) -> void:
	if _slots.is_empty():
		return
	_crowd.tick(delta)
	_elapsed += delta
	if _elapsed > 1.0 and _elapsed < 1.1:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://tests/dev/crowd_probe_out.png")
		print("[crowd_probe] saved")
		get_tree().quit(0)
