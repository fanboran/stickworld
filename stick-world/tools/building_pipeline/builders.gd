## build 域分发器：spec.builder → 具体建筑族装配器，返回运行时元数据。
extends RefCounted

const Common := preload("res://tools/building_pipeline/builders/common.gd")
const Shell := preload("res://tools/building_pipeline/builders/shell.gd")
const Smithy := preload("res://tools/building_pipeline/builders/smithy.gd")
const Civic := preload("res://tools/building_pipeline/builders/civic.gd")
const Rural := preload("res://tools/building_pipeline/builders/rural.gd")


static func build(p, L: Dictionary) -> Dictionary:
	var meta := Common.base_meta(L)
	var b := String(L["spec"]["builder"])
	match b:
		"shell":
			Shell.build(p, L, meta)
		"smithy1", "smithy2", "smithy3", "smithy4":
			Smithy.build(p, L, meta, b)
		"church", "chapel", "tower", "gatehouse", "wall_seg":
			Civic.build(p, L, meta, b)
		"barn", "stable", "windmill", "well", "market_stall":
			Rural.build(p, L, meta, b)
		_:
			push_error("未知 builder 类型 %s" % b)
	return meta
