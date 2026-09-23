class_name SketchDraw
extends Object
## 手绘涂鸦绘制库 —— 与血条 HealthBarIndicator 完全同源的 boiling line 算法。
##
## 同源三要素：
## 1. 确定性伪噪声 wobble()：与血条 _wobble 同公式（sin(i*127.1+seed*0.3117)*43758.5453）
## 2. 沸腾节拍 WOBBLE_INTERVAL=0.12s：seed 重掷 → 边缘像手绘逐帧重画
## 3. 实心扰动多边形 + draw_polyline 粗描边（抗锯齿）：马克笔线条质感
##
## UI 适配差异（相对血条的横条）：
## - 四边分段按边长自适应（SEG_LEN ≈ 血条 96px/6段 的密度），杜绝长边折线感
## - 四角圆角（血条是两端外凸圆头）；半径只向外扰动（血条注释的教训：内凹自交
##   会导致三角化失败 Invalid polygon）
## - 过小矩形回退普通 draw_rect（血条同款退化保护）

## boiling 抖动幅度基准（px）——血条 0.9 的同量级；大面板按尺寸放大
const WOBBLE_AMP: float = 0.95
## 重掷间隔（s）：与血条一致
const WOBBLE_INTERVAL: float = 0.12
## 描边宽（px）：血条 OUTLINE_WIDTH 同值
const OUTLINE_WIDTH: float = 1.6
## 每段长度（px）：顶点采样密度（血条 96px 宽 6 段 ≈ 16px/段）
const SEG_LEN: float = 18.0
## UI 面板圆角半径（px）
const CORNER_R: float = 7.0
## 每个角的弧采样数
const ARC_STEPS: int = 4


## 1px 空纹理（shared）：覆盖引擎原生图标用（SketchHSlider 滑块等，不影响布局处）
static var _empty_tex: ImageTexture = null

static func empty_texture() -> ImageTexture:
	if _empty_tex == null:
		_empty_tex = ImageTexture.create_from_image(
				Image.create_empty(1, 1, false, Image.FORMAT_RGBA8))
	return _empty_tex


## 指定尺寸的全透明纹理（shared，按尺寸缓存）：覆盖引擎图标并占住图标槽位——
## CheckBox/CheckButton 的最小宽度 = 图标宽 + h_separation，1px 空纹理会让控件
## 塌成 1px 宽（ScrollContainer 等裁剪容器里自绘描边被剪没的教训）
static var _blank_tex_cache: Dictionary = {}

static func blank_texture(size: Vector2i) -> ImageTexture:
	if not _blank_tex_cache.has(size):
		_blank_tex_cache[size] = ImageTexture.create_from_image(
				Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8))
	return _blank_tex_cache[size]


## 确定性伪噪声（-0.5~0.5）：seed 变化 = boiling 逐帧重掷（与血条同公式）
static func wobble(i: int, seed: int) -> float:
	var v: float = sin(float(i) * 127.1 + float(seed) * 0.3117) * 43758.5453
	return fposmod(v, 1.0) - 0.5


## 按控件短边自适应的抖动幅度：始终小幅双向摆动（血条质感来源），
## 大面板略放大到可见即止——边框永远画在标准圆角矩形位置上，只让线"活"
static func amp_for(r: Rect2) -> float:
	var m: float = minf(r.size.x, r.size.y)
	return clampf(WOBBLE_AMP * m / 40.0, WOBBLE_AMP, 1.3)


## 画一个手绘面板底：实心扰动多边形 + 闭合粗描边。
## fill/outline 任一 alpha=0 时跳过对应层。退化保护与血条一致。
static func draw_panel(c: CanvasItem, r: Rect2, seed: int, fill: Color,
		outline: Color, outline_w: float = OUTLINE_WIDTH,
		corner_r: float = CORNER_R) -> void:
	if r.size.x < 8.0 or r.size.y < 8.0:
		if fill.a > 0.0:
			c.draw_rect(r, fill)
		if outline.a > 0.0:
			c.draw_rect(r, outline, false, outline_w)
		return
	var pts := wobbly_rect_path(r, seed, corner_r)
	if fill.a > 0.0:
		c.draw_colored_polygon(pts, fill)
	if outline.a > 0.0:
		var loop := pts.duplicate()
		loop.append(pts[0])
		c.draw_polyline(loop, outline, outline_w, true)


