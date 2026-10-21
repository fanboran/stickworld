extends RefCounted
## hd2d_street_placer.gd —— HD-2D 摆街域组件（hd2d_world 职责拆分）。
##
## 职责：把"什么卡摆在哪"一次算清并落到 3D 场景——前排意图表与摆位求解器
## （_resolve_front_row 画面宽推挤+整格吸附）、三层背景（bg1 主天际线扫铺 /
## bg2 吸缝补洞）、街具道具与自然物卡摆放（手摆表 / 布局 plan / 战场分支）、
## 建造系统补背景楼入口（spawn_bg_for_front）与布局查询（get_layout_props /
## get_layout_width）。碰撞区间账本（_prop_solids/_clutter_occ）归门面 solids 域，
## 本组件只写账。
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

var w: Node3D = null   # 门面回引（_ready 注入；禁循环 preload 故不标门面类型）

## 道具（bake_props.py 从 props.py 库烘的卡，26° 与建筑卡同视角）。
## 摆位（2026-09-14 手工摆=村A主场景语义翻译，随建筑落位走绝对坐标）：
## `x` = 街格坐标；`z` = 纵深（台面带 ≈1.2~1.8 / 路面 ≈4.5~7.0）；
## `plat=true` → 台面（y+PLAT_H）；false → 路面（y=0）。
## 路肩台面带=建筑脚下细带（BAND_SIDEWALK z 0.42~1.95；楼后地面已抬至
## 同标高连片到地平线）——z≥2 是路面，带 plat 即悬空 0.65 格。
const PROPS: Array = [
	# 铁匠铺（smithy@-7.5）门前工位
	{"card": "anvil", "x": -9.5, "z": 4.5, "plat": true},
	{"card": "grindstone", "x": -5.0, "z": 4.3, "plat": true},
	# 宅邸（guildhall@+8）前市集面（路面上，井居中）
	{"card": "market_stall", "x": 14.5, "z": 4.6, "plat": false},
	{"card": "market_table", "x": 18.0, "z": 5.6, "plat": false},
	{"card": "produce_baskets", "x": 21.0, "z": 4.6, "plat": false},
	{"card": "well", "x": 3.0, "z": 5.2, "plat": false},
	{"card": "banner", "x": 12.5, "z": 4.5, "plat": true},
	{"card": "lantern", "x": 28.0, "z": 4.6, "plat": true},
	{"card": "bench", "x": 7.0, "z": 5.4, "plat": false},
	# 西村口民居（house_w16@-50）与石造仓库（warehouse@-26）前
	{"card": "basket", "x": -50.0, "z": 4.4, "plat": true},
	{"card": "cart", "x": -32.0, "z": 6.0, "plat": false},
	{"card": "crate", "x": -20.5, "z": 4.4, "plat": true},
	{"card": "barrel", "x": -17.0, "z": 4.2, "plat": true},
	{"card": "sack_stack", "x": -24.0, "z": 5.8, "plat": false},
	# 西城门塔（tower@-90）前
	{"card": "lantern", "x": -87.0, "z": 4.6, "plat": true},
	# 东民居（house_w8@+36）前
	{"card": "barrel_stand", "x": 30.5, "z": 4.3, "plat": true},
	{"card": "pot", "x": 33.5, "z": 4.4, "plat": true},
	# 谷仓（barn@+51.5 落地面）、风车（windmill@+67）与马厩（stable@+76）前
	{"card": "haystack", "x": 47.0, "z": 5.6, "plat": false},
	{"card": "log_pile", "x": 44.0, "z": 6.0, "plat": false},
	{"card": "trough", "x": 70.0, "z": 5.0, "plat": false},
	{"card": "bench", "x": 62.0, "z": 5.0, "plat": false},
	# 东城门塔（gatehouse@+88.5）前
	{"card": "flower_box", "x": 84.0, "z": 4.4, "plat": true},
	{"card": "wheelbarrow", "x": 90.5, "z": 5.4, "plat": false},
]

