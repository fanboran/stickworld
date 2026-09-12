## 公共/信仰/防御建筑：教堂、小礼拜堂、瞭望塔、城门楼、城墙段。
extends RefCounted

const Comps := preload("res://tools/building_pipeline/comps.gd")
const Common := preload("res://tools/building_pipeline/builders/common.gd")
const Painter := preload("res://tools/building_pipeline/draw/painter.gd")


static func build(p: Painter, L: Dictionary, meta: Dictionary, kind: String) -> void:
	match kind:
		"church":
			_church(p, L, meta)
		"chapel":
			_chapel(p, L, meta)
		"tower":
			_tower(p, L, meta)
		"gatehouse":
			_gatehouse(p, L, meta)
		"wall_seg":
			_wall_seg(p, L, meta)


## 教堂：左钟楼（尖顶+钟）+ 中殿（玫瑰窗+拱门+拱窗）+ 石板瓦顶。
static func _church(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var wall_h := float(L["wall_h"])
	var rng := p.branch("church")
	var tow_w := maxf(84.0, px_w * 0.26)
	# 中殿
	var nave := Rect2(tow_w * 0.55, wall_top, px_w - tow_w * 0.55, wall_h)
	Comps.wall_plane(p, nave, "stone_light", "base", 2.6)
	Comps.belt_course(p, nave, wall_top + wall_h * 0.3, "stone_dark", p.branch("ch_nave_belt"))
	# 玫瑰窗 + 拱门 + 侧拱窗
	Comps.rose_window(p, Vector2(nave.get_center().x, wall_top + wall_h * 0.34), minf(42.0, wall_h * 0.16), p.branch("ch_rose"))
	var dw := 54.0
	Comps.door(p, Rect2(nave.get_center().x - dw * 0.5, baseline - wall_h * 0.5, dw, wall_h * 0.5), "wood_dark", p.branch("ch_door"), false, true)
	for k in 2:
		var ax := nave.position.x + nave.size.x * (0.18 + 0.64 * float(k))
		Comps.arch_window(p, Rect2(ax - 17.0, wall_top + wall_h * 0.52, 34.0, 42.0), p.branch("ch_aw%d" % k), false)
	# 中殿屋顶
	Comps.slope_roof(p, Rect2(nave.position.x, wall_top, nave.size.x, 10.0), {"rise": 26.0, "eave_drop": 8.0, "skew": 6.0, "overhang": 9.0, "mat": "slate"}, p.branch("ch_roof"))
	# 钟楼（在前，遮住中殿左侧）
	var tow_h := wall_h + 150.0
	var tower := Rect2(4.0, wall_top - tow_h + wall_h, tow_w, tow_h)
	Comps.wall_plane(p, tower, "stone_light", "base", 2.8)
	Comps.belt_course(p, tower, tower.position.y + tow_h * 0.42, "trim_white", p.branch("ch_tow_belt"))
	# 钟窗（拱）+ 钟
	Comps.arch_window(p, Rect2(tower.get_center().x - 19.0, tower.position.y + tow_h * 0.46, 38.0, 46.0), p.branch("ch_belfry"), false)
	Comps.bell(p, Vector2(tower.get_center().x, tower.position.y + tow_h * 0.34), 30.0, p.branch("ch_bell"))
	# 塔顶石檐 + 尖顶
	var eave := Rect2(tower.position.x - 9.0, tower.position.y - 11.0, tower.size.x + 18.0, 14.0)
	p.face(eave, "trim_white", "base")
	p.rect_stroke(eave, 2.2, {"rng": rng, "amp": 0.5})
	Comps.spire(p, eave, {"spire_h": 130.0, "mat": "slate"}, p.branch("ch_spire"))
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, Rect2(0, wall_top, px_w, wall_h))


## 小礼拜堂：石堂身 + 拱窗 + 拱门 + 山墙小尖顶。
static func _chapel(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var body: Rect2 = L["body"]
	var wall_h := float(L["wall_h"])
	var rng := p.branch("chapel")
	Comps.wall_plane(p, body, "stone", "base", 2.6)
	Comps.belt_course(p, body, body.position.y + wall_h * 0.34, "stone_dark", p.branch("cp_belt"))
	Comps.arch_window(p, Rect2(px_w * 0.2, body.position.y + wall_h * 0.42, 34.0, 46.0), p.branch("cp_w1"), false)
	Comps.arch_window(p, Rect2(px_w * 0.66, body.position.y + wall_h * 0.42, 18.0, 24.0), p.branch("cp_w2"), false)
	Comps.door(p, Rect2(px_w * 0.5 - 25.0, baseline - wall_h * 0.56, 50.0, wall_h * 0.56), "wood_dark", p.branch("cp_door"), false, true)
	var roof := {"rise": 84.0, "overhang": 18.0, "mat": "slate"}
	Comps.gable_roof(p, body, roof, p.branch("cp_roof"), true)
	# 山墙顶尖塔
	var apex := Vector2(body.get_center().x, body.position.y - 84.0)
	Comps.spire(p, Rect2(apex.x - 17.0, apex.y, 34.0, 10.0), {"spire_h": 74.0, "mat": "slate"}, p.branch("cp_spire"))
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, body)


