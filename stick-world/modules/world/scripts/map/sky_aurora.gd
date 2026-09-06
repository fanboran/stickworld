class_name SkyAurora
extends Node2D
## 极光 —— Terraria AuroraSky.cs + VertexStrip.cs 逐行移植（不手搓近似）。
##
## 结构对照（改动的只有坐标系与渲染后端）：
## - VertexStrip 140 段（num6）：每段一对顶点 v（下缘）/v2（上缘）+ 逐顶点颜色，
##   组装为三角带索引（PrepareIndices 同构；2D 无背面剔除，省略 includeBacksides）。
## - 光带数/形态按月相（Main.GetMoonPhase switch 直译）：满月 3 条（侧带朝月亮
##   收拢）、新月/半月变体、上弦左/满弦右直接无极光。
## - 颜色：Main.hslToRgb(hue + cos(t·2π·num7)·0.1, saturation, l) 逐顶点——下缘
##   l=0.5 饱和色、上缘 l=luminosity（1=近白），色相沿带微调制。
## - 运动：num5 = Main.GlobalTimeWrappedHourly/60（连续游戏小时/60，慢漂移），
##   非满月带叠加 2px 旋转扰动与 sin 摆动（:365-372 直译）。
## - 不透明度：AuroraSky.Update 直译（0.3/s 淡入、0.5/s 淡出；入夜激活）。
## 坐标：原版虚拟屏 1920×1080（Main.ScreenSize 缩放省略——本项目窗口同尺寸）；
## 本节点挂在 SkyStars 下（factor 0.08 近乎钉屏），x 以星野窗口中心对齐。
## 渲染：ADD 混合（Aurora shader 为加色发光）+ 顶点色经 unmodulate 补偿穿透
## CanvasModulate 夜间压暗；片元柔边+细丝见 aurora_strip.gdshader（原版 XNB
## 编译无公开源，等价近似——观感主体在顶点色）。

const SEGMENTS: int = 140          # 原版 num6
const VIRTUAL: Vector2 = Vector2(1920.0, 1080.0)
const REBUILD_HZ: float = 20.0
const StripShader: Shader = preload("res://modules/world/shaders/aurora_strip.gdshader")

var _mesh_inst: MeshInstance2D = null
var _mesh: ArrayMesh = null
## 三角带索引（满配 3 条带；PrepareIndices :129-158 同构，背面索引省略）
var _indices := PackedInt32Array()
## SkyStars 每帧注入的快照
var _night: float = 0.0
var _hour: float = 23.0
var _center_x: float = 0.0
var _phase: int = 0
var _seconds_per_day: float = 60.0
## Main.GlobalTimeWrappedHourly（秒）/3600 直译：连续累计的游戏小时
var _wrapped_hour: float = 20.0
## AuroraSky._opacity 直译
var _opacity: float = 0.0
var _acc: float = 99.0
var _env: Node = null


func _ready() -> void:
	_mesh = ArrayMesh.new()
	_mesh_inst = MeshInstance2D.new()
	_mesh_inst.name = "AuroraMesh"
	_mesh_inst.mesh = _mesh
	_mesh_inst.material = ShaderMaterial.new()
	(_mesh_inst.material as ShaderMaterial).shader = StripShader
	_mesh_inst.visible = false
	add_child(_mesh_inst)


## SkyStars._process 每帧注入昼夜快照
func bind_frame(night: float, hour: float, center_x: float, phase: int, seconds_per_day: float) -> void:
	_night = night
	_hour = hour
	_center_x = center_x
	_phase = phase
	_seconds_per_day = seconds_per_day


func _process(delta: float) -> void:
	if TimeManager == null or not TimeManager.is_paused():
		_wrapped_hour += delta * 24.0 / maxf(_seconds_per_day, 1.0)
	# AuroraSky.Update（:33-56）直译：激活淡入 0.3/s、离开淡出 0.5/s
	var active: bool = _night > 0.3
	if active:
		_opacity = minf(_opacity + delta * 0.3, 1.0)
	else:
		_opacity = maxf(_opacity - delta * 0.5, 0.0)
	if _opacity <= 0.01:
		if _mesh_inst.visible:
			_mesh_inst.visible = false
		return
	_acc += delta
	if _acc >= 1.0 / REBUILD_HZ:
		_acc = 0.0
		_rebuild()
		_mesh_inst.visible = true


# ─────────────────────────── DrawAuroraSky（:66-408）直译 ───────────────────────────

