@tool
extends BuildingExterior
## 草棚 —— 标准 16 格茅草屋外壳（房屋类建筑默认外壳）。
##
## 外观由 BuildingExterior 基类程序化生成（按 width 平铺，支持任意宽度），
## 调色板数据见 placeholder.tscn 注入的 thatch_hut_palette.tres。对应 def placeholder（建造菜单里的"草棚"）。
##
## 内饰（批次 4）：民居生活布局——床+草席+方桌（油灯/碗）+储物箱/木桶+墙挂干辣椒串。

func _furnish_floor(floor_node: Node2D) -> void:
	var w := float(width) * 32.0 - 24.0
	var slab := InteriorProps.make_floor(int(w), 24, Color(0.40, 0.32, 0.21))
	slab.position = Vector2(float(width) * 16.0, -12)
	floor_node.add_child(slab)


func _furnish_interior(props: Node2D) -> void:
	var w := float(width) * 32.0
	# 左区：睡床（暗红毯）+ 床头陶罐
	var bed := InteriorProps.make_bed("Bed", Color(0.56, 0.26, 0.20))
	bed.position = Vector2(95, 0)
	props.add_child(bed)
	var jug := InteriorProps.jug("Jug", 10.0)
	jug.position = Vector2(24, -8)
	props.add_child(jug)
	# 中区：草席 + 方桌（油灯+碗）+ 两凳
	var rug := InteriorProps.make_rug("Rug", 96.0)
	rug.position = Vector2(192, -4)
	props.add_child(rug)
	var table := InteriorProps.make_table("Table", 110.0)
	table.position = Vector2(295, 0)
	props.add_child(table)
	var lamp := InteriorProps.make_lamp("Lamp")
	lamp.position = Vector2(276, -62)
	props.add_child(lamp)
	var bowl := InteriorProps.make_bowl("Bowl", 11.0)
	bowl.position = Vector2(318, -62)
	props.add_child(bowl)
	for i in 2:
		var stool := InteriorProps.make_stool("Stool%d" % i)
		stool.position = Vector2(243.0 + float(i) * 104.0, 0)
		props.add_child(stool)
	# 右区：储物矮箱 + 木桶（锚右缘）
	var chest := InteriorProps.make_chest("Chest", 54.0)
	chest.position = Vector2(w - 92, 0)
	props.add_child(chest)
	var barrel := InteriorProps.make_barrel("Barrel", 50.0)
	barrel.position = Vector2(w - 40, 0)
	props.add_child(barrel)
	# 后墙：干辣椒串（挂横梁下，暖色生活气）
	var hang := InteriorProps.make_hang_string("HangChili", Color(0.72, 0.26, 0.14))
	hang.position = Vector2(w * 0.42, -230)
	props.add_child(hang)

