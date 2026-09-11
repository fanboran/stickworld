extends SceneTree
## 全盘数据紧致化：把运行时读取的 L1/L2/L3 战略图 JSON 烘焙成紧凑二进制（.bin）。
##
## 为什么：l*_world.json 里 polygon 顶点是 "Array of [y,x]"（L2/L3），JSON 解析 + 构造
##   数组对象开销大（L2 region_008 76ms / L3 l3_world 111ms）。烘焙后 polygon 存成
##   PackedVector2Array(Vector2(x,y))，bytes_to_var 一次分配、无逐点 Array 构造
##   （实测 76ms → 20ms，bin 体积省 ~32%）。
##
## 格式：magic "LWDB" + ver u16 + var_to_bytes(payload)。payload 是 Dictionary（字段名与
##   json 一致），其中 polygon 类字段为 PackedVector2Array；无 json 时回退（data 类
##   load_from 读不到 bin 或 bytes_to_var 失败自动回退 JSON，兼容 Godot 版本升级）。
##
## 坐标语义（尊重各层现状，避免动渲染逻辑）：
##   - L2/L3：json 顶点 [y,x] → bin PackedVector2Array(Vector2(x,y))（与 renderer 的
##     Vector2(p[1],p[0]) 一致，下游直接取 Vector2）
##   - L1：原样序列化（json 顶点 [x,y] Array），构造逻辑（_polygon_from）不变
##
## 运行：godot --headless --path <工程> -s res://tools/worldgen/l_world_bake.gd
## 输入：config/strategic_map/ 下的 l1_world.json + l1_packs/*/l1_world.json +
##       l2_packs/*/l2_world.json + l3_world.json + l3_l1.json + l3_city.json
## 输出：同名 .bin（与 json 同目录，json 保留作源码/回退）

const MAGIC := "LWDB"


func _init() -> void:
	var t0 := Time.get_ticks_msec()
	var n := 0
	n += _bake_l1("res://config/strategic_map/l1_world.json")
	n += _bake_l1_dir("res://config/strategic_map/l1_packs")
	n += _bake_l2_dir("res://config/strategic_map/l2_packs")
	n += 1 if _bake_l3("res://config/strategic_map/l3_world.json") else 0
	n += 1 if _bake_l3("res://config/strategic_map/l3_l1.json") else 0
	n += 1 if _bake_l3("res://config/strategic_map/l3_city.json") else 0
	n += 1 if _bake_political_mesh("res://config/strategic_map/l3_political_mesh.json") else 0
	print("全盘紧凑化完成: %d 个 bin，%d ms" % [n, Time.get_ticks_msec() - t0])
	quit()


# ---------- L1（原样序列化：json [x,y] Array，构造逻辑不变） ----------

func _bake_l1_dir(dir_path: String) -> int:
	var n := 0
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry.begins_with("l1_"):
			var j := "%s/%s/l1_world.json" % [dir_path, entry]
			if FileAccess.file_exists(j):
				if _bake_raw(j):
					n += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return n


func _bake_l1(json_path: String) -> int:
	return 1 if _bake_raw(json_path) else 0


## L1：整份 json 原样序列化（polygon 保持 Array），只换容器
func _bake_raw(json_path: String) -> bool:
	var jt := FileAccess.get_file_as_string(json_path)
	if jt.is_empty():
		push_error("[l_world_bake] 无法读取 %s" % json_path)
		return false
	var data: Variant = JSON.parse_string(jt)
	if not (data is Dictionary):
		push_error("[l_world_bake] JSON 解析失败: %s" % json_path)
		return false
	return _write_bin(json_path, data)


# ---------- L2（紧凑：polygon/polygons/holes + neighbors/lakes → PackedVector2Array） ----------

func _bake_l2_dir(dir_path: String) -> int:
	var n := 0
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return 0
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir() and entry.begins_with("region_"):
			var j := "%s/%s/l2_world.json" % [dir_path, entry]
			if FileAccess.file_exists(j):
				if _bake_l2(j):
					n += 1
		entry = dir.get_next()
	dir.list_dir_end()
	return n


func _bake_l2(json_path: String) -> bool:
	var data: Dictionary = _read_json(json_path)
	if data.is_empty():
		return false
	var tiles := []
	for t in (data.get("tiles", []) as Array):
		var d: Dictionary = t
		_compact_polygon_fields(d)
		tiles.append(d)
	data["tiles"] = tiles
	if data.has("neighbors"):
		data["neighbors"] = _compact_poly_list(data["neighbors"])
	if data.has("lakes"):
		data["lakes"] = _compact_poly_list(data["lakes"])
	if data.has("political_mesh"):
		data["political_mesh"] = _compact_political_mesh(data["political_mesh"], false)
	return _write_bin(json_path, data)