func _rebuild() -> void:
	# 月相 → 光带模式（:76-123 switch 直译；_day_count%8 与 MoonPhase 枚举同序）
	var flag := false    # Full 满月
	var flag2 := false   # Empty 新月 / HalfAtLeft / ThreeQuartersAtRight
	var flag3 := false
	var flag4 := false
	var num2: int = 1
	var num3: float = 1.0
	var num4: float = 1.0
	var flag5 := false   # ThreeQuartersAtLeft / QuarterAtRight
	var saturation: float = 1.0
	match _phase:
		0:  # Full
			flag = true
			num2 = 3
		1:  # ThreeQuartersAtLeft
			num2 = 2
			flag5 = true
		2:  # HalfAtLeft
			flag2 = true
			flag3 = true
			num2 = 3
			flag4 = true
			num4 *= 0.5
		3:  # QuarterAtLeft —— 无极光（:103 return）
			return
		4:  # Empty 新月
			flag2 = true
			num2 = 3
		5:  # QuarterAtRight
			num2 = 2
			flag5 = true
			saturation = 0.5
		6:  # HalfAtRight —— 无极光（:114 return）
			return
		7:  # ThreeQuartersAtRight
			flag2 = true
			flag3 = true
			num2 = 3
			flag4 = true
			num4 *= 0.5
			saturation = 0.5

	# 月亮归一化位置（Main.LastCelestialBodyPosition :64027 归一化同构；
	# 侧带尖端朝月亮收拢 + 近月 alpha 归零）
	var moon_frac := _moon_frac()

	var num5: float = _wrapped_hour / 60.0   # :131 GlobalTimeWrappedHourly/60
	var cm: Color = _current_cm()
	var off: Vector2 = Vector2(_center_x - VIRTUAL.x * 0.5, 0.0)   # 虚拟屏中心 → 星野窗口中心
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()

	for i in num2:
		# :134-190 每带参数档（specificData.X/Y/Z 原版喂 fragment shader——XNB 无
		# 公开源，我们的片元不消费；num7/num8/luminosity 的月相覆盖在逐点循环内直译）
		var num7: float = 2.5
		var num8: float = 0.0
		var luminosity: float = 1.0
		if flag4:
			luminosity = 1.0

		for num9 in range(SEGMENTS, -1, -1):
			var num10: float = float(num9) / float(SEGMENTS)   # t（1→0）
			var num11: float = num10
			if flag5 and i == 1:
				num10 = _remap(num10, 0.0, 1.0, 50.0 / float(SEGMENTS), 90.0 / float(SEGMENTS))
			var amount: float = num10
			if not flag:
				amount = 1.0 - num10
			# :204-210 基础几何
			var num12: float = lerpf(0.4, 0.1, num10)   # y 分数
			var num13: float = 0.4 + num5
			var num14: float = 3.0
			var num15: float = 0.5 + cos(num10 * PI * num14 + num13) * 0.4 * lerpf(1.0, 0.3, amount)   # x 分数
			var num16: float = _remap(absf(sin(num10 * PI * num14 + num13)), 0.0, 0.98, 0.0, 1.0)      # 射线门控
			var num17: float = lerpf(0.2, 0.05, amount) * num3   # 半宽（厚度）
			var num18: float = 0.5 - 0.5 * cos(num10 * TAU)      # 两端收敛包络
			var num19: float = num5                              # 色相基准
			if flag5:
				var num20: float = num5 * 0.16
				num12 += (1.0 - num10) * 0.05
				num17 += 0.05
				if i == 1:
					num12 = 0.5 + cos(num20 * TAU * 0.15 + num10 * 60.0) * 0.03
					var num21: float = num10 + num20
					num15 = 0.5 + cos(num21 * TAU) * 1.4 * lerpf(1.0, 0.3, num10)
					num15 += sin(num20 * TAU) * lerpf(0.4, 0.13, num10)
					num12 -= cos(num20 * TAU * 3.0 + num10 * 5.0) * 0.06
					num17 += 0.15
					num15 = num11 * 1.1
					num16 = 1.0 - sin(num11 * TAU * 2.0 + PI * 0.5) * 0.35 - 0.35
					num12 = sin(num11 * TAU * 2.0 + PI * 0.5) * 0.0125 + 0.55
					num17 = 0.16 * num3 + 0.05 + sin(num11 * TAU * 2.0) * 0.025
					num17 += 0.2
				if i == 0:
					var num22: float = _remap(num10, 0.0, 0.3, 0.0, 1.0)
					num18 *= num22 * num22 * num22
					num17 -= 0.1
					num17 += 0.8 * num10 * num10
			if flag and i == 0:
				var num23: float = num5 * 0.16
				num12 = 0.5 + cos(num23 * TAU * 0.15 + num10 * 60.0) * 0.03
				var num24: float = num10 + num23
				num15 = 0.5 + cos(num24 * TAU) * 1.4 * lerpf(1.0, 0.3, num10)
				num15 += sin(num23 * TAU) * lerpf(0.4, 0.13, num10)
				num17 += (sin(num23 * TAU) + 1.0) * lerpf(0.24, 0.15, num10) * num3
				num12 -= cos(num23 * TAU * 3.0 + num10 * 5.0) * 0.06
				num15 = num11 * 1.1
				num12 = sin(num11 * TAU * 2.0 + PI * 0.5 + num5 * 2.0 + PI) * 0.025 + 0.55
				num17 = 0.16 * num3 + 0.05 + sin(num11 * TAU * 2.0 + num5 * 2.0) * 0.02
				num16 = 1.0 - sin(num11 * TAU * 2.0 + PI * 0.5) * 0.35 - 0.35
			if flag2:
				var num25: float = num5 * 0.16
				if i == 0:
					num12 = 0.5 + cos(num25 * TAU * 0.15 + num10 * 60.0) * 0.03
					var num26: float = num10 + num25
					num15 = 0.5 + cos(num26 * TAU) * 1.4 * lerpf(1.0, 0.3, num10)
					num15 += sin(num25 * TAU) * lerpf(0.4, 0.13, num10)
					num12 -= cos(num25 * TAU * 3.0 + num10 * 5.0) * 0.06
					num17 += 0.15
					num15 = num11 * 1.1
					num16 = 1.0 - sin(num11 * TAU * 2.0 + PI * 0.5) * 0.35 - 0.35
					num12 = sin(num11 * TAU * 2.0 + PI * 0.5) * 0.025 + 0.55
					num17 = 0.16 * num3 + 0.05 + sin(num11 * TAU * 2.0) * 0.05
				else:
					num12 = 0.3
					var value: float = cos(num5 * TAU)
					if i == 1:
						num17 += 0.5 * num10
					num12 -= cos(num10 * TAU + num5 * 2.0) * 0.07
					num16 = _remap(absf(value), 0.0, 0.98, 0.0, 1.0)
					num16 = 1.0
					num15 = num10
					num19 += 0.35
					if not flag3:
						num19 -= 0.35
					num18 *= 0.55
					if i == 2:
						num12 -= cos(num5 * TAU * 0.35 + num10 * 13.73) * 0.04 * (1.0 - num10) + 0.04
						num12 -= 0.03
			if flag3:
				num19 = num5 + float(i) * 0.05
				num7 = 0.5
				num8 = 0.02
			if flag2 and not flag3:
				luminosity = 1.0
				num8 = 0.45
			if flag and i != 0:
				# :349-360 侧带尖端朝月亮收拢（LastCelestialBodyPosition 分数空间）
				num18 = maxf(num18 * 2.0, num10)
				if num18 > 1.0:
					num18 = 1.0
				num15 = lerpf(num15, moon_frac.x, num10)
				num12 += 0.05
				num12 = lerpf(num12, moon_frac.y + 0.025, num10)
				num18 *= 0.5
			# :361-373 顶点对 + 非满月扰动
			var v: Vector2 = VIRTUAL * Vector2(num15, num12)
			var v2: Vector2 = VIRTUAL * Vector2(num15, num12 - num17)
			if not flag:
				var num27: float = _wrapped_hour * 0.1
				v += Vector2.from_angle((num27 + 0.3) * TAU) * 2.0
				v2 += Vector2.from_angle((num27 * 0.8 + 0.67) * TAU) * 2.0
				v2.y += sin((num27 + num10) * TAU * 3.0) * 15.0 - 15.0
				v.y += sin((num27 + num10) * TAU * 0.5)
				v2.y += sin((num27 + num10) * TAU * 0.5)
				v.x += sin((num27 + num10) * TAU) * 3.0
				v2.x += sin((num27 + num10) * TAU * 0.75) * 3.0
			# :374-375 逐顶点 HSL 颜色（下缘 l=0.5 / 上缘 l=luminosity）
			var c1 := _hsl(fposmod(num19 + cos(num10 * TAU * num7) * 0.1, 1.0), saturation, 0.5)
			var c2 := _hsl(fposmod(num19 + cos(num10 * TAU * num7) * 0.1 + num8, 1.0), saturation, luminosity)
			# :380-400 alpha 包络（近月归零仅满月侧带）
			var num28: float = clampf(num16 * _opacity * num18 * num4, 0.0, 1.0)
			if flag:
				var from_value2: float = (VIRTUAL * Vector2(num15, num12 - num17 * 0.25)) \
						.distance_to(VIRTUAL * moon_frac)
				num28 *= _remap(from_value2, 29.0, 60.0, 0.0, 1.0)
				var num29: float = 505.0
				var num30: float = 1.0 - num10
				num30 *= num30 * num30
				if i == 1:
					v.x -= num29 * num30
					v2.x -= num29 * num30
					num28 -= num10 * num10 * 0.36
				if i == 2:
					v.x += num29 * num30
					v2.x += num29 * num30
					num28 -= num10 * num10 * 0.36
			num28 = clampf(num28, 0.0, 1.0)
			# 写入顶点对（AddVertexPair :200-209 同构）；unmodulate 补偿 CanvasModulate
			verts.append(v + off)
			verts.append(v2 + off)
			uvs.append(Vector2(num10, 1.0))
			uvs.append(Vector2(num10, 0.0))
			cols.append(EnvironmentAPI.unmodulate(Color(c1.r, c1.g, c1.b, num28), cm))
			cols.append(EnvironmentAPI.unmodulate(Color(c2.r, c2.g, c2.b, num28), cm))

	# 索引：每带 SEGMENTS 段四边形（PrepareIndices 同构，2D 无背面剔除省略 includeBacksides）
	if _indices.is_empty():
		for r in 3:
			for s in SEGMENTS:
				var base: int = (r * (SEGMENTS + 1) + s) * 2
				_indices.append_array(PackedInt32Array([
					base, base + 1, base + 2,
					base + 2, base + 1, base + 3,
				]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = _indices.slice(0, num2 * SEGMENTS * 6)
	_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)


# ─────────────────────────────── 工具 ────────────────────────────────

## Utils.Remap 直译（clamp 的线性重映射）
static func _remap(value: float, from_a: float, to_a: float, from_b: float, to_b: float) -> float:
	if to_a == from_a:
		return from_b
	return lerpf(from_b, to_b, clampf((value - from_a) / (to_a - from_a), 0.0, 1.0))


## Main.hslToRgb 直译（HSL→RGB，h/s/l ∈ 0..1）
static func _hsl(h: float, s: float, l: float) -> Color:
	if s <= 0.0:
		return Color(l, l, l)
	var q: float = l * (1.0 + s) if l < 0.5 else l + s - l * s
	var p: float = 2.0 * l - q
	return Color(_hue_to_rgb(p, q, h + 1.0 / 3.0), _hue_to_rgb(p, q, h), _hue_to_rgb(p, q, h - 1.0 / 3.0))


static func _hue_to_rgb(p: float, q: float, t: float) -> float:
	t = fposmod(t, 1.0)
	if t < 1.0 / 6.0:
		return p + (q - p) * 6.0 * t
	if t < 0.5:
		return q
	if t < 2.0 / 3.0:
		return p + (q - p) * (2.0 / 3.0 - t) * 6.0
	return p


## 月亮归一化位置（本项目月亮轨迹 → 原版 LastCelestialBodyPosition 同构分数）。
## 原版该位置是屏幕空间；这里顶点已 +off（center_x-960）抵消视差窗口平移
## （屏幕 = 本地 + (960-center_x)），月亮本地坐标须加同一平移才与顶点同空间，
## 否则侧带收拢点会比屏上月亮横偏 |off|（相机偏离 960 时达数百像素）。
func _moon_frac() -> Vector2:
	var t: float = SkyStars._traverse(_hour, 19.0, 29.0)
	if t < 0.0:
		return Vector2(0.5, 0.2)
	var pos: Vector2 = SkyStars._celestial_pos(t, _center_x)["pos"]
	pos.x += VIRTUAL.x * 0.5 - _center_x   # 本地 → 顶点(屏幕对齐)空间
	return pos / VIRTUAL


## CanvasModulate 补偿除法用（env 缺失按白 = 不补偿）
func _current_cm() -> Color:
	if _env == null or not is_instance_valid(_env):
		_env = get_tree().root.get_node_or_null("GameRoot/EnvironmentSystem")
	if _env != null and _env.has_method("get_current_light_color"):
		return _env.get_current_light_color()
	return Color.WHITE
