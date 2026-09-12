## 铁匠铺四级（对齐参考图 assets/_raw/建筑/smithy.png）：
##   smithy1 茅草开放棚 → smithy2 木屋工坊 → smithy3 石砌工坊 → smithy4 砖石行会工坊
extends RefCounted

const Comps := preload("res://tools/building_pipeline/comps.gd")
const Common := preload("res://tools/building_pipeline/builders/common.gd")
const Painter := preload("res://tools/building_pipeline/draw/painter.gd")


static func build(p: Painter, L: Dictionary, meta: Dictionary, tier: String) -> void:
	match tier:
		"smithy1":
			_tier1(p, L)
		"smithy2":
			_tier2(p, L)
		"smithy3":
			_tier3(p, L)
		"smithy4":
			_tier4(p, L)
	_props(p, L, meta)
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, L["body"])


## Lv1 茅草开放棚：粗木柱 + 双坡茅草顶，四面通透，内摆铁炉/铁砧/桶/凳。
static func _tier1(p: Painter, L: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var rng := p.branch("s1")
	# 后景地面（棚内浅色地坪）
	p.poly(Comps._rect_pts(Rect2(6.0, wall_top - 50.0, px_w - 12.0, baseline - wall_top + 50.0)), Color(0.86, 0.79, 0.66))
	# 柱（前柱醒目，后柱略暗）
	var n := maxi(3, roundi(px_w / 170.0) + 1)
	for i in n:
		var x := 14.0 + (px_w - 28.0) * float(i) / float(n - 1)
		var cw := 12.0
		p.face(Rect2(x - cw * 0.5, wall_top, cw, baseline - wall_top), "wood", "base")
		p.rect_stroke(Rect2(x - cw * 0.5, wall_top, cw, baseline - wall_top), 1.8, {"rng": rng, "amp": 0.4})
	# 柱顶横梁
	p.stroke(PackedVector2Array([Vector2(6, wall_top + 5), Vector2(px_w - 6, wall_top + 5)]), 4.4, {"rng": rng, "amp": 0.5})
	# 斜撑（两端人字撑）
	p.stroke(PackedVector2Array([Vector2(18, wall_top + 3), Vector2(px_w * 0.5, wall_top - 58)]), 3.0, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([Vector2(px_w - 18, wall_top + 3), Vector2(px_w * 0.5, wall_top - 30)]), 3.0, {"rng": rng, "amp": 0.5})
	# 茅草双坡顶（山墙朝前）
	var roof := {"rise": 100.0, "overhang": 28.0, "mat": "thatch"}
	Comps.gable_roof(p, Rect2(6.0, wall_top, px_w - 12.0, 18.0), roof, rng, false)


## Lv2 木屋工坊：木板墙全包，左侧敞口见炉，木板双坡顶，铁炉烟囱穿顶。
static func _tier2(p: Painter, L: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var body: Rect2 = L["body"]
	var rng := p.branch("s2")
	Comps.wall_plane(p, body, "wood", "base", 2.6)
	# 左侧敞口（占 38%）
	var open_w := px_w * 0.38
	var open_rect := Rect2(body.position.x + 6.0, baseline - float(L["wall_h"]) * 0.66, open_w, float(L["wall_h"]) * 0.66)
	p.poly(Comps._rect_pts(open_rect), Color(0.24, 0.175, 0.115))
	Comps.eave_shade(p, Rect2(open_rect.position, Vector2(open_rect.size.x, open_rect.size.y * 0.3)), 0.3)
	p.rect_stroke(open_rect, 2.4, {"rng": rng, "amp": 0.6})
	# 敞口上方墙面承接梁
	p.stroke(PackedVector2Array([Vector2(open_rect.end.x, open_rect.position.y), Vector2(open_rect.end.x, baseline)]), 3.0, {"rng": rng, "amp": 0.4, "taper": false})
	# 右侧大窗（十字棂）
	Comps.window(p, Rect2(px_w * 0.62, wall_top + float(L["wall_h"]) * 0.3, 46.0, 42.0), p.branch("s2_win"), false)
	# 门（右侧）
	var dr := Rect2(px_w * 0.88, baseline - float(L["wall_h"]) * 0.66, 46.0, float(L["wall_h"]) * 0.66)
	Comps.door(p, dr, "wood_dark", p.branch("s2_door"))
	# 木板双坡顶（山墙朝前，山墙窗）
	var roof := {"rise": 116.0, "overhang": 18.0, "mat": "roof_wood"}
	Comps.gable_roof(p, body, roof, p.branch("s2_roof"), true)


## Lv3 石砌工坊：亮灰石墙 + 平缓石瓦顶 + 拱窗/拱门 + 上部矮墙小窗。
static func _tier3(p: Painter, L: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var body: Rect2 = L["body"]
	var wall_h := float(L["wall_h"])
	var rng := p.branch("s3")
	Comps.wall_plane(p, body, "stone_light", "base", 2.6)
	# 上部矮墙线（二层平台感）
	var belt_y := wall_top + wall_h * 0.34
	Comps.belt_course(p, body, belt_y, "stone_dark", p.branch("s3_belt"))
	Comps.arch_window(p, Rect2(px_w * 0.3, wall_top + wall_h * 0.06, 36.0, 40.0), p.branch("s3_upw1"), false)
	Comps.arch_window(p, Rect2(px_w * 0.6, wall_top + wall_h * 0.06, 20.0, 22.0), p.branch("s3_upw2"), false)
	# 左下部敞口 + 内炉
	var open_rect := Rect2(body.position.x + 8.0, baseline - wall_h * 0.52, px_w * 0.5, wall_h * 0.52)
	p.poly(Comps._rect_pts(open_rect), Color(0.22, 0.21, 0.19))
	Comps.eave_shade(p, Rect2(open_rect.position, Vector2(open_rect.size.x, open_rect.size.y * 0.3)), 0.32)
	p.rect_stroke(open_rect, 2.4, {"rng": rng, "amp": 0.6})
	# 右拱窗 + 拱门
	Comps.arch_window(p, Rect2(px_w * 0.66, baseline - wall_h * 0.5, 54.0, 62.0), p.branch("s3_awin"), false)
	# 平缓石瓦顶
	Comps.slope_roof(p, body, {"rise": 62.0, "eave_drop": 14.0, "skew": 10.0, "overhang": 20.0, "mat": "slate"}, p.branch("s3_roof"))


## Lv4 砖石行会工坊：红砖墙 + 白石饰（壁柱/山花/饰带）+ 拱窗 + 深红瓦遮棚。
static func _tier4(p: Painter, L: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var body: Rect2 = L["body"]
	var wall_h := float(L["wall_h"])
	var rng := p.branch("s4")
	Comps.wall_plane(p, body, "brick", "base", 2.6)
	# 白石壁柱（左右）
	for sx in [body.position.x + 3.0, body.end.x - 9.0]:
		var pr := Rect2(float(sx), wall_top + 7.0, 11.0, wall_h - 12.0)
		p.face(pr, "trim_white", "base")
		p.rect_stroke(pr, 1.8, {"rng": rng, "amp": 0.4})
	# 层间白石饰带
	var belt := Rect2(body.position.x + 2.0, wall_top + wall_h * 0.42, body.size.x - 6.0, 13.0)
	p.face(belt, "trim_white", "base")
	p.rect_stroke(belt, 1.8, {"rng": rng, "amp": 0.4})
	# 拱窗（上部）
	Comps.arch_window(p, Rect2(px_w * 0.24, wall_top + wall_h * 0.5, 46.0, 54.0), p.branch("s4_w1"), false)
	Comps.arch_window(p, Rect2(px_w * 0.62, wall_top + wall_h * 0.5, 26.0, 30.0), p.branch("s4_w2"), false)
	# 深红瓦遮棚（悬于工坊区上方，前伸明显）
	var out := 30.0
	var eave_y := baseline - wall_h * 0.48
	var span_l := body.position.x + px_w * 0.14
	var span_r := body.end.x - px_w * 0.14
	var eave_l := Vector2(span_l - out, eave_y)
	var eave_r := Vector2(span_r + out, eave_y)
	var top_l := Vector2(span_l, eave_y - 46.0)
	var top_r := Vector2(span_r, eave_y - 46.0)
	p.quad_face([eave_l, eave_r, top_r, top_l], "tile", "base")
	p.stroke(PackedVector2Array([eave_l, eave_r]), 3.2, {"rng": rng, "amp": 0.6})
	p.stroke(PackedVector2Array([top_l, top_r]), 2.2, {"rng": rng, "amp": 0.5})
	p.stroke(PackedVector2Array([eave_l, top_l]), 2.0, {"rng": rng, "amp": 0.4, "taper": false})
	p.stroke(PackedVector2Array([eave_r, top_r]), 2.0, {"rng": rng, "amp": 0.4, "taper": false})
	Comps.eave_shade(p, Rect2(Vector2(eave_l.x, eave_y), Vector2(eave_r.x - eave_l.x, 9.0)), 0.22)
	# 前柱（落到地面）
	for sx in [eave_l.x + 10.0, eave_r.x - 10.0]:
		p.face(Rect2(float(sx) - 5.0, eave_y, 10.0, baseline - eave_y), "timber", "base")
		p.rect_stroke(Rect2(float(sx) - 5.0, eave_y, 10.0, baseline - eave_y), 2.0, {"rng": rng, "amp": 0.4})
	# 山花（顶部三角 + 涡卷）
	var apex := Vector2(body.get_center().x, wall_top - wall_h * 0.2)
	p.poly(PackedVector2Array([Vector2(body.position.x + 6.0, wall_top), Vector2(body.end.x - 6.0, wall_top), apex]), p.mat_color("trim_white", "base"))
	p.hatch(PackedVector2Array([Vector2(body.position.x + 6.0, wall_top), Vector2(body.end.x - 6.0, wall_top), apex]), 9.0, -50.0, 1.2, 0.18)
	p.stroke(PackedVector2Array([Vector2(body.position.x + 6.0, wall_top), Vector2(body.end.x - 6.0, wall_top), apex, Vector2(body.position.x + 6.0, wall_top)]), 2.4, {"rng": rng, "amp": 0.5})
	for k in 2:
		var dir := -1.0 if k == 0 else 1.0
		var cx := body.get_center().x + dir * px_w * 0.15
		var cy := wall_top + 6.0
		var scroll := PackedVector2Array()
		for i in 14:
			var t := float(i) / 13.0
			var ang := dir * (PI * 1.6 * t)
			var rad := 15.0 * (1.0 - t * 0.7)
			scroll.push_back(Vector2(cx + dir * t * 16.0 + cos(ang) * rad * 0.7, cy - t * 20.0 + sin(ang) * rad * 0.5))
		p.stroke(scroll, 2.0, {"rng": rng, "amp": 0.35, "overshoot": 1.0, "taper": false})
	# 山花中央宝瓶饰
	p.stroke(PackedVector2Array([Vector2(body.get_center().x, wall_top + 4.0), Vector2(body.get_center().x, wall_top - wall_h * 0.12)]), 3.0, {"rng": rng, "amp": 0.3, "overshoot": 1.0})
	p.circle(Vector2(body.get_center().x, wall_top - wall_h * 0.13), 4.5, p.mat_color("trim_white", "base"))
	with_roof(p, L, rng)


## Lv4 顶部瓦顶（山花之上）。
static func with_roof(p: Painter, L: Dictionary, rng: RandomNumberGenerator) -> void:
	var body: Rect2 = L["body"]
	Comps.slope_roof(p, Rect2(body.position.x + 14.0, body.position.y - 34.0, body.size.x - 28.0, 34.0), {"rise": 40.0, "eave_drop": 10.0, "skew": 6.0, "overhang": 14.0, "mat": "tile"}, rng)


## 四级共用工坊道具：铁炉（含穿顶烟囱）+ 铁砧 + 桶 + 凳。
static func _props(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var rng := p.branch("smithy_props")
	var tier := String(L["spec"]["builder"])
	var forge_x := px_w * (0.46 if tier == "smithy1" else 0.24)
	var forge_s := 80.0
	var chimney_h := 0.0
	if tier == "smithy1":
		chimney_h = 60.0
	elif tier == "smithy2":
		# 烟囱穿出木板屋顶（参考图 Lv2 特征）
		chimney_h = float(L["wall_h"]) + 60.0
	Comps.forge_stove(p, Vector2(forge_x, baseline - 2.0), forge_s, p.branch("forge"), chimney_h)
	var anvil_x := px_w * (0.2 if tier == "smithy1" else 0.78)
	Comps.anvil(p, Vector2(anvil_x, baseline - 2.0), 46.0, p.branch("anvil"))
	Comps.barrel(p, Vector2(px_w * 0.08, baseline - 2.0), 42.0, p.branch("barrel"))
	Comps.bench(p, Vector2(px_w * (0.86 if tier != "smithy1" else 0.62), baseline - 2.0), 50.0, p.branch("bench"))
	meta["workslots"] = [
		{"id": "forge", "x": int(forge_x), "y": int(baseline - 4.0)},
		{"id": "anvil", "x": int(anvil_x), "y": int(baseline - 4.0)},
	]
