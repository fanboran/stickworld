class_name EnvironmentAPI
extends RefCounted
## Environment 模块公共接口契约
##
## 本模块提供跨场景保持的环境系统：
## - 天空底色（清屏色随时间变化）+ 光照（CanvasModulate 按时间插值）—— P0 阶段
## - 天空（极光、星星、太阳/月亮 — Shader）—— P1 阶段
## - 天气（雨/雪/沙尘暴 — GPU 粒子）—— P1 阶段
## - 地面震动 —— P1 阶段
## - 生物群落基调 —— P1 阶段
##
## 昼夜色彩体系（Terraria Main.SetBackColor 直译，2026-09-06）分两条独立轨道：
## - 天空底色（SKY_BG_KEYFRAMES → 清屏色）：天空本身，不被 CanvasModulate 染色，
##   夜黑/黄昏粉/昼白；
## - 环境光（LIGHT_KEYFRAMES → CanvasModulate）：染地表一切，夜晚压至剪影量级
##   （夜 35,35,35→5,5,5 + 月相 floor 11~19 的折中）。
## 星/月/极光等发光体画在默认画布会被压暗，经 unmodulate() 除法补偿穿透。

# ─────────────────────────────── 一天的时间（小时） ────────────────────────────────
const HOURS_PER_DAY: int = 24

# ─────────────────────────────── 光照关键帧 ────────────────────────────────
## 时间 [小时] -> CanvasModulate.color（环境光，染地表/角色/背景贴图）
## 夜晚段为 Terraria 量级：入夜 (35,35,35) 级 → 午夜 ≈月相 floor 中值 (14,14,19)
## → 黎明前 (25,35,35)；地表呈剪影，发光体经 unmodulate 补偿保持亮度。
const LIGHT_KEYFRAMES: Array = [
	{"hour": 0.0,  "color": Color(0.050, 0.055, 0.075, 1.0)},  # 午夜（月相 floor 中值 14/255，微蓝）
	{"hour": 5.0,  "color": Color(0.100, 0.135, 0.135, 1.0)},  # 黎明前（Terraria 25,35,35）
	{"hour": 7.0,  "color": Color(0.95, 0.92, 0.85, 1.0)},  # 早晨
	{"hour": 12.0, "color": Color(1.00, 1.00, 0.95, 1.0)},  # 正午
	{"hour": 17.0, "color": Color(0.95, 0.85, 0.75, 1.0)},  # 下午
	{"hour": 19.0, "color": Color(0.72, 0.52, 0.42, 1.0)},  # 黄昏
	{"hour": 21.0, "color": Color(0.140, 0.140, 0.165, 1.0)},  # 入夜（Terraria 35,35,35 级）
	{"hour": 24.0, "color": Color(0.050, 0.055, 0.075, 1.0)},  # 午夜
]

# ─────────────────────────────── 天空底色关键帧 ────────────────────────────────
## 时间 [小时] -> 清屏色（天空本身；由 EnvironmentSystem 每帧写入
## RenderingServer.set_default_clear_color，不经过 CanvasModulate）。
## Terraria Main.SetBackColor 的 bgColor 直译：夜 (35,35,35)→(5,5,5)+月相 floor
## →黎明前 (25,35,35)→白；午后白→日落粉峰 (235,120,170)→入夜灰黑。
## 时间轴对齐本项目太阳 5..21 时（Terraria 日出 4:30/日落 19:30 平移至此）。
const SKY_BG_KEYFRAMES: Array = [
	{"hour": 0.0,  "color": Color(0.055, 0.055, 0.070, 1.0)},  # 午夜最黑（≈14,14,18）
	{"hour": 4.5,  "color": Color(0.100, 0.137, 0.137, 1.0)},  # 黎明前（25,35,35）
	{"hour": 7.5,  "color": Color(1.00, 1.00, 1.00, 1.0)},  # 全白（Terraria 正午白）
	{"hour": 17.0, "color": Color(1.00, 1.00, 1.00, 1.0)},  # 全白
	{"hour": 19.0, "color": Color(0.92, 0.47, 0.67, 1.0)},  # 日落粉峰（235,120,170）
	{"hour": 21.0, "color": Color(0.140, 0.137, 0.150, 1.0)},  # 入夜灰黑（35,35,38）
	{"hour": 24.0, "color": Color(0.055, 0.055, 0.070, 1.0)},  # 午夜最黑
]


## 按关键帧表插值采样（表须 hour 升序且首尾同值闭环；hour 超界回退首帧）
static func sample_keyframes(frames: Array, hour: float) -> Color:
	for i in range(frames.size() - 1):
		var a: Dictionary = frames[i]
		var b: Dictionary = frames[i + 1]
		if hour >= a["hour"] and hour <= b["hour"]:
			var span: float = b["hour"] - a["hour"]
			if span <= 0.0:
				return a["color"]
			return a["color"].lerp(b["color"], (hour - a["hour"]) / span)
	return frames[0]["color"]


## 采样环境光色（CanvasModulate.color）
static func sample_light_color(hour: float) -> Color:
	return sample_keyframes(LIGHT_KEYFRAMES, hour)


## 采样天空底色（清屏色）
static func sample_sky_bg_color(hour: float) -> Color:
	return sample_keyframes(SKY_BG_KEYFRAMES, hour)


## 发光体除法补偿：绘制色 ÷ CanvasModulate 当前色（逐通道，下限 0.045 防除零）。
## 星/月/极光/萤火等画在默认画布的发光体夜晚会被 CanvasModulate 乘暗至不可见，
## 补偿后屏显色 ≈ 目标色（中间值 >1 由绘制管线 float 承载，最终乘回原值）——
## 泰拉瑞亚星星 alpha 独立于天色手算的同构。
static func unmodulate(c: Color, cm: Color) -> Color:
	return Color(
		c.r / maxf(cm.r, 0.045),
		c.g / maxf(cm.g, 0.045),
		c.b / maxf(cm.b, 0.045),
		c.a,
	)
