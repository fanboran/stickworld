class_name GenerativeBackdrop
extends Control
## 生成艺术模态背景 —— 全屏模糊磨砂压暗 + 均匀排布的旋转几何体（方形/三角形/五边形）+ 鼠标排斥 + 光标范围光效。
##
## 设计（2026-08 磨砂玻璃迭代）：
##   - 背景玻璃感来自 GlassBlurShader：把模态底下的游戏画面整体模糊 + 压暗（真透明磨砂，
##     面板/按钮不再盖白/黑色）。
##   - 几何体：方形/三角形/五边形混合（各带更亮的上缘面做 3D 挤出感），网格均匀排布 + 随机抖动，
##     各自缓慢旋转；整体以极慢速度沿 4 个对角方向之一漂移（每次打开随机一个方向）。
##   - 鼠标靠近被排斥开；鼠标周围一圈从内到外淡出的柔和光晕（呼吸脉动）。
## Godot 侧单节点自绘（不建节点树），模态打开时运行。
##
## 用法：作为模态遮罩使用（StickScreen._bg / StickConfirmDialog._dim），全屏铺满；
## 自身消费鼠标（STOP + 吞掉事件，防穿透相机）。

# ─────────────────────────────── 视觉参数 ────────────────────────────────

## 几何体基础尺寸
const SHAPE_SIZE: float = 30.0
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
## 整体漂移速度（px/s，极慢）
const DRIFT_SPEED: float = 6.0
## 4 个对角方向（45°）——常量表达式不能用函数调用，放 var 里初始化
var DRIFT_DIRS: Array[Vector2] = [
	Vector2(1, 1).normalized(),   # ↗
	Vector2(1, -1).normalized(),  # ↘
	Vector2(-1, 1).normalized(),  # ↖
	Vector2(-1, -1).normalized(), # ↙
]

## 遮罩压暗色（背景变暗部分，几何体叠加其上）
var dim_color: Color = Color(0.02, 0.03, 0.06, 0.5)
## 动画总开关（外部可关，如低配/测试）
var animated: bool = true

# ─────────────────────────────── 内部状态 ────────────────────────────────

var _time: float = 0.0
var _mouse: Vector2 = Vector2(-99999, -99999)
var _mouse_valid: bool = false
## 模拟鼠标（截图/演示用；非零才覆盖真实鼠标）
var _simulated_mouse: Vector2 = Vector2(-99999, -99999)
var _shapes: Array[Dictionary] = []
var _grid_key := Vector2i.ZERO
## 漂移方向（每次打开随机）
var _drift: Vector2 = Vector2(1, 1).normalized()
## 模糊压暗层（ColorRect + GlassBlurShader）
var _dim_layer: ColorRect = null

const _GlassBlurShaderScript: GDScript = preload("res://modules/ui_global/scripts/effects/glass_blur_shader.gd")


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(func(_event: InputEvent): get_viewport().set_input_as_handled())
	# 模糊压暗层：真透明磨砂（模糊底下游戏画面 + 压暗），几何体画在它上面
	_dim_layer = ColorRect.new()
	_dim_layer.name = "GlassDim"
	_dim_layer.material = _GlassBlurShaderScript.create()
	_GlassBlurShaderScript.apply_dim(_dim_layer.material, dim_color)
	_dim_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dim_layer)
	_randomize_drift()
	# 每帧同步 dim 色 / 屏幕尺寸（外部可能改 bg_alpha；窗口尺寸变化时刷新）
	_GlassBlurShaderScript.apply_dim(_dim_layer.material, dim_color)
	if get_viewport() != null:
		_GlassBlurShaderScript.apply_screen_size(_dim_layer.material, get_viewport().get_visible_rect().size)


