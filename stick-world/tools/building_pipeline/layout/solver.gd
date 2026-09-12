## 布局求解器：spec + 宽度格数 + seed → 层几何 / 开间分配 / 屋顶参数。
## 开间（bay）参数化：宽度变化 = 开间数变化，永不拉伸任何纹理/构件。
## 开间宽允许浮点 px（开间是画面内部节奏，格数约束只管建筑总占位宽）。
extends RefCounted

const Spec := preload("res://tools/building_pipeline/spec.gd")

const DEFAULT_BAY_POOL := ["window", "blind", "timber", "window"]


static func solve(spec_id: String, width_cells: int, seed_val: int) -> Dictionary:
	if not Spec.PRESETS.has(spec_id):
		return {"ok": false, "error": "未知建筑预设 %s" % spec_id}
	var sp: Dictionary = Spec.PRESETS[spec_id]
	if width_cells < int(sp["min_w"]):
		return {"ok": false, "error": "%s 最小宽度 %d 格（请求 %d）" % [spec_id, int(sp["min_w"]), width_cells]}
	if width_cells > int(sp["max_w"]):
		return {"ok": false, "error": "%s 最大宽度 %d 格（请求 %d）" % [spec_id, int(sp["max_w"]), width_cells]}

	var px_w := width_cells * 32
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val

	# 墙高：shell 类由各层累加，特型由 wall_h 声明
	var stories: Array = sp.get("stories", [])
	var wall_h := 0
	if stories.is_empty():
		wall_h = int(sp.get("wall_h", 60))
	else:
		for s_v in stories:
			wall_h += int((s_v as Dictionary)["h"])

	# 屋顶参数（rise 随宽度增高，避免宽建筑扁顶）；顶端空间决定图高
	var roof: Dictionary = (sp["roof"] as Dictionary).duplicate() if sp.has("roof") else {}
	var top_space := 0
	if not roof.is_empty():
		var kind := String(roof.get("kind", "gable"))
		if roof.has("rise"):
			var base_rise := float(roof["rise"])
			roof["rise"] = minf(base_rise + maxf(0.0, float(width_cells - 4)) * 2.2, base_rise + 28.0)
			top_space = int(roof["rise"]) + (16 if kind == "gable" or kind == "hip" else int(float(roof.get("eave_drop", 8.0))) + 12)

	var img_h := int(sp.get("img_h", 0))
	if img_h <= 0:
		img_h = 8 + wall_h + top_space + 16
	var baseline := img_h - 8
	var wall_top := baseline - wall_h

	# 各层矩形（自下而上，含悬挑）
	var story_rects: Array = []
	var cum := 0.0
	var jetty := float(sp.get("jetty", 0.0))
	for i in stories.size():
		var s: Dictionary = stories[i]
		var j := jetty if i > 0 else 0.0
		var h := float(s["h"])
		story_rects.append({
			"rect": Rect2(j, float(baseline) - cum - h, float(px_w) - 2.0 * j, h),
			"grow": j,
			"h": h,
			"mat": s.get("mat", "plaster"),
			"trim": s.get("trim", ""),
			"windows": bool(s.get("windows", false)),
			"arch": bool(s.get("arch", false)),
			"shutters": bool(s.get("shutters", false)),
		})
		cum += h

	var L := {
		"ok": true,
		"spec_id": spec_id,
		"spec": sp,
		"width_cells": width_cells,
		"px_w": px_w,
		"img_h": img_h,
		"baseline_y": baseline,
		"wall_top": wall_top,
		"wall_h": wall_h,
		"body": Rect2(0, wall_top, px_w, wall_h),
		"stories": story_rects,
		"bays": [],
		"n_bays": 0,
		"door_idx": -1,
		"door_rect": Rect2(),
		"has_door": false,
		"roof": roof,
		"seed": seed_val,
	}

	if String(sp.get("layout", "none")) == "bays":
		_solve_bays(L, rng)

	return L


## 开间布局：端件固定宽，中段按名义开间宽均分为 N 个开间；门固定占正中开间，其余开间从池抽样且相邻不重复。
static func _solve_bays(L: Dictionary, rng: RandomNumberGenerator) -> void:
	var sp: Dictionary = L["spec"]
	var first: Dictionary = L["stories"][0] if not (L["stories"] as Array).is_empty() else {}
	var edge := float(sp.get("edge", 10.0))
	var px_w := int(L["px_w"])
	var middle := px_w - 2.0 * edge
	var n := maxi(1, roundi(middle / (float(sp.get("bay_w_cells", 2)) * 32.0)))
	var bw := middle / float(n)
	var door_idx := n / 2
	L["n_bays"] = n
	L["door_idx"] = door_idx
	var pool: Array = sp.get("bay_pool", DEFAULT_BAY_POOL)
	var last := "door"
	var story_h := float((first as Dictionary).get("h", float(L["wall_h"])))
	var story_bottom := float(L["baseline_y"])
	for i in n:
		var rect := Rect2(edge + float(i) * bw, story_bottom - story_h, bw, story_h)
		var kind := "blind"
		if i == door_idx:
			kind = "door"
		else:
			var cand := pool.duplicate()
			if cand.size() > 1:
				cand.erase(last)
			kind = String(cand[rng.randi_range(0, cand.size() - 1)])
		last = kind
		L["bays"].append({"kind": kind, "rect": rect, "index": i})
	# 门的实际绘制矩形（居中于门开间）
	if door_idx >= 0:
		var br: Rect2 = L["bays"][door_idx]["rect"]
		var dw := minf(br.size.x * 0.55, float(sp.get("door_w", 38.0)))
		var dh := minf(br.size.y * 0.66, float(sp.get("door_h", 44.0)))
		L["door_rect"] = Rect2(br.get_center().x - dw * 0.5, br.end.y - dh, dw, dh)
		L["has_door"] = true
