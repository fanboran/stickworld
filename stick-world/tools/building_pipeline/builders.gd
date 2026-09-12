## 建筑编排（build 域）：spec.builder 分发到具体类型的构件组合逻辑。
## 输入布局 L（solver 产出），输出运行时元数据 meta（与 PNG 配对入库）。
extends RefCounted

const Comps := preload("res://tools/building_pipeline/comps.gd")
const Painter := preload("res://tools/building_pipeline/draw/painter.gd")


static func build(p: Painter, L: Dictionary) -> Dictionary:
	var meta := _base_meta(L)
	match String(L["spec"]["builder"]):
		"house":
			_house(p, L, meta)
		"smithy":
			_smithy(p, L, meta)
		"warehouse":
			_warehouse(p, L, meta)
		_:
			push_error("未知 builder 类型 %s" % str(L["spec"]["builder"]))
	return meta


static func _base_meta(L: Dictionary) -> Dictionary:
	var W := int(L["width_cells"])
	return {
		"spec_id": L["spec_id"],
		"width_cells": W,
		"px": {"w": int(L["px_w"]) + 16, "h": int(L["img_h"]), "scale": 2, "baseline_y": int(L["baseline_y"])},
		"barrier": {},
		"front_wall": {},
		"interact_cells": {"from": 1, "to": W - 2},
		"workslots": [],
		"can_stand_on": false,
		"wall_tier": 0,
	}