## 自然物（bake_nature.py 从 nature.py 16 类库烘的卡）——手摆**纯景**散布。
## 资源点不在此表：野外资源分布走 resource_gen 程序化算法（群落散布+林区
## 梯度，创始人：算法就在那），宿主生成 ResourceNode 后经 spawn_nature_card_at
## 让 PBR 卡随点落。`z` ≥ 5 前景带。
const NATURE_SPOTS: Array = [
	# 西墙外开阔带纯景（创始人 2026-09-15：就一两棵树和木头，别摆密）
	{"card": "dead_tree", "x": -118.0, "z": 9.0},
	{"card": "grass_clump", "x": -108.0, "z": 5.0},
	# 东墙外东路开阔带纯景
	{"card": "bush", "x": 101.0, "z": 5.5},
	{"card": "dead_tree", "x": 116.0, "z": 9.5},
]

## 战场遗物（battlefield 模式手摆）：旧 12V12 战场旧址的残营读法——残旗/破车/
## 桶箱散在开阔地，全落地面（无台面）。活树/矿不在此表：野地资源走 resource_gen
## 算法全域撒布（宿主 Hd2dBattlefieldMap 消费），战场只做战痕。
## 战场摆件表：创始人 2026-09-15 反馈"还有一堆杂物"——清空，战场=开阔可列阵
## （资源点走 resource_gen 算法的树，玩法保留）
const BF_PROPS: Array = []

## 战场野地纯景（battlefield 模式手摆）：枯木/断桩/碎石堆 = 战痕，草丛灌木 =
## 荒野回生。`z` ≥ 5 前景带，x 铺满 ±94 格战场全域（中心留稀疏便于列阵读法）。
## 战痕自然物散布：同上清空（杂物反馈）
const BF_NATURE_SPOTS: Array = []

## 前排**摆位意图表**：人只声明 card + 语义锚点 x + 纵深（"大概在哪"），
## 实际 x 由 _resolve_front_row 按**画面宽**（cards.json units 数据包围盒）
## 推挤分配——重叠在求解阶段就不可能发生；中心吸附整格（创始人 2026-09-15：
## 建筑位置必须整格摆放）。顺序 = 村A 语义翻译：
## 西段居住/仓储（tower/hayloft/house_w16/warehouse）→ 中段市集/行政（smithy1/
## guildhall/shop/house_w8）→ 东段作坊/田园（barn/windmill/stable/gatehouse）；
## cottage 落墙外开阔带。未进前排的卡种全量参与背景层分带轮转。
## `z` = 纵深错落（0.4~1.3 台面为主，谷仓/孤屋落地面）；`door` = 门前短径。
const FRONT_ROW: Array = [
	{"card": "cottage_w6", "x": -102.0, "z": 2.4, "door": false},
	{"card": "tower_w6", "x": -90.0, "z": 0.9, "door": false},
	{"card": "hayloft_w8", "x": -69.0, "z": 0.7, "door": false},
	{"card": "house_w16", "x": -50.0, "z": 0.7, "door": true},
	{"card": "warehouse_w16", "x": -26.0, "z": 1.25, "door": false},
	{"card": "smithy1_w8", "x": -7.5, "z": 0.45, "door": true},
	{"card": "guildhall_w12", "x": 8.0, "z": 0.85, "door": true},
	{"card": "shop_w8", "x": 23.5, "z": 0.6, "door": false},
	{"card": "house_w8", "x": 36.0, "z": 0.6, "door": true},
	{"card": "barn_w12", "x": 51.5, "z": 2.4, "door": false},
	{"card": "windmill_w6", "x": 67.0, "z": 0.7, "door": false},
	{"card": "stable_w12", "x": 76.0, "z": 0.7, "door": false},
	{"card": "gatehouse_w8", "x": 88.5, "z": 0.4, "door": true},
]

