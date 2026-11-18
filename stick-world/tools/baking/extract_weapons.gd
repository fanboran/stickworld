@tool
extends Node
## 从解包 universal/meric 图集裁剪武器/盾牌贴图，保存为独立 PNG。
##
## 数据源（仓库根 external/，绝对路径——worktree 内 external/ 不全，统一读主工作区）：
##   universal：external/decompiled/legacy/spine_raw/textures/universal.png
##             + external/decompiled/legacy/spine_raw/核心单位骨架/[universal.atlas].txt
##   meric：    external/swl_apk/legacy_tex/meric.png（atlas 页名 meric.png 512x512）
##             + external/decompiled/legacy/spine_raw/核心单位骨架/meric.atlas.atlas.txt
## 输出：res://modules/stick_rig/assets/textures/weapons/*.png
##
## 运行：godot --headless --path stick-world res://tools/baking/extract_weapons.tscn

const REPO_ROOT := "F:/VSCode/stickworld"

## 图集源清单：atlas 文本 + 页 png + 该源要裁的 region。
## 新增图集时照抄一条（png 位置以 atlas 页名为线索在 external/ 下找）。
const SOURCES: Array[Dictionary] = [
	{
		"atlas": "external/decompiled/legacy/spine_raw/核心单位骨架/[universal.atlas].txt",
		"png": "external/decompiled/legacy/spine_raw/textures/universal.png",
		"regions": {
			"pickaxe": "sword.png",
			"classic-spearton-spear-0": "spear.png",
			"classic-spearton-shield-0": "shield.png",
			"Bow_Full1": "bow.png",
			"Arrow1": "arrow.png",
			"pickaxe1 (2)": "pickaxe.png",
			"magicstaff": "magicstaff.png",
		},
	},
	{
		"atlas": "external/decompiled/legacy/spine_raw/核心单位骨架/meric.atlas.atlas.txt",
		"png": "external/swl_apk/legacy_tex/meric.png",
		"regions": {
			## Meric 皮肤 weapon 槽唯一附件（name=Meric/meric-staff → path）：
			## rot=-90.91 xy=(-16.24,5.41) wh=125x600（region 实际 55x269），
			## 挂载骨 Meric/meric-staff @Stand t=0 世界角 90.0——推导链见
			## weapon_mericstaff.tscn 头注释。
			"meric-staff": "mericstaff.png",
		},
	},
]

const OUTPUT_DIR := "res://modules/stick_rig/assets/textures/weapons/"

## region 名以各兵种皮肤 weapon/Arrow1 附件实际引用为准（不是想当然）：
##   Swordwrath 剑=pickaxe（Swordwrath skin weapon 槽唯一附件名 "weapon"，其 name
##   字段指向 region "pickaxe" 55x198——粗制棒刃，正是游戏里 Swordwrath 的剑；
##   region "Swordbasic" 82x300 是 SwordwrathUnlocked 皮肤的长剑，曾错裁）；
##   Spearton 矛/盾=classic-spearton-*、Magikill 杖=magicstaff、弓=Bow_Full1、
##   **Miner 镐=pickaxe1 (2)**（region "pickaxe1" 74x127 是箭袋旁的另一张图，
##   region "pickaxe" 55x198 虽名近但其实是剑——见上）。


func _ready() -> void:
	print("=== 开始提取武器/盾牌贴图 ===")
	var total := 0
	var ok := 0
	var err := DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	if err != OK:
		printerr("创建输出目录失败 (err=%d)" % err)
		get_tree().quit(1)
		return
	for src_idx in SOURCES.size():
		var src: Dictionary = SOURCES[src_idx]
		var atlas_path: String = REPO_ROOT + "/" + src["atlas"]
		var png_path: String = REPO_ROOT + "/" + src["png"]
		var regions: Dictionary = src["regions"]
		var atlas_text := FileAccess.get_file_as_string(atlas_path)
		if atlas_text.is_empty():
			printerr("[源 %d] 无法读取 atlas: %s" % [src_idx, atlas_path])
			total += regions.size()
			continue
		var img := Image.load_from_file(png_path)
		if img == null or img.is_empty():
			printerr("[源 %d] 无法加载图集: %s" % [src_idx, png_path])
			total += regions.size()
			continue
		print("[源 %d] %s" % [src_idx, png_path.get_file()])
		for tex_name in regions.keys():
			total += 1
			var rect := _find_rect(atlas_text, tex_name)
			if rect == Rect2i():
				printerr("  未找到贴图: %s" % tex_name)
				continue
			var out_name: String = regions[tex_name]
			var out := img.get_region(rect)
			var path := OUTPUT_DIR + out_name
			var e := out.save_png(path)
			if e == OK:
				print("  OK %s  <- %s (%dx%d)" % [out_name, tex_name, out.get_width(), out.get_height()])
				ok += 1
			else:
				printerr("  保存失败 %s (err=%d)" % [out_name, e])
	print("=== 完成: %d / %d ===" % [ok, total])
	get_tree().quit(0 if ok == total else 1)


## 从 atlas 文本解析贴图的裁剪矩形（按行解析，Rotated 贴图宽高互换）
func _find_rect(atlas_text: String, tex_name: String) -> Rect2i:
	var lines := atlas_text.split("\n")
	var i := 0
	while i < lines.size():
		if lines[i].strip_edges() == tex_name:
			# 下一行 rotate，再下一行 xy，再下一行 size
			var rotate_line := lines[i + 1] if i + 1 < lines.size() else ""
			var xy_line := lines[i + 2] if i + 2 < lines.size() else ""
			var size_line := lines[i + 3] if i + 3 < lines.size() else ""
			var rotated: bool = rotate_line.contains("true")
			var xy := xy_line.split(":")[1].split(",")
			var sz := size_line.split(":")[1].split(",")
			var x := int(xy[0].strip_edges())
			var y := int(xy[1].strip_edges())
			var w := int(sz[0].strip_edges())
			var h := int(sz[1].strip_edges())
			if rotated:
				var tmp := w
				w = h
				h = tmp
			return Rect2i(x, y, w, h)
		i += 1
	return Rect2i()
