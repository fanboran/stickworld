extends RefCounted
## 城市生成·街道排布域（city_gen 管线第 4~5 段，由 CityGen.generate 编排）。
## 职责：行政居中 → 两侧序列从中心向两侧整格排布（推挤保底）→ 跨度中点
## 回正 → 背景两层随分区锚点落（跨度拉伸 + 行内推挤）。
## 纯静态纯函数：入参状态、出参结果；排布几何口径（MIN_GAP/WALL_MARGIN/
## GATE_DEF）属主在本文件。

## 空档槽字面量属主在序列规划域（插入端），本文件只按值识别
const SeqPlan := preload("res://modules/world/scripts/map/city_gen_seq.gd")

const MIN_GAP := 0.6
const WALL_MARGIN := 3.0
const GATE_DEF := "gatehouse_w8"


## 步骤 4：行政居中（当级行政槽，§二）+ 前排整格排布（推挤保底）+ 城门。
## 返回 {"placements": Array[{def,x,w,zone,...}], "width_cells": int}。
static func _step_layout_front_row(prof: Dictionary, queues: Dictionary,
		widths: Dictionary, prop_fp: Dictionary, prop_set: Dictionary,
		seq: Dictionary, clutter: Dictionary) -> Dictionary:
	var admin: String = "guildhall_w12"
	for d: String in prof["admin"]:
		if widths.has(d):
			admin = d
			break
	var placements: Array = []   # {def, x, w, zone}
	var w_a := float(widths.get(admin, 12.0))
	placements.append({"def": admin, "x": 0.0, "w": w_a, "zone": "core"})
	var cursor := {-1: -w_a * 0.5 - MIN_GAP, 1: w_a * 0.5 + MIN_GAP}
	var qi := {-1: 0, 1: 0}
	while int(qi[-1]) < seq[-1].size() or int(qi[1]) < seq[1].size():
		for s: int in [-1, 1]:
			if int(qi[s]) < seq[s].size():
				var d: String = seq[s][int(qi[s])]
				qi[s] = int(qi[s]) + 1
				if d == SeqPlan.GAP_SLOT or d == SeqPlan.GAP_SLOT_WIDE:
					# 刻意留白：占 1~2 整格不出卡
					var gw: float = 2.0 if d == SeqPlan.GAP_SLOT_WIDE else 1.0
					var xg: float = float(cursor[s]) + s * gw * 0.5
					placements.append({"def": d, "x": xg, "w": gw, "zone": "gap",
						"gap": true})
					cursor[s] = float(cursor[s]) + s * (gw + MIN_GAP)
				else:
					# 杂物占格宽按**真实地面占地**（footprint[0]）向上取整——画面宽
					# 含透视外扩，按它取整会让盆/筐这类小件虚占 2~3 格（创始人
					# 2026-09-15 指正）；卡库缺失兜底 footprint [2.0,1.5]→2 格。
					# 建筑照旧查卡宽表。
					var w_default := 2.0 if clutter.has(d) else float(widths.get(d, 8.0))
					var w := float(prop_set.get(d, w_default))
					if clutter.has(d):
						var fpw: Array = prop_fp.get(d, [2.0, 1.5])
						w = ceilf(float(fpw[0]))
					var x: float = float(cursor[s]) + s * w * 0.5
					var zone := "float"
					if clutter.has(d):
						zone = "clutter"
					else:
						for z: String in queues:
							if d in queues[z]:
								zone = z
								break
					placements.append({"def": d, "x": x, "w": w, "zone": zone,
						"clutter": clutter.has(d)})
					cursor[s] = float(cursor[s]) + s * (w + MIN_GAP)
	for s: int in [-1, 1]:
		var w2 := float(widths.get(GATE_DEF, 10.5))
		var x2: float = float(cursor[s]) + s * w2 * 0.5
		placements.append({"def": GATE_DEF, "x": x2, "w": w2, "zone": "gate", "door": true})
		cursor[s] = float(cursor[s]) + s * (w2 + MIN_GAP)

	# 城市中心 = 前排跨度中点（创始人 2026-09-15：出生点应在城市中心——
	# 分区非对称时行政槽自然偏于一侧属城区分布，出生点仍落跨度正中）
	var left := INF
	var right := -INF
	for p: Dictionary in placements:
		left = minf(left, float(p["x"]) - float(p["w"]) * 0.5)
		right = maxf(right, float(p["x"]) + float(p["w"]) * 0.5)
	var shift: float = (left + right) * 0.5
	for p: Dictionary in placements:
		p["x"] = float(p["x"]) - shift
	# 整格吸附（创始人 2026-09-15：建筑位置必须整格摆放——宽度本就是格
	# 整数倍）：中心取整，同排整格步进推开（间隙承诺 ≥MIN_GAP 由整格步距
	# ≥1 格兑现），再把跨度中点回正（整数平移保持整格）
	for p: Dictionary in placements:
		p["x"] = float(roundi(float(p["x"])))
	placements.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
	for i in range(1, placements.size()):
		var need_i: float = float(placements[i - 1]["x"]) + float(placements[i - 1]["w"]) * 0.5 \
				+ MIN_GAP + float(placements[i]["w"]) * 0.5
		if float(placements[i]["x"]) < need_i:
			placements[i]["x"] = float(ceilf(need_i))
	left = INF
	right = -INF
	for p: Dictionary in placements:
		left = minf(left, float(p["x"]) - float(p["w"]) * 0.5)
		right = maxf(right, float(p["x"]) + float(p["w"]) * 0.5)
	var mid_shift := (left + right) * 0.5
	if absf(mid_shift) >= 0.5:
		for p: Dictionary in placements:
			p["x"] = float(p["x"]) - roundf(mid_shift)
	left = INF
	right = -INF
	for p: Dictionary in placements:
		left = minf(left, float(p["x"]) - float(p["w"]) * 0.5)
		right = maxf(right, float(p["x"]) + float(p["w"]) * 0.5)
	var width_cells := int(round(right - left + WALL_MARGIN * 2.0))
	return {"placements": placements, "width_cells": width_cells}