## 背景楼选卡随机源与近卡防复读记忆（_pick_bg_card 专用）
var _bg_rng := RandomNumberGenerator.new()
var _bg_recent: Array[String] = []
## 当前层各卡卡底 z 的采样（层结束取中位数写进 w._bg_base_z）
var _bg_base_samples: Array = []


## 前排摆位求解器（原型兜底路径；游戏内前排来自 CityGen 整格吸附）：
##   1. 意图表的锚点只是"想要的位置"，占位/间隙一律用**画面宽**（cards.json
##      units 的数据包围盒）计算——重叠在求解阶段就不可能出现；
##   2. 中心吸附整格 + 左→右整格步进推挤（创始人 2026-09-15：位置必须整格
##      摆放；保底间隙 0.6 格由整格步距 ≥1 格兑现，间隙承诺不破）。
func _resolve_front_row(intent: Array) -> Array:
	var MIN_GAP := 0.6
	var out: Array = []
	var prev_right := -INF
	for e: Variant in intent:
		var card: String = str(e["card"])
		var cw: float = w.cards._cw(card)
		if cw < 1.0:
			cw = 8.0   # 卡元数据缺失兜底（_cw 同口径）
		var x: float = roundf(float(e["x"]))
		# 推挤保底：不小于"前栋右缘 + 间隙 + 本栋半宽"的最小整格
		x = maxf(x, prev_right + MIN_GAP + cw * 0.5)
		x = ceilf(x)
		prev_right = x + cw * 0.5
		out.append({"card": card, "x": x, "z": e.get("z", 0.6),
			"door": bool(e.get("door", false))})
	return out


func _median(arr: Array) -> float:
	if arr.is_empty():
		return 0.0
	var a := arr.duplicate()
	a.sort()
	return float(a[a.size() / 2])


## 从 list[ci] 起顺位找第一张**画面宽 ≤ room** 的卡（放得下才用）；找不到返回 ""。
## 背景"缝"按卡画面宽算（含出檐），cottage_w6 画面 ~9.1 格、townhouse_w12 ~15.9 格。
func _pick_card(list: Array, ci: int, room: float) -> String:
	for k in list.size():
		var c: String = str(list[(ci + k) % list.size()])
		var cw: float = w.cards._cw(c)
		if cw < 1.0 or cw <= room:
			return c
	return ""


## 已占用区间 [x0,x1] 的补集（在 [lo,hi] 内）——用于"后层插前层缝"
func _gaps(occ: Array, lo: float = -40.0, hi: float = 40.0) -> Array:
	var s := occ.duplicate()
	s.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var out := []
	var cur := lo
	for iv in s:
		if float(iv[0]) > cur + 0.5:
			out.append([cur, float(iv[0])])
		cur = maxf(cur, float(iv[1]))
	if cur < hi - 0.5:
		out.append([cur, hi])
	return out


