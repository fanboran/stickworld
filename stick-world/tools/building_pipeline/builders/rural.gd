## 田园/生产建筑：谷仓、马厩、风车、水井、市集摊。
extends RefCounted

const Comps := preload("res://tools/building_pipeline/comps.gd")
const Common := preload("res://tools/building_pipeline/builders/common.gd")
const Painter := preload("res://tools/building_pipeline/draw/painter.gd")


static func build(p: Painter, L: Dictionary, meta: Dictionary, kind: String) -> void:
	match kind:
		"barn":
			_barn(p, L, meta)
		"stable":
			_stable(p, L, meta)
		"windmill":
			_windmill(p, L, meta)
		"well":
			_well(p, L, meta)
		"market_stall":
			_stall(p, L, meta)


## 谷仓：深木墙 + 大坡木板顶 + 大门 + 山墙通风窗 + 干草。
static func _barn(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var body: Rect2 = L["body"]
	var wall_h := float(L["wall_h"])
	var rng := p.branch("barn")
	Comps.wall_plane(p, body, "wood_dark", "base", 2.6)
	# 竖板缝
	var x := body.position.x + 18.0
	while x < body.end.x - 10.0:
		p.stroke(PackedVector2Array([Vector2(x, body.position.y + 3.0), Vector2(x, body.end.y - 2.0)]), 1.6, {"rng": rng, "amp": 0.5, "taper": false})
		x += rng.randf_range(36.0, 56.0)
	# 大门（宽双开）
	var dw := px_w * 0.34
	Comps.door(p, Rect2(px_w * 0.5 - dw * 0.5, baseline - wall_h * 0.74, dw, wall_h * 0.74), "wood_dark", p.branch("b_door"), true)
	# 山墙大顶 + 通风窗
	Comps.gable_roof(p, body, {"rise": 150.0, "overhang": 22.0, "mat": "roof_wood"}, p.branch("b_roof"), true)
	Comps.hay_pile(p, Vector2(body.end.x - 26.0, baseline - 1.0), 60.0, p.branch("b_hay"))
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, body)


## 马厩：木墙 + 前檐开口 + 干草 + 栅栏。
static func _stable(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var wall_h := float(L["wall_h"])
	var rng := p.branch("stable")
	var body: Rect2 = L["body"]
	Comps.wall_plane(p, body, "wood", "base", 2.6)
	# 前檐下的开放隔间（左 40%）
	var open_w := px_w * 0.4
	var open_rect := Rect2(body.position.x + 6.0, baseline - wall_h * 0.62, open_w, wall_h * 0.62)
	p.poly(Comps._rect_pts(open_rect), Color(0.23, 0.17, 0.11))
	Comps.eave_shade(p, Rect2(open_rect.position, Vector2(open_rect.size.x, open_rect.size.y * 0.32)), 0.3)
	p.rect_stroke(open_rect, 2.2, {"rng": rng, "amp": 0.6})
	# 隔间柱
	p.stroke(PackedVector2Array([Vector2(open_rect.end.x, open_rect.position.y), Vector2(open_rect.end.x, baseline)]), 3.4, {"rng": rng, "amp": 0.4, "taper": false})
	# 顶部坡檐（前伸低垂）
	var eave_y := wall_top + 16.0
	var out := 24.0
	p.quad_face([Vector2(-out, eave_y), Vector2(px_w + out, eave_y), Vector2(px_w - 2.0, wall_top - 56.0), Vector2(2.0, wall_top - 56.0)], "thatch_dry", "base")
	p.stroke(PackedVector2Array([Vector2(-out, eave_y), Vector2(px_w + out, eave_y)]), 3.0, {"rng": rng, "amp": 0.6})
	p.stroke(PackedVector2Array([Vector2(2.0, wall_top - 56.0), Vector2(px_w - 2.0, wall_top - 56.0)]), 2.0, {"rng": rng, "amp": 0.5})
	Comps.eave_shade(p, Rect2(Vector2(-out, eave_y), Vector2(px_w + out * 2.0, 9.0)), 0.22)
	# 门 + 干草 + 栅栏
	Comps.door(p, Rect2(px_w * 0.72, baseline - wall_h * 0.56, 46.0, wall_h * 0.56), "wood_dark", p.branch("st_door"))
	Comps.hay_pile(p, Vector2(body.get_center().x * 0.55 + open_w * 0.5, baseline - 1.0), 54.0, p.branch("st_hay"))
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, body)


## 风车：石砌塔身（下宽上窄）+ 锥顶 + 四叶。
static func _windmill(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var wall_h := float(L["wall_h"])
	var rng := p.branch("windmill")
	# 收分塔身（梯形）
	var bl := Vector2(px_w * 0.02, baseline)
	var br := Vector2(px_w * 0.98, baseline)
	var tr := Vector2(px_w * 0.78, wall_top)
	var tl := Vector2(px_w * 0.22, wall_top)
	var body := PackedVector2Array([bl, br, tr, tl])
	p.poly(body, p.mat_color("stone_dark", "base"))
	p.hatch(body, 9.0, -70.0, 1.1, 0.16)
	p.stroke(PackedVector2Array([bl, br, tr, tl, bl]), 2.8, {"rng": rng, "amp": 0.5})
	# 石层缝
	for i in 3:
		var t := 0.28 + 0.22 * float(i)
		p.stroke(PackedVector2Array([bl.lerp(tl, t), br.lerp(tr, t)]), 1.5, {"rng": rng, "amp": 0.4, "taper": false})
	# 门
	Comps.door(p, Rect2(px_w * 0.5 - 23.0, baseline - wall_h * 0.3, 46.0, wall_h * 0.3), "wood_dark", p.branch("wm_door"), false, true)
	# 锥顶
	var cap := PackedVector2Array([tl, tr, Vector2(px_w * 0.5, wall_top - 56.0)])
	p.poly(cap, p.mat_color("roof_wood", "base"))
	p.hatch(cap, 8.0, -50.0, 1.1, 0.2)
	p.stroke(PackedVector2Array([tl, tr, Vector2(px_w * 0.5, wall_top - 56.0), tl]), 2.6, {"rng": rng, "amp": 0.5})
	# 风车叶（hub 在塔身上部，四叶十字）
	var hub := Vector2(px_w * 0.5, wall_top + wall_h * 0.12)
	Comps.windmill_blades(p, hub, minf(74.0, px_w * 0.44), p.branch("wm_blades"))
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, Rect2(px_w * 0.05, wall_top, px_w * 0.9, wall_h))
	meta["workslots"] = [{"id": "grind", "x": int(px_w * 0.5), "y": int(baseline - 4.0)}]


## 水井。
static func _well(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var s := minf(px_w * 0.46, 62.0)
	Comps.well(p, Vector2(px_w * 0.5, baseline - 1.0), s, p.branch("well"))
	Common.ground_shadow(p, L, 0.7)
	Common.body_barrier(meta, Rect2(px_w * 0.5 - s * 0.6, baseline - s, s * 1.2, s))


## 市集摊。
static func _stall(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	Comps.stall(p, Vector2(px_w * 0.5, baseline - 1.0), px_w * 0.88, p.branch("stall"))
	Common.ground_shadow(p, L, 0.7)
	Common.body_barrier(meta, Rect2(px_w * 0.08, baseline - 34.0, px_w * 0.84, 34.0))
	meta["workslots"] = [{"id": "trade", "x": int(px_w * 0.5), "y": int(baseline - 4.0)}]
