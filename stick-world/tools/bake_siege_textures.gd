extends SceneTree
## 离线烘焙守城战石质贴图：城墙段（带垛口 alpha 镂空）+ 城门（拱门立面）。
## 用法：godot --headless --script tools/bake_siege_textures.gd --path .
## 产物（提交进仓库，运行时直接 load，不再依赖生成代码）：
##   assets/environment/siege_wall_seg.png
##   assets/environment/siege_gate.png

const OUT_DIR := "res://assets/environment"


func _init() -> void:
	# 城墙段：512×478 墙身（运行时按 region 竖向裁切拼接）+ 34 垛口
	var seg := StoneBrickGen.make_crenellated(512, 478, 20260906, 34, 56, Vector2i(64, 30))
	var err1 := seg.save_png(_out("siege_wall_seg.png"))
	# 城门：440×280 立面（与 SiegeWall.GATE_H 对齐），门洞 150×170
	var gate := StoneBrickGen.make_gate(440, 280, 20260907, Vector2i(150, 170))
	var err2 := gate.save_png(_out("siege_gate.png"))
	print("[bake_siege] wall_seg(%dx%d) err=%d, gate(%dx%d) err=%d" % [
		seg.get_width(), seg.get_height(), err1, gate.get_width(), gate.get_height(), err2])
	quit(0 if err1 == OK and err2 == OK else 1)


func _out(name: String) -> String:
	return OUT_DIR.path_join(name)
