## 注册表：def_id → spec 预设 + 烘焙宽度档清单（中世纪欧洲城市建筑谱系）。
## 宽度合法域默认 3~16 格；城墙段为特例允许 1 格（按段拼接）。
extends RefCounted

const DEFS := {
	# ===== 街屋 / 民居 / 商铺 =====
	"cottage": {"spec": "cottage", "widths": [3, 4, 6, 8]},
	"house": {"spec": "house", "widths": [3, 4, 6, 8, 12, 16]},
	"townhouse": {"spec": "townhouse", "widths": [4, 6, 8, 12, 16]},
	"plaster_house": {"spec": "plaster_house", "widths": [4, 6, 8, 12]},
	"tavern": {"spec": "tavern", "widths": [4, 6, 8, 12]},
	"bakery": {"spec": "bakery", "widths": [4, 6, 8, 10]},
	"shop": {"spec": "shop", "widths": [3, 4, 6, 8]},
	"guildhall": {"spec": "guildhall", "widths": [8, 10, 12, 16]},
	"stone_upper": {"spec": "stone_upper", "widths": [4, 6, 8, 10]},
	# ===== 铁匠铺四级 =====
	"smithy1": {"spec": "smithy1", "widths": [4, 6, 8, 10]},
	"smithy2": {"spec": "smithy2", "widths": [5, 6, 8, 10]},
	"smithy3": {"spec": "smithy3", "widths": [5, 6, 8, 10]},
	"smithy4": {"spec": "smithy4", "widths": [6, 8, 10, 12]},
	# ===== 公共 / 信仰 / 防御 =====
	"church": {"spec": "church", "widths": [8, 10, 12, 14, 16]},
	"chapel": {"spec": "chapel", "widths": [5, 6, 8, 10]},
	"tower": {"spec": "tower", "widths": [3, 4, 5]},
	"gatehouse": {"spec": "gatehouse", "widths": [4, 6, 8, 10]},
	"wall_seg": {"spec": "wall_seg", "widths": [1, 2, 3]},
	# ===== 地标 / 组合形态 =====
	"shelter": {"spec": "shelter", "widths": [3, 4, 6, 8]},
	"lighthouse": {"spec": "lighthouse", "widths": [3, 4, 5]},
	"bridge_house": {"spec": "bridge_house", "widths": [8, 10, 12, 16]},
	# ===== 田园 / 生产 =====
	"barn": {"spec": "barn", "widths": [5, 6, 8, 10, 12]},
	"stable": {"spec": "stable", "widths": [4, 6, 8, 10]},
	"windmill": {"spec": "windmill", "widths": [3, 4, 5]},
	"well": {"spec": "well", "widths": [3, 4]},
	"market_stall": {"spec": "market_stall", "widths": [3, 4, 6]},
}

## 分组（验收拼页按组出图，避免单页过大）。
const GROUPS := {
	"street": ["cottage", "house", "townhouse", "plaster_house", "tavern", "bakery", "shop", "guildhall", "stone_upper"],
	"smithy": ["smithy1", "smithy2", "smithy3", "smithy4"],
	"civic": ["church", "chapel", "tower", "gatehouse", "wall_seg"],
	"landmark": ["shelter", "lighthouse", "bridge_house"],
	"rural": ["barn", "stable", "windmill", "well", "market_stall"],
}