## 瞭望塔：石塔 + 箭窗三层 + 顶部垛口。
static func _tower(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var wall_h := float(L["wall_h"])
	var rng := p.branch("tower")
	var body := Rect2(px_w * 0.08, wall_top, px_w * 0.84, wall_h)
	Comps.wall_plane(p, body, "stone_dark", "base", 2.8)
	for i in 3:
		var y := wall_top + wall_h * (0.16 + 0.24 * float(i))
		Comps.arch_window(p, Rect2(body.get_center().x - 11.0, y, 22.0, 32.0), p.branch("tw_w%d" % i), false)
	Comps.door(p, Rect2(body.get_center().x - 23.0, baseline - wall_h * 0.26, 46.0, wall_h * 0.26), "wood_dark", p.branch("tw_door"), false, true)
	Comps.battlement(p, body.position.x - 4.0, body.end.x + 4.0, wall_top, 26.0, "stone_dark", p.branch("tw_batt"))
	# 塔身收分线
	p.stroke(PackedVector2Array([Vector2(body.position.x + 3.0, wall_top), Vector2(body.position.x + 3.0, baseline)]), 2.0, {"rng": rng, "amp": 0.4, "taper": false})
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, body)
	meta["can_stand_on"] = true
	meta["wall_tier"] = 3


## 城门楼：双塔 + 中央拱门洞 + 垛口。
static func _gatehouse(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var wall_h := float(L["wall_h"])
	var rng := p.branch("gate")
	var tow_w := px_w * 0.28
	# 门洞两侧墙体 + 上部连墙
	var lintel_top := baseline - wall_h * 0.62
	var wall := Rect2(0.0, wall_top, px_w, wall_h)
	Comps.wall_plane(p, wall, "stone", "base", 2.6)
	# 中央拱门洞
	var door_w := px_w * 0.34
	Comps.door(p, Rect2(px_w * 0.5 - door_w * 0.5, lintel_top, door_w, baseline - lintel_top), "wood_dark", p.branch("g_door"), true, true)
	# 门洞上方小窗
	Comps.arch_window(p, Rect2(px_w * 0.5 - 15.0, wall_top + wall_h * 0.14, 30.0, 38.0), p.branch("g_win"), false)
	# 两侧塔
	for k in 2:
		var tx := 2.0 if k == 0 else px_w - tow_w - 2.0
		var tower := Rect2(tx, wall_top - 24.0, tow_w, wall_h + 24.0)
		Comps.wall_plane(p, tower, "stone", "base", 2.8)
		Comps.arch_window(p, Rect2(tower.get_center().x - 13.0, wall_top + wall_h * 0.3, 26.0, 34.0), p.branch("g_tw%d" % k), false)
		Comps.battlement(p, tower.position.x - 3.0, tower.end.x + 3.0, wall_top - 24.0, 26.0, "stone", p.branch("g_batt%d" % k))
	# 中间垛口
	Comps.battlement(p, tow_w + 6.0, px_w - tow_w - 6.0, wall_top, 26.0, "stone", p.branch("g_battm"))
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, wall)
	meta["can_stand_on"] = true
	meta["wall_tier"] = 3


## 城墙段（1 格可平铺）：石墙 + 顶部垛口。
static func _wall_seg(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var body: Rect2 = L["body"]
	var rng := p.branch("wall")
	Comps.wall_plane(p, body, "stone", "base", 2.4)
	# 中部腰线
	p.stroke(PackedVector2Array([Vector2(body.position.x, wall_top + body.size.y * 0.45), Vector2(body.end.x, wall_top + body.size.y * 0.45)]), 1.6, {"rng": rng, "amp": 0.4, "taper": false})
	Comps.battlement(p, body.position.x, body.end.x, wall_top, 24.0, "stone", p.branch("w_batt"))
	Common.ground_shadow(p, L, 0.9)
	Common.body_barrier(meta, body)
	meta["can_stand_on"] = true
	meta["wall_tier"] = 2