func _place_rows() -> void:
	# 前排：**手工摆**（2026-09-14，村A主场景 InitialBuildingsList 的语义翻译，
	# 街长铺到村A全域 -67~+67）——逐栋写死在 FRONT_ROW，不再随机轮转。
	# z 错落/门前径也随清单写死；建筑格宽重叠由摆位表保证（相邻名义缝 ≥0.5 格）。
	var occ_front := []
	var rng_f := RandomNumberGenerator.new()
	rng_f.seed = 20260914
	# 前排来源：布局驱动（city_layout row0，算法村）或手摆主街 FRONT_ROW
	# 布局 JSON 的 z 字段是定稿契约：0.45~1.3 = 台面、2.4 = 落地面，直接采用。
	var front_list: Array = FRONT_ROW
	if not w._layout.is_empty():
		front_list = []
		for b: Variant in w._layout.get("buildings", []):
			if int(b["row"]) != 0:
				continue
			front_list.append({"card": str(b["card"]), "x": float(b["x"]),
				"z": float(b.get("z", 0.6)), "door": bool(b.get("door", false))})
	else:
		# 手摆主街：意图表过摆位求解器（画面宽推挤 + 微抖动）
		front_list = _resolve_front_row(front_list)
	for e in front_list:
		var card: String = str(e["card"])
		var cx: float = float(e["x"])
		var z_off: float = float(e.get("z", 0.6))
		# 台面站位：卡底落在台面标高；谷仓 z>2 = 落地面（不上台面，路面标高）
		var on_plat: bool = z_off < 2.0
		var mi: MeshInstance3D = w.cards._spawn_card(card, cx, z_off, false, w.PLAT_H if on_plat else 0.0)
		w.cards._spawn_building_shadow(card, cx, mi)
		if bool(e.get("door", false)) or not on_plat:
			w._door_path_xs.append(cx)   # 宏伟建筑/落地建筑：门前短径
		var cw: float = w.cards._cw(card)
		occ_front.append([cx - cw * 0.5, cx + cw * 0.5, card, z_off])
	w._prop_slots = []
	w._front_occ = occ_front
	# ── 三层背景（创始人 2026-09-14 定案，2026-09-17 恢复——此前被改成两层
	# 扫铺、地面跟着第二层基线收，第三层整层消失+地面悬空 3.5 格＝「后景缩水/
	# 没到最后一排根部」）：
	#   · bg1 = 布局后排（plan.row>=1，x 由算法分配互不重叠）；手摆主街=主题段
	#     自由铺（西段教堂天际线/中段市集街屋/东段田园作坊，缝 1.2~2.6 格）；
	#   · bg2/bg3 吸附前层缝（从缝里透出楼身），末层补洞把地平线遮死；
	#   · 末层（第三层）楼根 = 地平线基线，地面远端 far_z 与它同一常量（同源对齐）。
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260914
	# 主题组合段（创始人 2026-09-14：背景种类要多、要有好看的组合，不要高重复轮转）：
	#   西段=教堂/法师塔天际线 · 中段=市集街屋 · 东段=田园作坊——卡按楼所在 x 段
	#   从池里顺位取，防邻重；外段边界随实际背景跨度伸展（八城城市远宽于旧 ±93 街）
	var bands := [
		{"x0": -93.0, "x1": -16.0, "pool": ["cathedral_w16", "tower_w6", "house_w8", "guildhall_w12", "mage_tower_w8", "library_w12", "house_w16", "townhouse_w12", "alchemy_w8"]},
		{"x0": -16.0, "x1": 16.0, "pool": ["shop_w8", "bakery_w8", "house_w8", "tower_w6", "tavern_w12", "townhouse_w12", "rowhouse_w12", "library_w12"]},
		{"x0": 16.0, "x1": 93.0, "pool": ["barn_w12", "stable_w12", "cottage_w6", "hayloft_w8", "smithy2_w8", "smithy3_w8", "smithy4_w12", "shelter_w6", "barracks_w12", "windmill_w6", "rowhouse_w12", "tavern_w12"]},
	]
	var band_cursor := [0, 0, 0]
	var _pick_in_band := func(x: float, room: float) -> String:
		for bi in bands.size():
			var b: Dictionary = bands[bi]
			if float(b["x0"]) <= x and x < float(b["x1"]):
				var pool: Array = b["pool"]
				for k in pool.size():
					var c: String = str(pool[(band_cursor[bi] + k) % pool.size()])
					var band_cw: float = w.cards._cw(c)
					if band_cw < 1.0 or band_cw <= room:
						band_cursor[bi] = (band_cursor[bi] + k + 1) % pool.size()
						return c
				return ""
		return ""
	var bg_lo: float = -93.0
	var bg_hi: float = 93.0
	w._bg_span_x = 0.0
	if not w._layout.is_empty():
		# 布局驱动：背景跨度 = plan 后排实际跨度（主题段外边界随之伸展）
		for b: Variant in w._layout.get("buildings", []):
			if int(b.get("row", 0)) >= 1:
				bg_lo = minf(bg_lo, float(b["x"]) - float(b.get("cells", 8.0)) * 0.5)
				bg_hi = maxf(bg_hi, float(b["x"]) + float(b.get("cells", 8.0)) * 0.5)
		bands[0]["x0"] = bg_lo
		bands[2]["x1"] = bg_hi
	var prev_slots: Array = []      # 前一层楼的画面占用 [x0,x1]
	for li in w.BG_LAYERS:
		var lz: float = w.SKYLINE_Z - w.BG_LAYER_GAP * float(li)
		var tint: Color = w.BG_TINTS[li]
		var occ: Array = []
		if li == 0 and not w._layout.is_empty():
			# bg1 = 布局后排（city_layout row>=1，x 由算法分配互不重叠）
			for b: Variant in w._layout.get("buildings", []):
				if int(b.get("row", 0)) < 1:
					continue
				var card2: String = str(b["card"])
				var cx2: float = float(b["x"])
				var w2: float = w.cards._cw(card2)
				_spawn_bg_card(card2, cx2, lz, tint)
				occ.append([cx2 - w2 * 0.5, cx2 + w2 * 0.5])
				w._bg_span_x = maxf(w._bg_span_x, absf(cx2) + w2 * 0.5)
		elif li == 0:
			# bg1 自由铺：楼 + 1.2~2.6 格缝的节奏（根部被前排挡住）
			var gx: float = bg_lo
			while gx < bg_hi:
				var card: String = str(_pick_in_band.call(gx, 999.0))
				if card == "":
					card = "house_w8"
				var cw: float = w.cards._cw(card)
				if cw < 1.0:
					cw = 8.0
				_spawn_bg_card(str(card), gx + cw * 0.5, lz, tint)
				occ.append([gx, gx + cw])
				gx += cw + rng.randf_range(1.2, 2.6)
		else:
			# bg2/bg3 吸附前层缝：每条缝中心放一栋楼（从缝里露出楼身）。
			# 本层自身保持 ≥1 格缝（给再后一层插）；放不下的缝放弃（末层补洞兜底）。
			var last_x1 := -999.0
			for g in _gaps(prev_slots, bg_lo, bg_hi):
				var g0: float = float(g[0])
				var g1: float = float(g[1])
				if g1 - g0 < 1.0:
					continue
				var cx: float = (g0 + g1) * 0.5
				var room: float = cx - (last_x1 + 1.0)   # 左侧可用宽度
				var card: String = _pick_in_band.call(cx, room)
				if card == "":
					continue
				var cw: float = w.cards._cw(card)
				if cw < 1.0:
					cw = 8.0
				_spawn_bg_card(card, cx, lz, tint)
				occ.append([cx - cw * 0.5, cx + cw * 0.5])
				last_x1 = cx + cw * 0.5
			# bg2/bg3 职责 = 遮死中景与地平线：吸附放不下的层再补大洞（近贴 0.6 格缝）。
			# 阈值 9.8 = 库里最小画面宽 cottage_w6(9.1) + 0.6 缝，更窄的洞放不下任何卡。
			for g in _gaps(occ, bg_lo, bg_hi):
				var g0: float = float(g[0])
				var g1: float = float(g[1])
				while g1 - g0 > 9.8:
					var room: float = g1 - g0 - 0.6
					var card: String = _pick_in_band.call((g0 + g1) * 0.5, room)
					if card == "":
						break
					var cw: float = w.cards._cw(card)
					_spawn_bg_card(card, g0 + cw * 0.5, lz, tint)
					occ.append([g0, g0 + cw])
					g0 += cw + 0.6
		prev_slots = occ
		w._bg_base_z[li] = _median(_bg_base_samples)
		_bg_base_samples.clear()


