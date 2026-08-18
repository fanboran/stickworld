@tool
extends Node
## L3 大世界几何烘焙 —— 把运行时三角剖分提前到素材阶段（对齐 L2 的 l2_geom.bin 做法）。
##
## 为什么：l3_world.json 的 13 个地区多边形共 21 万顶点，Godot Geometry2D.triangulate_polygon
## 运行时要 11.6s（首次打开 M 键战略图卡死主线程的根因，见 tests/dev/perf_bench_l3.gd）。
## 素材阶段烘焙一次，运行时零几何计算，首次打开从 11.6s 降到 ~150ms。
##
## 用法（必须在 Godot 工程内运行，工具场景）：
##   godot --headless --path <工程> res://tools/worldgen/l3_bake.tscn
##
## 输入：res://config/strategic_map/l3_world.json（export_l3_view.py 产出）
## 输出：res://config/strategic_map/l3_geom.bin
##
## 二进制格式（与 l2_geom.bin 同风格）：
##   magic  "L3GB" (4B)
##   ver    u16 = 1
##   ---- mesh section ×2（land, holes）----
##   每段：
##     tri_count u32
##     每三角形：v0.x v0.y v1.x v1.y v2.x v2.y (6 × f32) + r g b a (4 × u8)
##   land  = 各地区陆地外轮廓（填充色 = 地区色）
##   holes = C 形地区内海洋（填充色 = 海洋色，覆盖在陆地之上挖空）

const INPUT_JSON := "res://config/strategic_map/l3_world.json"
const OUTPUT_BIN := "res://config/strategic_map/l3_geom.bin"

const OCEAN_COLOR := Color(30.0 / 255.0, 55.0 / 255.0, 95.0 / 255.0)
const MAGIC := "L3GB"
const VER := 1


func _ready() -> void:
	print("=== L3 几何烘焙开始 ===")
	var t0 := Time.get_ticks_msec()
	if not FileAccess.file_exists(INPUT_JSON):
		push_error("[L3Bake] 找不到 %s" % INPUT_JSON)
		get_tree().quit(1)
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(INPUT_JSON))
	if data == null or not (data is Dictionary):
		push_error("[L3Bake] JSON 解析失败")
		get_tree().quit(1)
		return

	# ── land：全部地区陆地外轮廓（region 色）──
	var land_tris := PackedByteArray()
	var land_count := 0
	# ── holes：洞轮廓（海洋色）──
	var hole_tris := PackedByteArray()
	var hole_count := 0
	var regions: Array = data.get("regions", [])
	var ridx := 0
	for r in regions:
		ridx += 1
		print("  剖分地区 %d/%d (label=%s)..." % [ridx, regions.size(), r.get("label", "?")])
		var col: Array = r.get("color", [])
		var fill := Color(0.6, 0.7, 0.8)
		if col.size() >= 3:
			fill = Color(col[0] / 255.0, col[1] / 255.0, col[2] / 255.0)
		for poly in r.get("land_polygons", [r.get("land_polygon", [])]):
			if (poly as Array).size() < 3:
				continue
			var tris := _triangulate(poly, fill)
			if tris.size() > 0:
				land_tris.append_array(tris)
				land_count += tris.size() / 28
		for hole in r.get("land_holes", []):
			if (hole as Array).size() < 3:
				continue
			var tris := _triangulate(hole, OCEAN_COLOR)
			if tris.size() > 0:
				hole_tris.append_array(tris)
				hole_count += tris.size() / 28

	# ── 写文件 ──
	var f := FileAccess.open(OUTPUT_BIN, FileAccess.WRITE)
	if f == null:
		push_error("[L3Bake] 无法写入 %s" % OUTPUT_BIN)
		get_tree().quit(1)
		return
	f.store_buffer(MAGIC.to_ascii_buffer())
	f.store_16(VER)
	f.store_buffer(_mesh_section(land_tris))
	f.store_buffer(_mesh_section(hole_tris))
	f.close()
	var dt := Time.get_ticks_msec() - t0
	print("  地区: %d, 三角形: land=%d holes=%d" % [regions.size(), land_count, hole_count])
	print("  输出: %s (%d bytes), 耗时 %dms" % [OUTPUT_BIN, FileAccess.get_file_as_bytes(OUTPUT_BIN).size(), dt])
	print("=== L3 几何烘焙完成 ===")
	get_tree().quit(0)


## 三角剖分单个多边形（(y,x) JSON 坐标 -> 渲染坐标 (x,y)），返回序列化字节
func _triangulate(poly: Array, fill: Color) -> PackedByteArray:
	var pts2 := PackedVector2Array()
	for p in poly:
		pts2.append(Vector2(p[1], p[0]))
	var tri := Geometry2D.triangulate_polygon(pts2)
	if tri.is_empty():
		return PackedByteArray()
	var out := PackedByteArray()
	var cr: int = int(fill.r * 255.0)
	var cg: int = int(fill.g * 255.0)
	var cb: int = int(fill.b * 255.0)
	for i in range(0, tri.size(), 3):
		for k in range(3):
			var v: Vector2 = pts2[tri[i + k]]
			out.append_array(encode_float(v.x))
			out.append_array(encode_float(v.y))
		out.append(cr)
		out.append(cg)
		out.append(cb)
		out.append(255)
	return out


## 浮点转 4 字节（little-endian，与 PackedFloat32Array.to_byte_array 一致）
func encode_float(value: float) -> PackedByteArray:
	var arr := PackedFloat32Array([value])
	return arr.to_byte_array()


## 网格段：tri_count u32 + 三角形字节
func _mesh_section(tris: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	var count := tris.size() / 28
	var cnt := PackedInt32Array([count])
	out.append_array(cnt.to_byte_array())
	out.append_array(tris)
	return out
