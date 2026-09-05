extends Node2D
## 树形参数实验室 v4 —— 内核 = 基线管线 GD 移植（tree_pipeline.gd，与
## tools/ai/gen_trees.py 同构）。主菜单 → 测试场景 → 树形参数实验室。
##
## 布局：顶部参数面板（结构 10 滑条 + 笔触 3 滑条 + 按钮行）；
## 主预览 = 当前参数成品贴图（后台线程 生成+栅格化，滑条防抖 0.3s 后重算）；
## 第二排 = 管线阶段分解（同种子：①结构线框 ②+干笔触 ③+枝 ④+冠笔触=最终）；
## 第三排 = 变体预览（3 个不同种子的成品，排队后台算）。
## 「烘焙变体池」：当前参数 × 10 种子渲染 PNG 存 assets/resources/（重开场景生效）。
## WASD/方向键平移，滚轮缩放，ESC 回主菜单。

const TP := preload("res://tests/dev/tree_pipeline.gd")
const PreviewNode := preload("res://tests/dev/tree_preview_node.gd")

const BAKE_COUNT := 10
const MAIN_SEED := 7000

## 结构滑条 = 基线 DEFAULT_PARAMS；笔触滑条 = 拟合笔数/笔宽缩放
## ⚠ 结构项的默认值列必须与 tree_pipeline.gd 的 DEFAULT_PARAMS 手动同步
## （滑条 value 会作为参数覆盖管线默认，不同步 = 改了管线默认不生效）
const PARAM_DEFS := [
	["height_factor", "总高因子", 1.0, 0.70, 1.00, 0.01, 2],
	["bare_frac", "底部裸干比例", 0.30, 0.00, 0.45, 0.01, 2],
	["trunk_frac", "枝干占枝叶区比例", 0.90, 0.40, 0.95, 0.01, 2],
	["trunk_w", "干宽系数(×树高)", 0.042, 0.025, 0.070, 0.001, 3],
	["crown_r_coef", "冠主团系数", 0.52, 0.35, 0.70, 0.01, 2],
	["crown_cap", "冠宽上限(×画布宽)", 0.30, 0.20, 0.45, 0.01, 2],
	["crown_lift", "冠心上提", 0.30, 0.00, 0.60, 0.01, 2],
	["hat_n", "帽圈子团数", 8.0, 4.0, 14.0, 1.0, 0],
	["branch_prob", "枝概率", 0.48, 0.10, 0.90, 0.01, 2],
	["seg_n", "干段数", 9.0, 6.0, 14.0, 1.0, 0],
	["trunk_n", "干笔数", 1400.0, 400.0, 2400.0, 50.0, 0],
	["crown_n", "冠笔数", 3400.0, 1000.0, 6000.0, 100.0, 0],
	["w_scale", "笔宽缩放", 1.0, 0.5, 1.6, 0.05, 2],
]

var _params: Dictionary = {}
var _cam: Camera2D
var _status_label: Label
var _dirty := true
var _debounce := 0.0
var _main_node: PreviewNode
var _stage_nodes: Array = []
var _variant_nodes: Array = []
# 统一后台任务队列：{seed, kind:"main"/"variant"/"bake", idx}
var _queue: Array = []
var _worker: Thread
var _worker_busy := false
var _main_version := 0
var _baking := false
var _bake_done := 0
var _variant_base := 7100
# 布局拖拽：按住任意预览树拖到想要的位置；「复位布局」恢复默认
var _drag_node: PreviewNode = null
var _drag_off := Vector2.ZERO
var _default_origins: Array = []


func _ready() -> void:
	for d: Array in PARAM_DEFS:
		_params[d[0]] = d[2]
	_build_panel()
	_build_previews()
	_cam = Camera2D.new()
	_cam.position = Vector2(960, 560)
	_cam.zoom = Vector2(0.42, 0.42)
	add_child(_cam)
	_cam.make_current()
	_enqueue_main()


