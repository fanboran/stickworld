extends Node2D
## 树形参数实验室 v3 —— 实时笔触生成 + 逐笔生长动画（渲染过程展示）。
## 主菜单 → 测试场景 → 树形参数实验室；方向键/WASD 平移，ESC 回主菜单。
##
## 布局：顶部参数面板；下方 3 排 × 3 棵预览树（逐笔生长 = 笔触管线过程可视化，
## 上排先长、中下排依次跟上）。滑条防抖 0.15s 后全部重算重画。
## 「烘焙变体池」：当前参数 × 10 种子渲染成 PNG 存 assets/resources/（重开场景生效）。
## 笔列表坐标约定：贴图原生坐标（x 居中 192、y 向下、ground=660）。

const GRID := 3  # 3 排 × 3 棵
const SEED_BASE := 1000
const BAKE_COUNT := 10
const CANVAS := Vector2(384.0, 672.0)
const PIVOT := Vector2(192.0, 660.0)  # 画布中轴 × 地面线

const PARAM_DEFS := [
	["height_factor", "总高因子", 1.0, 0.70, 1.00, 0.01, 2],
	["bare_frac", "底部裸干比例", 0.13, 0.00, 0.30, 0.01, 2],
	["trunk_frac", "枝干占枝叶区比例", 0.60, 0.40, 0.72, 0.01, 2],
	["trunk_w", "干宽系数(×树高)", 0.042, 0.025, 0.070, 0.001, 3],
	["trunk_lean", "干倾角(±)", 0.03, 0.00, 0.10, 0.005, 3],
	["crown_r_coef", "冠主团系数", 0.52, 0.35, 0.70, 0.01, 2],
	["crown_cap", "冠宽上限(×画布宽)", 0.30, 0.20, 0.45, 0.01, 2],
	["crown_lift", "冠心上提", 0.30, 0.00, 0.60, 0.01, 2],
	["hat_n", "帽圈子团数", 8.0, 4.0, 14.0, 1.0, 0],
	["branch_prob", "枝概率", 0.48, 0.10, 0.90, 0.01, 2],
	["stroke_len", "笔长(px)", 18.0, 5.0, 30.0, 0.5, 1],
	["stroke_w", "笔宽(px)", 3.5, 1.5, 6.0, 0.1, 1],
	["crown_density", "冠笔密度", 1.0, 0.3, 2.5, 0.05, 2],
]

var _params: Dictionary = {}
var _cam: Camera2D
var _status_label: Label
var _dirty := true
var _debounce := 0.0
var _previews: Array = []

const LEAF_L := Color(0.58, 0.72, 0.34)
const LEAF_M := Color(0.42, 0.61, 0.27)
const LEAF_D := Color(0.29, 0.45, 0.22)
const TRUNK_C := Color(0.40, 0.24, 0.12)
const TRUNK_L := Color(0.50, 0.31, 0.16)
const TRUNK_D := Color(0.28, 0.16, 0.08)


func _ready() -> void:
	for d in PARAM_DEFS:
		_params[d[0]] = d[2]
	_build_panel()
	_build_previews()
	_cam = Camera2D.new()
	# 下移让出顶部面板（118px ≈ 屏高 18%）；zoom 0.19 一屏收全 3×3
	_cam.position = Vector2(1040, 1480 + 300)
	_cam.zoom = Vector2(0.19, 0.19)
	add_child(_cam)
	_cam.make_current()
	_refresh_all()


func _build_panel() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_bottom = 118.0
	panel.modulate = Color(1, 1, 1, 0.93)
	add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 2)
	scroll.add_child(grid)
	for d in PARAM_DEFS:
		grid.add_child(_make_slider(d[0], d[1], d[2], d[3], d[4], d[5], d[6]))
	var bake_btn := Button.new()
	bake_btn.text = "烘焙变体池(10棵)"
	bake_btn.pressed.connect(_bake_pool)
	grid.add_child(bake_btn)
	var copy_btn := Button.new()
	copy_btn.text = "复制参数JSON"
	copy_btn.pressed.connect(_copy_params)
	grid.add_child(copy_btn)
	_status_label = Label.new()
	_status_label.text = "就绪（树逐笔生长 = 渲染过程；WASD 平移看三排）"
	_status_label.add_theme_font_size_override("font_size", 13)
	grid.add_child(_status_label)


