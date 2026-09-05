extends RefCounted
## 基线树管线的 GDScript 移植 —— 与 tools/ai/gen_trees.py + stroke_paint.py（mona-3
## StrokeGenerator）逐阶段对齐：结构直绘 → 分区域参考色/蒙版 → 块级结构张量流场
## （+冠部螺旋注入）→ 分层笔触拟合（贪心扫描/误差驱动选点 + 色块断链截笔 + 中点
## 取色混合 + mask 笔级过滤）→ 圆头笔栅格化（alpha 并集，硬边 0/255）。
##
## 与 Python 的两点等价简化（视觉不变）：
## 1. 模拟画布/误差场维护在 GRID=4px 网格分辨率（= Python 里 downsample 的分辨率，
##    选点逻辑本来就只读网格）；烘焙栅格化仍是全分辨率。
## 2. 参考图不落全分辨率像素，直接生成网格色（含噪声的解析等效：格均值噪声 σ/4），
##    干区矩形按格覆盖率混合。
## 结构/运笔/取色/断链/过滤的随机分布与 Python 一致（RNG 流不同 → 树不同，同种子可复现）。
##
## pen 约定：{a: Vector2, b: Vector2, c: Color(eff 混合后), w: int(像素宽), g: int}
## g：0=干笔触 1=枝直绘 2=冠笔触；绘制顺序 = 列表顺序（冠最后 = alpha-over 在上）。

const W := 384
const H := 672
const GRID := 4
const GW := W / GRID  # 96
const GH := H / GRID  # 168
const NC := GW * GH
const NCC := NC * 3
## stroke_paint.paint 的整体笔宽/笔长缩放（max(W,H)/256；THIN_LAYERS 基值 × 此值）
const K_SCALE := 2.625

## 结构参数默认值 = gen_trees.DEFAULT_PARAMS（用户认可基线，勿动）
const DEFAULT_PARAMS := {
	"height_factor": 1.00,
	"bare_frac": 0.13,
	"trunk_frac": 0.60,
	"trunk_w": 0.042,
	"crown_r_coef": 0.52,
	"crown_cap": 0.30,
	"crown_lift": 0.30,
	"hat_n": 8.0,
	"branch_prob": 0.48,
	"seg_n": 9.0,
}

## 笔触分层（THIN_LAYERS 基值，未乘 K_SCALE；ratio=层笔数占总笔数比例）
const LAYERS := [
	{"name": "underpainting", "ratio": 0.20, "w0": 3.6, "w1": 2.8, "ln": 22.0, "alpha": 0.98,
		"jit": 0.24, "band_jit": 0.28},
	{"name": "body", "ratio": 0.42, "w0": 2.4, "w1": 1.7, "ln": 11.0, "alpha": 0.97,
		"jit": 0.20, "band_jit": 0.22, "color_break": true},
	{"name": "detail", "ratio": 0.32, "w0": 0.9, "w1": 0.55, "ln": 8.0, "alpha": 0.90,
		"jit": 0.9, "band_jit": 0.0, "color_break": true, "refine": true, "err_thresh": 0.06},
	{"name": "glaze", "ratio": 0.06, "w0": 3.0, "w1": 2.4, "ln": 26.0, "alpha": 0.12,
		"jit": 0.5, "band_jit": 0.0},
]

const LEAF_PALETTES := [
	[Vector3i(158, 196, 92), Vector3i(108, 162, 66), Vector3i(70, 118, 48)],
	[Vector3i(140, 192, 104), Vector3i(92, 152, 76), Vector3i(58, 112, 54)],
	[Vector3i(152, 186, 116), Vector3i(102, 150, 82), Vector3i(66, 116, 60)],
	[Vector3i(172, 196, 96), Vector3i(122, 164, 72), Vector3i(82, 126, 54)],
]
const TRUNK_COLORS := [Vector3i(116, 72, 34), Vector3i(88, 52, 26), Vector3i(58, 34, 18)]

const COLOR_BREAK := 55.0   # 色块断链/截笔阈值（L2 色距）
const FLOW_BLOCK := 48      # 流场块尺寸（px）；W/H 恰被整除


## ─────────────────────── 对外入口 ───────────────────────

## 生成一棵树（结构 + 全部笔触）。P 覆盖 DEFAULT_PARAMS；返回
## {"wire": 结构, "pens": 笔列表, "stats": {干/枝/冠笔数, 各层实际落笔数}}
static func build_tree(p_seed: int, P: Dictionary, trunk_n: int, crown_n: int,
		w_scale: float = 1.0, ln_scale: float = 1.0) -> Dictionary:
	var params := DEFAULT_PARAMS.duplicate()
	for k: String in P:
		params[k] = P[k]
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var wire := _gen_tree_struct(rng, params)
	var stats := {}
	var trunk_rng := RandomNumberGenerator.new()
	trunk_rng.seed = p_seed + 1
	var trunk_region := _Region.new(wire, 0, trunk_rng)
	var trunk_pens: Array = trunk_region.gen(w_scale, ln_scale, trunk_n, stats)
	var branch_pens := _branch_pens(wire)
	var crown_rng := RandomNumberGenerator.new()
	crown_rng.seed = p_seed + 2
	var crown_region := _Region.new(wire, 2, crown_rng)
	var crown_pens: Array = crown_region.gen(w_scale, ln_scale, crown_n, stats)
	var pens: Array = []
	pens.append_array(trunk_pens)
	pens.append_array(branch_pens)
	pens.append_array(crown_pens)
	stats["branch"] = branch_pens.size()
	return {"wire": wire, "pens": pens, "stats": stats,
		"trunk_canvas": (trunk_region as _Region).canvas_init_img(),
		"crown_canvas": crown_region.canvas_init_img()}


## [调试] 导出某种子的冠区参考色可视化（与 Python render_crown_ref 目检对齐用）
static func debug_crown_ref(p_seed: int) -> Image:
	var rng := RandomNumberGenerator.new()
	rng.seed = p_seed
	var wire := _gen_tree_struct(rng, DEFAULT_PARAMS)
	var r := RandomNumberGenerator.new()
	r.seed = p_seed + 2
	var reg := _Region.new(wire, 2, r)
	var img := Image.create(W, H, false, Image.FORMAT_RGB8)
	for row: int in GH:
		for col: int in GW:
			var i := row * GW + col
			var c := Color(
				clampf(refc_of(reg, i * 3) / 255.0, 0.0, 1.0),
				clampf(refc_of(reg, i * 3 + 1) / 255.0, 0.0, 1.0),
				clampf(refc_of(reg, i * 3 + 2) / 255.0, 0.0, 1.0))
			img.fill_rect(Rect2i(col * GRID, row * GRID, GRID, GRID), c)
	return img


static func refc_of(reg: _Region, idx: int) -> float:
	return reg.refc[idx]


## 笔列表 → 全分辨率 RGBA 贴图。
## 像素级模拟画布重放（与 Python stamp_canvas 同构）：eff = col×alpha +
## 画布中点色×(1-alpha)，alpha = 笔并集硬边。干/冠各用自己区域的初始画布
## （参考灰度模糊），笔按分区重放后 alpha-over 合成。
## 直绘枝笔（g=1）alpha=1 纯色直接盖。
static func rasterize(pens: Array, trunk_canvas: Image, crown_canvas: Image) -> Image:
	var rgb := [trunk_canvas.duplicate(), crown_canvas.duplicate()]
	var alp := [
		Image.create(W, H, false, Image.FORMAT_L8),
		Image.create(W, H, false, Image.FORMAT_L8),
	]
	for p: Dictionary in pens:
		var g: int = p["g"]
		var canvas: Image = rgb[0] if g != 2 else rgb[1]
		var alpha: Image = alp[0] if g != 2 else alp[1]
		_stamp_img(canvas, alpha, p)
	return _alpha_over(rgb[0], alp[0], rgb[1], alp[1])


