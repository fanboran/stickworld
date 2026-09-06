extends SceneTree
## 离线烘焙守城战石质贴图：城墙段（带垛口 alpha 镂空）+ 城门（拱门立面）。
## 用法：godot --headless --script tools/bake_siege_textures.gd --path .
## 产物（提交进仓库，运行时直接 load，不再依赖生成代码）：
##   assets/environment/siege_wall_seg.png
##   assets/environment/siege_gate.png

const OUT_DIR := "res://assets/environment"


func _init() -> void:
	# 城墙段：512×512 纯侧砖立面（无垛口——齿朝战场侧看不见，墙顶走马道+矮墙）
	var seg := StoneBrickGen.make_wall(512, 512, 20260906, Vector2i(64, 30), false)
	var err1 := seg.save_png(_out("siege_wall_seg.png"))
	# 城墙马道面（俯视砖铺：无受光渐变，战场视角的墙顶上表面）
	var top := StoneBrickGen.make_wall(512, 320, 20260908, Vector2i(56, 30), true)
	var err2 := top.save_png(_out("siege_top_face.png"))
	print("[bake_siege] wall_seg(%dx%d) err=%d, top(%dx%d) err=%d" % [
		seg.get_width(), seg.get_height(), err1, top.get_width(), top.get_height(), err2])
	quit(0 if err1 == OK and err2 == OK else 1)


func _out(name: String) -> String:
	return OUT_DIR.path_join(name)