func _make_slider(key: String, label: String, def: float, lo: float, hi: float,
		step: float, decimals: int) -> Control:
	var box := VBoxContainer.new()
	var lab := Label.new()
	lab.add_theme_font_size_override("font_size", 12)
	box.add_child(lab)
	var slider := HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = def
	slider.custom_minimum_size = Vector2(150, 18)
	box.add_child(slider)
	slider.value_changed.connect(func(_v):
		_params[key] = slider.value
		lab.text = "%s: %s" % [label, ("%.*f" % [decimals, slider.value])]
		_dirty = true)
	lab.text = "%s: %s" % [label, ("%.*f" % [decimals, def])]
	return box


func _build_previews() -> void:
	for r in GRID:
		for c in GRID:
			var node := preload("res://tests/dev/tree_preview_node.gd").new()
			add_child(node)
			_previews.append(node)
	# 三条地面线
	_draw_ground_lines()


func _draw_ground_lines() -> void:
	for r in GRID:
		var line := Line2D.new()
		line.width = 6.0
		line.default_color = Color(0.42, 0.52, 0.33)
		var y := 300 + r * 1180
		line.points = PackedVector2Array([Vector2(-400, y), Vector2(2600, y)])
		add_child(line)


func _copy_params() -> void:
	DisplayServer.clipboard_set(JSON.stringify(_params))
	_status_label.text = "参数已复制到剪贴板"