## 背景卡 = skyline 卡 + 按层距离染色；同时**实测卡底世界 z**（供层基线辅助线与
## 底衬远端对齐）。卡底贴地落位后底边 z = 层 z 本身；ground=台面标高——
## 后景楼站在城内地面上（与建筑带同高，创始人 2026-09-15）
func _spawn_bg_card(card: String, x: float, lz: float, tint: Color) -> void:
	var mi: MeshInstance3D = w.cards._spawn_card(card, x, lz, true, w.PLAT_H)
	if mi == null:
		return
	(mi.material_override as ShaderMaterial).set_shader_parameter("tint", tint)
	_bg_base_samples.append(lz)


## 背景楼选卡：全卡池，排除前排本卡与附近已用卡（同屏避同卡）；max_h = 画面高
## 上限（格），bg1 用它排除过高卡（过滤后池空则放开——"尽量"口径，不无楼可摆）。
## 种子由（前排 x, 层）决定——多局一致，加建前排时同样确定性补楼。
func _pick_bg_card(front_card: String, fx: float, li: int, max_h: float = INF) -> String:
	_bg_rng.seed = int(abs(fx * 7919.0)) + li * 104729 + 13
	var pool: Array = []
	for c: String in w._cards.keys():
		if c == front_card or _bg_recent.has(c):
			continue
		var meta: Dictionary = w._cards.get(c, {})
		if max_h != INF and not meta.is_empty() \
				and float(meta["units"][1]) * w.S > max_h:
			continue
		pool.append(c)
	if pool.is_empty():
		for c: String in w._cards.keys():
			if c != front_card:
				pool.append(c)
	var card: String = str(pool[_bg_rng.randi_range(0, pool.size() - 1)])
	_bg_recent.append(card)
	while _bg_recent.size() > 4:
		_bg_recent.pop_front()
	return card


