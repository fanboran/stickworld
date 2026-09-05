extends SceneTree
## 烘焙树变体池：当前规格参数 × 10 种子 → assets/resources/tree_paint_tree_v0-9.png
## 运行：godot --headless --path stick-world --script res://tests/dev/tree_bake_pool.gd
const TP := preload("res://tests/dev/tree_pipeline.gd")


func _init() -> void:
	for i: int in 10:
		var tree: Dictionary = TP.build_tree(8000 + i * 13, {}, 2000, 5000)
		var img := TP.rasterize(tree["pens"], tree["trunk_canvas"], tree["crown_canvas"])
		img.save_png("res://assets/resources/tree_paint_tree_v%d.png" % i)
		print("[bake] v%d 完成（落笔 %d）" % [i, (tree["pens"] as Array).size()])
	quit(0)