func _input(event: InputEvent) -> void:
	# 滚轮缩放：看整屏 3×3 ↔ 拉近看单棵笔触细节
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_cam.zoom = (_cam.zoom * 1.12).clampf(0.12, 1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_cam.zoom = (_cam.zoom / 1.12).clampf(0.12, 1.0)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("ui_cancel"):
		get_tree().change_scene_to_file("res://modules/ui_global/scenes/menus/main_menu.tscn")
		return
	var dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		dir.y += 1.0
	_cam.position += dir * 900.0 * delta / maxf(_cam.zoom.x, 0.05)
	if _dirty:
		_debounce += delta
		if _debounce >= 0.15:
			_dirty = false
			_debounce = 0.0
			_refresh_all()
	else:
		_debounce = 0.0


func _refresh_all() -> void:
	for r in GRID:
		for c in GRID:
			var idx := r * GRID + c
			var seed := SEED_BASE + idx * 17 + 3
			var pens := gen_strokes(_gen_tree(seed), seed + 1)
			(_previews[idx] as Node2D).setup(pens,
				Vector2(360 + c * 640, 300 + r * 1180), 1.484, r * 0.2)


# ─────────────────────────── 结构生成 ───────────────────────────

func _gen_tree(seed: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var W := CANVAS.x
	var H := CANVAS.y
	var p := _params
	var ground: float = H - 12.0
	var usable: float = (ground - 14.0) * float(p["height_factor"])
	var bare: float = usable * rng.randf_range(float(p["bare_frac"]) * 0.62, float(p["bare_frac"]) * 1.38)
	var leaf_zone: float = usable - bare
	var trunk_h: float = leaf_zone * rng.randf_range(float(p["trunk_frac"]) - 0.06, float(p["trunk_frac"]) + 0.06)
	var w_base: float = H * rng.randf_range(float(p["trunk_w"]) - 0.006, float(p["trunk_w"]) + 0.006)
	var w_top: float = w_base * rng.randf_range(0.60, 0.78)
	var lean: float = rng.randf_range(-1.0, 1.0) * float(p["trunk_lean"]) * (trunk_h + bare)
	# 干：一整根（底 → 干顶连续，微倾角）；枝只在枝叶区高度出
	var trunk_top_y: float = ground - bare - trunk_h
	var trunk_bot_x: float = W * 0.5 + rng.randf_range(-6.0, 6.0)
	var trunk_top_x: float = trunk_bot_x + lean
	var full_h: float = ground - trunk_top_y

	var branches: Array = []
	var bp := float(p["branch_prob"])
	var side := 1.0
	var n_br := int(bp * 6.0 + rng.randf_range(0.0, 1.5))
	for i in n_br:
		var f := rng.randf_range(0.12, 0.95)  # 枝叶区内高度比例（0=干顶 1=枝叶区底）
		var oy: float = trunk_top_y + f * trunk_h
		side = -side
		var hf: float = (ground - oy) / full_h
		var w_at: float = lerpf(w_top, w_base, hf)
		var axis_x: float = lerpf(trunk_top_x, trunk_bot_x, hf)
		var origin := Vector2(axis_x + side * w_at * 0.5, oy)
		var length: float = w_base * rng.randf_range(2.2, 3.4)
		var ang := deg_to_rad(rng.randf_range(28.0, 52.0))
		var tip := origin + length * Vector2(side * sin(ang), -cos(ang))
		branches.append({"o": origin, "t": tip, "w0": w_base * 0.62, "w1": w_base * 0.36})

	# 冠：主团 + 帽圈子团 + 下垂团 + 枝端团
	var crown_h: float = leaf_zone - trunk_h
	var r_main: float = minf(crown_h * float(p["crown_r_coef"]), W * float(p["crown_cap"]))
	var cy: float = trunk_top_y - r_main * float(p["crown_lift"])
	var blobs: Array = [{"c": Vector2(trunk_top_x, cy), "r": r_main}]
	var hat_n := int(float(p["hat_n"]))
	var last_ang := -10.0
	for k in hat_n:
		# 角度随机+最小间距（去均匀环分布——均匀分布让冠呈规则圆形）
		var a := rng.randf_range(0.0, TAU)
		if absf(angle_difference(a, last_ang)) < TAU / float(hat_n) * 0.5:
			a += TAU / float(hat_n)
		last_ang = a
		var d: float = r_main * rng.randf_range(0.60, 1.05)
		blobs.append({"c": Vector2(trunk_top_x + d * cos(a), cy + d * sin(a) * rng.randf_range(0.6, 0.95)),
			"r": r_main * rng.randf_range(0.30, 0.55)})
	for k in rng.randi_range(2, 3):
		var a := PI + rng.randf_range(-0.6, 0.6)
		var d: float = r_main * rng.randf_range(0.8, 1.0)
		var by: float = minf(cy + d * sin(a) * 0.8, ground - r_main * 0.36)
		blobs.append({"c": Vector2(trunk_top_x + d * cos(a), by), "r": r_main * rng.randf_range(0.30, 0.45)})
	for br in branches:
		blobs.append({"c": Vector2(br["t"].x, br["t"].y - 4.0),
			"r": r_main * rng.randf_range(0.26, 0.4)})
	return {"branches": branches, "blobs": blobs, "ground": ground, "W": W, "H": H,
		"trunk_bot_x": trunk_bot_x, "trunk_top_x": trunk_top_x,
		"trunk_top_y": trunk_top_y, "full_h": full_h, "w_base": w_base, "w_top": w_top}


# ─────────────────────────── 笔触生成（结构 → 笔列表） ───────────────────────────

func gen_strokes(t: Dictionary, seed: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var pens: Array = []
	var ground: float = t["ground"]
	var sl: float = float(_params["stroke_len"])
	var sw: float = float(_params["stroke_w"])
	var full_h: float = t["full_h"]

	# ── 干笔（一整根连续笔列：宽度沿高渐变、微倾角、左亮右暗）──
	var cols_n := maxi(3, int(t["w_base"] / maxf(sw * 1.6, 1.0)))
	for ci in cols_n:
		var fx := (ci + 0.5) / float(cols_n) * 2.0 - 1.0  # -1..1 干轴横向
		var shade := 1.0 - absf(fx + 0.35) * 0.9
		var col := TRUNK_C.lerp(TRUNK_L, clampf(shade, 0.0, 1.0))
		col = col.lightened(rng.randf_range(-0.03, 0.03))
		var yy: float = float(t["trunk_top_y"]) + rng.randf_range(0.0, sl * 0.6)
		while yy < ground:
			var hf: float = (ground - yy) / full_h  # 0 顶 1 底
			var w_at: float = lerpf(t["w_top"], t["w_base"], hf)
			var axis_x: float = lerpf(t["trunk_top_x"], t["trunk_bot_x"], hf)
			var l: float = minf(sl * rng.randf_range(0.5, 1.5), ground - yy)
			var px := axis_x + fx * w_at * 0.42 + rng.randf_range(-2.0, 2.0)
			var skew := rng.randf_range(-2.5, 2.5)
			var top := Vector2(px + rng.randf_range(-1.2, 1.2), yy)
			var bot := Vector2(px + skew, yy + l)
			pens.append({"a": top, "b": bot, "c": col, "w": sw * rng.randf_range(0.8, 1.25)})
			yy += l * 0.95 + sl * 0.15  # 笔间留缝：短笔拼接而非连成长线

	# ── 枝笔：沿贝塞尔弧撒短笔拼接（宽度从 w0 渐变到 w1，方向沿枝+抖动）──
	for br in t["branches"]:
		var o: Vector2 = br["o"]
		var tip: Vector2 = br["t"]
		var ctrl: Vector2 = o.lerp(tip, 0.5) + Vector2(0, -10.0)
		var n_pen := 7
		for i in n_pen:
			var f0 := i / float(n_pen)
			var f1 := (i + 1.0) / float(n_pen)
			var bez := func(f: float) -> Vector2:
				return o.lerp(ctrl, f).lerp(ctrl.lerp(tip, f), f)
			var pa: Vector2 = bez.call(f0)
			var pb: Vector2 = bez.call(f1)
			var mid := (pa + pb) * 0.5 + Vector2(rng.randf_range(-1.5, 1.5), rng.randf_range(-1.0, 1.0))
			var w: float = lerpf(br["w0"], br["w1"], (f0 + f1) * 0.5) * rng.randf_range(0.85, 1.1)
			var col := TRUNK_D.lightened(rng.randf_range(-0.03, 0.05))
			pens.append({"a": pa, "b": mid, "c": col, "w": w})
			pens.append({"a": mid, "b": pb, "c": col, "w": w * 0.95})

	# ── 冠笔（绕团切向，左上受光三档；撒到团半径 1.02 铺满）──
	for b in t["blobs"]:
		var c: Vector2 = b["c"]
		var br_r: float = b["r"]
		var n: int = int(br_r * br_r * 0.085 * float(_params["crown_density"]))
		for i in n:
			var a := rng.randf_range(0.0, TAU)
			var d := sqrt(rng.randf()) * br_r * 1.15  # 越界撒点：参差外缘而非圆盘边
			var pos: Vector2 = c + Vector2(cos(a), sin(a)) * d
			var tang: float = a + PI * 0.5 + rng.randf_range(-0.35, 0.35)
			var rand_ang := rng.randf_range(0.0, TAU)
			var mix_a := atan2(lerpf(sin(tang), sin(rand_ang), 0.35),
				lerpf(cos(tang), cos(rand_ang), 0.35))
			var dir := Vector2(cos(mix_a), sin(mix_a))
			var l: float = sl * rng.randf_range(0.6, 1.4)
			var w: float = sw * rng.randf_range(0.7, 1.3)
			var loff: float = (pos - c - Vector2(-br_r * 0.3, -br_r * 0.34)).length() / maxf(br_r, 1.0)
			if loff > 0.9:
				w *= 0.7  # 边缘笔更细：外缘参差破碎（拟合版笔越界的视觉等效）
			var base := LEAF_L if loff < 0.55 else (LEAF_M if loff < 1.0 else LEAF_D)
			var col := Color.from_hsv(
				fposmod(base.h + rng.randf_range(-0.01, 0.01), 1.0),
				clampf(base.s + rng.randf_range(-0.06, 0.06), 0.30, 0.90),
				clampf(base.v + rng.randf_range(-0.08, 0.08), 0.30, 1.0))
			pens.append({"a": pos - dir * l * 0.5, "b": pos + dir * l * 0.5, "c": col, "w": w})
	return pens


# ─────────────────────────── 烘焙：SubViewport → PNG 变体池 ───────────────────────────

func _bake_pool() -> void:
	_status_label.text = "烘焙中…"
	var vp := SubViewport.new()
	vp.size = CANVAS
	vp.transparent_bg = true
	add_child(vp)
	var canvas := preload("res://tests/dev/tree_bake_canvas.gd").new()
	vp.add_child(canvas)
	for i in BAKE_COUNT:
		var seed := SEED_BASE + i * 13 + 5
		canvas.setup(gen_strokes(_gen_tree(seed), seed + 1))
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.save_png("res://assets/resources/tree_paint_tree_v%d.png" % i)
		_status_label.text = "烘焙中… %d/%d" % [i + 1, BAKE_COUNT]
	canvas.queue_free()
	vp.queue_free()
	_status_label.text = "烘焙完成 %d 棵（重开场景生效）" % BAKE_COUNT
	print("[lab] 烘焙完成")