## 前排加建时补背景楼（建造系统事件接线入口；初始生成走 _place_rows）：
## 只补 bg1 主天际线——bg2 是地平线补缝位，由遮挡关系自然成立，不随加建补
func spawn_bg_for_front(front_card: String, fx: float) -> void:
	var card: String = _pick_bg_card(front_card, fx, 0, w.BG1_MAX_H)
	_spawn_bg_card(card, roundf(fx), w.SKYLINE_Z, w.BG_TINTS[0])


func _place_props() -> void:
	if w.battlefield and not w.resource_field:
		for e in BF_PROPS:
			_spawn_prop(str(e["card"]), float(e["x"]), float(e.get("z", 5.0)), false)
		return
	if not w._layout.is_empty():
		for e: Variant in w._layout.get("props", []):
			_spawn_prop(str(e["card"]), float(e["x"]), float(e.get("z", 5.0)),
					bool(e.get("plat", false)))
			# 占格件（CityGen 杂物）：并进 F3 建筑辅助线——左右边界双黄线 +
			# 紫占地带，与建筑同口径；碰撞仍走 _prop_solids 点障碍
			if float(e.get("occ_cells", 0.0)) > 0.0:
				var oc_y: float = 516.0 + float(e.get("z", 5.0)) * 24.0
				var oc_x0: float = float(e["x"]) - float(e["occ_cells"]) * 0.5
				w._clutter_occ.append([oc_x0, oc_x0 + float(e["occ_cells"]),
						oc_y - 26.0, oc_y + 26.0])
		return
	for e in PROPS:
		_spawn_prop(str(e["card"]), float(e["x"]), float(e["z"]), bool(e.get("plat", true)))


## 自然物卡摆放（手摆纯景 / 布局 trees / 战场战痕三分支）
func _place_nature() -> void:
	if w.battlefield and not w.resource_field:
		for e in BF_NATURE_SPOTS:
			_spawn_nature_card(str(e["card"]), float(e["x"]), float(e["z"]))
		return
	if not w._layout.is_empty():
		for e: Variant in w._layout.get("trees", []):
			_spawn_nature_card(str(e["card"]), float(e["x"]), float(e.get("z", 5.5)))
		return
	for e in NATURE_SPOTS:
		_spawn_nature_card(str(e["card"]), float(e["x"]), float(e["z"]))


