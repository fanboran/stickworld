extends Node2D
## 武器图集 MMI 最小对照实验（一次性）：四行并排定性「带 alpha 纹理在 MMI 的渲染行为」
## A 白纹理(对照) / B 导入武器纹理原样 / C 自建图集透明底 / D 不透明品红底图集+discard shader
## 用法：godot --path . res://tests/dev/weapon_probe.tscn（1s 自动截图退出）

const BatchRig := preload("res://modules/units/scripts/rig/stickman_batch_rig.gd")

var _elapsed: float = 0.0


func _ready() -> void:
	var cam := Camera2D.new()
	cam.position = Vector2(400, 300)
	cam.zoom = Vector2(0.8, 0.8)
	add_child(cam)
	cam.make_current()
	# A 白纹理对照（红色识别）
	_mm(100, BatchRig._get_white_tex(), null, Color(1, 0, 0, 1))
	# B 导入武器纹理原样（CompressedTexture2D，带透明背景）
	_mm(250, load("res://modules/units/assets/textures/weapons/spear.png"), null, Color(1, 1, 1, 1))
	# C 自建图集（透明底）：sword + pickaxe blit
	var atlas := Image.create(256, 128, false, Image.FORMAT_RGBA8)
	var simg: Image = (load("res://modules/units/assets/textures/weapons/sword.png") as Texture2D).get_image()
	simg.convert(Image.FORMAT_RGBA8)
	atlas.blit_rect(simg, Rect2i(Vector2i.ZERO, simg.get_size()), Vector2i(4, 4))
	var pimg: Image = (load("res://modules/units/assets/textures/weapons/pickaxe.png") as Texture2D).get_image()
	pimg.convert(Image.FORMAT_RGBA8)
	atlas.blit_rect(pimg, Rect2i(Vector2i.ZERO, pimg.get_size()), Vector2i(132, 4))
	_mm(400, ImageTexture.create_from_image(atlas), null, Color(1, 1, 1, 1))
	# D 不透明品红底图集 + discard shader
	var atlas2 := Image.create(256, 128, false, Image.FORMAT_RGBA8)
	atlas2.fill(Color(1, 0, 1, 1))
	atlas2.blit_rect(simg, Rect2i(Vector2i.ZERO, simg.get_size()), Vector2i(4, 4))
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.r > 0.9 && c.b > 0.9 && c.g < 0.1) discard;
	COLOR = c * COLOR;
}
"""
	_mm(550, ImageTexture.create_from_image(atlas2), sh, Color(1, 1, 1, 1))


func _mm(x: float, tex: Texture2D, sh: Shader, col: Color) -> void:
	var mmi := MultiMeshInstance2D.new()
	mmi.texture = tex
	if sh != null:
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mmi.material = mat
	mmi.position = Vector2(x, 300)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = BatchRig._get_quad_mesh()
	mm.instance_count = 1
	mm.custom_aabb = AABB(Vector3(-4096, -4096, 0), Vector3(16384, 16384, 0))
	var buf := PackedFloat32Array()
	buf.resize(12)
	buf[0] = 96.0
	buf[5] = 96.0
	buf[8] = col.r
	buf[9] = col.g
	buf[10] = col.b
	buf[11] = col.a
	mm.buffer = buf
	mmi.multimesh = mm
	add_child(mmi)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed > 1.0:
		var img := get_viewport().get_texture().get_image()
		img.save_png("res://tests/dev/weapon_probe_out.png")
		get_tree().quit()
