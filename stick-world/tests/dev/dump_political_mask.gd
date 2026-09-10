extends SceneTree
## feedback2 临时诊断：dump L3/L2 政治 ID mask 的原始/导入纹理像素值（用完即删）

func _init() -> void:
	# L3：渲染器同路径（FileAccess 原始字节解码）
	var f := FileAccess.open("res://config/strategic_map/l3_political_id_8192.png", FileAccess.READ)
	var img := Image.new()
	var err := img.load_png_from_buffer(f.get_buffer(f.get_length()))
	print("L3 raw err=", err, " fmt=", img.get_format(), " size=", img.get_size())
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	print("L3 raw @anchor(5917,2950)=", int(img.get_pixel(5917, 2950).r * 255.0 + 0.5),
			" @(6080,2990)(海)=", int(img.get_pixel(6080, 2990).r * 255.0 + 0.5),
			" @(6200,3300)=", int(img.get_pixel(6200, 3300).r * 255.0 + 0.5))
	# L3：导入纹理路径
	var tex := load("res://config/strategic_map/l3_political_id_8192.png") as Texture2D
	if tex != null:
		var im2 := tex.get_image()
		print("L3 imported fmt=", im2.get_format(), " size=", im2.get_size())
		if im2.get_format() != Image.FORMAT_RGBA8:
			im2.convert(Image.FORMAT_RGBA8)
		print("L3 imported @anchor=", int(im2.get_pixel(5917, 2950).r * 255.0 + 0.5))
	else:
		print("L3 imported = null")
	# L2：导入纹理路径（l2_world_data 同款）
	var tex2 := load("res://config/strategic_map/l2_packs/region_013/l2_political_id.png") as Texture2D
	if tex2 != null:
		var im3 := tex2.get_image()
		print("L2 imported fmt=", im3.get_format(), " size=", im3.get_size())
		if im3.get_format() != Image.FORMAT_RGBA8:
			im3.convert(Image.FORMAT_RGBA8)
		# 城邦 anchor -> context: ox=4814, oy=2240
		print("L2 imported @birth(5917-4814,2950-2240)=", int(im3.get_pixel(1103, 710).r * 255.0 + 0.5))
	else:
		print("L2 imported = null")
	quit()
