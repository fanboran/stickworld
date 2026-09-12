## 地标与组合形态：草棚（柱撑）、灯塔、桥接屋（两翼单体 + 天桥，A/C 桥接语义）。
## 参考文档：docs/设计/系统/03-定居点与建筑.md「分裂 + 天桥」「露台/烟囱/招牌」。
extends RefCounted

const Comps := preload("res://tools/building_pipeline/comps.gd")
const Common := preload("res://tools/building_pipeline/builders/common.gd")
const Painter := preload("res://tools/building_pipeline/draw/painter.gd")


static func build(p: Painter, L: Dictionary, meta: Dictionary, kind: String) -> void:
	match kind:
		"shelter":
			_shelter(p, L, meta)
		"lighthouse":
			_lighthouse(p, L, meta)
		"bridge":
			_bridge(p, L, meta)


## 草棚：4~6 根粗木柱撑茅草双坡顶，四面透空（营地/集市/临时工棚）。
static func _shelter(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var rng := p.branch("shelter")
	# 棚内地面
	p.poly(Comps._rect_pts(Rect2(5.0, wall_top - 40.0, px_w - 10.0, baseline - wall_top + 40.0)), Color(0.56, 0.47, 0.33))
	p.tex("grass", Rect2(5.0, wall_top - 40.0, px_w - 10.0, baseline - wall_top + 40.0), 0.55)
	# 柱
	var n := maxi(3, roundi(px_w / 170.0) + 1)
	for i in n:
		var x := 18.0 + (px_w - 36.0) * float(i) / float(n - 1)
		var cw := 13.0
		p.face(Rect2(x - cw * 0.5, wall_top, cw, baseline - wall_top), "wood", "base")
		p.rect_stroke(Rect2(x - cw * 0.5, wall_top, cw, baseline - wall_top), 2.0, {"rng": rng, "amp": 0.5})
	# 横梁 + 斜撑
	p.stroke(PackedVector2Array([Vector2(6, wall_top + 6), Vector2(px_w - 6, wall_top + 6)]), 5.0, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([Vector2(22, wall_top + 6), Vector2(px_w * 0.5, wall_top - 56)]), 3.4, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([Vector2(px_w - 22, wall_top + 6), Vector2(px_w * 0.5, wall_top - 56)]), 3.4, {"rng": rng, "amp": 0.5})
	# 茅草顶
	Comps.gable_roof(p, Rect2(6.0, wall_top, px_w - 12.0, 20.0), {"rise": 100.0, "overhang": 30.0, "mat": "thatch"}, rng, false)
	# 道具
	Comps.barrel(p, Vector2(px_w * 0.14, baseline - 2.0), 42.0, p.branch("sh_barrel"))
	Comps.crate(p, Rect2(px_w * 0.78, baseline - 33.0, 33.0, 30.0), p.branch("sh_crate"))
	Comps.hay_pile(p, Vector2(px_w * 0.56, baseline - 1.0), 50.0, p.branch("sh_hay"))
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, L["body"])
	meta["workslots"] = [{"id": "rest", "x": int(px_w * 0.5), "y": int(baseline - 4.0)}]


