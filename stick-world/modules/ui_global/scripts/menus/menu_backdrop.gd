class_name MenuBackdrop
extends Control
## 菜单背景 —— 黄金时刻天空 + 暮色远/近山 + 手绘漂移云 + 飞鸟，
## 鼠标视差让画面"活"（主菜单审计整改的成果，见 docs/设计/UI/03-主菜单与流程.md §2.2）。
##
## 抽成独立控件的原因：主菜单与原声带页要同一片天空——两屏都是浮在同一个活着的
## 世界上的窗（§2.3「窗户不是海报」），各写一份会漂移成两套天空。
##
## 用法：`add_child(MenuBackdropScript.new())`，自己铺满父节点，不接收鼠标
## （不挡菜单点击）。挂在场景根的第一个子节点位置。

const SkyDecorMountains := "res://assets/sky/bg_mountain_far.png"
const SkyDecorMountainsNear := "res://assets/sky/bg_mountain_near.png"
const MenuBirdsScript: GDScript = preload("res://modules/ui_global/scripts/menus/menu_birds.gd")
const SketchCloudScript: GDScript = preload("res://modules/ui_global/scripts/sketch/sketch_cloud.gd")

## 远山暮色基调（蓝贴图×暖玫瑰=黄金时刻大气透视；视差呼吸围绕此色）
const MOUNTAIN_TINT := Color(0.82, 0.60, 0.56)
## 设计分辨率（canvas_items 拉伸下的逻辑坐标；云回绕与视差归一化都用它）
const DESIGN_SIZE := Vector2(1920.0, 1080.0)


func _ready() -> void:
	# ⚠ 必须 set_anchors**_and_offsets**_preset：只设锚点会把"当前矩形"（新建节点是
	# 0×0）原样保留成 offset_right/bottom = -父宽/-父高，控件永远是 0 尺寸，
	# 天空与山静默不画（踩过一次）
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_sky()
	_build_birds()
	_build_mountains()
	_build_clouds()


## 天空垂直渐变：暖金 → 琥珀玫瑰 → 暮尘 → 深暮蓝，色相连续不断链
func _build_sky() -> void:
	var sky := TextureRect.new()
	sky.name = "SkyGradient"
	sky.set_anchors_preset(Control.PRESET_FULL_RECT)
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sky.stretch_mode = TextureRect.STRETCH_SCALE
	var grad := Gradient.new()
	grad.set_color(0, Color(0.99, 0.82, 0.55))
	grad.set_color(1, Color(0.23, 0.20, 0.29))
	grad.add_point(0.42, Color(0.94, 0.67, 0.46))
	grad.add_point(0.72, Color(0.62, 0.44, 0.44))
	var gt := GradientTexture2D.new()
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.gradient = grad
	gt.width = 8
	gt.height = 512
	sky.texture = gt
	add_child(sky)
	_sky_rect = sky


## 远/近山两层（贴屏幕底）：远山暮色染调（消中饱和扁平蓝与暖天的撞色），
## 近山更暗更近叠出纵深；无贴图时静默跳过
func _build_mountains() -> void:
	if ResourceLoader.exists(SkyDecorMountains):
		var m := TextureRect.new()
		m.name = "Mountains"
		_mountains_rect = m
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		m.stretch_mode = TextureRect.STRETCH_TILE
		m.texture = load(SkyDecorMountains)
		m.anchor_left = 0.0
		m.anchor_right = 1.0
		m.anchor_top = 1.0
		m.anchor_bottom = 1.0
		m.offset_top = -300.0
		m.offset_bottom = 0.0
		m.modulate = MOUNTAIN_TINT
		add_child(m)
	if ResourceLoader.exists(SkyDecorMountainsNear):
		var mn := TextureRect.new()
		mn.name = "MountainsNear"
		_mountains_near_rect = mn
		mn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mn.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mn.stretch_mode = TextureRect.STRETCH_TILE
		mn.texture = load(SkyDecorMountainsNear)
		mn.anchor_left = 0.0
		mn.anchor_right = 1.0
		mn.anchor_top = 1.0
		mn.anchor_bottom = 1.0
		mn.offset_top = -170.0
		mn.offset_bottom = 0.0
		mn.modulate = Color(0.45, 0.36, 0.40)
		add_child(mn)


## 漂移云（手绘简笔画系三风格混排：毛线团/笔触/鼓包，与沸腾语言同源）
func _build_clouds() -> void:
	_cloud_rects = []
	_cloud_base_ys = []
	for i in 3:
		var c: Node2D = SketchCloudScript.new()
		c.set("style", [1, 2, 0][i % 3])
		c.set("cloud_size", Vector2(200.0, 83.0) * randf_range(0.85, 1.2))
		c.position = Vector2(randf_range(0.1, 0.7) * DESIGN_SIZE.x, randf_range(40.0, 300.0))
		c.modulate = Color(1, 1, 1, 0.85)
		add_child(c)
		_cloud_rects.append(c)
		_cloud_base_ys.append(c.position.y)


## 远空飞鸟（自绘剪影，与游戏内 sky_birds 同视觉语言）
func _build_birds() -> void:
	var birds: Node2D = MenuBirdsScript.new()
	birds.name = "MenuBirds"
	add_child(birds)


func _process(delta: float) -> void:
	# 云缓移（回绕宽度按 cloud_size）
	for i in _cloud_rects.size():
		var c: Node2D = _cloud_rects[i]
		c.position.x += (6.0 + 4.0 * i) * delta
		if c.position.x > DESIGN_SIZE.x:
			c.position.x = -float((c.get("cloud_size") as Vector2).x)
	# 鼠标视差（背景层按深度反向微移：菜单标配的"画面活着"）
	var mp := get_viewport().get_mouse_position()
	var target := Vector2(mp.x / DESIGN_SIZE.x - 0.5, mp.y / DESIGN_SIZE.y - 0.5)
	_mouse_norm = _mouse_norm.lerp(target, minf(1.0, 3.0 * delta))
	# 山层贴底 anchor 不被视差破坏：远山以暮色基调做轻微明暗呼吸暗示深度，
	# 近山只做 x 向微视差（直接改 position 会破坏贴底锚点，只动 x 分量）
	if _mountains_rect != null:
		_mountains_rect.modulate = MOUNTAIN_TINT.lerp(
				MOUNTAIN_TINT.lightened(0.06), (_mouse_norm.x + 0.5))
	if _mountains_near_rect != null:
		_mountains_near_rect.position.x = -_mouse_norm.x * 12.0
	if _sky_rect != null:
		_sky_rect.position = -_mouse_norm * 6.0
	for i in _cloud_rects.size():
		_cloud_rects[i].position.y = _cloud_base_ys[i] - _mouse_norm.y * (16.0 + 8.0 * i)


## 背景视差引用
var _sky_rect: Control = null
var _mountains_rect: TextureRect = null
var _mountains_near_rect: TextureRect = null
## 鼠标归一化位置（-0.5~0.5），用于背景层反向微移
var _mouse_norm: Vector2 = Vector2.ZERO
## 手绘漂移云（位置/基准高度）
var _cloud_rects: Array = []
var _cloud_base_ys: Array = []