## 手绘圆角矩形路径（顺时针，四边按 SEG_LEN 分段 + 四角外凸圆弧，全部带扰动）。
## 顶点噪声索引连续递增，保证任意两点扰动独立。
static func wobbly_rect_path(r: Rect2, seed: int, corner_r: float = CORNER_R,
		amp: float = -1.0) -> PackedVector2Array:
	if amp < 0.0:
		amp = amp_for(r)
	corner_r = minf(corner_r, r.size.x * 0.5 - 2.0)
	corner_r = minf(corner_r, r.size.y * 0.5 - 2.0)
	if corner_r < 2.0:
		corner_r = 2.0
	var idx: int = 0
	var pts := PackedVector2Array()
	var left: float = r.position.x
	var top: float = r.position.y
	var right: float = r.end.x
	var bottom: float = r.end.y

	# 直边采样（顺时针：顶→右→底→左），法向 = 指向矩形外侧
	# 顶边（左→右）
	var n: int = maxi(2, roundi((right - left - corner_r * 2.0) / SEG_LEN))
	for i in n + 1:
		var t: float = float(i) / float(n)
		var x: float = left + corner_r + (right - left - corner_r * 2.0) * t
		var ny: float = wobble(idx, seed) * amp
		idx += 1
		pts.append(Vector2(x, top + ny))
	# 右上角弧
	_append_arc(pts, Vector2(right - corner_r, top + corner_r), -PI * 0.5, 0.0,
			corner_r, seed, idx, amp)
	idx += ARC_STEPS
	# 右边（上→下）
	n = maxi(2, roundi((bottom - top - corner_r * 2.0) / SEG_LEN))
	for i in n + 1:
		var t: float = float(i) / float(n)
		var y: float = top + corner_r + (bottom - top - corner_r * 2.0) * t
		var nx: float = wobble(idx, seed) * amp
		idx += 1
		pts.append(Vector2(right + nx, y))
	# 右下角弧
	_append_arc(pts, Vector2(right - corner_r, bottom - corner_r), 0.0, PI * 0.5,
			corner_r, seed, idx, amp)
	idx += ARC_STEPS
	# 底边（右→左）
	n = maxi(2, roundi((right - left - corner_r * 2.0) / SEG_LEN))
	for i in n + 1:
		var t: float = 1.0 - float(i) / float(n)
		var x: float = left + corner_r + (right - left - corner_r * 2.0) * t
		var ny: float = wobble(idx, seed) * amp
		idx += 1
		pts.append(Vector2(x, bottom + ny))
	# 左下角弧
	_append_arc(pts, Vector2(left + corner_r, bottom - corner_r), PI * 0.5, PI,
			corner_r, seed, idx, amp)
	idx += ARC_STEPS
	# 左边（下→上）
	n = maxi(2, roundi((bottom - top - corner_r * 2.0) / SEG_LEN))
	for i in n + 1:
		var t: float = 1.0 - float(i) / float(n)
		var y: float = top + corner_r + (bottom - top - corner_r * 2.0) * t
		var nx: float = wobble(idx, seed) * amp
		idx += 1
		pts.append(Vector2(left + nx, y))
	# 左上角弧（收尾）
	_append_arc(pts, Vector2(left + corner_r, top + corner_r), PI, PI * 1.5,
			corner_r, seed, idx, amp)
	return pts


## 角弧采样：半径带小幅双向扰动（普通圆角，线活一点点；
## 扰动下限钳住 0 防自交——血条注释的三角化失败教训）
static func _append_arc(pts: PackedVector2Array, center: Vector2, a0: float,
		a1: float, radius: float, seed: int, idx_base: int, amp: float) -> void:
	for i in ARC_STEPS:
		var t: float = float(i) / float(ARC_STEPS)
		var a: float = a0 + (a1 - a0) * t
		var rr: float = radius + wobble(idx_base + i, seed) * amp * 0.9
		pts.append(center + Vector2(cos(a), sin(a)) * maxf(rr, radius * 0.55))


## 手绘波浪线（分隔线）：沿线分段 + 法向扰动
static func draw_wavy_line(c: CanvasItem, from: Vector2, to: Vector2, seed: int,
		color: Color, width: float = 1.3) -> void:
	var len: float = from.distance_to(to)
	if len < 4.0:
		c.draw_line(from, to, color, width)
		return
	var n: int = maxi(2, roundi(len / SEG_LEN))
	var dir: Vector2 = (to - from) / len
	var normal: Vector2 = Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array()
	for i in n + 1:
		var t: float = float(i) / float(n)
		var p: Vector2 = from.lerp(to, t)
		var o: float = wobble(i * 3, seed) * WOBBLE_AMP * 1.4
		pts.append(p + normal * o)
	c.draw_polyline(pts, color, width, true)


