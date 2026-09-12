## 建筑类型预设（规格域）：中世纪欧洲城市建筑谱系，声明式参数。
## 尺寸单位 1x 像素（1 格 = 32px）。**高度基准：火柴人身高 130px ≈ 4 格**
##   —— 单层层高约 120~140（≈1 个身高），屋顶 rise 84~150；城墙 192（tier3 高墙）；教堂钟楼 410+；塔 400。
## 宽度合法域默认 3~16 格（各预设可加 min_w 收紧；城墙段为特例允许 1 格）。
## shell 类通用字段：
##   stories: 自下而上各层 [{h, mat, trim?, windows?, arch?, shutters?}]（层数上限由材质定：稻草1/木板2/石头3/砖4）
##   jetty:   二层及以上每侧出挑 px（悬挑街屋）
##   roof:    {kind: gable|slope|hip|spire|flat, rise/spire_h/parapet, overhang, mat, ...}
##   extras:  ["plinth","chimney","chimney_big","sign","lantern","flag","bell","awning","barrel","hay","fence","stairs"]
extends RefCounted

const PRESETS := {
	# ===== 街屋 / 民居 / 商铺 =====
	"cottage": {
		"label": "茅草农舍", "builder": "shell",
		"min_w": 3, "max_w": 12, "layout": "bays", "bay_w_cells": 2,
		"stories": [{"h": 120, "mat": "plaster", "trim": "timber", "windows": true}],
		"roof": {"kind": "gable", "rise": 95, "overhang": 13.0, "mat": "thatch", "gable_window": true},
		"extras": ["plinth", "chimney", "barrel"],
	},
	"house": {
		"label": "民居", "builder": "shell",
		"min_w": 3, "max_w": 16, "layout": "bays", "bay_w_cells": 2,
		"stories": [{"h": 132, "mat": "plaster", "trim": "timber", "windows": true}],
		"roof": {"kind": "gable", "rise": 100, "overhang": 13.0, "mat": "thatch", "gable_window": false},
		"extras": ["plinth"],
	},
	"townhouse": {
		"label": "木骨街屋", "builder": "shell",
		"min_w": 4, "max_w": 16, "layout": "bays", "bay_w_cells": 2.4,
		"stories": [
			{"h": 120, "mat": "plaster", "windows": false},
			{"h": 112, "mat": "plaster", "trim": "timber", "windows": true},
		],
		"jetty": 7.0,
		"roof": {"kind": "gable", "rise": 88, "overhang": 15.0, "mat": "tile", "gable_window": true},
		"extras": ["plinth", "chimney", "lantern", "stairs"],
	},
	"plaster_house": {
		"label": "抹灰街屋", "builder": "shell",
		"min_w": 4, "max_w": 16, "layout": "bays", "bay_w_cells": 2.4,
		"stories": [
			{"h": 118, "mat": "plaster", "windows": false},
			{"h": 108, "mat": "trim_white", "windows": true, "shutters": true},
		],
		"jetty": 0.0,
		"roof": {"kind": "gable", "rise": 84, "overhang": 12.0, "mat": "slate", "gable_window": true},
		"extras": ["plinth", "chimney"],
	},
	"tavern": {
		"label": "酒馆", "builder": "shell",
		"min_w": 4, "max_w": 14, "layout": "bays", "bay_w_cells": 2.4,
		"stories": [
			{"h": 124, "mat": "wood", "windows": true},
			{"h": 104, "mat": "plaster", "trim": "timber", "windows": true},
		],
		"jetty": 6.0,
		"roof": {"kind": "gable", "rise": 90, "overhang": 15.0, "mat": "tile", "gable_window": true},
		"extras": ["plinth", "sign", "lantern", "barrel"],
	},
	"bakery": {
		"label": "面包房", "builder": "shell",
		"min_w": 4, "max_w": 14, "layout": "bays", "bay_w_cells": 2.6,
		"stories": [
			{"h": 118, "mat": "brick", "windows": false},
			{"h": 96, "mat": "plaster", "windows": true},
		],
		"jetty": 0.0,
		"roof": {"kind": "gable", "rise": 80, "overhang": 12.0, "mat": "tile", "gable_window": false},
		"extras": ["plinth", "chimney_big", "sign", "lantern"],
	},
	"shop": {
		"label": "商铺", "builder": "shell",
		"min_w": 3, "max_w": 12, "layout": "bays", "bay_w_cells": 2.2,
		"stories": [{"h": 132, "mat": "wood", "windows": true}],
		"roof": {"kind": "gable", "rise": 96, "overhang": 13.0, "mat": "thatch_dry"},
		"extras": ["plinth", "sign", "awning", "barrel"],
	},
	"guildhall": {
		"label": "行会馆", "builder": "shell",
		"min_w": 8, "max_w": 16, "layout": "bays", "bay_w_cells": 3,
		"stories": [
			{"h": 140, "mat": "stone_light", "windows": false, "arch": true},
			{"h": 126, "mat": "brick", "windows": true, "arch": true},
		],
		"jetty": 0.0,
		"roof": {"kind": "gable", "rise": 96, "overhang": 15.0, "mat": "tile", "gable_window": true},
		"extras": ["plinth", "chimney", "bell", "flag"],
		"grand": true,
	},
	"stone_upper": {
		"label": "石基木楼", "builder": "shell",
		"min_w": 4, "max_w": 12, "layout": "bays", "bay_w_cells": 2.4,
		"stories": [
			{"h": 140, "mat": "stone", "windows": false, "arch": true},
			{"h": 100, "mat": "thatch", "trim": "timber", "windows": true},
		],
		"jetty": 5.0,
		"roof": {"kind": "gable", "rise": 76, "overhang": 14.0, "mat": "thatch", "gable_window": false},
		"extras": ["plinth", "stairs", "barrel"],
	},

	# ===== 铁匠铺四级（参考图 smithy.png）=====
	"smithy1": {"label": "茅草棚工坊", "builder": "smithy1", "min_w": 4, "max_w": 12, "img_h": 300, "layout": "none", "wall_h": 150},
	"smithy2": {"label": "木屋工坊", "builder": "smithy2", "min_w": 5, "max_w": 14, "img_h": 350, "layout": "none", "wall_h": 176},
	"smithy3": {"label": "石砌工坊", "builder": "smithy3", "min_w": 5, "max_w": 14, "img_h": 320, "layout": "none", "wall_h": 190},
	"smithy4": {"label": "砖石行会工坊", "builder": "smithy4", "min_w": 6, "max_w": 16, "img_h": 400, "layout": "none", "wall_h": 210},

	# ===== 公共 / 信仰 / 防御 =====
	"church": {"label": "教堂", "builder": "church", "min_w": 8, "max_w": 16, "img_h": 600, "layout": "none", "wall_h": 260},
	"chapel": {"label": "小礼拜堂", "builder": "chapel", "min_w": 5, "max_w": 10, "img_h": 400, "layout": "none", "wall_h": 170},
	"tower": {"label": "瞭望塔", "builder": "tower", "min_w": 3, "max_w": 7, "img_h": 470, "layout": "none", "wall_h": 400},
	"gatehouse": {"label": "城门楼", "builder": "gatehouse", "min_w": 4, "max_w": 10, "img_h": 390, "layout": "none", "wall_h": 290},
	"wall_seg": {"label": "城墙段", "builder": "wall_seg", "min_w": 1, "max_w": 3, "img_h": 250, "layout": "none", "wall_h": 192},
	"lighthouse": {"label": "灯塔", "builder": "lighthouse", "min_w": 3, "max_w": 6, "img_h": 480, "layout": "none", "wall_h": 380},
	"shelter": {"label": "草棚", "builder": "shelter", "min_w": 3, "max_w": 12, "img_h": 300, "layout": "none", "wall_h": 150},
	"bridge_house": {"label": "桥接屋", "builder": "bridge", "min_w": 8, "max_w": 16, "img_h": 340, "layout": "none", "wall_h": 150},

	# ===== 田园 / 生产 =====
	"barn": {"label": "谷仓", "builder": "barn", "min_w": 5, "max_w": 16, "img_h": 360, "layout": "none", "wall_h": 150},
	"stable": {"label": "马厩", "builder": "stable", "min_w": 4, "max_w": 12, "img_h": 240, "layout": "none", "wall_h": 124},
	"windmill": {"label": "风车磨坊", "builder": "windmill", "min_w": 3, "max_w": 6, "img_h": 380, "layout": "none", "wall_h": 260},
	"well": {"label": "水井", "builder": "well", "min_w": 3, "max_w": 6, "img_h": 130, "layout": "none", "wall_h": 90},
	"market_stall": {"label": "市集摊", "builder": "market_stall", "min_w": 3, "max_w": 8, "img_h": 160, "layout": "none", "wall_h": 110},
}