## 政治矢量 mesh（边界超分 S3）紧凑化。
## 顶点 json 是 [x,y] 序（与 l2/l3 老字段的 [y,x] 不同——mesh 是新格式新约定）。
## full=true 为 L3 顶层 mesh（arcs 平铺 + tiles 弧引用），false 为 L2 注入版。
func _compact_political_mesh(pm: Dictionary, full: bool) -> Dictionary:
	if pm.has("verts"):
		pm["verts"] = _to_vec2_arr_xy(pm["verts"])
	for f in ["code", "idx"]:
		if pm.has(f):
			pm[f] = _to_int_arr(pm[f])
	for f in ["borders_national", "borders_region", "borders_free"]:
		if pm.has(f):
			var lines := []
			for ln in (pm[f] as Array):
				lines.append(_to_vec2_arr_xy(ln))
			pm[f] = lines
	if full:
		if pm.has("arcs"):
			pm["arcs"] = _to_float_arr(pm["arcs"])
		for f in ["arc_ptr", "arc_code_a", "arc_code_b", "arc_border"]:
			if pm.has(f):
				pm[f] = _to_int_arr(pm[f])
	return pm


## L3 顶层政治矢量 mesh：arcs/弧侧码/界分类/fill 三角网/tiles 弧引用
func _bake_political_mesh(json_path: String) -> bool:
	if not FileAccess.file_exists(json_path):
		print("  .. %s 不存在，跳过（mask 路线回退可用）" % json_path)
		return false
	var data: Dictionary = _read_json(json_path)
	if data.is_empty():
		return false
	data = _compact_political_mesh(data, true)
	return _write_bin(json_path, data)


# ---------- L3（紧凑：regions 的 land_polygon*/full_polygon + l1/city tiles polygons） ----------

func _bake_l3(json_path: String) -> bool:
	var data: Dictionary = _read_json(json_path)
	if data.is_empty():
		return false
	if data.has("regions"):
		var regions := []
		for r in (data["regions"] as Array):
			var d: Dictionary = r
			for f in ["land_polygon", "land_polygons", "land_holes", "full_polygon"]:
				if d.has(f):
					d[f] = _compact_poly(d[f]) if _is_poly_field_single(f) else _compact_poly_list(d[f])
			regions.append(d)
		data["regions"] = regions
	if data.has("tiles"):
		var tiles := []
		for t in (data["tiles"] as Array):
			var d: Dictionary = t
			_compact_polygon_fields(d)
			tiles.append(d)
		data["tiles"] = tiles
	return _write_bin(json_path, data)


# ---------- 工具 ----------

func _is_poly_field_single(f: String) -> bool:
	# land_polygon / full_polygon 是单个环；land_polygons / land_holes 是环列表
	return f in ["land_polygon", "full_polygon"]


func _compact_polygon_fields(d: Dictionary) -> void:
	# 地块 tile：polygon（主环）+ polygons（次环列表）+ holes
	if d.has("polygon") and (d["polygon"] is Array):
		d["polygon"] = _to_vec2_arr(d["polygon"])
	for f in ["polygons", "holes"]:
		if d.has(f) and (d[f] is Array):
			d[f] = _compact_poly_list(d[f])


func _compact_poly_list(arr: Variant) -> Array:
	var out := []
	for poly in (arr as Array):
		if poly is Array and (poly as Array).size() > 0:
			if (poly as Array)[0] is Array:
				out.append(_to_vec2_arr(poly))
			else:
				# 已是顶点（单环被包成列表）
				out.append(_to_vec2_arr(poly))
	return out


func _compact_poly(poly: Variant) -> Variant:
	if poly is Array and (poly as Array).size() > 0 and (poly as Array)[0] is Array:
		return _to_vec2_arr(poly)
	return poly


func _to_vec2_arr(poly: Array) -> PackedVector2Array:
	var arr := PackedVector2Array()
	arr.resize(poly.size())
	for i in poly.size():
		var p: Array = poly[i]
		arr[i] = Vector2(float(p[1]), float(p[0]))  # json [y,x] → Vector2(x,y)
	return arr


## political_mesh 顶点：json [x,y] → Vector2(x,y)（新格式直转，无序交换）
func _to_vec2_arr_xy(poly: Array) -> PackedVector2Array:
	var arr := PackedVector2Array()
	arr.resize(poly.size())
	for i in poly.size():
		var p: Array = poly[i]
		arr[i] = Vector2(float(p[0]), float(p[1]))
	return arr


func _to_int_arr(arr: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(arr.size())
	for i in arr.size():
		out[i] = int(arr[i])
	return out


func _to_float_arr(arr: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(arr.size())
	for i in arr.size():
		out[i] = float(arr[i])
	return out


func _read_json(json_path: String) -> Dictionary:
	var jt := FileAccess.get_file_as_string(json_path)
	if jt.is_empty():
		push_error("[l_world_bake] 无法读取 %s" % json_path)
		return {}
	var data: Variant = JSON.parse_string(jt)
	if not (data is Dictionary):
		push_error("[l_world_bake] JSON 解析失败: %s" % json_path)
		return {}
	return data


func _write_bin(json_path: String, payload: Variant) -> bool:
	var bin_path := json_path.get_basename() + ".bin"
	var buf := PackedByteArray()
	buf.append_array(MAGIC.to_ascii_buffer())
	var ver := PackedByteArray([0x01, 0x00])
	buf.append_array(ver)
	buf.append_array(var_to_bytes(payload))
	var f := FileAccess.open(bin_path, FileAccess.WRITE)
	if f == null:
		push_error("[l_world_bake] 无法写入 %s" % bin_path)
		return false
	f.store_buffer(buf)
	f.close()
	print("  -> %s (%d KB)" % [bin_path, buf.size() / 1024])
	return true