## 民居：山墙朝前小屋，开间门窗 + 茅草人字顶。
static func _house(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var sp: Dictionary = L["spec"]
	var body: Rect2 = L["body"]
	var rng := p.branch("house_body")
	Comps.wall_plane(p, body, String(sp["mat_wall"]), "base", 2.4)
	# 角柱
	for x in [body.position.x + 2.0, body.end.x - 2.0]:
		p.stroke(PackedVector2Array([Vector2(x, body.position.y + 1), Vector2(x + rng.randf_range(-1.0, 1.0), body.end.y - 1)]), 3.4, {"rng": rng, "amp": 0.5})
	# 开间
	var i := 0
	for bay_v in L["bays"]:
		var bay: Dictionary = bay_v
		var br: Rect2 = bay["rect"]
		var inner := br.grow_individual(4, 5, 4, 6)
		match String(bay["kind"]):
			"door":
				Comps.door(p, inner, String(sp["mat_door"]), p.branch("door_%d" % i))
			"window":
				Comps.window(p, Rect2(inner.get_center() - Vector2(11, 10), Vector2(22, 20)), p.branch("win_%d" % i), i == 0 and L["width_cells"] >= 6)
			"timber":
				Comps.timber_bay(p, inner, String(sp["mat_trim"]), p.branch("timber_%d" % i))
			_:
				Comps.blind_bay(p, inner, p.branch("blind_%d" % i))
		i += 1
	# 屋顶
	var roof: Dictionary = L["roof"]
	Comps.gable_roof(p, body, roof, p.branch("roof"))
	# 接地投影
	_ground_shadow(p, L, 0.9)
	if L["has_door"]:
		meta["barrier"] = _r(body)
		meta["front_wall"] = _r(body)


## 铁匠铺：宽棚工坊，端柱+补柱，正面大敞口，炉口/铁砧工位，石烟囱。
static func _smithy(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var sp: Dictionary = L["spec"]
	var body: Rect2 = L["body"]
	var px_w := int(L["px_w"])
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var rng := p.branch("smithy_body")
	# 后墙（棚后暗一档）
	Comps.wall_plane(p, body, String(sp["mat_wall"]), "shadow", 2.2)
	# 柱（前柱压在后墙前，亮一档）
	var pillar_w := 5.0
	for x_v in L["pillar_xs"]:
		var x := float(x_v)
		p.face(Rect2(x - pillar_w * 0.5, wall_top, pillar_w, float(L["wall_h"])), "timber", "base")
		p.stroke(PackedVector2Array([Vector2(x - pillar_w * 0.5, wall_top + 1), Vector2(x - pillar_w * 0.5, baseline - 1)]), 1.6, {"rng": rng, "amp": 0.4, "taper": false})
	# 顶横梁
	p.stroke(PackedVector2Array([Vector2(2, wall_top + 2), Vector2(px_w - 2, wall_top + 2)]), 4.0, {"rng": rng, "amp": 0.6})
	# 正面敞口（工坊大开口）：内墙暗褐而非纯黑，顶部内阴影 + 后壁横板缝
	var open_h := float(sp["open_h"])
	var open_rect := Rect2(body.position.x + 22, baseline - open_h, body.size.x - 44, open_h)
	p.poly(_pts(open_rect), Color(0.24, 0.175, 0.115))
	var inner_rng := p.branch("open_inner")
	for k in 2:
		var sy := open_rect.position.y + open_h * (0.38 + 0.3 * float(k))
		p.stroke(PackedVector2Array([Vector2(open_rect.position.x + 3, sy), Vector2(open_rect.end.x - 3, sy)]), 1.2, {"rng": inner_rng, "amp": 0.4, "taper": false, "color": Color(0.1, 0.07, 0.05, 0.5)})
	Comps.eave_shade(p, Rect2(Vector2(open_rect.position.x, open_rect.position.y), Vector2(open_rect.size.x, open_h * 0.3)), 0.25)
	p.rect_stroke(open_rect, 2.2, {"rng": rng, "amp": 0.7})
	# 敞口内：炉口（左）+ 铁砧（右）
	var forge_x := px_w * float(sp["forge_ratio"])
	var forge_rect := Rect2(forge_x - 16, baseline - open_h * 0.72, 32, open_h * 0.62)
	Comps.forge_mouth(p, forge_rect, p.branch("forge"))
	Comps.anvil(p, Vector2(open_rect.end.x - 40, baseline - 3), 26.0, p.branch("anvil"))
	Comps.barrel(p, Vector2(open_rect.position.x + 14, baseline - 2), 22.0, p.branch("barrel"))
	# 宽棚：棚面平行四边形（下缘压住墙顶线避免漏底，顶缘抬高 awn.h）
	var awn: Dictionary = sp["awn"]
	var out := float(awn["out"])
	var awn_h := float(awn["h"])
	var eave_y := wall_top - 2.0
	var eave_l := Vector2(body.position.x - out, eave_y)
	var eave_r := Vector2(body.end.x + out, eave_y)
	var top_l := Vector2(body.position.x - out * 0.4, wall_top - awn_h)
	var top_r := Vector2(body.end.x + out * 0.4, wall_top - awn_h)
	p.quad_face([eave_l, eave_r, top_r, top_l], String(awn["mat"]), "base")
	p.stroke(PackedVector2Array([eave_l, eave_r]), 3.4, {"rng": rng, "amp": 0.7})
	p.stroke(PackedVector2Array([top_l, top_r]), 2.2, {"rng": rng, "amp": 0.7})
	p.stroke(PackedVector2Array([eave_l, top_l]), 2.0, {"rng": rng, "amp": 0.5, "taper": false})
	p.stroke(PackedVector2Array([eave_r, top_r]), 2.0, {"rng": rng, "amp": 0.5, "taper": false})
	# 棚下阴影压住敞口上缘
	Comps.eave_shade(p, Rect2(Vector2(eave_l.x, eave_y), Vector2(eave_r.x - eave_l.x, 12.0)), 0.2)
	# 石烟囱
	var ch: Dictionary = sp["chimney"]
	var ch_w := float(ch["w"])
	var ch_x := px_w * float(ch["x_ratio"])
	var ch_top := wall_top - awn_h - float(ch["top_above_awn"])
	Comps.chimney(p, Rect2(ch_x - ch_w * 0.5, ch_top, ch_w, (wall_top - awn_h) - ch_top + 10.0), ch_top, "stone", p.branch("chimney"))
	# 接地投影
	_ground_shadow(p, L, 1.0)
	meta["barrier"] = _r(body)
	meta["front_wall"] = _r(body)
	meta["workslots"] = [
		{"id": "forge", "x": int(forge_x), "y": int(baseline - 4)},
		{"id": "anvil", "x": int(open_rect.end.x - 40), "y": int(baseline - 4)},
	]


## 仓库：坡面朝前屋顶 + 板墙竖缝 + 大门。
static func _warehouse(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var sp: Dictionary = L["spec"]
	var body: Rect2 = L["body"]
	var rng := p.branch("wh_body")
	Comps.wall_plane(p, body, String(sp["mat_wall"]), "base", 2.4)
	# 角柱
	for x in [body.position.x + 2.0, body.end.x - 2.0]:
		p.face(Rect2(x - 3.0, body.position.y + 1.0, 6.0, body.size.y - 2.0), "dark_wood", "base")
	# 开间竖缝 + 内容
	var i := 0
	for bay_v in L["bays"]:
		var bay: Dictionary = bay_v
		var br: Rect2 = bay["rect"]
		match String(bay["kind"]):
			"door":
				var dw := float(int(sp["door_w_cells"]) * 32) - 10.0
				var dh := body.size.y * 0.66
				var dr := Rect2(br.get_center().x - dw * 0.5, body.end.y - dh, dw, dh)
				Comps.door(p, dr, String(sp["mat_door"]), p.branch("door_%d" % i), true)
			_:
				Comps.blind_bay(p, br.grow_individual(3, 4, 3, 4), p.branch("blind_%d" % i))
		i += 1
	# 屋顶
	Comps.slope_roof(p, body, L["roof"], p.branch("roof"))
	# 檐下吊一盏灯（宽 ≥ 8 格才有）
	if L["width_cells"] >= 8:
		var lamp_x := body.get_center().x + body.size.x * 0.28
		var lamp_y := body.position.y + 14.0
		p.stroke(PackedVector2Array([Vector2(lamp_x, body.position.y + 1), Vector2(lamp_x, lamp_y)]), 1.2, {"rng": rng, "amp": 0.3, "taper": false})
		p.poly(PackedVector2Array([Vector2(lamp_x - 5, lamp_y), Vector2(lamp_x + 5, lamp_y), Vector2(lamp_x + 4, lamp_y + 10), Vector2(lamp_x - 4, lamp_y + 10)]), Comps.DARK_HOLE)
		p.poly(PackedVector2Array([Vector2(lamp_x - 3, lamp_y + 2), Vector2(lamp_x + 3, lamp_y + 2), Vector2(lamp_x + 2, lamp_y + 8), Vector2(lamp_x - 2, lamp_y + 8)]), Color(Comps.GLOW.r, Comps.GLOW.g, Comps.GLOW.b, 0.85))
	# 接地投影 + 门口桶箱
	_ground_shadow(p, L, 0.95)
	Comps.barrel(p, Vector2(body.position.x + 14, float(L["baseline_y"]) - 2), 24.0, p.branch("wh_barrel"))
	if L["width_cells"] >= 6:
		Comps.crate(p, Rect2(body.end.x - 30, float(L["baseline_y"]) - 20, 20, 18), p.branch("wh_crate"))
	meta["barrier"] = _r(body)
	meta["front_wall"] = _r(body)


static func _ground_shadow(p, L: Dictionary, strength: float) -> void:
	var baseline := float(L["baseline_y"])
	var w := float(int(L["px_w"])) * 0.92
	var x0 := (float(int(L["px_w"])) - w) * 0.5
	var rect := Rect2(x0, baseline - 1.5, w, 4.5)
	p.poly(_pts(rect), Color(Comps.SHADE.r, Comps.SHADE.g, Comps.SHADE.b, 0.18 * strength))


static func _pts(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y),
	])


static func _r(r: Rect2) -> Dictionary:
	return {"x": int(r.position.x), "y": int(r.position.y), "w": int(r.size.x), "h": int(r.size.y)}
