class_name FxDamageTextPool
extends RefCounted
## 伤害飘字池域 —— 伤害数字 Label 的复用池 + 出生/跟随/淡出表现（Demo 打磨包）。
##
## 从 FxLibrary 拆出（伤害飘字本就是一个可命名的域）：池状态、出池/回池、
## 飘字生成与退出清理全在此。外部签名由 FxLibrary.spawn_damage_text 薄转发保住
## （消费点：combat/DamagePipeline.apply、tests/integration/test_fx_damage_text）。
## 坐标口径（视觉域重映射 + 髋抬升）是跨域协议，仍归 FxLibrary.remap_body_pos。

## 飘字复用池（战斗性能优化：混战每秒几十次 Label.new+Tween 创建销毁，
## 池化后 Label 只建一次反复改文本/位置重飘；场景切换后失效引用自动丢弃）
## 生命周期：spawn 淡出回池（写入）→ GameRoot._exit_tree 经
## FxLibrary.clear_runtime_pools() 清空（清理）。池中 Label 挂 tree.current_scene，
## 随场景释放；不清则静态数组跨退出/重建携带悬置 Label 引用。
static var _pool: Array = []


## 生命周期出口：清空飘字复用池（GameRoot._exit_tree 聚合出口调用）。逐条
## is_instance_valid 守卫（与出池路径同一防御风格）：悬垂引用直接丢弃；仍存活
## 的 Label（含 deferred add_child 尚未落树的无父孤儿）queue_free 延迟释放——
## 退出期直接 free 会与场景自身拆除交扰。行为零变化：这些 Label 本就随场景销毁，
## 这里只是断掉静态持有并提前收掉无父孤儿。
static func clear() -> void:
	for entry in _pool:
		if entry is Node and is_instance_valid(entry):
			entry.queue_free()
	_pool.clear()


## 出池：弹出一个存活 Label 复用；池空/全悬垂则新建（deferred 挂 current_scene）。
static func _acquire(tree: SceneTree) -> Label:
	var label: Label = null
	if not _pool.is_empty():
		# 弹出到无类型临时再判活：池里可能有场景切换时被释放的悬垂引用，
		# 直接赋给类型化变量会在赋值处报错（场景切换后的首波伤害必现）
		var popped = _pool.pop_back()
		if is_instance_valid(popped):
			label = popped
	if label == null:
		label = Label.new()
		label.z_index = 90
		# deferred：伤害结算发生在物理帧内，同帧改树会挤掉其他节点的帧处理（血条时序交扰）
		tree.current_scene.add_child.call_deferred(label)
	return label


## 回池：淡出终点回收（隐藏 + 入池待复用；tween 收尾回调调用）。
static func _release(label: Label) -> void:
	if is_instance_valid(label):
		label.visible = false
	_pool.append(label)


## 在目标头顶飘伤害数字（白=普通 / 金=暴击·爆头）；出生弹性回落 + 恒定屏上尺寸；
## 0.7s 上浮淡出后回池。combat 管线（DamagePipeline.apply）结算后调用；fx 挂目标宿主层，不进战斗逻辑。
## 锚点 = 目标原点（HD-2D 图 = 视觉脚线），经 remap_body_pos 抬到身体高度后再叠
## 内部 -62 头顶偏移——不抬的话数字落在目标脚面上（本轮"火柴人与特效错位"根因）。
## 传 target 时数字**跟随目标**：命中后目标继续移动/被击退，定死出生点的数字会
## 蹦在"命中瞬间目标所在、现在已经空了"的位置（混战里人人都在动 = 处处蹦空气）。
## 屏上恒定口径：字号除以 zoom 后钳制（保可读），**偏移用真实 1/zoom**（跟随头顶）——
## 旧写法 inv_zoom = 钳后字号/基准字号，钳制生效时偏移塌缩、数字贴脚面。
static func spawn(tree: SceneTree, pos: Vector2, amount: float, crit: bool,
		target: Node2D = null) -> void:
	if tree == null or tree.current_scene == null:
		return
	pos = FxLibrary.remap_body_pos(tree, pos)
	var label := _acquire(tree)
	# 恒定屏上尺寸：字号 = 基准/zoom 再钳制（可读下限）；屏上偏移 = 真实 1/zoom
	#（钳制只影响字号不影响偏移——两者解耦，见函数头注释）
	var cam := tree.root.get_viewport().get_camera_2d()
	var zoom: float = clampf(cam.zoom.x if cam != null else 1.0, 0.35, 3.0)
	var base_px: float = 17.0 if crit else 12.0
	var font_px: int = int(round(clampf(base_px / zoom, 11.0, 28.0)))
	var inv_zoom: float = 1.0 / zoom
	label.visible = true
	label.text = str(int(round(amount)))
	label.add_theme_font_size_override("font_size", font_px)
	label.add_theme_constant_override("outline_size", clampi(font_px / 4, 4, 12))
	if crit:
		label.add_theme_color_override("font_color", Color(1.0, 0.82, 0.35))
		label.add_theme_color_override("font_outline_color", Color(0.45, 0.2, 0.0, 0.9))
	else:
		label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.98))
		label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	# 随机水平偏移防数字完全重叠（出生时定死，跟随期保持个体错位）
	var jitter_x := randf_range(-16.0, 16.0) * inv_zoom
	# current_scene 在原点，local==global
	label.position = pos + Vector2(jitter_x, -62.0 * inv_zoom)
	label.modulate.a = 1.0
	label.rotation = 0.0
	# 出生弹性：放大起手回落带轻微回弹（TRANS_BACK 过冲）；暴击冲击更强并带一点歪斜回正
	label.reset_size()
	label.pivot_offset = label.size * 0.5
	label.scale = Vector2.ONE * (1.55 if crit else 1.3)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "scale", Vector2.ONE, 0.18 if crit else 0.13) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	if crit:
		label.rotation = randf_range(-0.09, 0.09)
		tween.tween_property(label, "rotation", 0.0, 0.22).set_ease(Tween.EASE_OUT)
	if target != null:
		# 跟随目标：每帧重取目标位置重映射（地面锚压缩 + 髋抬升）再叠头顶偏移
		# 与上浮进度。目标经 weakref 弱引用——直接捕获对象的话，目标中途被释放
		# 会让引擎逐 tick 报 "Lambda capture was freed"（实测 195 条/场）
		var target_ref: WeakRef = weakref(target)
		var follow := func(t: float) -> void:
			var t_obj: Node2D = target_ref.get_ref()
			if t_obj == null:
				return
			var base: Vector2 = FxLibrary.remap_body_pos(tree, t_obj.global_position)
			label.position = base + Vector2(jitter_x, (-62.0 - 52.0 * t) * inv_zoom)
		tween.tween_method(follow, 0.0, 1.0, 0.7).set_ease(Tween.EASE_OUT)
	else:
		tween.tween_property(label, "position:y", label.position.y - 52.0 * inv_zoom, 0.7).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.45).set_delay(0.25)
	tween.chain().tween_callback(func() -> void: _release(label))