## 手绘进度条（进度方向水平）：外框 groove + 填充（内缩 inset，带端帽）
static func draw_progress(c: CanvasItem, r: Rect2, ratio: float, seed: int,
		fill_color: Color, track_color: Color) -> void:
	ratio = clampf(ratio, 0.0, 1.0)
	# 轨道（凹槽 + 淡描边）
	draw_panel(c, r, seed, track_color, Color(StickTokens.BORDER.r,
			StickTokens.BORDER.g, StickTokens.BORDER.b, 0.12), 1.3, 5.0)
	var inset: float = 2.5
	var fw: float = (r.size.x - inset * 2.0) * ratio
	if fw > 1.5:
		var fill_rect := Rect2(r.position.x + inset, r.position.y + inset,
				fw, r.size.y - inset * 2.0)
		# 填充用独立 seed 偏移，与轨道边缘错开 boiling 相位
		draw_panel(c, fill_rect, seed + 77, fill_color,
				Color(0, 0, 0, 0.35), 0.0, 3.0)


## 手绘扁平齿轮图标（正圆 wobbly 轮体 + 放射齿 + 中心孔）。
## 齿 = 圆周外的粗短楔形（马克笔笔画感），孔 = 底色圆盖出。
static func draw_gear(c: CanvasItem, center: Vector2, radius: float, seed: int,
		color: Color, bg: Color) -> void:
	var teeth := 8
	var r_body: float = radius * 0.72
	# 齿（先画，被轮体压住内半段 = 扁平契形）
	for i in teeth:
		var a: float = TAU * float(i) / float(teeth) + 0.15
		var dir := Vector2(cos(a), sin(a))
		var r0: float = r_body * 0.8 + wobble(i * 5, seed) * 0.6
		var r1: float = radius * (0.98 + wobble(i * 5 + 2, seed) * 0.1)
		var half_w: float = radius * 0.16
		var nrm := Vector2(-dir.y, dir.x)
		var p0 := center + dir * r0 + nrm * half_w
		var p1 := center + dir * r1 + nrm * (half_w * 0.55)
		var p2 := center + dir * r1 - nrm * (half_w * 0.55)
		var p3 := center + dir * r0 - nrm * half_w
		c.draw_colored_polygon(PackedVector2Array([p0, p1, p2, p3]), color)
	# 轮体（wobbly 圆）
	var pts := PackedVector2Array()
	var seg := 14
	for i in seg:
		var a: float = TAU * float(i) / float(seg)
		var rr: float = r_body + wobble(i * 3 + 40, seed) * 0.8
		pts.append(center + Vector2(cos(a), sin(a)) * rr)
	c.draw_colored_polygon(pts, color)
	# 中心孔（底色盖出；wobbly 小圆）
	var hole := PackedVector2Array()
	for i in 10:
		var a: float = TAU * float(i) / float(10)
		var rr: float = radius * 0.26 + wobble(i * 7 + 80, seed) * 0.5
		hole.append(center + Vector2(cos(a), sin(a)) * rr)
	c.draw_colored_polygon(hole, bg)


# ───────────────────────── 播放器图形（走带/音符）─────────────────────────
# 为什么自绘而不走图标管线：StickHand 字体**不含** ▶ / ⏸ / ⏮ / ⏭ / ♪ 这些符号
# （实测 has_char 全 false），贴图管线也没有对应母题——音乐播放器的走带键
# 和音符角标只能矢量自绘。画法与 draw_gear 同源：wobble 扰动 + 马克笔笔画。

## 可自绘的图形（SketchGlyphButton 的 glyph 取值）
enum Glyph { NOTE, PLAY, PAUSE, PREV, NEXT, REPEAT }


## 图形总入口：center = 图形中心，radius = 图形外接半径（约等于短边的一半 × 0.4）
static func draw_glyph(c: CanvasItem, glyph: int, center: Vector2, radius: float,
		seed: int, color: Color) -> void:
	match glyph:
		Glyph.NOTE:
			draw_note(c, center, radius, seed, color)
		Glyph.PLAY:
			draw_play(c, center, radius, seed, color)
		Glyph.PAUSE:
			draw_pause(c, center, radius, seed, color)
		Glyph.PREV:
			draw_track_step(c, center, radius, seed, color, true)
		Glyph.NEXT:
			draw_track_step(c, center, radius, seed, color, false)
		Glyph.REPEAT:
			draw_repeat(c, center, radius, seed, color)


## 音符（八分音符）：实心扁圆符头 + 符干 + 右甩符尾（原声带入口的角标）
static func draw_note(c: CanvasItem, center: Vector2, r: float, seed: int,
		color: Color) -> void:
	var head_c := center + Vector2(-r * 0.30, r * 0.62)
	_filled_ellipse(c, head_c, Vector2(r * 0.62, r * 0.46), seed + 3, color)
	# 符干：符头右缘起笔，竖到顶部（略右倾，手写感）
	var stem_bottom := head_c + Vector2(r * 0.52, -r * 0.12)
	var stem_top := stem_bottom + Vector2(r * 0.16, -r * 1.62)
	_stroke(c, [stem_bottom, stem_top], r * 0.20, seed + 5, color)
	# 符尾：顶部向右下的一笔弧
	var flag_a := stem_top + Vector2(r * 0.02, r * 0.06)
	var flag_b := stem_top + Vector2(r * 0.92, r * 0.46)
	var flag_mid := (flag_a + flag_b) * 0.5 + Vector2(r * 0.10, -r * 0.26)
	_stroke(c, [flag_a, flag_mid, flag_b], r * 0.19, seed + 7, color)