func _build_panel() -> void:
	# UI 必须挂 CanvasLayer：挂 Node2D 下会被 Camera2D 变换带出屏幕（滑条静默不可见）
	var ui_layer := CanvasLayer.new()
	add_child(ui_layer)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_bottom = 118.0
	panel.modulate = Color(1, 1, 1, 0.93)
	ui_layer.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 2)
	scroll.add_child(grid)
	for d: Array in PARAM_DEFS:
		grid.add_child(_make_slider(d[0], d[1], d[2], d[3], d[4], d[5], d[6]))
	var action_row := HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 12)
	grid.add_child(action_row)
	var bake_btn := Button.new()
	bake_btn.text = "烘焙变体池(10棵)"
	bake_btn.pressed.connect(_bake_pool)
	action_row.add_child(bake_btn)
	var copy_btn := Button.new()
	copy_btn.text = "复制参数JSON"
	copy_btn.pressed.connect(_copy_params)
	action_row.add_child(copy_btn)
	var var_btn := Button.new()
	var_btn.text = "换一批种子"
	var_btn.pressed.connect(_next_variants)
	action_row.add_child(var_btn)
	var reset_btn := Button.new()
	reset_btn.text = "复位布局"
	reset_btn.pressed.connect(_reset_layout)
	action_row.add_child(reset_btn)
	_status_label = Label.new()
	_status_label.text = "就绪：主预览=成品；第二排=管线阶段；第三排=变体"
	_status_label.add_theme_font_size_override("font_size", 13)
	action_row.add_child(_status_label)


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
	slider.value_changed.connect(func(_v: float) -> void:
		_params[key] = slider.value
		lab.text = "%s: %s" % [label, ("%.*f" % [decimals, slider.value])]
		_dirty = true)
	lab.text = "%s: %s" % [label, ("%.*f" % [decimals, def])]
	return box


func _build_previews() -> void:
	# 地面线（第一排 y=660 处锚点、第二排 +760）
	for y: float in [660.0, 1420.0]:
		var line := Line2D.new()
		line.width = 6.0
		line.default_color = Color(0.42, 0.52, 0.33)
		line.points = PackedVector2Array([Vector2(-600, y), Vector2(2600, y)])
		add_child(line)
	# 主预览（成品贴图）
	_main_node = PreviewNode.new()
	_main_node.display_scale = 0.75
	_main_node.display_origin = Vector2(700, 660)
	add_child(_main_node)
	# 第二排：管线阶段 4 档
	for i: int in 4:
		var node: PreviewNode = PreviewNode.new()
		node.display_scale = 0.55
		node.display_origin = Vector2(1330 + i * 430, 660)
		add_child(node)
		_stage_nodes.append(node)
	# 第三排：变体 3 棵
	for i: int in 3:
		var node: PreviewNode = PreviewNode.new()
		node.display_scale = 0.55
		node.display_origin = Vector2(400 + i * 560, 1420)
		add_child(node)
		_variant_nodes.append(node)
	_record_default_layout()


func _all_previews() -> Array:
	var all: Array = [_main_node]
	all.append_array(_stage_nodes)
	all.append_array(_variant_nodes)
	return all


func _record_default_layout() -> void:
	_default_origins.clear()
	for node: PreviewNode in _all_previews():
		_default_origins.append(node.display_origin)


func _reset_layout() -> void:
	for i: int in _all_previews().size():
		(_all_previews()[i] as PreviewNode).display_origin = _default_origins[i]
		(_all_previews()[i] as PreviewNode).queue_redraw()