# ─────────────────────── 树结构：Terraria 段堆叠（gen_tree_struct 直译） ───────────────────────

static func _gen_tree_struct(rng: RandomNumberGenerator, P: Dictionary) -> Dictionary:
	var ground_y: float = H - 12.0
	var usable_h: float = (ground_y - 14.0) * float(P["height_factor"])
	var bare_frac := float(P["bare_frac"])
	var bare_h: float = usable_h * rng.randf_range(bare_frac * 0.62, bare_frac * 1.38)
	var leaf_zone: float = usable_h - bare_h
	var trunk_frac := float(P["trunk_frac"])
	var trunk_h: float = leaf_zone * rng.randf_range(trunk_frac - 0.06, trunk_frac + 0.06)
	var n_seg := int(float(P["seg_n"]))
	var seg_h: float = trunk_h / n_seg
	var leaf_ground: float = ground_y - bare_h
	var trunk_w := float(P["trunk_w"])
	var w_base: float = H * rng.randf_range(trunk_w - 0.006, trunk_w + 0.006)
	var w_top: float = w_base * rng.randf_range(0.60, 0.78)

	# 干中线：段接缝渐进偏移（几乎直），整体居中
	var xs: Array[float] = [W * 0.5 + rng.randf_range(-8.0, 8.0)]
	for _i: int in n_seg:
		xs.append(xs[xs.size() - 1] + rng.randf_range(-6.0, 6.0))
	var cx_mean := 0.0
	for x: float in xs:
		cx_mean += x
	cx_mean /= xs.size()
	for i: int in xs.size():
		xs[i] -= cx_mean - W * 0.5

	# 枝叶干段：首末段强制普通，中间段按样式池出枝（同侧枝不连续）
	var segs: Array = []
	var last_l := false
	var last_r := false
	var bp := float(P["branch_prob"])
	for i: int in n_seg:
		var y_top: float = leaf_ground - (i + 1) * seg_h
		var y_bot: float = leaf_ground - i * seg_h
		var f := (i + 0.5) / n_seg
		var w := w_base + (w_top - w_base) * f
		var style := "plain"
		if i != 0 and i != n_seg - 1:
			var r := rng.randf()
			var can_l := not last_l
			var can_r := not last_r
			if r < (1.0 - 2.0 * bp) or (not can_l and not can_r):
				style = "plain"
			elif can_l and (r < (1.0 - bp) or not can_r):
				style = "left"
			elif can_r:
				style = "right"
		last_l = style == "left"
		last_r = style == "right"
		segs.append({"xc": (xs[i] + xs[i + 1]) * 0.5, "y_top": y_top, "y_bot": y_bot,
			"w": w, "style": style})

	# 底部裸干延长段（2-4 段 plain，宽度接续 w_base，无任何枝）
	var n_bare: int = rng.randi_range(2, 4)
	var bare_seg_h: float = bare_h / n_bare
	for j: int in n_bare:
		segs.insert(0, {"xc": xs[0], "y_top": ground_y - (j + 1) * bare_seg_h,
			"y_bot": ground_y - j * bare_seg_h, "w": w_base + 2.0, "style": "plain"})

	# 侧枝：二次贝塞尔路径（10 点），短、斜上
	var branches: Array = []
	for s: Dictionary in segs:
		var sty := String(s["style"])
		if sty != "left" and sty != "right":
			continue
		if rng.randf() < 0.25:
			continue
		var side := -1.0 if sty == "left" else 1.0
		var oy: float = float(s["y_bot"]) - seg_h * rng.randf_range(0.3, 0.7)
		var length: float = w_base * rng.randf_range(2.2, 3.4)
		var ang := deg_to_rad(rng.randf_range(28.0, 52.0))
		var origin := Vector2(float(s["xc"]) + side * float(s["w"]) * 0.45, oy)
		var tip := origin + length * Vector2(side * sin(ang), -cos(ang))
		var ctrl := origin + length * 0.5 * Vector2(side * sin(ang) * 0.4, -1.0)
		var path := PackedVector2Array()
		for i: int in 10:
			var t := i / 9.0
			var u := 1.0 - t
			path.append(u * u * origin + 2.0 * u * t * ctrl + t * t * tip)
		branches.append({"path": path, "w0": w_base * 0.62, "w1": w_base * 0.36, "tip": tip})

	# 顶帽：主团 + 帽圈子团 + 底缘下垂团 + 枝端团，每团带 2-3 个错位子圆
	var crown_h: float = leaf_zone - trunk_h
	var r_main: float = minf(crown_h * float(P["crown_r_coef"]), W * float(P["crown_cap"]))
	var cy: float = leaf_ground - trunk_h - r_main * float(P["crown_lift"])
	var trunk_top_x: float = xs[xs.size() - 1]
	var blobs: Array = [{"c": Vector2(trunk_top_x, cy), "r": r_main}]
	var n_hat: int = maxi(3, int(float(P["hat_n"])) + rng.randi_range(-2, 2))
	for k: int in n_hat:
		var a := k / float(n_hat) * TAU + rng.randf_range(-0.22, 0.22)
		var d := r_main * rng.randf_range(0.68, 1.0)
		blobs.append({"c": Vector2(trunk_top_x + d * cos(a), cy + d * sin(a) * 0.85),
			"r": r_main * rng.randf_range(0.38, 0.58)})
	for _i: int in rng.randi_range(2, 3):
		var a := PI + rng.randf_range(-0.6, 0.6)
		var d := r_main * rng.randf_range(0.8, 1.0)
		var by := minf(cy + d * sin(a) * 0.8, ground_y - r_main * 0.45 * 0.8)
		blobs.append({"c": Vector2(trunk_top_x + d * cos(a), by),
			"r": r_main * rng.randf_range(0.30, 0.45)})
	for br: Dictionary in branches:
		var tip: Vector2 = br["tip"]
		# 枝端叶团（用户反馈增量：基线 Python 版 r=0.26-0.4×r_main 太小，枝梢裸露
		# 观感"秃枝"；加大到 0.42-0.6 且中心向枝根回缩 18% 盖住梢部）
		var origin0: Vector2 = (br["path"] as PackedVector2Array)[0]
		var bc := tip.lerp(origin0, 0.18) + Vector2(0.0, -4.0)
		blobs.append({"c": bc, "r": r_main * rng.randf_range(0.42, 0.6)})
	for b: Dictionary in blobs:
		var subs: Array = []
		var bc0: Vector2 = b["c"]
		var br0: float = b["r"]
		for _j: int in rng.randi_range(2, 3):
			subs.append(Vector3(bc0.x + rng.randf_range(-0.5, 0.5) * br0,
				bc0.y + rng.randf_range(-0.45, 0.45) * br0,
				br0 * rng.randf_range(0.45, 0.65)))
		b["sub"] = subs

	var palette: Array = LEAF_PALETTES[rng.randi_range(0, LEAF_PALETTES.size() - 1)]
	var s := {"segs": segs, "branches": branches, "blobs": blobs, "palette": palette,
		"ground_y": ground_y, "w_base": w_base}
	_fit_tree_to_canvas(s)
	return s


