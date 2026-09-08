extends SceneTree
## 渲染建筑内饰验收图（批次 4）：4 类建筑逐一渲染「进屋状态」
## （set_state OPERATIONAL + _set_transparent(true)：前景柱/屋顶淡出 + Interior 可见）。
## 运行（非 headless，SubViewport 需要 GPU）：
##   godot --path stick-world --script res://tools/baking/render_interior.gd
## 输出：user://interior_render_<def_id>.png（日志打印全局路径）
## 注意：--script 模式下全局类名解析不可靠，一律 duck typing + 枚举字面量。

const TARGETS := [
	["placeholder", "res://modules/building_gen/buildings/placeholder.tscn"],
	["barracks", "res://modules/building_gen/buildings/barracks.tscn"],
	["warehouse", "res://modules/building_gen/buildings/warehouse.tscn"],
	["smithy_lv1", "res://modules/building_gen/buildings/smithy_lv1.tscn"],
]
const VW := 900
const VH := 600
const GROUND_Y := 470.0


func _initialize() -> void:
	_run()


func _run() -> void:
	for target in TARGETS:
		var def_id: String = target[0]
		var path: String = target[1]
		var scene: PackedScene = load(path)
		if scene == null:
			push_error("[render_interior] 场景加载失败: " + path)
			quit(1)
			return
		var sub := SubViewport.new()
		sub.size = Vector2i(VW, VH)
		sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var world := Node2D.new()
		sub.add_child(world)
		root.add_child(sub)
		# 背景：暗色天 + 草地条（区分室内地面与室外）
		var bg := ColorRect.new()
		bg.color = Color(0.09, 0.09, 0.11)
		bg.size = Vector2(VW, VH)
		world.add_child(bg)
		var grass := ColorRect.new()
		grass.color = Color(0.16, 0.22, 0.12)
		grass.position = Vector2(0, GROUND_Y)
		grass.size = Vector2(VW, VH - GROUND_Y)
		world.add_child(grass)
		var b: Node2D = scene.instantiate()
		world.add_child(b)
		# ⚠️ _initialize 上下文中 root 尚未进树，add_child 的 _ready（程序化装配）延迟到
		# 第一帧——必须先等一帧再驱动状态，否则 set_state/_set_transparent 全部落空
		# （症状：首栋裸壳图 + "Tween started with no Tweeners"）
		await process_frame
		b.position = Vector2(VW * 0.5 - float(b.get("width")) * 16.0, GROUND_Y)
		# 落成态（PLANNED 是 0.3 蓝图半透明）+ 进屋态（前景淡出/Interior 可见）
		if b.has_method("set_state"):
			b.call("set_state", 2)  # Building.State.OPERATIONAL
		if b.has_method("_set_transparent"):
			b.call("_set_transparent", true)
		# 等 @tool 装配 + 纹理就绪 + 透明化渐变（0.2s，--script 模式帧率不稳多等）
		for i in 45:
			await process_frame
		var img := sub.get_texture().get_image()
		var out := "user://interior_render_%s.png" % def_id
		img.save_png(out)
		print("[render_interior] saved: ", ProjectSettings.globalize_path(out))
		sub.queue_free()
		root.remove_child(sub)
	quit(0)