func _copy_params() -> void:
	DisplayServer.clipboard_set(JSON.stringify(_params))
	_status_label.text = "参数已复制到剪贴板"


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_cam.zoom = (_cam.zoom * 1.12).clampf(0.12, 1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_cam.zoom = (_cam.zoom / 1.12).clampf(0.12, 1.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				var wp := get_global_mouse_position()
				for node: PreviewNode in _all_previews():
					if _hit_tree(node, wp):
						_drag_node = node
						_drag_off = node.display_origin - wp
						break
			else:
				_drag_node = null
	elif event is InputEventMouseMotion and _drag_node != null:
		_drag_node.display_origin = get_global_mouse_position() + _drag_off
		_drag_node.queue_redraw()


## 命中测试：点在树贴图矩形内（锚点=中轴×地面线）
func _hit_tree(node: PreviewNode, wp: Vector2) -> bool:
	var w := float(TP.W) * node.display_scale
	var h := float(TP.H) * node.display_scale
	var top_left := node.display_origin - Vector2(w * 0.5, 660.0 * node.display_scale)
	return Rect2(top_left, Vector2(w, h)).has_point(wp)


func _exit_tree() -> void:
	if _worker != null and _worker.is_started():
		_worker.wait_to_finish()


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
		if _debounce >= 0.3:
			_dirty = false
			_debounce = 0.0
			_enqueue_main()
	else:
		_debounce = 0.0
	_poll_worker()


## ─────────────── 后台任务队列（单线程串行；主任务入队时清掉排队的旧任务） ───────────────

func _enqueue_main() -> void:
	_main_version += 1
	for j: int in range(_queue.size() - 1, -1, -1):
		if String(_queue[j]["kind"]) != "bake":
			_queue.remove_at(j)  # 丢掉排队中的旧参数任务，烘焙任务保留
	_queue.append({"seed": MAIN_SEED, "kind": "main", "idx": _main_version})
	for i: int in _variant_nodes.size():
		_queue.append({"seed": _variant_base + i * 100, "kind": "variant", "idx": i})


## 变体排换 3 个新种子（不动主预览参数）
func _next_variants() -> void:
	_variant_base += 300
	for j: int in range(_queue.size() - 1, -1, -1):
		if String(_queue[j]["kind"]) == "variant":
			_queue.remove_at(j)
	for i: int in _variant_nodes.size():
		_queue.append({"seed": _variant_base + i * 100, "kind": "variant", "idx": i})


func _bake_pool() -> void:
	if _baking:
		_status_label.text = "烘焙已在进行…"
		return
	_baking = true
	_bake_done = 0
	_status_label.text = "烘焙中… 0/%d" % BAKE_COUNT
	for i: int in BAKE_COUNT:
		_queue.append({"seed": 8000 + i * 13, "kind": "bake", "idx": i})


func _poll_worker() -> void:
	if _worker_busy:
		if _worker.is_alive():
			return
		# 线程刚结束：取结果
		var result: Dictionary = _worker.wait_to_finish()
		_worker_busy = false
		var kind := String(result["kind"])
		if kind == "main" and int(result["ver"]) == _main_version:
			var tree: Dictionary = result["tree"]
			var tex := ImageTexture.create_from_image(result["img"])
			_main_node.setup_tex(tex, _main_node.display_origin, _main_node.display_scale)
			var imgs: Array = result["stage_imgs"]
			imgs.append(result["img"])  # ④最终 = 主成品图
			_refresh_stage_row(tree, imgs)
		elif kind == "variant" and int(result["idx"]) < _variant_nodes.size():
			var node: PreviewNode = _variant_nodes[int(result["idx"])]
			var tex2 := ImageTexture.create_from_image(result["img"])
			node.setup_tex(tex2, node.display_origin, node.display_scale)
		elif kind == "bake":
			_bake_done += 1
			_status_label.text = "烘焙中… %d/%d" % [_bake_done, BAKE_COUNT]
			if _bake_done >= BAKE_COUNT:
				_baking = false
				_status_label.text = "烘焙完成 %d 棵（重开场景生效）" % BAKE_COUNT
		# 继续取下一个任务
	if _worker_busy or _queue.is_empty():
		return
	var job: Dictionary = _queue.pop_front()
	if String(job["kind"]) == "main" and int(job["idx"]) != _main_version:
		return  # 过期主任务
	var params := _params.duplicate()
	var trunk_n := int(float(params["trunk_n"]))
	var crown_n := int(float(params["crown_n"]))
	var w_scale := float(params["w_scale"])
	var seed: int = job["seed"]
	var kind2 := String(job["kind"])
	var ver := _main_version
	var idx := int(job["idx"])
	_worker = Thread.new()
	_worker_busy = true
	_worker.start(func() -> Dictionary:
		var tree := TP.build_tree(seed, params, trunk_n, crown_n, w_scale, 1.0)
		var img := TP.rasterize(tree["pens"], tree["trunk_canvas"], tree["crown_canvas"])
		if kind2 == "bake":
			img.save_png("res://assets/resources/tree_paint_tree_v%d.png" % idx)
			return {"kind": kind2, "ver": ver, "idx": idx, "tree": tree, "img": img}
		# 主/变体任务：顺带栅格化管线阶段②(干)③(+枝)；④=最终复用 img
		var n_trunk := 0
		var n_branch := 0
		for pen: Dictionary in tree["pens"]:
			var g := int(pen["g"])
			if g == 0:
				n_trunk += 1
			elif g == 1:
				n_branch += 1
		var stage_imgs: Array = []
		if kind2 == "main":
			var pens: Array = tree["pens"]
			stage_imgs.append(TP.rasterize(pens.slice(0, n_trunk),
				tree["trunk_canvas"], tree["crown_canvas"]))
			stage_imgs.append(TP.rasterize(pens.slice(0, n_trunk + n_branch),
				tree["trunk_canvas"], tree["crown_canvas"]))
		return {"kind": kind2, "ver": ver, "idx": idx, "tree": tree, "img": img,
			"stage_imgs": stage_imgs})


func _refresh_stage_row(tree: Dictionary, stage_imgs: Array) -> void:
	# ①结构线框（draw 直绘）②③④=真实栅格化中间产物贴图（与成品同视觉）
	var stages := [
		["① 结构线框", true, null],
		["② + 干笔触", false, stage_imgs[0]],
		["③ + 枝直绘", false, stage_imgs[1]],
		["④ + 冠笔触 = 最终", false, stage_imgs[2]],
	]
	for i: int in stages.size():
		var node: PreviewNode = _stage_nodes[i]
		node.label = String(stages[i][0])
		if bool(stages[i][1]):
			node.setup_wire(tree["wire"], node.display_origin, node.display_scale)
		else:
			var stex := ImageTexture.create_from_image(stages[i][2])
			node.setup_tex(stex, node.display_origin, node.display_scale)
