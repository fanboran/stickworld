class_name PostProcessLayer
extends CanvasLayer
## 全屏后处理层 —— "精品小游戏"质感渲染（Demo P3）。
##
## 六层后处理一次采样完成（见 post_process.gdshader）：暖色分级 / 顶部天光 /
## 太阳炫光(glow+streak+ghost) / 渐晕 / 边缘色差 / 胶片颗粒。
##
## 摆放：layer = 0.5 —— 压在游戏世界（默认画布）之上、UIROOT（layer=1）之下，
## UI 永不受后处理污染。由 SystemSetup 装配，bind_env 注入环境系统做昼夜联动
## （夜晚太阳炫光与天光淡出，白天恢复）。

const PostShader: Shader = preload("res://modules/environment/shaders/post_process.gdshader")

var _rect: ColorRect = null
var _mat: ShaderMaterial = null
var _env_system: Node = null
var _time_acc: float = 0.0


func _ready() -> void:
	layer = 0.5
	_rect = ColorRect.new()
	_rect.name = "PostProcessRect"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = PostShader
	_rect.material = _mat
	add_child(_rect)


## 注入环境系统（昼夜联动数据源）；null 时炫光恒定白天强度
func bind_env(env_system: Node) -> void:
	_env_system = env_system


func _process(delta: float) -> void:
	_time_acc += delta
	_mat.set_shader_parameter("time_seed", _time_acc)
	if _env_system == null or not _env_system.has_method("get_current_light_color"):
		return
	# 环境亮度（CanvasModulate luminance）：白天≈1，夜晚被压暗
	var lum: float = _env_system.get_current_light_color().get_luminance()
	var day_t: float = clampf((lum - 0.55) / 0.35, 0.0, 1.0)
	_mat.set_shader_parameter("flare_intensity", 0.22 + 0.78 * day_t)
	_mat.set_shader_parameter("top_light", 0.05 + 0.09 * day_t)
	# 夜晚整体冷暗，颗粒稍增（胶片夜戏感）
	_mat.set_shader_parameter("warm_tint", Vector3(1.045 - 0.05 * (1.0 - day_t), 1.0, 0.945 + 0.07 * (1.0 - day_t)))
	_mat.set_shader_parameter("grain_strength", 0.045 + 0.02 * (1.0 - day_t))
