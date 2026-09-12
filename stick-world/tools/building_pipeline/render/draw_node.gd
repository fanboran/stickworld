## 渲染域绘制节点：gen 入口注入布局 L，_draw 时构建画笔并执行建筑编排。
## 坐标系：1x 图内局部（本节点由入口挂 scale=2、x 偏移 8px 的出血余量）。
extends Node2D

const Painter := preload("res://tools/building_pipeline/draw/painter.gd")
const Builders := preload("res://tools/building_pipeline/builders.gd")

var L: Dictionary = {}


func _draw() -> void:
	if L.is_empty():
		return
	var p := Painter.new(self, int(L["seed"]))
	var meta := Builders.build(p, L)
	set_meta("meta", meta)