## 步骤 5：背景两层随分区锚点落（行内推挤 + 跨度拉伸）。
## 返回 {"rows": {1/2: Array[{def,x,w}]}, "zone_anchor": {zone: x}}。
static func _step_background_rows(pools: Dictionary, widths: Dictionary,
		placements: Array, rng: RandomNumberGenerator) -> Dictionary:
	var zone_anchor: Dictionary = {}
	for p: Dictionary in placements:
		var zn: String = str(p["zone"])
		if zn == "core" or zn == "gate" or zn == "clutter" or zn == "gap":
			continue
		zone_anchor[zn] = (float(zone_anchor.get(zn, float(p["x"]))) + float(p["x"])) * 0.5
	var bg_rows := {1: [], 2: []}
	var bg_i := 0
	for p: Dictionary in placements:
		var zn2: String = str(p["zone"])
		if zn2 == "core" or zn2 == "gate" or zn2 == "clutter" or zn2 == "gap":
			continue
		var zpool: Array = pools.get(zn2, ["house_w8"])
		for k in 2:
			var d: String = str(zpool[(bg_i + k) % zpool.size()])
			bg_i += 1
			var row: int = 1 if bg_i % 2 == 0 else 2
			var anchor: float = float(zone_anchor.get(zn2, float(p["x"])))
			bg_rows[row].append({"def": d, "x": anchor + rng.randf_range(-9.0, 9.0),
				"w": float(widths.get(d, 8.0))})
	# 背景跨度契约（创始人：后景只比前景短几格）——每排线性拉伸到
	# 前排跨度各收 3 格，拉伸后再行内推挤（间隙只增不减）
	var front_lo: float = INF
	var front_hi: float = -INF
	for p: Dictionary in placements:
		front_lo = minf(front_lo, float(p["x"]) - float(p["w"]) * 0.5)
		front_hi = maxf(front_hi, float(p["x"]) + float(p["w"]) * 0.5)
	var front_span: float = front_hi - front_lo
	for row: int in [1, 2]:
		var bs: Array = bg_rows[row]
		bs.sort_custom(func(a, b): return float(a["x"]) < float(b["x"]))
		if bs.is_empty():
			continue
		var lo: float = float(bs[0]["x"]) - float(bs[0]["w"]) * 0.5
		var hi: float = float(bs[bs.size() - 1]["x"]) + float(bs[bs.size() - 1]["w"]) * 0.5
		var target_lo: float = front_lo + 3.0
		var target_hi: float = front_hi - 3.0
		if hi - lo > 1.0 and target_hi - target_lo > hi - lo:
			var k: float = (target_hi - target_lo) / (hi - lo)
			var mid: float = (lo + hi) * 0.5
			for b: Dictionary in bs:
				b["x"] = mid + (float(b["x"]) - mid) * k
		for i in range(1, bs.size()):
			var need: float = float(bs[i - 1]["x"]) + float(bs[i - 1]["w"]) * 0.5 + MIN_GAP + float(bs[i]["w"]) * 0.5
			if float(bs[i]["x"]) < need:
				bs[i]["x"] = need
	return {"rows": bg_rows, "zone_anchor": zone_anchor}
