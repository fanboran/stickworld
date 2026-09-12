## build 域公共工具：元数据骨架、地面投影、通用 extras（烟囱/招牌/灯笼/旗/钟/遮阳棚/桶/栅栏）。
extends RefCounted

const Comps := preload("res://tools/building_pipeline/comps.gd")
const Painter := preload("res://tools/building_pipeline/draw/painter.gd")


static func base_meta(L: Dictionary) -> Dictionary:
	var w := int(L["width_cells"])
	return {
		"spec_id": L["spec_id"],
		"width_cells": w,
		"px": {"w": int(L["px_w"]) + 16, "h": int(L["img_h"]), "scale": 2, "baseline_y": int(L["baseline_y"])},
		"barrier": {},
		"front_wall": {},
		"interact_cells": {"from": 1, "to": maxi(1, w - 2)},
		"workslots": [],
		"can_stand_on": false,
		"wall_tier": 0,
	}


static func rect_meta(r: Rect2) -> Dictionary:
	return {"x": int(r.position.x), "y": int(r.position.y), "w": int(r.size.x), "h": int(r.size.y)}


static func body_barrier(meta: Dictionary, body: Rect2) -> void:
	meta["barrier"] = rect_meta(body)
	meta["front_wall"] = rect_meta(body)


static func ground_shadow(p: Painter, L: Dictionary, strength: float = 1.0) -> void:
	Comps.ground_shadow(p, float(int(L["px_w"])) * 0.5, float(int(L["px_w"])), float(L["baseline_y"]), strength)


## 通用装饰分发（spec.extras 逐项调用）。
static func extra(p: Painter, L: Dictionary, meta: Dictionary, name: String, rng: RandomNumberGenerator) -> void:
	var body: Rect2 = L["body"]
	var px_w := float(int(L["px_w"]))
	var baseline := float(L["baseline_y"])
	var wall_top := float(L["wall_top"])
	var roof: Dictionary = L["roof"]
	var rise := float(roof.get("rise", 30.0)) if not roof.is_empty() else 30.0
	match name:
		"plinth":
			Comps.plinth(p, body, String(L["spec"].get("mat_plinth", "stone_dark")), 9.0, rng)
		"chimney", "chimney_big":
			var big := name == "chimney_big"
			var mat := String(L["spec"].get("mat_chimney", "brick" if big else "stone"))
			var cw := 20.0 if big else 14.0
			var cx := body.position.x + px_w * (0.26 if not big else 0.78)
			var ctop := wall_top - rise * 0.72 - (26.0 if big else 20.0)
			Comps.chimney(p, Rect2(cx - cw * 0.5, ctop, cw, wall_top - ctop + rise * 0.3), ctop, mat, rng)
		"sign":
			var sx := body.position.x + px_w * 0.22
			Comps.sign_board(p, Vector2(sx, wall_top + 16.0), 1, rng)
		"lantern":
			Comps.lantern(p, Vector2(body.end.x - px_w * 0.18, wall_top + 4.0), rng)
		"flag":
			Comps.flag(p, Vector2(body.get_center().x, wall_top - rise), 26.0, "cloth_red", rng)
		"bell":
			var bc := Vector2(body.get_center().x, wall_top - rise * 0.42)
			p.stroke(PackedVector2Array([Vector2(bc.x - 9.0, wall_top - rise * 0.62), bc + Vector2(-9.0, 6.0)]), 2.2, {"rng": rng, "amp": 0.3, "taper": false})
			p.stroke(PackedVector2Array([Vector2(bc.x + 9.0, wall_top - rise * 0.62), bc + Vector2(9.0, 6.0)]), 2.2, {"rng": rng, "amp": 0.3, "taper": false})
			p.stroke(PackedVector2Array([Vector2(bc.x - 11.0, wall_top - rise * 0.62), Vector2(bc.x + 11.0, wall_top - rise * 0.66)]), 2.2, {"rng": rng, "amp": 0.3, "taper": false})
			Comps.bell(p, bc, 16.0, rng)
		"awning":
			# 首层窗上条纹遮阳棚（商铺）
			var aw := px_w * 0.72
			var ay := baseline - float(L["wall_h"]) * 0.62
			var ac := Vector2(body.get_center().x, ay)
			var quad_l := Vector2(ac.x - aw * 0.5, ay)
			var quad_r := Vector2(ac.x + aw * 0.5, ay)
			var top_l := Vector2(ac.x - aw * 0.44, ay - 16.0)
			var top_r := Vector2(ac.x + aw * 0.44, ay - 16.0)
			p.quad_face([quad_l, quad_r, top_r, top_l], "cloth_red", "base")
			p.stroke(PackedVector2Array([quad_l, quad_r]), 2.6, {"rng": rng, "amp": 0.5})
			p.stroke(PackedVector2Array([top_l, top_r]), 2.2, {"rng": rng, "amp": 0.5})
			p.stroke(PackedVector2Array([quad_l, top_l]), 1.8, {"rng": rng, "amp": 0.3, "taper": false})
			p.stroke(PackedVector2Array([quad_r, top_r]), 1.8, {"rng": rng, "amp": 0.3, "taper": false})
		"barrel":
			Comps.barrel(p, Vector2(body.position.x + 14.0, baseline - 2.0), 24.0, rng)
			Comps.crate(p, Rect2(body.end.x - 28.0, baseline - 19.0, 19.0, 17.0), rng)
		"hay":
			Comps.hay_pile(p, Vector2(body.end.x - 22.0, baseline - 1.0), 30.0, rng)
		"fence":
			Comps.fence(p, body.position.x + 4.0, body.end.x - 4.0, baseline - 1.0, 16.0, rng)
		_:
			pass
