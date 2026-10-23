class_name CityGen
extends RefCounted
## 初始城市生成器（GD 运行时版，与 tools/blender_buildings/gen_initial_city.py
## 同算法；建筑池按 docs/设计/系统/16-聚落等级与建筑分级.md 的**级别窗口表**取）。
##
## 语义（创始人 2026-09-15 裁决）：
##   · 城市大小 = 建筑排完的自然跨度 + 墙留边，不写死——建筑变多城市扩展，
##     城墙自动前移（运行时从 width_cells 推导），野地资源窗随之露出；
##   · 核心居中，市场/工匠/居住/生产/仓储五带随机分配到某侧（轻量配平，非镜像）；
##   · 居住/仓储随机塞；教堂等特殊建筑浮动插位；从中心向两侧逐栋排布；
##   · 画面宽推挤 + 产物级修复，零重叠；
##   · 背景两层（row1/row2）随分区锚点落。
##
## 选池铁律（级别窗口表 §三）：铁匠 3 级封顶、草棚/干草棚村舍进城消亡、
## 花店 town 起（DRESS）、仓库 city 起——别把村舍摆进首都。
## 行政槽：每档主街中心必有一件当级行政建筑（§二），候选按优先级取
## 第一张**已烘卡**（未烘自动降级，不阻塞生成）。
##
## 生成时机：宿主首次进入该城时按**确定性种子**生成（多局尽量一致）。
##
## 管线分域（generate 只做编排，各段实现在同目录三份纯函数域文件）：
##   city_gen_seq.gd    第 1~3.7 段 序列规划（档位配置/侧位配平/区队列/拼接杂物配额）
##   city_gen_layout.gd 第 4~5 段   街道排布（行政居中整格排布/背景两层）
##   city_gen_dress.gd  第 6~7 段   街具与组装（道具互斥落位/组装修复）

const SeqPlan := preload("res://modules/world/scripts/map/city_gen_seq.gd")
const StreetLayout := preload("res://modules/world/scripts/map/city_gen_layout.gd")
const StreetDress := preload("res://modules/world/scripts/map/city_gen_dress.gd")


## 道具卡宽表（格 = props.json units[0]/32；兼当"已烘卡名集合"用——
## has()/is_empty() 语义与卡名集合一致，值=卡画面宽供组内肩并肩排布）。
## 街具节奏里的未烘卡由调用侧过滤。
static func prop_names() -> Dictionary:
	var out: Dictionary = {}
	for base_path: String in ["res://temp/proto_hd2d/props.json",
			"res://tests/dev/proto_hd2d/tex/proto_hd2d/props.json"]:
		if not FileAccess.file_exists(base_path):
			continue
		var f := FileAccess.open(base_path, FileAccess.READ)
		if f == null:
			continue
		var v: Variant = JSON.parse_string(f.get_as_text())
		if v is Array:
			for c: Variant in v:
				out[str(c["card"])] = float(c["units"][0]) / 32.0
			break
	return out


## 卡画面宽表（格）：temp/proto25d/cards.json，缺失回退 tex 入库副本
static func card_widths() -> Dictionary:
	var out: Dictionary = {}
	for base_path: String in ["res://temp/proto25d/cards.json",
			"res://tests/dev/proto_hd2d/tex/proto25d/cards.json"]:
		if not FileAccess.file_exists(base_path):
			continue
		var f := FileAccess.open(base_path, FileAccess.READ)
		if f == null:
			continue
		var v: Variant = JSON.parse_string(f.get_as_text())
		if v is Array:
			for c: Variant in v:
				var name: String = str(c["card"])
				out[name] = float(c["units"][0]) / 32.0
			break
	if out.is_empty():   # 兜底：全按 8 格
		for d: String in ["guildhall", "shop", "bakery", "tavern", "smithy1", "smithy2",
				"smithy3", "smithy4", "house", "cottage", "hayloft", "rowhouse",
				"townhouse", "barn", "windmill", "stable", "warehouse", "alchemy",
				"library", "mage_tower", "barracks", "shelter", "tower", "cathedral",
				"council_hall", "gatehouse"]:
			for w: int in [4, 6, 8, 12, 16]:
				out["%s_w%d" % [d, w]] = float(w) + 2.0
	return out


## 道具卡占地表：props.json footprint = [宽格, 纵深格]——杂物占格宽按**真实
## 地面占地宽**（footprint[0]）向上取整（画面宽含透视外扩，按它取整小件
## 虚占格子），贴楼脚 z 落深按纵深分量（footprint[1]）推导。
static func prop_footprints() -> Dictionary:
	var out: Dictionary = {}
	for base_path: String in ["res://temp/proto_hd2d/props.json",
			"res://tests/dev/proto_hd2d/tex/proto_hd2d/props.json"]:
		if not FileAccess.file_exists(base_path):
			continue
		var f := FileAccess.open(base_path, FileAccess.READ)
		if f == null:
			continue
		var v: Variant = JSON.parse_string(f.get_as_text())
		if v is Array:
			for c: Variant in v:
				var fp: Variant = c.get("footprint", [1.5, 1.5])
				var fpa: Array = fp if fp is Array else [1.5, 1.5]
				out[str(c["card"])] = [float(fpa[0]) if fpa.size() > 0 else 1.5,
						float(fpa[1]) if fpa.size() > 1 else 1.5]
			break
	return out


## 生成布局（tier ∈ 八档链，查 SeqPlan.TIERS；seed 确定性 → 多局尽量一致）。
## 返回 proto_hd2d 的 layout_data 契约（width_cells/buildings/props/trees）。
## 编排顺序即原 7 段管线顺序，rng 调用序列与拆分前逐位一致（确定性契约）；
## 段间共享中间态走局部 Dictionary 传递，无类级可变状态。
static func generate(tier: String, seed_v: int, prop_set: Dictionary = {}) -> Dictionary:
	var widths := card_widths()
	var prop_fp := prop_footprints()   # 杂物占格宽/贴楼 z 用（footprint=[宽,纵深]）
	var conf: Dictionary = SeqPlan.resolve_profile(tier)
	var prof: Dictionary = conf["prof"]
	var pools: Dictionary = conf["pools"]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v

	# 1+2 分区侧位配平 / 各区建筑队列；3~3.7 序列拼接 + 浮动插位 + 杂物/空档 + 2 层配额
	var zq: Dictionary = SeqPlan._step_zone_queues(prof, pools, widths, rng)
	var seq_out: Dictionary = SeqPlan._step_build_sequences(tier, pools, widths,
			prop_set, zq["sides"], zq["queues"], rng)
	# 4 行政居中 + 前排整格排布（推挤保底）；5 背景两层随分区锚点落
	var front: Dictionary = StreetLayout._step_layout_front_row(prof, zq["queues"],
			widths, prop_fp, prop_set, seq_out["seq"], seq_out["clutter"])
	var bg: Dictionary = StreetLayout._step_background_rows(pools, widths,
			front["placements"], rng)
	# 6 街具/道具落位；7 组装 + 产物级重叠修复
	var props: Array = StreetDress._step_street_props(tier, pools, prop_fp,
			prop_set, front["placements"], bg["zone_anchor"], int(front["width_cells"]), rng)
	return StreetDress._step_assemble(tier, seed_v, prop_fp, front["placements"],
			bg["rows"], props, int(front["width_cells"]))