## 宿主按资源分布算法落卡（ResourceNode 点位 → 匹配自然物 PBR 卡，卡随点落）
func spawn_nature_card_at(card: String, x_px: float, y_px: float) -> void:
	_spawn_nature_card(card, x_px / 24.0, (y_px - 516.0) / 24.0)


## 道具卡：与建筑卡同一套 anchor 落位（基座落 z_off 平面；plat 版再加台面高）。
func _spawn_prop(card: String, x: float, z_off: float, plat: bool) -> MeshInstance3D:
	var meta: Dictionary = w._props.get(card, {})
	if meta.is_empty():
		push_warning("[hd2d] 无此道具卡: " + card)
		return null
	var units: Array = meta["units"]
	var q := QuadMesh.new()
	q.size = Vector2(float(units[0]) * w.S, float(units[1]) * w.S)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	# 卡底贴地落位（创始人 2026-09-14 修穿模）：道具卡的 anchor 是"画面中心对应点"，
	# 沿用建筑卡公式会让卡底按半高入地。地面高 = 台面(0.65) 或 路面(0)。
	# 台面只认台面带（z<2.0）：台面带外（路面）的 plat 在此强制回路面。
	if z_off >= 2.0:
		plat = false
	var ground: float = w.PLAT_H if plat else 0.0
	var half: float = float(units[1]) * w.S * 0.5
	var t: float = deg_to_rad(w.TILT_DEG)
	# 卡底留白下沉（创始人 2026-09-15：浮空摆件）——alpha 扫描卡底透明行，
	# 卡内容实际落到地面（留白比例每卡只扫一次，缓存）
	mi.position = Vector3(x, ground + cos(t) * half
			- w.cards._card_bottom_pad(card, w._props, w.PROP_DIR),
			z_off - sin(t) * half)
	mi.basis = w.cards._cam_basis()
	var m := ShaderMaterial.new()
	m.shader = w.CARD_SHADER
	m.set_shader_parameter("albedo_tex", w._tex_abs(w._temp + w.PROP_DIR + card + ".png"))
	# 夜版道具卡缺失回退日版（街边小物件夜里的月光来自 Blender 烘的夜版贴图）
	var prop_night: Texture2D = w._tex_abs_soft(w._temp + w.PROP_DIR + card + "_night.png")
	if prop_night == null:
		prop_night = w._tex_abs(w._temp + w.PROP_DIR + card + ".png")
	m.set_shader_parameter("albedo_night_tex", prop_night)
	m.set_shader_parameter("glow_tex", w._tex_abs(w._temp + w.PROP_DIR + card + "_glow.png"))
	var px: Array = meta.get("px", [128, 128])
	m.set_shader_parameter("tex_px", Vector2(float(px[0]), float(px[1])))
	m.set_shader_parameter("relief", 4.5)
	m.set_shader_parameter("alpha_cut", 0.4)
	m.set_shader_parameter("glow_energy", 0.0)
	m.set_shader_parameter("tint", Color(1, 1, 1))
	w.cards._card_mats.append(m)
	mi.material_override = m
	mi.name = "Prop_" + card
	w._prop_root.add_child(mi)
	# 实心区间（格）：卡宽收窄 15%；细杆件（灯笼）不挡人。
	# 道具是台面/路面上的点障碍——碰撞只在其纵深带附近（z→y 窄带），
	# 不挡整条行走带（玩家/NPC 从前景绕过去）。
	# 纵深带=卡底贴地基线向街心延伸 [y_c−52, y_c]（2026-09-16：此前基线前后
	# 各跨 26，前缘伸到基线前方，角色在基线前 ~38px（26+脚框半宽 12）就被
	# 挡住——观感"碰撞箱向下偏移 ~32px"（38·ez@113% 档），创始人指认）。
	if card != "lantern":
		var half_w: float = float(units[0]) * w.S * 0.5 * 0.85
		var y_c: float = 516.0 + z_off * 24.0
		w._prop_solids.append([x - half_w, x + half_w, y_c - 52.0, y_c])
	return mi


