class_name GenerativeBackdrop
extends Control
## 生成艺术模态背景 —— 全屏遮罩 + 均匀排布的旋转圆润立方体 + 鼠标排斥 + 光标范围光效。
##
## 前端常见的那种「背景生成艺术」：立方体网格均匀排布、各自随机旋转；鼠标靠近被排斥开，
## 鼠标周围带一圈柔和光晕。Godot 侧用单个 _draw 自绘实现（一次绘制全部，不建节点树，
## 60fps 下 60+ 个立方体 + 光晕约百次 draw 调用，仅模态打开时运行）。
##
## 用法：作为模态遮罩使用（StickScreen._bg / StickConfirmDialog._dim），全屏铺满；
## 自身消费鼠标（STOP + 吞掉事件，防穿透相机）。

# ─────────────────────────────── 视觉参数 ────────────────────────────────

## 立方体基础尺寸
const CUBE_SIZE: float = 30.0
## 网格间距（均匀排布）
const GRID_SPACING: float = 64.0
## 网格随机抖动幅度（避免死板对齐）
const JITTER: float = 8.0
## 鼠标排斥半径（px）
const REPULSION_RADIUS: float = 250.0
## 排斥最大位移（px）
const REPULSION_STRENGTH: float = 52.0
## 光标光晕半径（px）——柔和径向渐变，非同心圈
const GLOW_RADIUS: float = 120.0
## 光晕呼吸脉动幅度（alpha 上下摆）
const GLOW_PULSE: float = 0.06

## 遮罩压暗色（背景变暗部分，立方体叠加其上）
var dim_color: Color = Color(0.02, 0.03, 0.06, 0.5)
## 动画总开关（外部可关，如低配/测试）
var animated: bool = true

# ─────────────────────────────── 内部状态 ────────────────────────────────

var _time: float = 0.0
var _mouse: Vector2 = Vector2(-99999, -99999)
var _mouse_valid: bool = false
## 模拟鼠标（截图/演示用；非零才覆盖真实鼠标）
var _simulated_mouse: Vector2 = Vector2(-99999, -99999)
var _cubes: Array[Dictionary] = []
var _grid_key := Vector2i.ZERO


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(func(_event: InputEvent): get_viewport().set_input_as_handled())


func _process(delta: float) -> void:
	if not visible:
		return
	_time += delta
	var vp := get_viewport()
	var raw: Vector2 = _simulated_mouse if _simulated_mouse.x >= -1000.0 else (vp.get_mouse_position() if vp else Vector2.ZERO)
	_mouse = raw
	_mouse_valid = raw.x >= 0.0 and raw.y >= 0.0
	if size != Vector2.ZERO:
		_rebuild_grid_if_needed()
	queue_redraw()


## 设置模拟鼠标位置（演示/截图用；传极小值恢复真实鼠标）
func set_simulated_mouse(pos: Vector2) -> void:
	_simulated_mouse = pos


## 手动取鼠标位置（供外部读，如生成艺术交互）
func get_cursor_pos() -> Vector2:
	return _mouse


# ─────────────────────────────── 网格构建 ────────────────────────────────

func _rebuild_grid_if_needed() -> void:
	var cols: int = maxi(1, int(ceil(size.x / GRID_SPACING)))
	var rows: int = maxi(1, int(ceil(size.y / GRID_SPACING)))
	var key := Vector2i(cols, rows)
	if key == _grid_key and not _cubes.is_empty():
		return
	_grid_key = key
	_cubes.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260818
	for iy in range(rows):
		for ix in range(cols):
			var sz: float = CUBE_SIZE * rng.randf_range(0.7, 1.28)
			_cubes.append({
				"pos": Vector2(
						(float(ix) + 0.5) * GRID_SPACING + rng.randf_range(-JITTER, JITTER),
						(float(iy) + 0.5) * GRID_SPACING + rng.randf_range(-JITTER, JITTER)),
				"size": sz,
				"radius": sz * 0.24,
				"phase": rng.randf_range(0.0, TAU),
				"speed": rng.randf_range(-0.9, 1.1),
				"bob_phase": rng.randf_range(0.0, TAU),
				"bob_amp": rng.randf_range(0.0, 5.0),
			})