## 整体适配：包围盒超画布则等比缩放 + 平移（底边贴地）
static func _fit_tree_to_canvas(s: Dictionary) -> void:
	var min_x := 1e9
	var max_x := -1e9
	var min_y := 1e9
	var max_y := -1e9
	for seg: Dictionary in s["segs"]:
		min_x = minf(min_x, float(seg["xc"]) - float(seg["w"]) * 0.5)
		max_x = maxf(max_x, float(seg["xc"]) + float(seg["w"]) * 0.5)
		min_y = minf(min_y, float(seg["y_top"]))
		max_y = maxf(max_y, float(seg["y_bot"]))
	for br: Dictionary in s["branches"]:
		var path: PackedVector2Array = br["path"]
		for p: Vector2 in path:
			min_x = minf(min_x, p.x)
			max_x = maxf(max_x, p.x)
			min_y = minf(min_y, p.y)
			max_y = maxf(max_y, p.y)
	for b: Dictionary in s["blobs"]:
		var bc: Vector2 = b["c"]
		var br_r: float = b["r"]
		min_x = minf(min_x, bc.x - br_r)
		max_x = maxf(max_x, bc.x + br_r)
		min_y = minf(min_y, bc.y - br_r)
		max_y = maxf(max_y, bc.y + br_r)
		for sub: Vector3 in b["sub"]:
			min_x = minf(min_x, sub.x - sub.z)
			max_x = maxf(max_x, sub.x + sub.z)
			min_y = minf(min_y, sub.y - sub.z)
			max_y = maxf(max_y, sub.y + sub.z)
	var ground_y: float = s["ground_y"]
	var k := minf(1.0, minf((W - 8.0) / maxf(max_x - min_x, 1.0),
		(ground_y - 8.0) / maxf(max_y - min_y, 1.0)))
	var dx := W / 2.0 - (min_x + max_x) / 2.0
	var dy := ground_y - max_y * k
	for seg: Dictionary in s["segs"]:
		seg["xc"] = float(seg["xc"]) * k + dx
		seg["y_top"] = float(seg["y_top"]) * k + dy
		seg["y_bot"] = float(seg["y_bot"]) * k + dy
		seg["w"] = float(seg["w"]) * k
	for br: Dictionary in s["branches"]:
		var path: PackedVector2Array = br["path"]
		for i: int in path.size():
			path[i] = Vector2(path[i].x * k + dx, path[i].y * k + dy)
		br["path"] = path  # PackedArray 值语义，改完写回
		br["w0"] = float(br["w0"]) * k
		br["w1"] = float(br["w1"]) * k
	for b: Dictionary in s["blobs"]:
		var bc: Vector2 = b["c"]
		b["c"] = Vector2(bc.x * k + dx, bc.y * k + dy)
		b["r"] = float(b["r"]) * k
		var subs: Array = b["sub"]
		for i: int in subs.size():
			var sub: Vector3 = subs[i]
			subs[i] = Vector3(sub.x * k + dx, sub.y * k + dy, sub.z * k)
	s["w_base"] = float(s["w_base"]) * k


## 枝直绘笔（paint_branches_on 等效：圆头笔段序列，颜色沿程渐暗）
static func _branch_pens(wire: Dictionary) -> Array:
	var pens: Array = []
	var t_mid := TRUNK_COLORS[1]
	for br: Dictionary in wire["branches"]:
		var path: PackedVector2Array = br["path"]
		var m := path.size()
		for i: int in m - 1:
			var f := i / float(maxi(m - 2, 1))
			var w: float = float(br["w0"]) + (float(br["w1"]) - float(br["w0"])) * f
			var km := 0.92 - f * 0.12
			var col := Color8(int(float(t_mid.x) * km), int(float(t_mid.y) * km),
				int(float(t_mid.z) * km))
			pens.append({"a": path[i], "b": path[i + 1], "c": col,
				"w": maxi(2, int(roundf(w))), "g": 1})
	return pens


# ─────────────────────── 区域拟合（StrokeGenerator 移植，网格分辨率） ───────────────────────

