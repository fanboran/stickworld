## 建筑类型预设（规格域）：参数化建模的类型差异全部在此声明。
## 尺寸均为 1x 像素（1 格 = 32px）；宽度合法域统一 3~16 格，另受各预设 min_w 约束。
extends RefCounted

const PRESETS := {
	"house": {
		"label": "民居",
		"builder": "house",
		"min_w": 3, "max_w": 16,
		"img_h": 132,
		"layout": "bays",
		"edge": 10.0,          # 端件（角柱）宽 px
		"bay_w_cells": 2,      # 名义开间宽（格），实际按中段宽均分
		"wall_h": 60,
		"mat_wall": "plaster", "mat_trim": "timber", "mat_door": "dark_wood",
		"roof": {"kind": "gable", "rise": 44, "overhang": 8.0, "mat": "thatch", "eave_mat": "thatch"},
		"bay_pool": ["window", "blind", "window", "timber"],
		"door": true,
		"chimney": false,
	},
	"smithy": {
		"label": "铁匠铺",
		"builder": "smithy",
		"min_w": 6, "max_w": 16,
		"img_h": 196,
		"layout": "pillars",
		"edge": 14.0,
		"pillar_gap": 96.0,    # 中段补柱基准间距
		"wall_h": 78,
		"mat_wall": "wood", "mat_trim": "dark_wood",
		"awn": {"h": 36, "out": 26.0, "mat": "thatch"},   # 宽棚：棚面抬高 h、前伸 out
		"open_h": 44,          # 正面敞口高（工坊大开口）
		"chimney": {"x_ratio": 0.22, "w": 16.0, "top_above_awn": 30.0},
		"forge_ratio": 0.18,   # 炉口中心 x（占宽比例）
	},
	"warehouse": {
		"label": "仓库",
		"builder": "warehouse",
		"min_w": 4, "max_w": 16,
		"img_h": 150,
		"layout": "bays",
		"edge": 12.0,
		"bay_w_cells": 3,
		"wall_h": 72,
		"mat_wall": "wood", "mat_trim": "dark_wood", "mat_door": "dark_wood",
		"roof": {"kind": "slope", "rise": 42, "eave_drop": 10.0, "skew": 7.0, "overhang": 9.0, "mat": "roof_wood"},
		"door_w_cells": 2,
		"door": true,
		"chimney": false,
	},
}