# ─────────────────────────────── 绘制 ────────────────────────────────

func _draw() -> void:
	# 1. 遮罩压暗
	draw_rect(Rect2(Vector2.ZERO, size), dim_color)
	# 2. 立方体网格（排斥 + 旋转 + 轻微浮动）
	for c in _cubes:
		var base: Vector2 = c["pos"]
		var push := _repulsion(base)
		var bob := Vector2(0.0, sin(_time * 1.1 + c["bob_phase"]) * c["bob_amp"])
		var ang: float = c["phase"] + _time * c["speed"]
		_draw_cube(base + push + bob, c["size"], c["radius"], ang)
	# 3. 光标范围光效
	if _mouse_valid:
		_draw_glow(_mouse)


## 鼠标排斥：半径内平滑推开（平方衰减）
func _repulsion(base: Vector2) -> Vector2:
	if not _mouse_valid:
		return Vector2.ZERO
	var to_mouse: Vector2 = _mouse - base
	var dist: float = to_mouse.length()
	if dist <= 0.001:
		return Vector2.ZERO
	var falloff: float = 1.0 - clampf(dist / REPULSION_RADIUS, 0.0, 1.0)
	falloff = falloff * falloff
	return -to_mouse / dist * REPULSION_STRENGTH * falloff


## 画一个旋转的圆润立方体（主体 + 更亮的顶面，旋转跟随整体）
func _draw_cube(center: Vector2, sz: float, radius: float, angle: float) -> void:
	draw_set_transform(center, angle, Vector2.ONE)
	# 主体（磨砂白，低透明）
	var body := Rect2(-sz * 0.5, -sz * 0.5, sz, sz)
	_rounded_rect(body, radius, Color(1.0, 1.0, 1.0, 0.09))
	# 顶面（更亮、更小、左上偏移）→ 立方体感
	var top := Rect2(-sz * 0.72, -sz * 0.72, sz * 0.72, sz * 0.72)
	_rounded_rect(top, radius * 0.7, Color(1.0, 1.0, 1.0, 0.17))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 圆角矩形（draw_style_box 复用同一 StyleBox，仅改颜色）
var _sb_cache: StyleBoxFlat = null

func _rounded_rect(rect: Rect2, radius: float, color: Color) -> void:
	if _sb_cache == null:
		_sb_cache = StyleBoxFlat.new()
	_sb_cache.bg_color = color
	_sb_cache.corner_radius_top_left = int(radius)
	_sb_cache.corner_radius_top_right = int(radius)
	_sb_cache.corner_radius_bottom_left = int(radius)
	_sb_cache.corner_radius_bottom_right = int(radius)
	_sb_cache.border_width_left = 0
	_sb_cache.border_width_top = 0
	_sb_cache.border_width_right = 0
	_sb_cache.border_width_bottom = 0
	draw_style_box(_sb_cache, rect)


## 光标光效：径向渐变贴图一张画完（无同心圈/无跳变），随时间缓慢呼吸脉动
var _glow_tex: GradientTexture2D = null

func _draw_glow(pos: Vector2) -> void:
	if _glow_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1.0, 0.93, 0.78, 0.32))
		g.set_color(1, Color(1.0, 0.93, 0.78, 0.0))
		_glow_tex = GradientTexture2D.new()
		_glow_tex.gradient = g
		_glow_tex.fill = GradientTexture2D.FILL_RADIAL
		_glow_tex.fill_from = Vector2(0.5, 0.5)
		_glow_tex.fill_to = Vector2(1.0, 0.5)
		_glow_tex.width = 128
		_glow_tex.height = 128
	var breath: float = 1.0 + sin(_time * 1.6) * GLOW_PULSE
	var r: float = GLOW_RADIUS
	draw_texture_rect(_glow_tex, Rect2(pos - Vector2(r, r), Vector2(r * 2.0, r * 2.0)), false, Color(1.0, 1.0, 1.0, breath))
