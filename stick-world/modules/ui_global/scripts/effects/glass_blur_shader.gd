class_name GlassBlurShader
extends RefCounted
## 磨砂玻璃模糊 shader 工厂 —— 模态背景用的全屏模糊 + 压暗。
##
## 原理：采样 screen_texture（模态层底下 = 游戏画面），做 5x5 高斯模糊，
## 再乘 dim 压暗色 → 背景变成"毛玻璃"；面板/按钮都是真透明玻璃，
## 玻璃感全部来自这一层模糊 + 自身边缘高光。
## 单 pass 16 tap（9 距离档），60fps 无压力；仅模态打开时绘制。

static func create() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = _shader()
	return mat


## 设置压暗色（在 dim_color 变化时调用）
static func apply_dim(mat: ShaderMaterial, dim: Color) -> void:
	if mat:
		mat.set_shader_parameter("dim_color", dim)


## 设置屏幕尺寸（模糊半径按真实分辨率计算；在可见时同步）
static func apply_screen_size(mat: ShaderMaterial, screen: Vector2) -> void:
	if mat:
		mat.set_shader_parameter("screen_size", screen)


static var _shader_cache: Shader = null

static func _shader() -> Shader:
	if _shader_cache != null:
		return _shader_cache
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

uniform vec4 dim_color : source_color = vec4(0.02, 0.03, 0.06, 0.5);
uniform float blur_strength : hint_range(0.0, 16.0) = 3.5;
uniform vec2 screen_size = vec2(1920.0, 1080.0);
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

// 5x5 高斯权重（中心列/行），9 个距离档
const float W_C = 0.227027;
const float W_1 = 0.1945946;
const float W_2 = 0.1216216;
const float W_3 = 0.0540540;
const float W_4 = 0.0162162;

void fragment() {
	vec2 uv = UV;
	vec2 texel = (1.0 / max(screen_size, vec2(1.0))) * blur_strength;
	vec3 sum = texture(SCREEN_TEXTURE, uv).rgb * W_C;
	float wsum = W_C;
	// 两轴各 4 档距离（9-tap 等效的 5x5 方形核）
	for (int i = 1; i <= 4; i++) {
		float w = (i == 1) ? W_1 : (i == 2) ? W_2 : (i == 3) ? W_3 : W_4;
		vec2 off = texel * float(i);
		sum += texture(SCREEN_TEXTURE, clamp(uv + vec2(off.x, 0.0), vec2(0.0), vec2(1.0))).rgb * w;
		sum += texture(SCREEN_TEXTURE, clamp(uv - vec2(off.x, 0.0), vec2(0.0), vec2(1.0))).rgb * w;
		sum += texture(SCREEN_TEXTURE, clamp(uv + vec2(0.0, off.y), vec2(0.0), vec2(1.0))).rgb * w;
		sum += texture(SCREEN_TEXTURE, clamp(uv - vec2(0.0, off.y), vec2(0.0), vec2(1.0))).rgb * w;
		wsum += w * 4.0;
	}
	vec3 blurred = sum / wsum;
	// 压暗 + 略微降低饱和（毛玻璃观感）
	vec3 c = blurred * dim_color.rgb;
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(vec3(lum), c, 0.92);
	COLOR = vec4(c, dim_color.a);
}
"""
	_shader_cache = shader
	return shader