## 灯塔：收分石塔 + 拱窗（守塔人）+ 顶灯室（火盆 + 光晕）。
static func _lighthouse(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var wall_h := float(L["wall_h"])
	var rng := p.branch("lh")
	# 收分塔身
	var bl := Vector2(px_w * 0.06, baseline)
	var br := Vector2(px_w * 0.94, baseline)
	var tr := Vector2(px_w * 0.72, wall_top)
	var tl := Vector2(px_w * 0.28, wall_top)
	var body := PackedVector2Array([bl, br, tr, tl])
	p.poly(body, p.mat_color("stone_light", "base"))
	p.hatch(body, 11.0, -68.0, 1.4, 0.14)
	p.stroke(PackedVector2Array([bl, br, tr, tl, bl]), 3.0, {"rng": rng, "amp": 0.5})
	# 石层缝 + 白色环形饰带（灯塔特征）
	for i in 4:
		var t := 0.18 + 0.2 * float(i)
		p.stroke(PackedVector2Array([bl.lerp(tl, t), br.lerp(tr, t)]), 2.0, {"rng": rng, "amp": 0.4, "taper": false})
	for band_i in 2:
		var t2 := 0.34 + 0.28 * float(band_i)
		var pts := PackedVector2Array()
		for k in 9:
			var tt := float(k) / 8.0
			pts.push_back(bl.lerp(tl, t2).lerp(br.lerp(tr, t2), tt))
		p.stroke(pts, 9.0, {"rng": rng, "amp": 0.3, "overshoot": 0.0, "taper": false, "color": p.mat_color("trim_white", "base")})
	# 拱窗 + 门
	Comps.arch_window(p, Rect2(px_w * 0.5 - 12.0, baseline - wall_h * 0.74, 24.0, 34.0), p.branch("lh_w1"), false)
	Comps.arch_window(p, Rect2(px_w * 0.5 - 12.0, baseline - wall_h * 0.45, 24.0, 34.0), p.branch("lh_w2"), false)
	Comps.door(p, Rect2(px_w * 0.5 - 24.0, baseline - wall_h * 0.26, 48.0, wall_h * 0.26), "wood_dark", p.branch("lh_door"), false, true)
	# 顶平台 + 灯室
	var deck := Rect2(tl.x - 8.0, wall_top - 12.0, tr.x - tl.x + 16.0, 12.0)
	p.face(deck, "trim_white", "base")
	p.rect_stroke(deck, 2.4, {"rng": rng, "amp": 0.5})
	var lamp := Rect2(tl.x + (tr.x - tl.x) * 0.28, wall_top - 56.0, (tr.x - tl.x) * 0.44, 44.0)
	p.face(lamp, "iron", "base")
	# 灯室内火光 + 光晕
	var inner := Rect2(lamp.position.x + 6.0, lamp.position.y + 8.0, lamp.size.x - 12.0, lamp.size.y - 16.0)
	p.poly(Comps._rect_pts(inner), Color(Comps.GLOW_HI.r, Comps.GLOW_HI.g, Comps.GLOW_HI.b, 0.9))
	var halo := PackedVector2Array()
	var hc := inner.get_center()
	for i in 22:
		var a := TAU * float(i) / 22.0
		halo.push_back(hc + Vector2(cos(a), sin(a)) * (lamp.size.x * 1.5))
	p.poly(halo, Color(0.98, 0.86, 0.5, 0.16))
	p.rect_stroke(lamp, 2.6, {"rng": rng, "amp": 0.5})
	# 顶盖 + 尖
	p.poly(PackedVector2Array([lamp.position + Vector2(-7, 0), Vector2(lamp.end.x + 7, lamp.position.y), Vector2(lamp.get_center().x, lamp.position.y - 26)]), p.mat_color("slate", "base"))
	p.stroke(PackedVector2Array([lamp.position + Vector2(-7, 0), Vector2(lamp.end.x + 7, lamp.position.y), Vector2(lamp.get_center().x, lamp.position.y - 26), lamp.position + Vector2(-7, 0)]), 2.6, {"rng": rng, "amp": 0.4})
	p.stroke(PackedVector2Array([Vector2(lamp.get_center().x, lamp.position.y - 26), Vector2(lamp.get_center().x, lamp.position.y - 40)]), 2.4, {"rng": rng, "amp": 0.2, "overshoot": 0.0})
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, Rect2(px_w * 0.1, wall_top, px_w * 0.8, wall_h))
	meta["workslots"] = [{"id": "beacon", "x": int(px_w * 0.5), "y": int(baseline - 4.0)}]


