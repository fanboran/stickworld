extends Node
## 验证程序化叠加层：idle 呼吸 + 移动惯性是否真的叠加到骨骼

const STICKMAN_SCENE: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")


func _ready() -> void:
	var entity: Node2D = STICKMAN_SCENE.instantiate()
	add_child(entity)
	for i in 5:
		await get_tree().process_frame
	var rig: Node = entity.get("rig")
	var skeleton: Node2D = rig as Skeleton2D  # rig 就是 StickmanRig (Skeleton2D)
	print("rig:", rig, " skeleton:", skeleton)
	var head: Node2D = skeleton.get_node_or_null("hip/lower_torso/upper_torso/neck/head")
	if head == null:
		head = skeleton.get_node_or_null("hip/lower_torso/upper_torso/neck")
	var hip: Node2D = skeleton.get_node_or_null("hip")
	print("head:", head, " hip:", hip)
	if head == null:
		print("验证失败：找不到骨骼")
		get_tree().quit(1)
		return
	# idle 呼吸：head rotation 应随时间正弦波动（3 个采样点）
	# 同时采样 global_rotation（渲染用全局变换）：若叠加层只改本地、渲染未生效，
	# 则 local 波动而 global 恒定。
	var samples: Array[float] = []
	var gsamples: Array[float] = []
	for i in 12:
		await get_tree().create_timer(0.1).timeout
		samples.append(rad_to_deg(head.rotation))
		gsamples.append(rad_to_deg(head.global_rotation))
	var fmt: Array[String] = []
	for s in samples:
		fmt.append("%.2f" % s)
	print("idle head rotation 12 采样: ", fmt)
	var gfmt: Array[String] = []
	for s in gsamples:
		gfmt.append("%.2f" % s)
	print("idle head global_rotation 12 采样: ", gfmt)
	var mn: float = samples[0]
	var mx: float = samples[0]
	for s in samples:
		mn = minf(mn, s)
		mx = maxf(mx, s)
	var spread := mx - mn
	var gmn: float = gsamples[0]
	var gmx: float = gsamples[0]
	for s in gsamples:
		gmn = minf(gmn, s)
		gmx = maxf(gmx, s)
	var gspread := gmx - gmn
	print("idle head 本地波动: %.2f° %s | 全局波动: %.2f° %s" % [
		spread, "OK" if spread > 0.3 else "弱",
		gspread, "OK（渲染生效）" if gspread > 0.3 else "不生效（渲染用旧全局变换）"
	])
	# 移动惯性：切 walk + 连续移动（位置差分驱动 lean）
	var r2: Node = entity.get("rig")
	if r2 != null and r2.has_method("play"):
		r2.play("walk")
	var walk_torso: Node2D = skeleton.get_node_or_null("hip/lower_torso")
	var lean_samples: Array[float] = []
	for i in 6:
		await get_tree().process_frame
		entity.global_position += Vector2(2.0, 0.0)  # 每帧移动 2px ≈ 120px/s
		lean_samples.append(rad_to_deg(walk_torso.rotation))
	var lean_fmt: Array[String] = []
	for s in lean_samples:
		lean_fmt.append("%.2f" % s)
	print("walk torso rotation 6 采样: ", lean_fmt)
	print("验证完成")
	get_tree().quit(0)