class _Region:
	extends RefCounted
	## 一个区域（干/冠）的参考色 + 流场 + 分层笔触拟合。
	## 参考色/画布/误差都在 GRID 网格上（Python 中选点逻辑只读 downsample 网格）。

	const TP := preload("res://tests/dev/tree_pipeline.gd")
	## 调试统计开关（env TREE_PIPE_DBG=1）：打印 imp 场与选点分布诊断
	static var DBG := OS.get_environment("TREE_PIPE_DBG")


	var region := 0  # 0=干 2=冠
	var rng: RandomNumberGenerator
	var wire: Dictionary

	var refc := PackedFloat32Array()   # 参考色 NC×3（浮点，含噪声等效）
	var colq := PackedInt32Array()     # 量化参考色 NC×3（0-255，取色/断链用）
	var flow := PackedFloat32Array()   # 流场方向 NC
	var gradn := PackedFloat32Array()  # 归一化梯度强度 NC
	var imp := PackedFloat32Array()    # 重要性 NC = smooth(1+2×grad)
	var mask := Image.new()            # 全分辨率 L8 硬蒙版（笔中心判定）

	var cov := PackedFloat32Array()    # 覆盖累计 NC
	var canv := PackedFloat32Array()   # 模拟画布 NC×3
	var err := PackedFloat32Array()    # 画布-参考误差 NC
	var errs := PackedFloat32Array()   # 平滑归一化误差 NC
	var err_frac_high := 1.0
	var frac_frozen := false   # refine 层内冻结（见 _sync 注释）
	var since_sync := 0
	# 细化层加权采样缓存（_sync 时重建）
	var err_w := PackedFloat32Array()  # imp×errs^1.2
	var err_cum := PackedFloat32Array() # 前缀和
	var err_w_total := 0.0
	var err_w_max := 0.0


	func _init(p_wire: Dictionary, p_region: int, p_rng: RandomNumberGenerator) -> void:
		wire = p_wire
		region = p_region
		rng = p_rng
		mask = Image.create(TP.W, TP.H, false, Image.FORMAT_L8)
		if region == 0:
			_build_trunk()
		else:
			_build_crown()
		_build_flow()
		var imp_raw := PackedFloat32Array()
		imp_raw.resize(TP.NC)
		for i: int in TP.NC:
			imp_raw[i] = 1.0 + 2.0 * gradn[i]
		imp = _smooth(imp_raw, 1.0)
		colq.resize(TP.NCC)
		for i: int in TP.NCC:
			colq[i] = clampi(int(roundf(refc[i])), 0, 255)
		cov.resize(TP.NC)
		canv.resize(TP.NCC)
		err.resize(TP.NC)
		errs.resize(TP.NC)
		# 画布初始 = 参考灰度模糊（经典 underpaint 底色）
		var gray := PackedFloat32Array()
		gray.resize(TP.NC)
		for i: int in TP.NC:
			gray[i] = (refc[i * 3] + refc[i * 3 + 1] + refc[i * 3 + 2]) / 3.0
		gray = _smooth(gray, 2.0)
		gray = _smooth(gray, 2.0)
		for i: int in TP.NC:
			canv[i * 3] = gray[i]
			canv[i * 3 + 1] = gray[i]
			canv[i * 3 + 2] = gray[i]
		_sync()


	## ── 参考色与蒙版：干区 ──
	func _build_trunk() -> void:
		refc.resize(TP.NCC)
		var t_mid := TP.TRUNK_COLORS[1]
		var t_dark := TP.TRUNK_COLORS[2]
		var t_l := TP.TRUNK_COLORS[0]
		var tilt := [1.2, 0.9, 0.65]
		for i: int in TP.NC:
			for ch: int in 3:
				refc[i * 3 + ch] = float(t_mid[ch]) \
					+ rng.randfn(0.0, 7.0 / 4.0) * float(tilt[ch])
		var n_all: int = wire["segs"].size()
		for i: int in n_all:
			var seg: Dictionary = wire["segs"][i]
			var x0: float = float(seg["xc"]) - float(seg["w"]) * 0.5
			var x1: float = float(seg["xc"]) + float(seg["w"]) * 0.5
			var y_top: float = seg["y_top"]
			var y_bot: float = seg["y_bot"]
			var f := i / float(maxi(n_all - 1, 1))
			_rect_mask(x0, y_top, x1, y_bot)
			_cell_rect(x0, y_top, x1, y_bot,
				Vector3(float(t_dark.x), float(t_dark.y), float(t_dark.z)))
			var ins: float = float(seg["w"]) * 0.15
			var km := 1.10 - f * 0.16
			_cell_rect(x0 + ins, y_top, x1 - ins, y_bot,
				Vector3(float(t_mid.x) * km, float(t_mid.y) * km, float(t_mid.z) * km))
			var hl := Vector3(minf(float(t_l.x) * 1.05, 255.0),
				minf(float(t_l.y) * 1.05, 255.0), minf(float(t_l.z) * 1.05, 255.0))
			_cell_rect(x0 + ins, y_top, x0 + ins + float(seg["w"]) * 0.18, y_bot, hl)
			if i > 0:
				_cell_rect(x0, y_bot - 2.5, x1, y_bot,
					Vector3(float(t_dark.x) * 0.8, float(t_dark.y) * 0.8,
						float(t_dark.z) * 0.8))
			for fx: float in [0.42, 0.68]:
				var mx := x0 + (x1 - x0) * fx
				_cell_rect(mx, y_top, mx + 2.0, y_bot,
					Vector3(float(t_mid.x) * 0.78, float(t_mid.y) * 0.78,
						float(t_mid.z) * 0.78))
		# 枝：参考色 + 蒙版（蒙版笔宽 +2）
		for br: Dictionary in wire["branches"]:
			var path: PackedVector2Array = br["path"]
			var m := path.size()
			for i: int in m - 1:
				var f := i / float(maxi(m - 2, 1))
				var w: float = float(br["w0"]) + (float(br["w1"]) - float(br["w0"])) * f
				var km := 0.85 - f * 0.15
				_capsule_cells(path[i], path[i + 1], w,
					Vector3(float(t_mid.x) * km, float(t_mid.y) * km, float(t_mid.z) * km))
				_capsule_mask(path[i], path[i + 1], w + 2.0)


	## ── 参考色与蒙版：冠区 ──
	func _build_crown() -> void:
		refc.resize(TP.NCC)
		var pal: Array = wire["palette"]
		var light := Vector3(float(pal[0].x), float(pal[0].y), float(pal[0].z))
		var mid := Vector3(float(pal[1].x), float(pal[1].y), float(pal[1].z))
		var dark := Vector3(float(pal[2].x), float(pal[2].y), float(pal[2].z))
		for i: int in TP.NCC:
			var ch := i % 3
			var tilt := 0.95 if ch == 0 else (1.25 if ch == 1 else 0.85)
			refc[i] = mid[ch] + rng.randfn(0.0, 8.0 / 4.0) * tilt
		# 团按 cy 降序（自下而上）叠合 0.25/0.75
		var order := (wire["blobs"] as Array).duplicate()
		order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return Vector2(a["c"]).y > Vector2(b["c"]).y)
		for b: Dictionary in order:
			var bc: Vector2 = b["c"]
			var circles: Array = [Vector3(bc.x, bc.y, float(b["r"]))]
			circles.append_array(b["sub"])
			for cir: Vector3 in circles:
				_blob_dome(cir, light, mid, dark)
		# 蒙版：团圆并集（含子圆）+ 整体椭圆填充（团间空隙 = 内部）
		var min_x := 1e9
		var max_x := -1e9
		var min_y := 1e9
		var max_y := -1e9
		for b: Dictionary in wire["blobs"]:
			var bc: Vector2 = b["c"]
			var br_r: float = b["r"]
			var circles: Array = [Vector3(bc.x, bc.y, br_r)]
			circles.append_array(b["sub"])
			for cir: Vector3 in circles:
				_fill_circle_mask(cir.x, cir.y, cir.z)
				min_x = minf(min_x, cir.x - cir.z)
				max_x = maxf(max_x, cir.x + cir.z)
				min_y = minf(min_y, cir.y - cir.z)
				max_y = maxf(max_y, cir.y + cir.z)
		if min_x < max_x:
			var ecx := (min_x + max_x) / 2.0
			var ecy := (min_y + max_y) / 2.0
			var erx := (max_x - min_x) * 0.47
			var ery := (max_y - min_y) * 0.47
			_fill_ellipse_mask(ecx, ecy, erx, ery)


	## 单团受光 dome（render_crown_ref 等效：每格 2×2 子采样求均值后 0.25/0.75 叠合）。
	## dome 斜坡陡（亮核直径仅 5-8 格），格中心单点采样会漏峰值、暗环被平滑成
	## 整圈"描边"——实测参考图 P90 低 17 级、暗区多 65%，子采样恢复像素级平均。
	func _blob_dome(cir: Vector3, light: Vector3, mid: Vector3, dark: Vector3) -> void:
		var sx := cir.x
		var sy := cir.y
		var sr := cir.z
		var lx := sx - sr * 0.30
		var ly := sy - sr * 0.34
		var r_cell: int = int(ceilf(1.35 * sr / TP.GRID)) + 1
		var cc := clampi(int(sx / TP.GRID), 0, TP.GW - 1)
		var cr := clampi(int(sy / TP.GRID), 0, TP.GH - 1)
		for row: int in range(maxi(0, cr - r_cell), mini(TP.GH, cr + r_cell + 1)):
			for col: int in range(maxi(0, cc - r_cell), mini(TP.GW, cc + r_cell + 1)):
				var acc := Vector3(0.0, 0.0, 0.0)
				var n_sub := 0
				for sy_i: int in 2:
					for sx_i: int in 2:
						var px := (col + 0.25 + 0.5 * sx_i) * TP.GRID
						var py := (row + 0.25 + 0.5 * sy_i) * TP.GRID
						var d := sqrt((px - lx) * (px - lx) + (py - ly) * (py - ly)) \
							/ maxf(sr, 1.0)
						if d >= 1.35:
							continue
						n_sub += 1
						var dome: float = clampf(1.0 - (d - 0.55) / 0.5, 0.0, 1.0)
						var vshade := 0.82 + 0.10 * (1.0 - (py - sy) / maxf(sr, 1.0))
						for ch: int in 3:
							var base: float = mid[ch] * vshade
							var col_v: float = base * (0.78 + 0.55 * dome)
							if dome > 0.75:
								col_v += (light[ch] - base) * 0.45
							if dome < 0.18:
								col_v += (dark[ch] - base) * 0.55
							acc[ch] += col_v
				if n_sub == 0:
					continue
				var idx := row * TP.GW + col
				for ch: int in 3:
					refc[idx * 3 + ch] = refc[idx * 3 + ch] * 0.25 \
						+ (acc[ch] / float(n_sub)) * 0.75


		## ── 流场：块级结构张量 + 颜色门控扩散（build_flow_regional 移植） ──
	func _build_flow() -> void:
		# 格级梯度 + 解析噪声抖动（每轴 σ=4）：Python 的梯度来自含噪像素
		# （σ≈8/px），噪声能量（bg 中位 grad_norm 0.10~0.14）淹没 dome 结构信号
		# → imp 场近平平（实测内外均 1.22~1.30），贪心选点近似均匀、落笔率≈
		# mask 面积占比（冠 under 落 ~300/680、干 ~25/280）。格级平均把噪声消掉
		# 后信噪比虚高 4 倍、imp 对比过锐 → 落笔偏多边缘偏整齐。注入抖动让
		# 梯度/张量/imp 的噪声主导特性与像素级一致。
		var gray := PackedFloat32Array()
		gray.resize(TP.NC)
		for i: int in TP.NC:
			gray[i] = (refc[i * 3] + refc[i * 3 + 1] + refc[i * 3 + 2]) / 3.0
		var gx := PackedFloat32Array()
		gx.resize(TP.NC)
		var gy := PackedFloat32Array()
		gy.resize(TP.NC)
		gradn.resize(TP.NC)
		var gmax := 0.0
		for r: int in TP.GH:
			for c: int in TP.GW:
				var i := r * TP.GW + c
				var xm: float = gray[r * TP.GW + maxi(c - 1, 0)]
				var xp: float = gray[r * TP.GW + mini(c + 1, TP.GW - 1)]
				var ym: float = gray[maxi(r - 1, 0) * TP.GW + c]
				var yp: float = gray[mini(r + 1, TP.GH - 1) * TP.GW + c]
				gx[i] = (xp - xm) * 0.5 + rng.randfn(0.0, 4.0)
				gy[i] = (yp - ym) * 0.5 + rng.randfn(0.0, 4.0)
				var mag := sqrt(gx[i] * gx[i] + gy[i] * gy[i])
				gradn[i] = mag
				gmax = maxf(gmax, mag)
		for i: int in TP.NC:
			gradn[i] = gradn[i] / gmax if gmax > 0.0 else 0.0
		# 块级结构张量（块 = FLOW_BLOCK px = 12×12 格）
		var nb_y: int = TP.H / TP.FLOW_BLOCK
		var nb_x: int = TP.W / TP.FLOW_BLOCK
		var cb: int = TP.FLOW_BLOCK / TP.GRID
		var ixx: Array = []
		var iyy: Array = []
		var ixy: Array = []
		var coh: Array = []
		var ang_b: Array = []
		var col_b: Array = []
		for br_i: int in nb_y:
			for bc_j: int in nb_x:
				var sxx := 0.0
				var syy := 0.0
				var sxy := 0.0
				var col := Vector3(0.0, 0.0, 0.0)
				for rr: int in cb:
					for cc: int in cb:
						var i: int = (br_i * cb + rr) * TP.GW + bc_j * cb + cc
						sxx += gx[i] * gx[i]
						syy += gy[i] * gy[i]
						sxy += gx[i] * gy[i]
						col.x += refc[i * 3]
						col.y += refc[i * 3 + 1]
						col.z += refc[i * 3 + 2]
				var n_cells := float(cb * cb)
				ixx.append(sxx)
				iyy.append(syy)
				ixy.append(sxy)
				col_b.append(col / n_cells)
				ang_b.append(0.5 * atan2(2.0 * sxy, sxx - syy) + PI / 2.0)
				coh.append(sqrt((sxx - syy) * (sxx - syy) + 4.0 * sxy * sxy)
					/ (sxx + syy + 0.000001))
		# 色块门（右/下邻色距 → 可融合度）
		var gate_r: Array = []
		var gate_d: Array = []
		for br_i: int in nb_y:
			for bc_j: int in nb_x:
				var i := br_i * nb_x + bc_j
				if bc_j < nb_x - 1:
					gate_r.append(_gate(col_b[i], col_b[i + 1]))
				else:
					gate_r.append(1.0)
				if br_i < nb_y - 1:
					gate_d.append(_gate(col_b[i], col_b[i + nb_x]))
				else:
					gate_d.append(1.0)
		# 门控扩散（3 轮 4 邻域，双倍角向量）
		var ux: Array = []
		var uy: Array = []
		for i: int in ang_b.size():
			ux.append(cos(2.0 * float(ang_b[i])))
			uy.append(sin(2.0 * float(ang_b[i])))
		for _it: int in 3:
			var nux: Array = []
			var nuy: Array = []
			for i: int in ux.size():
				var acc_x := 0.0
				var acc_y := 0.0
				var wsum := 0.0
				var j: int
				j = i + 1 if i % nb_x < nb_x - 1 else -1
				if j >= 0:
					acc_x += ux[j] * gate_r[i]
					acc_y += uy[j] * gate_r[i]
					wsum += gate_r[i]
				j = i - 1 if i % nb_x > 0 else -1
				if j >= 0:
					acc_x += ux[j] * gate_r[j]
					acc_y += uy[j] * gate_r[j]
					wsum += gate_r[j]
				j = i + nb_x if i < ux.size() - nb_x else -1
				if j >= 0:
					acc_x += ux[j] * gate_d[i]
					acc_y += uy[j] * gate_d[i]
					wsum += gate_d[i]
				j = i - nb_x if i >= nb_x else -1
				if j >= 0:
					acc_x += ux[j] * gate_d[j]
					acc_y += uy[j] * gate_d[j]
					wsum += gate_d[j]
				var cf: float = clampf(float(coh[i]) * 2.2, 0.12, 0.88)
				var keep: float = clampf(cf + (1.0 - cf) * (1.0 - clampf(wsum / 4.0, 0.0, 1.0)), 0.0, 1.0)
				if wsum > 0.000001:
					nux.append(ux[i] * keep + (acc_x / wsum) * (1.0 - keep))
					nuy.append(uy[i] * keep + (acc_y / wsum) * (1.0 - keep))
				else:
					nux.append(ux[i])
					nuy.append(uy[i])
			ux = nux
			uy = nuy
		# 块方向铺回格级
		flow.resize(TP.NC)
		for r: int in TP.GH:
			var br_i := mini(r / cb, nb_y - 1)
			for c: int in TP.GW:
				var bc_j := mini(c / cb, nb_x - 1)
				flow[r * TP.GW + c] = 0.5 * atan2(
					float(uy[br_i * nb_x + bc_j]), float(ux[br_i * nb_x + bc_j]))
		# 冠部螺旋注入：每团一个绕圈切向场（add_spiral 移植）
		if region == 2:
			for b: Dictionary in wire["blobs"]:
				var bc: Vector2 = b["c"]
				_add_spiral(bc, float(b["r"]) * 1.30, 0.55)


	func _gate(a: Vector3, b: Vector3) -> float:
		var d := (a - b).length()
		return exp(-(d / TP.COLOR_BREAK) * (d / TP.COLOR_BREAK))


	func _add_spiral(center: Vector2, rad: float, strength: float) -> void:
		var r_cell: int = int(ceilf(rad * 2.5 / TP.GRID))
		var cc := clampi(int(center.x / TP.GRID), 0, TP.GW - 1)
		var cr := clampi(int(center.y / TP.GRID), 0, TP.GH - 1)
		for row: int in range(maxi(0, cr - r_cell), mini(TP.GH, cr + r_cell + 1)):
			for col: int in range(maxi(0, cc - r_cell), mini(TP.GW, cc + r_cell + 1)):
				var px := (col + 0.5) * TP.GRID - center.x
				var py := (row + 0.5) * TP.GRID - center.y
				var idx := row * TP.GW + col
				var fa := flow[idx]
				var spiral := atan2(py, px) + PI / 2.0 - 0.18
				var r := sqrt(px * px + py * py)
				var wgt := exp(-(r / rad) * (r / rad))
				var mixv: float = clampf(strength * wgt, 0.0, 1.0)
				var uxv: float = cos(2.0 * fa) * (1.0 - mixv) + cos(2.0 * spiral) * mixv
				var uyv: float = sin(2.0 * fa) * (1.0 - mixv) + sin(2.0 * spiral) * mixv
				flow[idx] = 0.5 * atan2(uyv, uxv)


	## ── 分层笔触生成（gen_layer 移植；THIN_LAYERS 的链式参数在 stamp 产物上
	##    等效为每笔独立选点——Python 版 chain=0 时同此行为） ──
	func gen(w_scale: float, ln_scale: float, total: int, stats: Dictionary) -> Array:
		var pens: Array = []
		var stats_key := "trunk_layers" if region == 0 else "crown_layers"
		stats[stats_key] = []
		if DBG != "":
			var imp_in := 0.0
			var imp_out := 0.0
			var n_in := 0
			var n_out := 0
			for r: int in TP.GH:
				for c: int in TP.GW:
					var i := r * TP.GW + c
					var mx := clampi(c * TP.GRID + TP.GRID / 2, 0, TP.W - 1)
					var my := clampi(r * TP.GRID + TP.GRID / 2, 0, TP.H - 1)
					if mask.get_pixel(mx, my).r >= 0.5:
						imp_in += imp[i]
						n_in += 1
					else:
						imp_out += imp[i]
						n_out += 1
			print("[dbg] 区%d mask格占比 %.2f imp内均 %.3f imp外均 %.3f" % [
				region, float(n_in) / float(TP.NC),
				imp_in / float(maxi(n_in, 1)), imp_out / float(maxi(n_out, 1))])
		for layer: Dictionary in TP.LAYERS:
			var n: int = int(float(total) * float(layer["ratio"]))
			var layer_stat := {"name": String(layer["name"]), "req": n, "got": 0}
			stats[stats_key].append(layer_stat)
			if n == 0:
				continue
			var w0: float = float(layer["w0"]) * TP.K_SCALE * w_scale
			var w1: float = float(layer["w1"]) * TP.K_SCALE * w_scale
			var ln_eff: float = float(layer["ln"]) * TP.K_SCALE * ln_scale
			var has_break: bool = layer.get("color_break", false)
			var refine: bool = layer.get("refine", false)
			var err_thresh := float(layer.get("err_thresh", 0.06))
			var band_jit := float(layer.get("band_jit", 0.0))
			var jit := float(layer["jit"])
			if refine:
				_sync()
				frac_frozen = true  # 层内恒定（Python 实测；见 _sync 注释）
			var w_step := (w1 - w0) / float(maxi(n, 1))
			for i: int in n:
				var w := w0 + w_step * i
				var length := ln_eff * rng.randf_range(0.6, 1.3)
				var alpha: float = minf(1.0, float(layer["alpha"]) * rng.randf_range(0.9, 1.1))
				var cell := _pick_start(refine, err_thresh)
				if cell < 0:
					print("[pipeline] 区%d %s层 误差收笔于 %d/%d" % [region, String(layer["name"]), i, n])
					break  # 误差收敛 → 提前收笔
				var cr := cell / TP.GW
				var cc := cell % TP.GW
				var x := cc * TP.GRID + rng.randf_range(0.0, TP.GRID)
				var y := cr * TP.GRID + rng.randf_range(0.0, TP.GRID)
				var fa: float = flow[cell] + rng.randf_range(-band_jit, band_jit)
				var ang: float = fa + rng.randf_range(-jit, jit)
				if has_break:
					length = _clamp_to_color(x, y, ang, length, cell)
				var col := _cell_color_jitter(cell)
				var ex := x + cos(ang) * length
				var ey := y + sin(ang) * length
				_mark_coverage(x, y, ex, ey, w)
				if _stamp(x, y, ex, ey, w, col, alpha, pens):
					layer_stat["got"] = int(layer_stat["got"]) + 1
			frac_frozen = false
		return pens


	## 初始画布可视化/重放用：canv → RGB Image（灰度模糊参考 = underpaint 底色）
	func canvas_init_img() -> Image:
		var img := Image.create(TP.W, TP.H, false, Image.FORMAT_RGB8)
		for row: int in TP.GH:
			for col_i: int in TP.GW:
				var i := row * TP.GW + col_i
				var v := clampf(canv[i * 3] / 255.0, 0.0, 1.0)
				img.fill_rect(Rect2i(col_i * TP.GRID, row * TP.GRID, TP.GRID, TP.GRID),
					Color(v, v, v))
		return img


	## 选点：细化层=误差加权采样（前缀和二分）；其余=24 贪心扫描（pick_start 移植）
	func _pick_start(refine: bool, thresh_in: float) -> int:
		if refine:
			if err_frac_high < 0.02:
				return -1
			if err_w_max < 0.02:
				return -1
			var r := rng.randf() * err_w_total
			var lo := 0
			var hi := TP.NC - 1
			while lo < hi:
				var mid := (lo + hi) / 2
				if err_cum[mid] < r:
					lo = mid + 1
				else:
					hi = mid
			return lo
		var thresh := thresh_in
		var best := 0
		for _attempt: int in 3:
			var best_v := -1.0
			for _k: int in 24:
				var cell: int = rng.randi_range(0, TP.NC - 1)
				var avail: float = imp[cell] * clampf(1.0 - cov[cell] / 1.6, 0.0, 1.0)
				var v := avail * rng.randf_range(0.7, 1.0)
				if v > best_v:
					best_v = v
					best = cell
			if best_v >= thresh:
				return best
			cov.fill(0.0)
			thresh *= 0.5
		return best


	## 色块断链截笔（_clamp_to_color_region 移植：2px 步进探测）
	func _clamp_to_color(x: float, y: float, ang: float, length: float, anchor_cell: int) -> float:
		var st := 2.0
		var ca := cos(ang)
		var sa := sin(ang)
		var d := st
		while d <= length:
			var c := clampi(int((x + ca * d) / TP.GRID), 0, TP.GW - 1)
			var r := clampi(int((y + sa * d) / TP.GRID), 0, TP.GH - 1)
			if _col_dist(r * TP.GW + c, anchor_cell) > TP.COLOR_BREAK:
				return maxf(st * 0.6, d - st)
			d += st
		return length


	func _col_dist(a: int, b: int) -> float:
		var dr := float(colq[a * 3] - colq[b * 3])
		var dg := float(colq[a * 3 + 1] - colq[b * 3 + 1])
		var db := float(colq[a * 3 + 2] - colq[b * 3 + 2])
		return sqrt(dr * dr + dg * dg + db * db)


	func _cell_color_jitter(cell: int) -> Vector3i:
		return Vector3i(
			clampi(colq[cell * 3] + rng.randi_range(-4, 4), 0, 255),
			clampi(colq[cell * 3 + 1] + rng.randi_range(-4, 4), 0, 255),
			clampi(colq[cell * 3 + 2] + rng.randi_range(-4, 4), 0, 255))


	## 覆盖标记（mark_coverage 移植：沿线 2px 步进）
	func _mark_coverage(x0: float, y0: float, x1: float, y1: float, w: float) -> void:
		var d := sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
		var steps := maxi(1, int(d / 2.0))
		for i: int in steps + 1:
			var t := i / float(steps)
			var c := clampi(int((x0 + (x1 - x0) * t) / TP.GRID), 0, TP.GW - 1)
			var r := clampi(int((y0 + (y1 - y0) * t) / TP.GRID), 0, TP.GH - 1)
			cov[r * TP.GW + c] += w * 0.06


	## 落笔：mask 笔中心硬判定 → eff 混合（中点画布色）→ 画布格覆盖混合 + 输出笔
	func _stamp(x0: float, y0: float, x1: float, y1: float, w: float, col: Vector3i,
			alpha: float, pens: Array) -> bool:
		var mx := clampi(int((x0 + x1) * 0.5), 0, TP.W - 1)
		var my := clampi(int((y0 + y1) * 0.5), 0, TP.H - 1)
		if mask.get_pixel(mx, my).r < 0.5:
			return false
		var cell: int = clampi(int(my / TP.GRID), 0, TP.GH - 1) * TP.GW \
			+ clampi(int(mx / TP.GRID), 0, TP.GW - 1)
		var eff := Vector3i(
			clampi(int(float(col.x) * alpha + canv[cell * 3] * (1.0 - alpha)), 0, 255),
			clampi(int(float(col.y) * alpha + canv[cell * 3 + 1] * (1.0 - alpha)), 0, 255),
			clampi(int(float(col.z) * alpha + canv[cell * 3 + 2] * (1.0 - alpha)), 0, 255))
		var wd := maxi(1, int(roundf(w)))
		_stamp_cells(x0, y0, x1, y1, wd, eff)
		# pen 存 col 原色+alpha（eff 混合在 rasterize 的像素画布上做，与 PY 同构）
		pens.append({"a": Vector2(x0, y0), "b": Vector2(x1, y1),
			"c": Color8(col.x, col.y, col.z), "w": wd, "g": region, "al": alpha})
		since_sync += 1
		if since_sync >= 256:
			_sync()
		return true


	## 画布格覆盖混合（胶囊 → 格覆盖率近似：中心距三分档）
	func _stamp_cells(x0: float, y0: float, x1: float, y1: float, wd: int, eff: Vector3i) -> void:
		var r := maxf(wd * 0.5, 0.5)
		var c0 := clampi(int((minf(x0, x1) - r) / TP.GRID), 0, TP.GW - 1)
		var c1 := clampi(int((maxf(x0, x1) + r) / TP.GRID), 0, TP.GW - 1)
		var r0 := clampi(int((minf(y0, y1) - r) / TP.GRID), 0, TP.GH - 1)
		var r1 := clampi(int((maxf(y0, y1) + r) / TP.GRID), 0, TP.GH - 1)
		var half := TP.GRID * 0.5
		for row: int in range(r0, r1 + 1):
			var cy := row * TP.GRID + half
			for col: int in range(c0, c1 + 1):
				var f := _capsule_frac(x0, y0, x1, y1, r, col * TP.GRID + half, cy)
				if f <= 0.0:
					continue
				var idx := row * TP.GW + col
				canv[idx * 3] = canv[idx * 3] * (1.0 - f) + float(eff.x) * f
				canv[idx * 3 + 1] = canv[idx * 3 + 1] * (1.0 - f) + float(eff.y) * f
				canv[idx * 3 + 2] = canv[idx * 3 + 2] * (1.0 - f) + float(eff.z) * f


	static func _capsule_frac(x0: float, y0: float, x1: float, y1: float, r: float,
			px: float, py: float) -> float:
		var dx := x1 - x0
		var dy := y1 - y0
		var dd := dx * dx + dy * dy
		var t := 0.5
		if dd > 0.000001:
			t = clampf(((px - x0) * dx + (py - y0) * dy) / dd, 0.0, 1.0)
		var qx := x0 + dx * t - px
		var qy := y0 + dy * t - py
		var dist := sqrt(qx * qx + qy * qy)
		if dist <= r - 2.5:
			return 1.0
		if dist >= r + 2.9:
			return 0.0
		return 0.5


	## 误差同步（_sync_canvas 移植：格级 |画布-参考| + 平滑归一化 + 加权采样缓存）。
	## 三处像素级语义的解析等效（数值均经 Python 探针实测校准，temp/pycheck/）：
	## 1. 噪声底噪：Python 像素误差在平坦区有 E|N(0,σ)|≈σ·√(2/π) 底噪（downsample
	##    后仍在），格级平均会消掉 → errs 加回（冠 6.4 / 干 5.1）。
	## 2. err_frac_high（>40 像素占比）＝背景概率（折叠正态解析）＋冠区带状量化项：
	##    Python 实测 detail 起点冠 mask 内 >40 占 8.7%（dome 明暗带的笔触量化误差，
	##    细笔不可修复、全程恒定）→ 冠区解析值 +0.010 校准。实测对照：
	##    Python 冠 0.031~0.048（永不 <0.02，detail 跑满 1088）/ 干 ~0（立即收笔）。
	## 3. refine 层内冻结：Python 的 frac 在层内恒定（背景不被笔触改变 + 量化误差
	##    不可修复），格模型的覆盖混合会让它中途跌破阈值 → 层内不更新。
	func _sync() -> void:
		var noise_floor := 6.4 if region == 2 else 5.1
		var sig0 := 7.6 if region == 2 else 8.4
		var sig1 := 10.0 if region == 2 else 6.3
		var sig2 := 6.8 if region == 2 else 4.55
		var emax := 0.0
		var psum := 0.0
		for i: int in TP.NC:
			var d0 := absf(canv[i * 3] - refc[i * 3])
			var d1 := absf(canv[i * 3 + 1] - refc[i * 3 + 1])
			var d2 := absf(canv[i * 3 + 2] - refc[i * 3 + 2])
			var e := (d0 + d1 + d2) / 3.0 + noise_floor
			err[i] = e
			emax = maxf(emax, e)
			# 像素误差 = 三通道 |d_ch - n_ch| 均值 > 40 ⇔ Σ|d_ch-n_ch| > 120；
			# Σ 近似正态（折叠正态的均值/方差按通道累加）
			var m := 0.0
			var vv := 0.0
			for pair: Vector2 in [Vector2(d0, sig0), Vector2(d1, sig1), Vector2(d2, sig2)]:
				var d := pair.x
				var sg := pair.y
				if sg <= 0.0 or d > sg * 6.0:
					m += d
					continue
				var t := d / sg
				var m_ch: float = sg * 0.7978845608 * exp(-0.5 * t * t) \
					+ d * TP._erf(t * 0.7071067812)
				m += m_ch
				vv += d * d + sg * sg - m_ch * m_ch
			if vv <= 0.000001:
				psum += 1.0 if m > 120.0 else 0.0
			else:
				psum += 0.5 * (1.0 - TP._erf((120.0 - m) / sqrt(vv) * 0.7071067812))
		if not frac_frozen:
			err_frac_high = psum / float(TP.NC) + (0.010 if region == 2 else 0.0)
		var sm := _smooth(err, 1.0)
		err_w.resize(TP.NC)
		err_cum.resize(TP.NC)
		err_w_total = 0.0
		err_w_max = 0.0
		for i: int in TP.NC:
			errs[i] = sm[i] / emax if emax > 0.000001 else 0.0
			var wgt: float = imp[i] * pow(clampf(errs[i], 0.0, 1.0), 1.2)
			err_w[i] = wgt
			err_w_total += wgt
			err_w_max = maxf(err_w_max, wgt)
			err_cum[i] = err_w_total
		since_sync = 0


	## 3-tap 平滑（PIL GaussianBlur 的分离近似），保持量纲
	func _smooth(arr: PackedFloat32Array, radius: float) -> PackedFloat32Array:
		var rad := maxi(1, int(roundf(radius)))
		var out := PackedFloat32Array()
		out.resize(arr.size())
		for r: int in TP.GH:
			var base := r * TP.GW
			for c: int in TP.GW:
				var s := 0.0
				var wsum := 0.0
				for k: int in range(-rad, rad + 1):
					var cc := c + k
					if cc < 0 or cc >= TP.GW:
						continue
					var wgt := 1.0 - absf(float(k)) / float(rad + 1.0)
					s += arr[base + cc] * wgt
					wsum += wgt
				out[base + c] = s / wsum
		var out2 := PackedFloat32Array()
		out2.resize(arr.size())
		for r: int in TP.GH:
			var base := r * TP.GW
			for c: int in TP.GW:
				var s := 0.0
				var wsum := 0.0
				for k: int in range(-rad, rad + 1):
					var rr := r + k
					if rr < 0 or rr >= TP.GH:
						continue
					var wgt := 1.0 - absf(float(k)) / float(rad + 1.0)
					s += out[rr * TP.GW + c] * wgt
					wsum += wgt
				out2[base + c] = s / wsum
		return out2


	## ── 参考色/蒙版栅格辅助 ──
	# 轴对齐矩形：格覆盖率精确混合（refc）
	func _cell_rect(x0: float, y0: float, x1: float, y1: float, col: Vector3) -> void:
		if x1 <= x0 or y1 <= y0:
			return
		var c0 := maxi(int(floorf(x0 / TP.GRID)), 0)
		var c1 := mini(int(floorf((x1 - 0.001) / TP.GRID)), TP.GW - 1)
		var r0 := maxi(int(floorf(y0 / TP.GRID)), 0)
		var r1 := mini(int(floorf((y1 - 0.001) / TP.GRID)), TP.GH - 1)
		for row: int in range(r0, r1 + 1):
			var ry0: float = row * TP.GRID
			var fy := (minf(y1, ry0 + TP.GRID) - maxf(y0, ry0)) / TP.GRID
			for ci: int in range(c0, c1 + 1):
				var cx0: float = ci * TP.GRID
				var fx := (minf(x1, cx0 + TP.GRID) - maxf(x0, cx0)) / TP.GRID
				var f := fx * fy
				if f <= 0.0:
					continue
				var idx := row * TP.GW + ci
				for ch: int in 3:
					refc[idx * 3 + ch] = refc[idx * 3 + ch] * (1.0 - f) + col[ch] * f

	# 胶囊：格中心距三分档覆盖混合（枝参考色）
	func _capsule_cells(a: Vector2, b: Vector2, w: float, col: Vector3) -> void:
		var r := maxf(w * 0.5, 0.5)
		var c0 := clampi(int((minf(a.x, b.x) - r) / TP.GRID), 0, TP.GW - 1)
		var c1 := clampi(int((maxf(a.x, b.x) + r) / TP.GRID), 0, TP.GW - 1)
		var r0 := clampi(int((minf(a.y, b.y) - r) / TP.GRID), 0, TP.GH - 1)
		var r1 := clampi(int((maxf(a.y, b.y) + r) / TP.GRID), 0, TP.GH - 1)
		var half := TP.GRID * 0.5
		for row: int in range(r0, r1 + 1):
			for ci: int in range(c0, c1 + 1):
				var f := _capsule_frac(a.x, a.y, b.x, b.y, r,
					ci * TP.GRID + half, row * TP.GRID + half)
				if f <= 0.0:
					continue
				var idx := row * TP.GW + ci
				for ch: int in 3:
					refc[idx * 3 + ch] = refc[idx * 3 + ch] * (1.0 - f) + col[ch] * f

	func _rect_mask(x0: float, y0: float, x1: float, y1: float) -> void:
		var rect := Rect2i(Vector2i(int(roundf(x0)), int(roundf(y0))),
			Vector2i(maxi(int(roundf(x1 - x0)), 1), maxi(int(roundf(y1 - y0)), 1)))
		rect = rect.intersection(Rect2i(Vector2i(0, 0), Vector2i(TP.W, TP.H)))
		if rect.size.x > 0 and rect.size.y > 0:
			mask.fill_rect(rect, Color(1, 1, 1))

	# 粗胶囊蒙版（枝，笔宽+2）：沿路径 1px 步进盖圆
	func _capsule_mask(a: Vector2, b: Vector2, w: float) -> void:
		var r := maxf(w * 0.5, 1.0)
		var d := a.distance_to(b)
		var steps := maxi(1, int(d))
		for i: int in steps + 1:
			var t := i / float(steps)
			_fill_circle_mask(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, r)

	func _fill_circle_mask(cx: float, cy: float, r: float) -> void:
		if r <= 0.0:
			return
		var y0 := maxi(int(ceilf(cy - r)), 0)
		var y1 := mini(int(cy + r), TP.H - 1)
		for y: int in range(y0, y1 + 1):
			var dy := float(y) - cy
			var half := sqrt(maxf(r * r - dy * dy, 0.0))
			var x0 := maxi(int(roundf(cx - half)), 0)
			var x1 := mini(int(roundf(cx + half)), TP.W - 1)
			if x1 >= x0:
				mask.fill_rect(Rect2i(x0, y, x1 - x0 + 1, 1), Color(1, 1, 1))

	func _fill_ellipse_mask(ecx: float, ecy: float, erx: float, ery: float) -> void:
		var y0 := maxi(int(ceilf(ecy - ery)), 0)
		var y1 := mini(int(ecy + ery), TP.H - 1)
		for y: int in range(y0, y1 + 1):
			var t := (float(y) + 0.5 - ecy) / maxf(ery, 1.0)
			if absf(t) >= 1.0:
				continue
			var half := erx * sqrt(1.0 - t * t)
			var x0 := maxi(int(roundf(ecx - half)), 0)
			var x1 := mini(int(roundf(ecx + half)), TP.W - 1)
			if x1 >= x0:
				mask.fill_rect(Rect2i(x0, y, x1 - x0 + 1, 1), Color(1, 1, 1))