## 桥接屋：左右两翼单体（可不同材质层数）+ 中间天桥（桥面 + 栏杆 + 支撑），桥下可通行。
static func _bridge(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var wall_h := float(L["wall_h"])
	var rng := p.branch("bridge")
	var wing_w := px_w * 0.32
	var gap := px_w - wing_w * 2.0
	# 左翼：石砌（下级）
	Comps.wall_plane(p, Rect2(0.0, wall_top, wing_w, wall_h), "stone", "base", 2.6)
	Comps.arch_window(p, Rect2(wing_w * 0.5 - 14.0, wall_top + wall_h * 0.18, 28.0, 36.0), p.branch("br_wl"), false)
	Comps.door(p, Rect2(wing_w * 0.5 - 22.0, baseline - wall_h * 0.46, 44.0, wall_h * 0.46), "wood_dark", p.branch("br_dl"), false, true)
	Comps.slope_roof(p, Rect2(0.0, wall_top, wing_w, 12.0), {"rise": 54.0, "eave_drop": 12.0, "skew": 8.0, "overhang": 16.0, "mat": "slate"}, p.branch("br_rl"))
	# 右翼：木骨（上级）
	var rx := px_w - wing_w
	Comps.wall_plane(p, Rect2(rx, wall_top, wing_w, wall_h), "plaster", "base", 2.6)
	Comps.timber_bay(p, Rect2(rx + 8.0, wall_top + 8.0, wing_w - 16.0, wall_h - 16.0), "timber", p.branch("br_tr"))
	Comps.window(p, Rect2(rx + wing_w * 0.5 - 18.0, wall_top + wall_h * 0.2, 36.0, 38.0), p.branch("br_wr"), false)
	Comps.door(p, Rect2(rx + wing_w * 0.5 - 22.0, baseline - wall_h * 0.46, 44.0, wall_h * 0.46), "wood_dark", p.branch("br_dr"))
	Comps.gable_roof(p, Rect2(rx, wall_top, wing_w, 12.0), {"rise": 62.0, "overhang": 18.0, "mat": "thatch"}, p.branch("br_rr"), false)
	# 天桥（跨中，桥面在墙高中部）
	var deck_y := wall_top + wall_h * 0.42
	var deck := Rect2(wing_w - 6.0, deck_y, gap + 12.0, 12.0)
	p.face(deck, "wood", "base")
	p.rect_stroke(deck, 2.4, {"rng": rng, "amp": 0.5})
	# 栏杆（横杆 + 立柱）
	var yy := deck.position.y - 22.0
	p.stroke(PackedVector2Array([Vector2(deck.position.x, yy), Vector2(deck.end.x, yy)]), 2.6, {"rng": rng, "amp": 0.5})
	var post_x := deck.position.x + 6.0
	while post_x < deck.end.x - 4.0:
		p.stroke(PackedVector2Array([Vector2(post_x, deck.position.y), Vector2(post_x, deck.position.y - 22.0)]), 2.0, {"rng": rng, "amp": 0.4})
		post_x += rng.randf_range(22.0, 34.0)
	# 桥下支撑柱 + 桥洞阴影
	p.stroke(PackedVector2Array([Vector2(wing_w + gap * 0.25, deck.end.y), Vector2(wing_w + gap * 0.25, baseline)]), 6.0, {"rng": rng, "amp": 0.4, "taper": false})
	p.stroke(PackedVector2Array([Vector2(wing_w + gap * 0.75, deck.end.y), Vector2(wing_w + gap * 0.75, baseline)]), 6.0, {"rng": rng, "amp": 0.4, "taper": false})
	Comps.eave_shade(p, Rect2(Vector2(deck.position.x, deck.end.y), Vector2(deck.size.x, 8.0)), 0.22)
	Common.ground_shadow(p, L, 1.0)
	meta["barrier"] = Common.rect_meta(Rect2(0.0, wall_top, px_w, wall_h))
	meta["barriers"] = [
		Common.rect_meta(Rect2(0.0, wall_top, wing_w, wall_h)),
		Common.rect_meta(Rect2(rx, wall_top, wing_w, wall_h)),
	]
	meta["front_wall"] = meta["barrier"]
	meta["workslots"] = [{"id": "bridge", "x": int(px_w * 0.5), "y": int(deck.position.y - 6.0)}]
