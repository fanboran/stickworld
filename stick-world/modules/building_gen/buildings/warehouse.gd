@tool
extends BuildingExterior
## 仓库 —— 商贸外壳：暖木色 + 檐下货箱堆 + 门侧麻袋。
##
## ⚠️ PLACEHOLDER 素材（2026-08-22）：货箱/麻袋为程序化几何占位，
## 替换清单见 docs/项目/待办事项.md「PLACEHOLDER 素材替换」——
## 后续替换方向：木箱贴图（木板纹+包角）、麻袋手绘、货物种类随库存变化。



func _post_build(ext: Node2D) -> void:
	var pal := _get_palette()
	var right_edge: float = float(width) * 32.0 - EXT_OFFSET_X
	var crate_face := Color(0.55, 0.40, 0.22)
	var crate_edge := Color(0.38, 0.27, 0.15)

	# 前墙右侧货箱堆：2 底 1 顶，错缝摆放
	var l4 := ext.get_node_or_null("L4_FrontWall") as Node2D
	if l4 != null:
		var base_y := -52.0
		for i in 2:
			l4.add_child(_crate("Crate%d" % i,
					Vector2(right_edge - 96.0 + float(i) * 62.0, base_y), crate_face, crate_edge))
		l4.add_child(_crate("CrateTop",
				Vector2(right_edge - 65.0, base_y - 58.0), crate_face.lightened(0.06), crate_edge))

	# 左端麻袋 ×2（椭圆堆叠）
	var l1 := ext.get_node_or_null("L1_BackWall") as Node2D
	if l1 != null:
		for i in 2:
			var sack := make_sack("Sack%d" % i, Color(0.72, 0.64, 0.46))
			sack.position = Vector2(-150.0 + float(i) * 54.0, -30.0 - float(i) * 6.0)
			l1.add_child(sack)


## 货箱：面板 + 四边包角压条
func _crate(node_name: String, pos: Vector2, face: Color, edge: Color) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	root.position = pos
	var s := 52.0
	var half := s * 0.5
	var panel := Polygon2D.new()
	panel.name = "Panel"
	panel.polygon = PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	panel.color = face
	root.add_child(panel)
	# 横向压条 ×2
	for i in 2:
		var bar := Polygon2D.new()
		bar.name = "Bar%d" % i
		var y := -half * 0.5 + float(i) * half
		bar.polygon = PackedVector2Array([
			Vector2(-half, y - 4), Vector2(half, y - 4), Vector2(half, y + 4), Vector2(-half, y + 4)])
		bar.color = edge
		root.add_child(bar)
	# 对角线（木板拼缝示意）
	var diag := Line2D.new()
	diag.name = "Diag"
	diag.points = PackedVector2Array([Vector2(-half, -half), Vector2(half, half)])
	diag.width = 3.0
	diag.default_color = edge
	root.add_child(diag)
	return root


## 麻袋：胖椭圆 + 扎口结
func make_sack(node_name: String, color: Color) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var body := Polygon2D.new()
	body.name = "Body"
	var pts := PackedVector2Array()
	for i in 12:
		var a := TAU * float(i) / 12.0
		var r := Vector2(30.0, 22.0)
		pts.append(Vector2(cos(a) * r.x, sin(a) * r.y))
	body.polygon = pts
	body.color = color
	root.add_child(body)
	var tie := Polygon2D.new()
	tie.name = "Tie"
	tie.polygon = PackedVector2Array([
		Vector2(-8, -26), Vector2(8, -26), Vector2(5, -34), Vector2(-5, -34)])
	tie.color = color.darkened(0.35)
	root.add_child(tie)
	return root


# ── 内饰（批次 4）：仓储布局——双货架+麻袋堆+箱堆+吊挂蒜串+地面散货 ──

func _furnish_floor(floor_node: Node2D) -> void:
	var w := float(width) * 32.0 - 24.0
	var slab := InteriorProps.make_floor(int(w), 24, Color(0.38, 0.28, 0.17))
	slab.position = Vector2(float(width) * 16.0, -12)
	floor_node.add_child(slab)


func _furnish_interior(props: Node2D) -> void:
	var w := float(width) * 32.0
	# 左/中区：双货架（格内杂物 seed 错开）
	for i in 2:
		var shelf := InteriorProps.make_shelf("Shelf%d" % i, 130.0, 150.0, 4, 11 + i * 17)
		shelf.position = Vector2(96.0 + float(i) * 170.0, 0)
		props.add_child(shelf)
	# 货架间隙：立式木桶（散货）
	var barrel := InteriorProps.make_barrel("LooseBarrel", 44.0)
	barrel.position = Vector2(181, 0)
	props.add_child(barrel)
	# 右区：麻袋三角堆（底 2 顶 1）+ 箱堆（底 2 顶 1）
	var s0 := InteriorProps.make_sack("Sack0", Color(0.72, 0.64, 0.46))
	s0.position = Vector2(368, -6)
	props.add_child(s0)
	var s1 := InteriorProps.make_sack("Sack1", Color(0.66, 0.58, 0.42))
	s1.position = Vector2(416, -4)
	props.add_child(s1)
	var s2 := InteriorProps.make_sack("SackTop", Color(0.76, 0.68, 0.50))
	s2.position = Vector2(392, -26)
	props.add_child(s2)
	for i in 2:
		var c := InteriorProps.crate_prop("Crate%d" % i, 44.0)
		c.position = Vector2(452.0 + float(i) * 44.0, 0)
		props.add_child(c)
	var ct := InteriorProps.crate_prop("CrateTop", 40.0)
	ct.position = Vector2(474, -44)
	props.add_child(ct)
	# 后墙：吊挂蒜串（仓库储粮气）
	var hang := InteriorProps.make_hang_string("HangGarlic", Color(0.78, 0.72, 0.52))
	hang.position = Vector2(348, -232)
	props.add_child(hang)
	# 地面散货：一只滚落的麻袋（微倾生活感）
	var loose := InteriorProps.make_sack("LooseSack", Color(0.60, 0.54, 0.40))
	loose.position = Vector2(258, -2)
	loose.rotation = 0.10
	props.add_child(loose)
