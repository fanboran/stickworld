// cloud_noise.gdshaderinc —— 云影遮罩（全场共享，按**世界坐标**采样）
//
// 【怎么用】每个要吃云影的自制 shader 三行：
//     global uniform vec4 cloud_shadow;    // xy = 世界偏移(格)  z = 强度  w = 尺度
//     #include "res://tests/dev/proto_hd2d/cloud_noise.gdshaderinc"
//     ALBEDO *= 1.0 - cloud_shadow_at(world_pos.xz);
//
// 【为什么按世界坐标采样】地面、建筑卡、道具卡、角色 billboard、背景层各是独立
//   网格（很多还各自面向相机），但它们面对的是同一片天空。把遮罩定义在**世界 XZ**
//   上，所有材质就自动落在同一团云底下 —— 这是 HD-2D 里"2D 角色与 3D 场景同处
//   一景"的关键一环，也让"2D 角色不吃场景光"的落差补上一块。
//
// 【形状纪律】只取多倍频 value noise 的**高段** + 宽 smoothstep：成片、边缘极软。
//   禁止用 sin 条纹做图案（会读作扫描线/脏污），所以整套图案只有 value noise 一族。
//
// 【无缝循环】晶格索引先折回 [0,32)（**必须用正模**：负数下取模会给出负索引，
//   hash 落进异常区间、fbm 均值塌掉，云就"没有"了），hash 因此对 32 晶格周期。
//   三个倍频以 0.5x/1x/2x 采样，偏移要同时是 64/32/16 晶格的整数倍才全体重合
//   → 最小正周期 = 64 晶格；换算到世界坐标就是"世界偏移推进 64/尺度 格后图案
//   完全重合"（尺度 0.24 → 267 格；按 0.7 格/秒漂移是 381 秒一轮，肉眼等不到重复）。
//
// 【强度口径】`cloud_shadow.z` 是**乘在 albedo 上的线性系数**（规格里的暗化幅度）。
//   屏上观感会缩水：sRGB 对亮部是凹函数，再加后处理，屏上暗化 ≈ (1-s)^0.42（实测）。
//   故 strength = 0.45 → 云心屏上暗化 ≈ 22%（规格 15~25%）；实测被盖住的场景均值
//   ~0.37、同一帧关云 ~0.48，整帧均值只从 0.469 压到 0.451（阳光高调不被破坏）。

float _cn_hash(vec2 p) {
	// 正模折回 [0,32) → 晶格索引周期 32 → 整套噪声可无缝平铺
	p = fract(p / 32.0) * 32.0;
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float _cn_vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(_cn_hash(i), _cn_hash(i + vec2(1.0, 0.0)), u.x),
		mix(_cn_hash(i + vec2(0.0, 1.0)), _cn_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// 多倍频 value noise（最多 4 层；返回 0..~0.875，均值 ≈0.435、标准差 ≈0.12）
float cn_fbm(vec2 p, int oct) {
	float n = 0.0;
	float amp = 0.5;
	float f = 0.5;
	for (int i = 0; i < 4; i++) {
		if (i >= oct) {
			break;
		}
		n += amp * _cn_vnoise(p * f);
		amp *= 0.5;
		f *= 2.0;
	}
	return n;
}

// 云影系数 0..1：1 = 云最厚。strength = 0 时恒为 0（可整体关掉做 A/B 对照）。
//
// 阈值窗 0.42..0.62（宽 0.20 ≈ 1.7 个标准差）：按 4M 点实测，世界 XZ 平面上约 51% 的
// 面积吃到 >5% 强度、约 9% 接近满强度 —— 读作"几团大片云影 + 大片留白"，而且窗宽
// 足够宽，边缘是渐变不是硬块。（画幅里还有不吃云影的天空，故屏上被压暗的面积更小：
// 约 24% 的像素暗化 >3%、13% 暗化 >6%。）
float cloud_shadow_at(vec2 wxz) {
	if (cloud_shadow.z <= 0.0001) {
		return 0.0;
	}
	float n = cn_fbm((wxz + cloud_shadow.xy) * cloud_shadow.w, 3);
	return smoothstep(0.42, 0.62, n) * cloud_shadow.z;
}