## 自然物卡落位（卡底贴地，同 _spawn_prop 公式；目录/元数据走 nature 侧）。
func _spawn_nature_card(card: String, x: float, z_off: float) -> MeshInstance3D:
	var meta: Dictionary = w._nature.get(card, {})
	if meta.is_empty():
		push_warning("[hd2d] 无此自然物卡: " + card)
		return null
	var units: Array = meta["units"]
	var q := QuadMesh.new()
	q.size = Vector2(float(units[0]) * w.S, float(units[1]) * w.S)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	var half: float = float(units[1]) * w.S * 0.5
	var t: float = deg_to_rad(w.TILT_DEG)
	# 卡底留白下沉（与道具卡同公式）：自然物卡底部同样有透明留白行，
	# 不下沉则树/石全体悬空一线
	mi.position = Vector3(x, cos(t) * half
			- w.cards._card_bottom_pad(card, w._nature, w.NATURE_DIR),
			z_off - sin(t) * half)
	mi.basis = w.cards._cam_basis()
	var m := ShaderMaterial.new()
	m.shader = w.CARD_SHADER
	m.set_shader_parameter("albedo_tex", w._tex_abs(w._temp + w.NATURE_DIR + card + ".png"))
	# 夜版自然物卡缺失回退日版（树/矿/水晶夜里的月光来自 Blender 烘的夜版贴图）
	var nature_night: Texture2D = w._tex_abs_soft(w._temp + w.NATURE_DIR + card + "_night.png")
	if nature_night == null:
		nature_night = w._tex_abs(w._temp + w.NATURE_DIR + card + ".png")
	m.set_shader_parameter("albedo_night_tex", nature_night)
	m.set_shader_parameter("glow_tex", w._tex_abs(w._temp + w.NATURE_DIR + card + "_glow.png"))
	var px: Array = meta.get("px", [128, 128])
	m.set_shader_parameter("tex_px", Vector2(float(px[0]), float(px[1])))
	m.set_shader_parameter("relief", 4.5)
	m.set_shader_parameter("alpha_cut", 0.4)
	m.set_shader_parameter("glow_energy", 0.0)
	m.set_shader_parameter("tint", Color(1, 1, 1))
	w.cards._card_mats.append(m)
	mi.material_override = m
	mi.name = "Nature_" + card
	w._prop_root.add_child(mi)
	# 自然物有建模体积（创始人 2026-09-15）：恢复实体——但碰撞收窄成
	# "树干/岩心"窄条（±0.4 格，非整卡宽）：挡得住穿体，村民又能走到
	# 资源点 24px 阈值内（此前整卡宽碰撞把采集 AI 卡死在卡边的教训）
	if bool(meta.get("solid", false)):
		var half_w: float = 0.4
		var y_c: float = 516.0 + z_off * 24.0
		w._prop_solids.append([x - half_w, x + half_w, y_c - 26.0, y_c + 26.0])
	return mi


## 露天工位点（宿主转发给 TownLife 露天工位 duck）：台面上的铁砧=铁匠工位。
## 返回 2D 行走带坐标（z → y 近似映射同 _place_nature）。
func get_open_work_sites() -> Array:
	var out: Array = []
	for e in PROPS:
		if str(e["card"]) == "anvil":
			out.append({
				"pos": Vector2(float(e["x"]) * 24.0, 516.0 + float(e["z"]) * 24.0),
				"work_site_def": "smithy_lv1",
			})
	return out


## 布局道具表（宿主工位/NPC 出生点推导用；手摆模式返回空）
func get_layout_props() -> Array:
	return w._layout.get("props", []) if not w._layout.is_empty() else []


## 布局驱动模式的街宽（格）；手摆主街返回 0（宿主用 tscn 边界）
func get_layout_width() -> float:
	if not w._layout.is_empty():
		return float(w._layout.get("width_cells", 96.0))
	return 0.0
