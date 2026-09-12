## shell 装配器：声明式多层街屋（民居/街屋/酒馆/商铺/面包房/行会馆…）。
## 层几何由 solver 提供（含悬挑扩宽），此处只负责逐层墙面/开间/窗与屋顶装配。
extends RefCounted

const Comps := preload("res://tools/building_pipeline/comps.gd")
const Common := preload("res://tools/building_pipeline/builders/common.gd")
const Painter := preload("res://tools/building_pipeline/draw/painter.gd")


static func build(p: Painter, L: Dictionary, meta: Dictionary) -> void:
	var sp: Dictionary = L["spec"]
	var stories: Array = L["stories"]
	var body: Rect2 = L["body"]
	# 逐层
	for i in stories.size():
		var st: Dictionary = stories[i]
		_draw_story(p, L, i, st, i == stories.size() - 1)
	# 门（首层，门开间）
	if bool(L["has_door"]):
		var dr: Rect2 = L["door_rect"]
		var first: Dictionary = stories[0]
		Comps.door(p, dr, String(sp.get("mat_door", "wood_dark")), p.branch("door"), dr.size.x > 30.0, bool(first.get("arch", false)))
	# 屋顶（用顶层宽）
	_roof(p, L)
	for e_v in sp.get("extras", []):
		Common.extra(p, L, meta, String(e_v), p.branch("extra_" + String(e_v)))
	Common.ground_shadow(p, L, 1.0)
	Common.body_barrier(meta, body)


static func _draw_story(p: Painter, L: Dictionary, idx: int, st: Dictionary, is_top: bool) -> void:
	var r: Rect2 = st["rect"]
	var srng := p.branch("story_%d" % idx)
	Comps.wall_plane(p, r, String(st["mat"]), "base", 2.6)
	# 悬挑层：底部梁托 + 出挑阴影
	if float(st.get("grow", 0.0)) > 0.0:
		Comps.jetty_beams(p, r.position.x, r.end.x, r.end.y, "timber", srng)
		Comps.eave_shade(p, Rect2(Vector2(r.position.x, r.end.y), Vector2(r.size.x, 6.0)), 0.2)
	# 开间
	var trim := String(st.get("trim", ""))
	var has_windows := bool(st.get("windows", false))
	for bay_v in L["bays"]:
		var bay: Dictionary = bay_v
		var br: Rect2 = bay["rect"]
		var x0 := maxf(br.position.x, r.position.x + 3.0)
		var x1 := minf(br.end.x, r.end.x - 3.0)
		if x1 - x0 < 10.0:
			continue
		if String(bay["kind"]) == "door" and idx == 0:
			continue
		var inner := Rect2(x0, r.position.y + 4.0, x1 - x0, r.size.y - 9.0)
		if trim != "":
			Comps.timber_bay(p, inner, trim, srng)
		if has_windows:
			var ww := minf(inner.size.x * 0.52, 36.0)
			var wh := minf(inner.size.y * 0.46, 38.0)
			var wr := Rect2(inner.get_center().x - ww * 0.5, inner.position.y + inner.size.y * 0.2, ww, wh)
			Comps.window(p, wr, srng, idx == 0 and srng.randf() < 0.35, bool(st.get("arch", false)), bool(st.get("shutters", false)))
		elif trim == "":
			Comps.blind_bay(p, inner, srng)
	# 层顶腰线（非顶层，檐口由屋顶处理）
	if not is_top:
		Comps.belt_course(p, r, r.position.y, "timber", srng)


static func _roof(p: Painter, L: Dictionary) -> void:
	var roof: Dictionary = L["roof"]
	if roof.is_empty():
		return
	var top_rect: Rect2 = L["body"]
	var stories: Array = L["stories"]
	if not stories.is_empty():
		top_rect = (stories[stories.size() - 1] as Dictionary)["rect"]
	var rrng := p.branch("roof")
	match String(roof.get("kind", "gable")):
		"gable":
			Comps.gable_roof(p, top_rect, roof, rrng, bool(roof.get("gable_window", false)))
		"slope":
			Comps.slope_roof(p, top_rect, roof, rrng)
		"hip":
			Comps.hip_roof(p, top_rect, roof, rrng)
