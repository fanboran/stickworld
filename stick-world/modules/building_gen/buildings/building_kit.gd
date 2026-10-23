@tool
class_name BuildingKit
extends RefCounted
## 建筑装配共享套件 —— 跨建筑脚本逐字重复的装配件（全静态库，InteriorProps 同口径）。
##
## 外观件：
##   upper_door  二层门板（对接阳台，manor/grand_hall 同款）
## 室内件：
##   furnish_floor  室内地面铺装（Floor 容器，全部带内饰的建筑同款，仅基色不同）
##
## 调用方为 BuildingExterior 子类：经 width（格）与调色板 dict 传参。
## 节点装配语义与原各脚本逐行一致——本件只下沉结构，不改观感
## （基线约束：受入文件在行数棘轮在册，共享件一律放新文件）。

# ── 室内件 ──────────────────────────────────────────────────

## 室内地面铺装（Interior/Floor 容器）：暗色横条 + 前缘压线，随建筑宽度铺满。
## width_cells = 建筑格宽（Building.width）；base = 夯土/木板基色（各建筑自定）。
static func furnish_floor(floor_node: Node2D, width_cells: int, base: Color) -> void:
	var w := float(width_cells) * 32.0 - 24.0
	var slab := InteriorProps.make_floor(int(w), 24, base)
	slab.position = Vector2(float(width_cells) * 16.0, -12)
	floor_node.add_child(slab)


# ── 外观件 ──────────────────────────────────────────────────

## 二层门板（对接阳台，平顶门 + 横板条 + 门楣）：manor/grand_hall 同款小件。
## cx/floor_y = 门板锚点（Exterior 局部，门底落楼面 y）；pal 取 C_WOOD_BEAM。
## 注：原装配经基类 _nc 建 "UpperDoor" 根（该名不在 LAYER_Z，z_index 不赋值），
## 本件直接建裸 Node2D，行为一致。
static func upper_door(parent: Node2D, cx: float, floor_y: float, pal: Dictionary) -> void:
	var root := Node2D.new()
	root.name = "UpperDoor"
	root.position = Vector2(cx, floor_y)
	parent.add_child(root)
	var wood: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var half := 24.0
	var h := 54.0
	var door := Polygon2D.new()
	door.name = "Door"
	door.polygon = PackedVector2Array([
		Vector2(-half, 0), Vector2(-half, -h), Vector2(half, -h), Vector2(half, 0)])
	door.color = wood.lightened(0.08)
	root.add_child(door)
	for i in 2:
		var bar := Line2D.new()
		bar.name = "Plank%d" % i
		var y := -16.0 - float(i) * 18.0
		bar.points = PackedVector2Array([Vector2(-half + 2, y), Vector2(half - 2, y)])
		bar.width = 2.0
		bar.default_color = wood.darkened(0.4)
		root.add_child(bar)
	# 门洞套框（顶横梁提示）
	var lintel := Polygon2D.new()
	lintel.name = "Lintel"
	lintel.polygon = PackedVector2Array([
		Vector2(-half - 5.0, -h - 10.0), Vector2(half + 5.0, -h - 10.0),
		Vector2(half + 5.0, -h), Vector2(-half - 5.0, -h)])
	lintel.color = wood.darkened(0.2)
	root.add_child(lintel)