func _notification(what: int) -> void:
	# 每次变成可见 → 随机一个新漂移方向（打开即换方向）
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible:
		_randomize_drift()
		# 修复：隐藏期间 queue_redraw 会丢失，变可见后画布不重绘（形状静默消失）。
		# 可见性变化时显式重绘一次，保证 _draw 的内容真正进画面。
		queue_redraw()


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
	if _dim_layer != null and get_viewport() != null:
		_GlassBlurShaderScript.apply_screen_size(_dim_layer.material, get_viewport().get_visible_rect().size)
	queue_redraw()


## 设置模拟鼠标位置（演示/截图用；传极小值恢复真实鼠标）
func set_simulated_mouse(pos: Vector2) -> void:
	_simulated_mouse = pos


## 手动取鼠标位置（供外部读，如生成艺术交互）
func get_cursor_pos() -> Vector2:
	return _mouse


## 强制重选漂移方向（外部可调，如测试）
func randomize_drift() -> void:
	_randomize_drift()


func _randomize_drift() -> void:
	_drift = DRIFT_DIRS[randi() % DRIFT_DIRS.size()]


# ─────────────────────────────── 网格构建 ────────────────────────────────

func _rebuild_grid_if_needed() -> void:
	var cols: int = maxi(1, int(ceil(size.x / GRID_SPACING)))
	var rows: int = maxi(1, int(ceil(size.y / GRID_SPACING)))
	var key := Vector2i(cols, rows)
	if key == _grid_key and not _shapes.is_empty():
		return
	_grid_key = key
	_shapes.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260818
	for iy in range(rows):
		for ix in range(cols):
			var sz: float = SHAPE_SIZE * rng.randf_range(0.7, 1.28)
			_shapes.append({
				"pos": Vector2(
						(float(ix) + 0.5) * GRID_SPACING + rng.randf_range(-JITTER, JITTER),
						(float(iy) + 0.5) * GRID_SPACING + rng.randf_range(-JITTER, JITTER)),
				"size": sz,
				"radius": sz * 0.24,
				# 形状种类：0=方形 1=三角形 2=五边形（约 1/3 各一）
				"kind": rng.randi() % 3,
				"phase": rng.randf_range(0.0, TAU),
				"speed": rng.randf_range(-0.9, 1.1),
				"bob_phase": rng.randf_range(0.0, TAU),
				"bob_amp": rng.randf_range(0.0, 4.0),
			})


# ─────────────────────────────── 绘制 ────────────────────────────────

func _draw() -> void:
	# 1. 模糊压暗由 _dim_layer 的 shader 完成（真透明磨砂），这里只画几何体
	# 2. 几何体网格（整体漂移 + 鼠标排斥 + 旋转 + 轻微浮动）
	for s in _shapes:
		var base: Vector2 = s["pos"] + _drift_pos()
		var push := _repulsion(base)
		var bob := Vector2(0.0, sin(_time * 1.1 + s["bob_phase"]) * s["bob_amp"])
		var ang: float = s["phase"] + _time * s["speed"]
		_draw_shape(base + push + bob, s["size"], s["radius"], ang, s["kind"])
	# 3. 光标范围光效
	if _mouse_valid:
		_draw_glow(_mouse)


## 整体漂移位移（带屏幕环绕——极慢匀速斜向移动）
func _drift_pos() -> Vector2:
	var move: Vector2 = _drift * DRIFT_SPEED * _time
	if size.x > 0.0 and size.y > 0.0:
		var span: Vector2 = size + Vector2(SHAPE_SIZE, SHAPE_SIZE)
		move.x = wrapf(move.x, 0.0, span.x)
		move.y = wrapf(move.y, 0.0, span.y)
	return move


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