# ─────────────────────── 全分辨率栅格化（烘焙/验证） ───────────────────────

## 误差函数近似（Abramowitz-Stegun 7.1.26，最大误差 1.5e-7；GDScript 无内置 erf）
static func _erf(x: float) -> float:
	var sg := signf(x)
	var ax := absf(x)
	var t := 1.0 / (1.0 + 0.3275911 * ax)
	var y := 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t \
		- 0.284496736) * t + 0.254829592) * t * exp(-ax * ax)
	return sg * y


## 圆头笔 stamp 进模拟画布（stamp_canvas 同构）：eff=col×alpha+画布中点×(1-alpha)，
## 画布 RGB 就地更新；alpha 并集画布 stamp 255（硬边）。枝直绘笔 al=1 纯色盖。
static func _stamp_img(canvas: Image, alpha: Image, p: Dictionary) -> void:
	var a: Vector2 = p["a"]
	var b: Vector2 = p["b"]
	var wd: int = p["w"]
	var al: float = p.get("al", 1.0)
	var col: Color = p["c"]
	var mid_x := clampi(int((a.x + b.x) * 0.5), 0, W - 1)
	var mid_y := clampi(int((a.y + b.y) * 0.5), 0, H - 1)
	var eff := col
	if al < 0.999:
		var under := canvas.get_pixel(mid_x, mid_y)
		eff = Color(
			col.r * al + under.r * (1.0 - al),
			col.g * al + under.g * (1.0 - al),
			col.b * al + under.b * (1.0 - al))
	var r := maxf(wd * 0.5, 0.5)
	var d := a.distance_to(b)
	var steps := maxi(1, int(d * 2.0))
	var dx := (b.x - a.x) / steps
	var dy := (b.y - a.y) / steps
	for i: int in steps + 1:
		var cx := a.x + dx * i
		var cy := a.y + dy * i
		var y0 := maxi(int(roundf(cy - r)), 0)
		var y1 := mini(int(roundf(cy + r)), H - 1)
		for y: int in range(y0, y1 + 1):
			var ddy := float(y) - cy
			var half := sqrt(maxf(r * r - ddy * ddy, 0.0))
			var rx0 := maxi(int(roundf(cx - half)), 0)
			var rx1 := mini(int(roundf(cx + half)), W - 1)
			if rx1 < rx0:
				continue
			for x: int in range(rx0, rx1 + 1):
				canvas.set_pixel(x, y, eff)
				alpha.set_pixel(x, y, Color(1, 1, 1))


## 标准 alpha-over：冠（top）盖干（bottom）
static func _alpha_over(trunk_rgb: Image, trunk_a: Image, crown_rgb: Image,
		crown_a: Image) -> Image:
	var out := Image.create(W, H, false, Image.FORMAT_RGBA8)
	for y: int in H:
		for x: int in W:
			var ab: float = trunk_a.get_pixel(x, y).r
			var at: float = crown_a.get_pixel(x, y).r
			var ao := at + ab * (1.0 - at)
			if ao < 0.003:
				out.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			var tb := trunk_rgb.get_pixel(x, y)
			var tc := crown_rgb.get_pixel(x, y)
			var r := (tc.r * at + tb.r * ab * (1.0 - at)) / ao
			var g := (tc.g * at + tb.g * ab * (1.0 - at)) / ao
			var bl := (tc.b * at + tb.b * ab * (1.0 - at)) / ao
			out.set_pixel(x, y, Color(r, g, bl, ao))
	return out
