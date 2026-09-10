extends Node
## 临时探针：实体场景装配后的节点树/脚本/rig 引用（批次 B 排障用，用完可留作 dev）
func _ready() -> void:
	var e: Node = load("res://modules/units/scenes/stickman_entity.tscn").instantiate()
	add_child(e)
	for i in 4:
		await get_tree().process_frame
	print("[probe] entity=", e, " script=", e.get_script())
	print("[probe] entity children=", e.get_children())
	var rh: Node = e.get_node_or_null("RigHost")
	print("[probe] RigHost=", rh)
	if rh != null:
		print("[probe]   children=", rh.get_children())
	print("[probe] rig=", e.get("rig"))
	print("[probe] rig_host_path ok=", rh != null and rh.get_node_or_null("OutlineGroup/StickmanRig") != null)
	# 骨骼 API 抽查
	var rig: Node = e.get("rig")
	if rig != null and rig.has_method("get_bone_names"):
		var names: Array = rig.get_bone_names()
		print("[probe] bones=", names.size(), " has pickaxe1=", "pickaxe1" in names, " has Arrow1=", "Arrow1" in names)
	print("[probe] weapon node=", e.call("get_weapon") if e.has_method("get_weapon") else "n/a")
	# 单独实例化 rig 场景，隔离"实例化失败"还是"挂载失败"
	var ps: PackedScene = load("res://modules/units/scenes/stickman_test.tscn")
	print("[probe] rig scene loaded=", ps)
	if ps != null:
		var ir: Node = ps.instantiate()
		print("[probe] standalone rig children=", ir.get_children())
		ir.queue_free()
	var es: PackedScene = load("res://modules/units/scenes/stickman_entity.tscn")
	print("[probe] entity scene state=", es.get_state())
	get_tree().quit(0)
