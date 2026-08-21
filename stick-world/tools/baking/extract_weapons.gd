@tool
extends Node
## 从解包 universal 图集裁剪武器/盾牌贴图，保存为独立 PNG。
##
## 数据源：external/decompiled/legacy/spine_raw/textures/universal.png
##        + external/decompiled/legacy/spine_raw/核心单位骨架/[universal.atlas].txt
## 输出：res://modules/units/assets/textures/weapons/*.png
##
## 运行：godot --headless --path "F:/VSCode/game-2-aux/stick-world" res://tools/baking/extract_weapons.tscn

const ATLAS_PATH := "F:/VSCode/game-2-aux/external/decompiled/legacy/spine_raw/核心单位骨架/[universal.atlas].txt"
const PNG_PATH := "F:/VSCode/game-2-aux/external/decompiled/legacy/spine_raw/textures/universal.png"
const OUTPUT_DIR := "res://modules/units/assets/textures/weapons/"

## 提取清单：贴图名 -> 输出文件名
const EXTRACT: Dictionary = {
	"Swordbasic":                   "sword.png",
	"classic-spearton-spear-0":     "spear.png",
	"classic-spearton-shield-0":    "shield.png",
	"Bow_Full1":                    "bow.png",
	"Arrow1":                      "arrow.png",
	"pickaxe":                      "pickaxe.png",
	"magicstaff":                   "magicstaff.png",
}


func _ready() -> void:
	print("=== 开始提取武器/盾牌贴图 ===")
	var atlas_text := FileAccess.get_file_as_string(ATLAS_PATH)
	if atlas_text.is_empty():
		printerr("无法读取 atlas: " + ATLAS_PATH)
		get_tree().quit(1)
		return
	var img := Image.load_from_file(PNG_PATH)
	if img == null or img.is_empty():
		printerr("无法加载图集: " + PNG_PATH)
		get_tree().quit(1)
		return
	var err := DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)
	var ok := 0
	for tex_name in EXTRACT.keys():
		var rect := _find_rect(atlas_text, tex_name)
		if rect == Rect2i():
			printerr("  未找到贴图: %s" % tex_name)
			continue
		var out_name: String = EXTRACT[tex_name]
		var out := img.get_region(rect)
		var path := OUTPUT_DIR + out_name
		var e := out.save_png(path)
		if e == OK:
			print("  OK %s  <- %s (%dx%d)" % [out_name, tex_name, out.get_width(), out.get_height()])
			ok += 1
		else:
			printerr("  保存失败 %s (err=%d)" % [out_name, e])
	print("=== 完成: %d / %d ===" % [ok, EXTRACT.size()])
	get_tree().quit(0 if ok == EXTRACT.size() else 1)


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
