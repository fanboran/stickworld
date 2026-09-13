shader_type spatial;
// ground.gdshader —— 可行走地面 / 门前场地的地面材质
//
// 为什么不用 StandardMaterial3D：地面是云影最大的承影面，必须能吃**按世界坐标采样的
// 共享噪声**（见 cloud_noise.gdshaderinc）；内置材质插不进这段逻辑，所以地面统一走
// 本 shader。除云影外，参数与原 StandardMaterial3D 一一对应（贴图 + 平铺 + 着色 +
// 粗糙度），保证换材质不改变地面本来的明暗与肌理。
//
// 平铺：PlaneMesh 的 UV 是 0..1，平铺倍数由 uv_scale 给（= 面尺寸 / 贴图世界尺寸），
// 与原 `uv1_scale` 同义。
//
// 贴图：**直接消费烘焙好的分段资产**（temp/ground_tiles 的 seg_* / gtx_* / band_*），
// 不做任何程序化着色 —— `tint` 一律给白，地面颜色就是资产自己的颜色。
// `mix_tex/mix_amount` 只做**两段贴图的线性叠加**（区带软混；创始人明确禁止程序噪声
// 渐变，所以这里不引入任何噪声，纯线性）。
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// 云影（全场共享的 global shader parameter）
global uniform vec4 cloud_shadow;
#include "res://tests/dev/proto_hd2d/cloud_noise.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap;
uniform sampler2D mix_tex : source_color, filter_linear_mipmap;
uniform float mix_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 tint : source_color = vec4(1.0);
uniform float rough : hint_range(0.0, 1.0) = 0.95;
uniform vec2 uv_scale = vec2(1.0, 1.0);

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 uv = UV * uv_scale;
	vec3 base = texture(albedo_tex, uv).rgb;
	if (mix_amount > 0.0) {
		base = mix(base, texture(mix_tex, uv).rgb, mix_amount);
	}
	ALBEDO = base * tint.rgb * (1.0 - cloud_shadow_at(wp.xz));
	ROUGHNESS = rough;
	SPECULAR = 0.08;
}