## 画一个旋转的圆润几何体（主体 + 更亮的上缘面，旋转跟随整体）
func _draw_shape(center: Vector2, sz: float, radius: float, angle: float, kind: int) -> void:
	draw_set_transform(center, angle, Vector2.ONE)
	# 主体（磨砂白，低透明——真玻璃不盖底色，靠边缘亮面）
	var body := Rect2(-sz * 0.5, -sz * 0.5, sz, sz)
	_draw_poly(body, radius, kind, Color(1.0, 1.0, 1.0, 0.3))
	# 上缘面（更亮、更小、左上偏移）→ 3D 挤出感
	var top := Rect2(-sz * 0.68, -sz * 0.68, sz * 0.68, sz * 0.68)
	_draw_poly(top, maxf(1.0, radius * 0.7), kind, Color(1.0, 1.0, 1.0, 0.55))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## 圆角多边形：按 kind 取预生成顶点（单位空间），缩放 + 位移到 rect
func _draw_poly(rect: Rect2, radius: float, kind: int, color: Color) -> void:
	var verts: PackedVector2Array = _polygon_for(kind, radius)
	var scaled := PackedVector2Array()
	for v in verts:
		scaled.append(rect.position + v * rect.size)
	draw_colored_polygon(scaled, color)


# ─────────────────────────────── 形状顶点（单位空间，圆角）────────────────────────────────

## 单位矩形顶点（居中）
const UNIT_SQUARE: Array = [
	Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5),
]

## 单位正三角形顶点（居中，顶点朝上）
const UNIT_TRI: Array = [
	Vector2(0.0, -0.55), Vector2(0.5, 0.45), Vector2(-0.5, 0.45),
]

## 单位正五边形顶点（居中）
const UNIT_PENT: Array = [
	Vector2(0.0, -0.55), Vector2(0.52, -0.17), Vector2(0.32, 0.45),
	Vector2(-0.32, 0.45), Vector2(-0.52, -0.17),
]

## 圆角弧段数（每角）——顶点数可控，一次绘制全部形状
const CORNER_SEGS: int = 10

var _poly_cache: Dictionary = {}

## 生成/取指定 kind + radius 的圆角多边形顶点（rect 单位空间）
## 做法（稳健版）：沿每条边的两个切点插值，再用 draw_colored_polygon 自带三角化。
## 每个角（顶点 a）两侧切点 = a ± r·(单位方向)；角部由"入边切点→出边切点"的直线连接
##（非弧线但视觉上仍是圆角多边形，凸多边形三角化必然成功）。
func _polygon_for(kind: int, radius: float) -> PackedVector2Array:
	var key := Vector2i(kind, int(radius * 4.0))
	if _poly_cache.has(key):
		return _poly_cache[key]
	var pts: Array = [UNIT_SQUARE, UNIT_TRI, UNIT_PENT][kind]
	var n: int = pts.size()
	var r: float = radius
	for i in range(n):
		var e: float = pts[i].distance_to(pts[(i + 1) % n])
		r = minf(r, e * 0.4)
	var out := PackedVector2Array()
	# 每个角生成一段小弧（绕顶点 a，从入边方向扫到出边方向）
	for i in range(n):
		var a: Vector2 = pts[i]
		var prev: Vector2 = pts[(i - 1 + n) % n]
		var b: Vector2 = pts[(i + 1) % n]
		var in_dir: Vector2 = (a - prev).normalized()
		var out_dir: Vector2 = (b - a).normalized()
		var in_ang: float = atan2(in_dir.y, in_dir.x)
		var out_ang: float = atan2(out_dir.y, out_dir.x)
		# 外角（凸多边形 < 180°）：从入边方向绕到出边方向
		var sweep: float = angle_to_positive(out_ang - in_ang)
		if sweep > PI:
			sweep -= TAU
		for k in range(CORNER_SEGS):
			var t: float = float(k) / float(CORNER_SEGS - 1)
			var ang: float = in_ang + sweep * t
			out.append(a + Vector2(cos(ang), sin(ang)) * r)
	_poly_cache[key] = out
	return out


## 把角度差归一到 [0, TAU)
func angle_to_positive(a: float) -> float:
	var x := fmod(a, TAU)
	if x < 0.0:
		x += TAU
	return x


# ─────────────────────────────── 光标光效 ────────────────────────────────

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
