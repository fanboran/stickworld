## 建筑类型预设（规格域）：中世纪欧洲城市建筑谱系，声明式参数。
## 尺寸单位 1x 像素（1 格 = 32px）。宽度合法域默认 3~16 格（各预设可加 min_w 收紧；城墙段为特例允许 1 格）。
## shell 类通用字段：
##   stories: 自下而上各层 [{h, mat, trim?, windows?, arch?, shutters?}]
##   jetty:   二层及以上每侧出挑 px（悬挑街屋）
##   roof:    {kind: gable|slope|hip|spire|flat, rise/spire_h/parapet, overhang, mat, ...}
##   extras:  ["plinth","chimney","sign","lantern","flag","bell","fence","awning"]
extends RefCounted

const PRESETS := {
	# ===== 街屋 / 民居 =====
	"cottage": {
		"label": "茅草农舍", "builder": "shell",
		"min_w": 3, "max_w": 12, "layout": "bays", "bay_w_cells": 2,
		"stories": [{"h": 46, "mat": "plaster", "trim": "timber", "windows": true}],
		"roof": {"kind": "gable", "rise": 40, "overhang": 9.0, "mat": "thatch", "gable_window": true},
		"extras": ["plinth", "chimney"],
	},
	"house": {
		"label": "民居", "builder": "shell",
		"min_w": 3, "max_w": 16, "layout": "bays", "bay_w_cells": 2,
		"stories": [{"h": 58, "mat": "plaster", "trim": "timber", "windows": true}],
		"roof": {"kind": "gable", "rise": 42, "overhang": 9.0, "mat": "thatch", "gable_window": false},
		"extras": ["plinth"],
	},
	"townhouse": {
		"label": "木骨街屋", "builder": "shell",
		"min_w": 4, "max_w": 16, "layout": "bays", "bay_w_cells": 2.4,
		"stories": [
			{"h": 46, "mat": "plaster", "windows": false},
			{"h": 40, "mat": "plaster", "windows": true},
		],
		"jetty": 5.0,
		"roof": {"kind": "gable", "rise": 34, "overhang": 10.0, "mat": "tile", "gable_window": true},
		"extras": ["plinth", "chimney", "lantern"],
	},
	"plaster_house": {
		"label": "抹灰街屋", "builder": "shell",
		"min_w": 4, "max_w": 16, "layout": "bays", "bay_w_cells": 2.4,
		"stories": [
			{"h": 44, "mat": "plaster", "windows": false},
			{"h": 38, "mat": "trim_white", "windows": true, "shutters": true},
		],
		"jetty": 0.0,
		"roof": {"kind": "gable", "rise": 32, "overhang": 8.0, "mat": "slate", "gable_window": true},
		"extras": ["plinth", "chimney"],
	},
	"tavern": {
		"label": "酒馆", "builder": "shell",
		"min_w": 4, "max_w": 14, "layout": "bays", "bay_w_cells": 2.4,
		"stories": [
			{"h": 48, "mat": "wood", "windows": true},
			{"h": 38, "mat": "plaster", "trim": "timber", "windows": true},
		],
		"jetty": 4.0,
		"roof": {"kind": "gable", "rise": 34, "overhang": 10.0, "mat": "tile", "gable_window": true},
		"extras": ["plinth", "sign", "lantern", "barrel"],
	},
	"bakery": {
		"label": "面包房", "builder": "shell",
		"min_w": 4, "max_w": 14, "layout": "bays", "bay_w_cells": 2.6,
		"stories": [
			{"h": 44, "mat": "brick", "windows": false},
			{"h": 34, "mat": "plaster", "windows": true},
		],
		"jetty": 0.0,
		"roof": {"kind": "gable", "rise": 30, "overhang": 8.0, "mat": "tile", "gable_window": false},
		"extras": ["plinth", "chimney_big", "sign", "lantern"],
	},
	"shop": {
		"label": "商铺", "builder": "shell",
		"min_w": 3, "max_w": 12, "layout": "bays", "bay_w_cells": 2.2,
		"stories": [{"h": 48, "mat": "wood", "windows": true}],
		"roof": {"kind": "gable", "rise": 32, "overhang": 9.0, "mat": "thatch_dry"},
		"extras": ["plinth", "sign", "awning", "barrel"],
	},
	"guildhall": {
		"label": "行会馆", "builder": "shell",
		"min_w": 8, "max_w": 16, "layout": "bays", "bay_w_cells": 3,
		"stories": [
			{"h": 52, "mat": "stone_light", "windows": false, "arch": true},
			{"h": 46, "mat": "brick", "windows": true, "arch": true},
		],
		"jetty": 0.0,
		"roof": {"kind": "gable", "rise": 40, "overhang": 10.0, "mat": "tile", "gable_window": true},
		"extras": ["plinth", "chimney", "bell", "flag"],
		"grand": true,
	},

	# ===== 铁匠铺四级（参考图 smithy.png）=====
	"smithy1": {"label": "茅草棚工坊", "builder": "smithy1", "min_w": 4, "max_w": 12, "img_h": 152, "layout": "none", "wall_h": 74},
	"smithy2": {"label": "木屋工坊", "builder": "smithy2", "min_w": 5, "max_w": 14, "img_h": 168, "layout": "none", "wall_h": 82},
	"smithy3": {"label": "石砌工坊", "builder": "smithy3", "min_w": 5, "max_w": 14, "img_h": 162, "layout": "none", "wall_h": 88},
	"smithy4": {"label": "砖石行会工坊", "builder": "smithy4", "min_w": 6, "max_w": 16, "img_h": 196, "layout": "none", "wall_h": 96},

	# ===== 公共 / 信仰 / 防御 =====
	"church": {
		"label": "教堂", "builder": "church",
		"min_w": 8, "max_w": 16, "img_h": 210, "layout": "none",
		"wall_h": 96,
	},
	"chapel": {
		"label": "小礼拜堂", "builder": "chapel",
		"min_w": 5, "max_w": 10, "img_h": 156, "layout": "none",
		"wall_h": 74,
	},
	"tower": {
		"label": "瞭望塔", "builder": "tower",
		"min_w": 3, "max_w": 7, "img_h": 168, "layout": "none",
		"wall_h": 130,
	},
	"gatehouse": {
		"label": "城门楼", "builder": "gatehouse",
		"min_w": 4, "max_w": 10, "img_h": 140, "layout": "none",
		"wall_h": 104,
	},
	"wall_seg": {
		"label": "城墙段", "builder": "wall_seg",
		"min_w": 1, "max_w": 3, "img_h": 90, "layout": "none",
		"wall_h": 62,
	},

	# ===== 田园 / 生产 =====
	"barn": {
		"label": "谷仓", "builder": "barn",
		"min_w": 5, "max_w": 16, "img_h": 144, "layout": "none",
		"wall_h": 72,
	},
	"stable": {
		"label": "马厩", "builder": "stable",
		"min_w": 4, "max_w": 12, "img_h": 122, "layout": "none",
		"wall_h": 64,
	},
	"windmill": {
		"label": "风车", "builder": "windmill",
		"min_w": 3, "max_w": 6, "img_h": 158, "layout": "none",
		"wall_h": 92,
	},
	"well": {
		"label": "水井", "builder": "well",
		"min_w": 3, "max_w": 6, "img_h": 70, "layout": "none",
		"wall_h": 30,
	},
	"market_stall": {
		"label": "市集摊", "builder": "market_stall",
		"min_w": 3, "max_w": 8, "img_h": 74, "layout": "none",
		"wall_h": 30,
	},
}
