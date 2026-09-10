class_name SettlementBlob
extends RefCounted
## 建成区 blob V2 运行时接入（观感返工 §R5：三档贴图 + 包几何 + 档位判定）
##
## 生成端 blob_v2_generate.py（场叠加管线）产出三档严格嵌套形状（low ⊆ mid ⊆ high，
## 每城按 population_score 烘三档），blob_v2_bake.py 把三档透明贴图（blob_low/mid/
## high.png）+ 压缩几何（blob_v2_geo.bin）烘进各 L1 包。运行时：
##   - 档位判定 tier_of：按运行时扰动后 population_score 分档（0.35/0.65 分界，
##     与生成端概览口径一致——jitter ±15% 后档位可能与烘焙档不同）
##   - 几何装载 load_pack_geometry：读包内 blob_v2_geo.bin（[u32 LE 原始长度]
##     [zlib json]，环顶点 = 相对聚落锚点的局部坐标 ×10 量化），供单城档位
##     刷新叠加贴图与 R2 当前城流动描边（mid 档轮廓）即时重烘
##   - even-odd 扫描线栅格化 rasterize_evenodd：运行时把环顶点烘成单城小贴图
##     （档位变化城的一次性补丁，map_renderer 分帧消费）
## 旧径向轮廓模型（r(θ)=base+capacity×g(s)，DJB2 跨端同源）已随 R5 退役。

## 档位（population_score → 形状档）
const TIER_LOW := 0
const TIER_MID := 1
const TIER_HIGH := 2
const TIER_COUNT := 3
const TIER_NAMES: Array[String] = ["low", "mid", "high"]
## 各档贴图文件名（包目录内；blob_v2_bake.py 产出）
const TIER_FILES: Array[String] = ["blob_low.png", "blob_mid.png", "blob_high.png"]
## 档位分界（与生成端 blob_v2_bake.py TIER_THRESHOLDS 同值，改边界两端同步）
const TIER_THRESHOLDS: Array[float] = [0.35, 0.65]
## 包几何文件名（blob_v2_bake.py 产出）
const GEO_FILE := "blob_v2_geo.bin"

## 16 方向容量数组长度（blob_capacity 字段仍是生成端容量探测产物，
## l1/l2_world_data 装配校验用；V2 渲染不再消费容量曲线）
const DIRECTION_COUNT := 16


## 兼容接口：容量数组长度（旧 l1/l2_world_data 校验逻辑引用）
static func direction_count() -> int:
	return DIRECTION_COUNT


## 档位判定（运行时扰动后 population_score；单调分段，越界值安全夹取）
static func tier_of(score: float) -> int:
	if score < TIER_THRESHOLDS[0]:
		return TIER_LOW
	if score < TIER_THRESHOLDS[1]:
		return TIER_MID
	return TIER_HIGH


## ===== 包几何装载 =====

