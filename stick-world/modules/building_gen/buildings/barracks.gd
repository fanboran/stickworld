@tool
extends BuildingExterior
## 兵营 —— 军事化外壳：深木色 + 檐口军旗 + 盾牌圆饰。
##
## ⚠️ PLACEHOLDER 素材（2026-08-22）：旗/盾为程序化几何占位，
## 替换清单见 docs/项目/待办事项.md「PLACEHOLDER 素材替换」——
## 后续替换方向：手绘军旗贴图、盾徽纹章、旗杆摆动动画。


func _get_palette() -> Dictionary:
	return {
		"C_THATCH_BACK": Color(0.44, 0.32, 0.17),
		"C_THATCH_MAIN": Color(0.58, 0.43, 0.23),
		"C_THATCH_LEFT": Color(0.50, 0.37, 0.20),
		"C_WOOD_FRONT": Color(0.33, 0.22, 0.12),
		"C_WOOD_BACK": Color(0.25, 0.17, 0.10),
		"C_WOOD_BEAM": Color(0.28, 0.19, 0.11),
		"C_WOOD_STRUT": Color(0.30, 0.21, 0.12),
	}


func _post_build(ext: Node2D) -> void:
	var pal := _get_palette()
	var right_edge: float = float(width) * 32.0 - EXT_OFFSET_X

	# 檐口军旗：旗杆（细柱）+ 垂幅（双色条带），挂右端屋顶上方
	var l5 := ext.get_node_or_null("L5_Roof") as Node2D
	if l5 != null:
		var pole_tex = TextureGenApi.make_wood_pillar(8, 96, pal.C_WOOD_BEAM)
		_a(l5, _sprite2d("BannerPole", Vector2(right_edge - 30.0, -392), pole_tex))
		# 垂幅：红底 + 下缘三角剪角（两段多边形近似）
		var flag_red := make_solid_poly("BannerCloth", Vector2(-26, 74),
				pal.get("C_ACCENT", Color(0.62, 0.18, 0.14)))
		flag_red.position = Vector2(right_edge + 4.0, -352)
		_a(l5, flag_red)
		# 中带浅条纹
		var flag_stripe := make_solid_poly("BannerStripe", Vector2(-26, 22),
				Color(0.88, 0.80, 0.60))
		flag_stripe.position = Vector2(right_edge + 4.0, -336)
		_a(l5, flag_stripe)

	# 前墙盾牌圆饰 ×2（八边形近似圆，深底浅缘）
	var l4 := ext.get_node_or_null("L4_FrontWall") as Node2D
	if l4 != null:
		for i in 2:
			var shield := make_shield("Shield%d" % i, 34.0,
					Color(0.70, 0.58, 0.38), Color(0.24, 0.16, 0.10))
			shield.position = Vector2(70.0 + float(i) * 130.0, -140)
			_a(l4, shield)


## 实心矩形多边形（w×h，中心锚点）
func make_solid_poly(node_name: String, size: Vector2, color: Color) -> Polygon2D:
	var hw := size.x * 0.5
	var hh := size.y * 0.5
	var p := Polygon2D.new()
	p.name = node_name
	p.polygon = PackedVector2Array([
		Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(-hw, hh)])
	p.color = color
	return p


## 八边形近似盾面：外圈木缘 + 内盘浅色
func make_shield(node_name: String, radius: float, face: Color, rim: Color) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var pts_out := PackedVector2Array()
	var pts_in := PackedVector2Array()
	for i in 8:
		var a := TAU * float(i) / 8.0 + TAU / 16.0
		pts_out.append(Vector2(cos(a), sin(a)) * radius)
		pts_in.append(Vector2(cos(a), sin(a)) * radius * 0.78)
	var outer := Polygon2D.new()
	outer.name = "Rim"
	outer.polygon = pts_out
	outer.color = rim
	root.add_child(outer)
	var inner := Polygon2D.new()
	inner.name = "Face"
	inner.polygon = pts_in
	inner.color = face
	root.add_child(inner)
	return root
