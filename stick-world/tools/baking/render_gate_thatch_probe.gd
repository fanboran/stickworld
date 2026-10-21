extends SceneTree
## 静态审计观感验收出图：石砖门洞越界钳制 + 茅草笔触负坐标 floori。
##
## 纯 CPU 出图（无 SubViewport/无 GPU 依赖），headless 可跑：
##   godot --headless --path stick-world --script res://tools/baking/render_gate_thatch_probe.gd
## 输出：四张 PNG 存 <worktree>/temp/（路径见 stdout）。
##
## 图一 gate_default            make_gate 默认门洞（正常观感基准，回归参照）
## 图二 gate_oversized_opening  opening 超图幅（旧版 set_pixel 报错刷屏，现逐边钳进画布）
## 图三 thatch_texture          茅草笔触整张观感（applier 现行参数直出）
## 图四 thatch_corner_negative  笔触圆心落在负坐标区、越左上缘（旧 int() 截断致 1px 错位，
##                              现 floori；×4 最近邻放大便于看边缘覆盖）

const OUT_DIR := "F:/VSCode/game-2/.temp/wf-static/temp"


func _initialize() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

	# ── 石砖门洞 ──
	var brick: GDScript = load("res://modules/texture_gen/scripts/stone_brick_gen.gd")
	# 画布高须容下默认门洞全形（直壁 190 + 拱半径 75）
	var gate_default: Image = brick.call("make_gate", 320, 300, 7)
	_save(gate_default, "gate_default.png")

	# 越界门洞：opening(200,260) 远超画布 128x96（半宽 100 > 中心 64，直壁 260 > 高 96）
	var gate_over: Image = brick.call("make_gate", 128, 96, 7, Vector2i(200, 260))
	_save(gate_over, "gate_oversized_opening.png")

	# ── 茅草笔触 ──
	var applier: Node = load("res://modules/texture_gen/materials/thatch/scripts/thatch_applier.gd").new()
	var thatch_tex: ImageTexture = applier.call("_generate_brush_texture", 160, 120, -30.0, 11)
	_save(thatch_tex.get_image(), "thatch_texture.png")

	# 角落探针：灰格底 + 一条起点在负坐标区的笔触（圆心扫过 x<0/y<0 区域）
	var probe := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	for yy in 96:
		for xx in 96:
			var grid := 12
			var c := Color(0.55, 0.55, 0.58) if (xx / grid + yy / grid) % 2 == 0 \
					else Color(0.42, 0.42, 0.46)
			probe.set_pixel(xx, yy, c)
	applier.call("_draw_brush_stroke_opaque", probe,
			-24.0, -16.0, 48.0, 40.0, 12.0,
			_set_seed(RandomNumberGenerator.new(), 23), 96, 96,
			Color(0.75, 0.45, 0.18))
	var zoomed := Image.create(96, 96, false, Image.FORMAT_RGBA8)
	zoomed.blend_rect(probe, Rect2i(0, 0, 96, 96), Vector2i.ZERO)
	zoomed.resize(384, 384, Image.INTERPOLATE_NEAREST)
	_save(zoomed, "thatch_corner_negative.png")

	applier.free()
	print("[gate_thatch_probe] done -> ", OUT_DIR)
	quit(0)


func _set_seed(rng: RandomNumberGenerator, seed_value: int) -> RandomNumberGenerator:
	rng.seed = seed_value
	return rng


func _save(img: Image, file_name: String) -> void:
	var path := OUT_DIR + "/" + file_name
	var err := img.save_png(path)
	print("[gate_thatch_probe] %s -> %s (err=%d)" % [file_name, path, err])