## 读包内 blob_v2_geo.bin → {sid: {"bake_tier": int, "rings": Array[3]}}。
## rings[t] = [{"outer": PackedVector2Array, "holes": Array[PackedVector2Array]}, ...]
## （相对聚落锚点的局部坐标）。包无几何文件（旧包）返回空 Dictionary。
static func load_pack_geometry(base_dir: String) -> Dictionary:
	var path := "%s/%s" % [base_dir, GEO_FILE]
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var raw_len := f.get_32()
	var packed := f.get_buffer(f.get_length() - 4)
	if raw_len <= 0 or packed.is_empty():
		return {}
	# blob_v2_geo.bin = [u32 LE 原始长度][gzip(json)]（生成端 gzip.compress mtime=0 确定性；
	# Godot 4.7 压缩枚举挂在 FileAccess.CompressionMode 下，无 ZLIB 项）
	var raw := packed.decompress(raw_len, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		push_warning("[SettlementBlob] blob_v2_geo.bin 解压失败: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not (parsed is Dictionary):
		push_warning("[SettlementBlob] blob_v2_geo.bin 解析失败: %s" % path)
		return {}
	var doc: Dictionary = parsed
	var cities_in: Dictionary = doc.get("cities", {})
	var q := maxf(float(doc.get("q", 10.0)), 1.0)
	var cities_out: Dictionary = {}
	for sid: String in cities_in:
		var cd: Dictionary = cities_in[sid]
		var tiers_raw: Array = cd.get("r", [])
		var rings: Array = []
		rings.resize(TIER_COUNT)
		for ti in TIER_COUNT:
			var polys: Array = []
			if ti < tiers_raw.size() and tiers_raw[ti] is Array:
				for poly_v: Variant in tiers_raw[ti]:
					var pd: Dictionary = poly_v
					var holes: Array = []
					for hole_v: Variant in pd.get("h", []):
						var pts := _pts_from_flat(hole_v, q)
						if pts.size() >= 3:
							holes.append(pts)
					var outer := _pts_from_flat(pd.get("o", []), q)
					if outer.size() >= 3:
						polys.append({"outer": outer, "holes": holes})
			rings[ti] = polys
		cities_out[sid] = {
			"bake_tier": clampi(int(cd.get("bt", 0)), 0, TIER_COUNT - 1),
			"rings": rings,
		}
	return cities_out


## 扁平量化数组 [dx,dy,dx,dy,...] → PackedVector2Array（÷q 还原）
static func _pts_from_flat(flat_v: Variant, q: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	if not (flat_v is Array):
		return pts
	var flat: Array = flat_v
	var n := flat.size() / 2
	pts.resize(n)
	for i in n:
		pts[i] = Vector2(float(flat[i * 2]) / q, float(flat[i * 2 + 1]) / q)
	return pts


## 取城某档多边形集合（无几何/该档无建成区返回空 Array——贫瘠缺席是合法画面）
static func city_rings(geo: Dictionary, sid: String, tier: int) -> Array:
	var cd: Dictionary = geo.get(sid, {})
	if cd.is_empty():
		return []
	var ti := clampi(tier, 0, TIER_COUNT - 1)
	var rings: Array = cd.get("rings", [])
	if ti >= rings.size():
		return []
	return rings[ti]


## 该城在 geo 里登记的烘焙档（贴图上画的档；无几何回退 TIER_LOW）
static func bake_tier_of(geo: Dictionary, sid: String) -> int:
	var cd: Dictionary = geo.get(sid, {})
	return clampi(int(cd.get("bake_tier", TIER_LOW)), 0, TIER_COUNT - 1)


## R2 当前城流动描边轮廓：mid 档最大外环（与建成区图形重合的 R2 语义；
## 档位随分数变化不换描边——固定 mid 档避免描边跳变）。缺 mid 依次回退
## low/high。返回局部坐标折线（调用方 + 聚落锚点平移）；无任何环返回空。
static func glow_outline(geo: Dictionary, sid: String) -> PackedVector2Array:
	for fallback in [TIER_MID, TIER_LOW, TIER_HIGH]:
		var best := _largest_outer(city_rings(geo, sid, fallback))
		if best.size() >= 3:
			return best
	return PackedVector2Array()


## 多边形集合中面积最大的外环（shoelace 有向面积取绝对值最大）
static func _largest_outer(polys: Array) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_area := 0.0
	for poly: Variant in polys:
		var pd: Dictionary = poly
		var outer: PackedVector2Array = pd.get("outer", PackedVector2Array())
		if outer.size() < 3:
			continue
		var a := 0.0
		for i in outer.size():
			var p := outer[i]
			var nxt := outer[(i + 1) % outer.size()]
			a += p.x * nxt.y - nxt.x * p.y
		a = absf(a) * 0.5
		if a > best_area:
			best_area = a
			best = outer
	return best


## ===== even-odd 扫描线栅格化（单城补丁贴图）=====

## 多边形集合 → 单城小贴图。环集合按 even-odd 判定（外环+洞任意嵌套均正确），
## 平涂 color（无卫星感纹理——运行时补丁从简，与烘焙贴图的差异见 R5 报告）。
## 返回 {"img": Image(RGBA8), "origin": Vector2(局部 bbox 左上)}；空集合/退化返回 {}。
static func rasterize_evenodd(polys: Array, color: Color, pad: int = 2) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var edges: Array[PackedVector2Array] = []
	for poly: Variant in polys:
		var pd: Dictionary = poly
		var outer: PackedVector2Array = pd.get("outer", PackedVector2Array())
		if outer.size() < 3:
			continue
		edges.append(outer)
		for p in outer:
			lo = lo.min(p)
			hi = hi.max(p)
		# 洞参与 even-odd（洞在外环内，不扩 bbox）
		for hole_v: Variant in pd.get("holes", []):
			var hole := hole_v as PackedVector2Array
			if hole.size() >= 3:
				edges.append(hole)
	if edges.is_empty():
		return {}
	if lo.x > hi.x or lo.y > hi.y:
		return {}
	var origin := Vector2(floorf(lo.x) - pad, floorf(lo.y) - pad)
	var w := int(ceilf(hi.x) + pad) - int(origin.x) + 1
	var h := int(ceilf(hi.y) + pad) - int(origin.y) + 1
	if w <= 0 or h <= 0 or w * h > 4_000_000:
		return {}
	var img := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	# 边按 y 分桶（每行只扫相交边）
	var buckets: Array = []
	buckets.resize(h)
	for e: PackedVector2Array in edges:
		var n := e.size()
		for i in n:
			var a := e[i] - origin
			var b := e[(i + 1) % n] - origin
			var y0 := maxi(int(floorf(minf(a.y, b.y))), 0)
			var y1 := mini(int(ceilf(maxf(a.y, b.y))), h - 1)
			for y in range(y0, y1 + 1):
				if buckets[y] == null:
					buckets[y] = []
				buckets[y].append([a, b])
	# 逐行求交点（像素中心 y+0.5），even-odd 成对填 span
	for y in h:
		var row: Variant = buckets[y]
		if row == null or (row as Array).is_empty():
			continue
		var yc := float(y) + 0.5
		var xs: Array[float] = []
		for pair: Variant in row:
			var a: Vector2 = pair[0]
			var b: Vector2 = pair[1]
			if (a.y <= yc and b.y > yc) or (b.y <= yc and a.y > yc):
				var t := (yc - a.y) / (b.y - a.y)
				xs.append(a.x + (b.x - a.x) * t)
		if xs.size() < 2:
			continue
		xs.sort()
		var i2 := 0
		while i2 + 1 < xs.size():
			var x0 := maxi(int(ceilf(xs[i2])), 0)
			var x1 := mini(int(floorf(xs[i2 + 1])), w - 1)
			if x1 >= x0:
				img.fill_rect(Rect2i(x0, y, x1 - x0 + 1, 1), color)
			i2 += 2
	return {"img": img, "origin": origin}
