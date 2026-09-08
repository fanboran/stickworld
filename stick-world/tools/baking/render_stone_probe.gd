extends SceneTree
## 材质路径最小渲染实验（批次 2 前置验证）——判定哪条路能出石头笔触。
##
## 背景：本环境 Polygon2D 的 uv 纹理采样曾坍缩为纹理平均色（平涂），
## stone ShaderMaterial 同样走 canvas shader 的 UV——需实测确认可用路径。
##
## 六格矩阵（2 行 × 3 列）：
##   A Polygon2D + uv 全 0..1  + CPU 石纹理   （复现坍缩？）
##   B Polygon2D + uv 收窄开区间 + CPU 石纹理 （smithy 批次 1 补救法）
##   C Sprite2D + CPU 石纹理                  （对照组，已知可靠）
##   D Sprite2D + stone_wall ShaderMaterial   （GPU 程序化石砖）
##   E Polygon2D + stone_wall ShaderMaterial  （GPU 在 P2D 上是否平涂）
##   F Sprite2D + region 平铺（×2 宽）        （拉伸平铺路径）
##
## 运行（非 headless，SubViewport 需要 GPU）：
##   godot --path stick-world --script res://tools/baking/render_stone_probe.gd
## 输出：user://stone_probe_render.png + 每格像素标准差判定（stdout）。
## 判据：格内 RGB 标准差 < 0.01 = 平涂；> 0.03 = 有笔触/结构。

const CELL_W := 220
const CELL_H := 140
const COLS := 3
const ROWS := 2


func _initialize() -> void:
	_run()


func _run() -> void:
	var sub := SubViewport.new()
	sub.size = Vector2i(CELL_W * COLS, CELL_H * ROWS)
	sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world := Node2D.new()
	sub.add_child(world)
	root.add_child(sub)

	var bg := ColorRect.new()
	bg.color = Color(0.10, 0.10, 0.12)
	bg.size = Vector2(CELL_W * COLS, CELL_H * ROWS)
	world.add_child(bg)

	# CPU 石纹理（不引用全局类名：load 脚本再调静态方法）
	var brick_script: GDScript = load("res://modules/texture_gen/scripts/stone_brick_gen.gd")
	var stone_img: Image = brick_script.call("make_wall", 128, 140, 7)
	var stone_tex: ImageTexture = ImageTexture.create_from_image(stone_img)
	var solid_script: GDScript = load("res://modules/texture_gen/scripts/procedural_materials.gd")
	var white_tex: ImageTexture = solid_script.call("make_solid", 128, 140, Color(0.8, 0.8, 0.8))

	var api_script: GDScript = load("res://modules/texture_gen/api.gd")

	# ── A: Polygon2D + uv 全 0..1 ──
	_add_poly(world, 0, stone_tex, PackedVector2Array([
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]), null)
	# ── B: Polygon2D + uv 收窄开区间 ──
	_add_poly(world, 1, stone_tex, PackedVector2Array([
		Vector2(0.005, 0.005), Vector2(0.995, 0.005),
		Vector2(0.995, 0.995), Vector2(0.005, 0.995)]), null)
	# ── C: Sprite2D + CPU 石纹理 ──
	_add_sprite(world, 2, stone_tex)
	# ── D: Sprite2D + stone_wall ShaderMaterial ──
	var d := _add_sprite(world, 3, white_tex)
	var mat_d: ShaderMaterial = api_script.call("load_shader_material", &"stone_wall")
	mat_d.set_shader_parameter("resolution", Vector2(CELL_W, CELL_H))
	d.material = mat_d
	# ── E: Polygon2D + stone_wall ShaderMaterial ──
	var e := _add_poly(world, 4, white_tex, PackedVector2Array([
		Vector2(0.005, 0.005), Vector2(0.995, 0.005),
		Vector2(0.995, 0.995), Vector2(0.005, 0.995)]), null)
	var mat_e: ShaderMaterial = api_script.call("load_shader_material", &"stone_wall")
	mat_e.set_shader_parameter("resolution", Vector2(CELL_W, CELL_H))
	e.material = mat_e
	# ── F: Sprite2D + region 平铺 ×2 ──
	var f := _add_sprite(world, 5, stone_tex)
	f.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	f.region_enabled = true
	f.region_rect = Rect2(0, 0, 256, 140)

	# 等 GPU 渲染若干帧
	for i in 8:
		await process_frame
	var img: Image = sub.get_texture().get_image()
	var out := "user://stone_probe_render.png"
	img.save_png(out)
	print("[stone_probe] saved: ", ProjectSettings.globalize_path(out))

	# ── 逐格像素判定 ──
	var names := ["A_P2D_uv_full", "B_P2D_uv_inset", "C_Sprite2D", "D_Sprite2D_shader", "E_P2D_shader", "F_Sprite2D_region"]
	for i in names.size():
		var cx := (i % COLS) * CELL_W
		var cy := (i / COLS) * CELL_H
		var mean := 0.0
		var sq := 0.0
		var n := 0
		# 中心区域采样，避开格间边界
		for yy in range(cy + 20, cy + CELL_H - 20, 2):
			for xx in range(cx + 20, cx + CELL_W - 20, 2):
				var c := img.get_pixel(xx, yy)
				var lum := (c.r + c.g + c.b) / 3.0
				mean += lum
				sq += lum * lum
				n += 1
		mean /= float(n)
		sq /= float(n)
		var std := sqrt(maxf(sq - mean * mean, 0.0))
		var verdict := "平涂!" if std < 0.01 else ("有笔触" if std > 0.03 else "弱笔触")
		print("[stone_probe] %s: std=%.4f -> %s" % [names[i], std, verdict])
	quit(0)


## 在第 idx 格放置 Polygon2D（局部坐标以格左上为原点）
func _add_poly(world: Node2D, idx: int, tex: ImageTexture, uvs: PackedVector2Array, _unused) -> Polygon2D:
	var cx := (idx % COLS) * CELL_W
	var cy := (idx / COLS) * CELL_H
	var p := Polygon2D.new()
	p.polygon = PackedVector2Array([
		Vector2(cx + 10, cy + 10), Vector2(cx + CELL_W - 10, cy + 10),
		Vector2(cx + CELL_W - 10, cy + CELL_H - 10), Vector2(cx + 10, cy + CELL_H - 10)])
	p.uv = uvs
	p.texture = tex
	world.add_child(p)
	return p


func _add_sprite(world: Node2D, idx: int, tex: ImageTexture) -> Sprite2D:
	var cx := (idx % COLS) * CELL_W
	var cy := (idx / COLS) * CELL_H
	var s := Sprite2D.new()
	s.centered = false
	s.position = Vector2(cx + 10, cy + 10)
	s.scale = Vector2((CELL_W - 20.0) / tex.get_width(), (CELL_H - 20.0) / tex.get_height())
	s.texture = tex
	world.add_child(s)
	return s