## 播放：右向实心三角（左缘略钝，避免"打印感"）
static func draw_play(c: CanvasItem, center: Vector2, r: float, seed: int,
		color: Color) -> void:
	var tip := center + Vector2(r * 0.86, 0.0)
	var top := center + Vector2(-r * 0.62, -r * 0.80)
	var bottom := center + Vector2(-r * 0.62, r * 0.80)
	var mid_top := Vector2(tip.x, top.y).lerp(Vector2(top.x, top.y), 0.32) \
			+ Vector2(0.0, wobble(1, seed) * r * 0.10)
	var mid_bottom := Vector2(tip.x, bottom.y).lerp(Vector2(bottom.x, bottom.y), 0.32) \
			+ Vector2(0.0, wobble(2, seed) * r * 0.10)
	c.draw_colored_polygon(PackedVector2Array([tip, mid_top, top, bottom, mid_bottom]), color)


## 暂停：两根竖条（等宽、圆头）
static func draw_pause(c: CanvasItem, center: Vector2, r: float, seed: int,
		color: Color) -> void:
	var w: float = r * 0.30
	var h: float = r * 0.82
	for i in 2:
		var x: float = center.x + (-1.0 if i == 0 else 1.0) * (w * 0.95) \
				+ wobble(i + 11, seed) * r * 0.06
		_stroke(c, [Vector2(x, center.y - h), Vector2(x, center.y + h)], w, seed + i, color)


## 上一曲/下一曲：三角 + 端竖条（next=true 时整体镜像）
static func draw_track_step(c: CanvasItem, center: Vector2, r: float, seed: int,
		color: Color, back: bool) -> void:
	var dir: float = 1.0 if back else -1.0
	var tip := center + Vector2(-dir * r * 0.30, 0.0)
	var a := center + Vector2(dir * r * 0.72, -r * 0.74)
	var b := center + Vector2(dir * r * 0.72, r * 0.74)
	c.draw_colored_polygon(PackedVector2Array([tip, a, b]), color)
	_stroke(c, [Vector2(a.x + dir * r * 0.14, a.y), Vector2(b.x + dir * r * 0.14, b.y)],
			r * 0.28, seed + 17, color)


## 循环：开口圆环 + 端头箭头（环形箭头，开口朝右上）
static func draw_repeat(c: CanvasItem, center: Vector2, r: float, seed: int,
		color: Color) -> void:
	var rr: float = r * 0.72
	var seg := 18
	var start_a: float = -PI * 0.35
	var end_a: float = TAU - PI * 0.62
	var pts := PackedVector2Array()
	for i in seg + 1:
		var a: float = start_a + (end_a - start_a) * float(i) / float(seg)
		var rad: float = rr + wobble(i * 2, seed) * r * 0.07
		pts.append(center + Vector2(cos(a), sin(a)) * rad)
	c.draw_polyline(pts, color, r * 0.20, true)
	# 端头箭头：末端切线方向上的小三角
	var tail := pts[0]
	var next_p := pts[1]
	var tg := (tail - next_p).normalized()
	var nrm := Vector2(-tg.y, tg.x)
	c.draw_colored_polygon(PackedVector2Array([
		tail + tg * r * 0.44,
		tail + nrm * r * 0.34,
		tail - nrm * r * 0.34,
	]), color)


## 实心扰动椭圆（符头）
static func _filled_ellipse(c: CanvasItem, center: Vector2, half: Vector2, seed: int,
		color: Color) -> void:
	var pts := PackedVector2Array()
	var seg := 12
	for i in seg:
		var a: float = TAU * float(i) / float(seg)
		var k: float = 1.0 + wobble(i * 3, seed) * 0.10
		pts.append(center + Vector2(cos(a) * half.x * k, sin(a) * half.y * k))
	c.draw_colored_polygon(pts, color)


## 折线马克笔笔画（圆头端帽 + 圆角连接，与 draw_wavy_line 同观感）
static func _stroke(c: CanvasItem, pts: Array, width: float, seed: int, color: Color) -> void:
	if pts.size() < 2:
		return
	var path := PackedVector2Array(pts)
	c.draw_polyline(path, color, width, true)
	for p: Vector2 in pts:
		c.draw_circle(p, width * 0.5, color)
