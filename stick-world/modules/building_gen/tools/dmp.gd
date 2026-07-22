extends SceneTree
## 通用贴图 dump 工具 —— 读取 tools/py/_material_config.json 切换材质
func _initialize():
	var config_path := "res://modules/building_gen/tools/py/_material_config.json"
	var material := "thatch"

	if FileAccess.file_exists(config_path):
		var f := FileAccess.open(config_path, FileAccess.READ)
		if f:
			var json_str := f.get_as_text()
			f.close()
			var json := JSON.new()
			if json.parse(json_str) == OK:
				material = json.data.get("material", "thatch")

	# 诊断：确认磁盘文件内容是否最新
	var diag := FileAccess.open("res://modules/building_gen/scripts/materials/procedural_materials.gd", FileAccess.READ)
	var diag_hash := hash(diag.get_as_text()) if diag else -1
	if diag: diag.close()
	var diag_f := FileAccess.open("res://modules/building_gen/reference/dmp_diag.log", FileAccess.WRITE)
	diag_f.store_string("procedural_materials.gd hash=%d\n" % diag_hash)
	diag_f.close()

	var PM := load("res://modules/building_gen/scripts/materials/procedural_materials.gd")
	# 强制重新加载脚本，避免 headless 模式下使用启动时的旧缓存
	if PM is GDScript:
		PM.reload(true)
	var save_path := ""
	var img: Image

	match material:
		"thatch":
			# dump 一个中等尺寸的范围专属茅草贴图（真实草丝瓦叠层）
			img = PM.make_thatch_for_polygon(260, 180, 0, 1.0, 0.18, 2.0, false, 0.0, 30.0).get_image()
			save_path = "res://modules/building_gen/reference/preview_thatch.png"
		"thatch_dark":
			img = PM.make_thatch_for_polygon(220, 100, 0, 0.85, 0.12, 2.0).get_image()
			save_path = "res://modules/building_gen/reference/preview_thatch_dark.png"

		# === 扩展新材质时在此追加 match 分支 ===
		# "stone_wall":
		# 	img = PM.make_stone_wall(512, 512, 0).get_image()
		# 	save_path = "res://modules/building_gen/reference/preview_stone_wall.png"
		# "wood_plank":
		# 	img = PM.make_wood_plank(512, 512).get_image()
		# 	save_path = "res://modules/building_gen/reference/preview_wood_plank.png"

		_:
			printerr("未知材质: ", material)
			quit(1)
			return

	if img == null:
		printerr("贴图生成返回 null: ", material)
		quit(1)
		return

	img.save_png(save_path)
	print("OK: " + ProjectSettings.globalize_path(save_path))
	quit()


func _process(_d: float) -> bool:
	return true
