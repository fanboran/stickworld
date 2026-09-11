class_name StoneBrickGen
extends Object
## CPU 程序化石砖纹理生成（静态工具）。
##
## 用途：城墙/城门贴图的运行时生成与离线烘焙（tools/bake_siege_textures.gd）
## 共用同一算法，保证"代码生成的石砖结构"在烘焙产物与运行时兜底两条路上一致。
##
## 配方（与 texture_gen/materials/stone_wall 的 GPU 配方同族，CPU 实现）：
## 错缝排砖 → 每砖独立色调/受光面 → 边缘手绘起伏 → 内部斑驳与裂纹 → 石缝填浆。
## 参考图：materials/stone_wall/reference/白_1.png（浅色石砖）。

## 浅色石砖配色（取自 stone_wall.gdshader 默认色板）
const PALE := {
	"light": Color(0.93, 0.90, 0.83),
	"mid": Color(0.82, 0.78, 0.70),
	"dark": Color(0.58, 0.52, 0.44),
	"mortar": Color(0.38, 0.34, 0.30),
}

## 蓝灰石带配色（取自 stone_band.gdshader 默认 band 色板，用于 make_band/石带）
const BLUEBAND := {
	"light": Color(0.68, 0.71, 0.77),
	"mid": Color(0.54, 0.57, 0.63),
	"dark": Color(0.34, 0.37, 0.43),
	"mortar": Color(0.30, 0.28, 0.27),
}


## 色板合并：调用方 palette 覆盖 PALE 同名键（缺省键不强制四色齐）。
## 所有带 palette 参数的函数经此处统一取有效色板。
static func _pal(palette: Dictionary) -> Dictionary:
	if palette.is_empty():
		return PALE
	var p := PALE.duplicate()
	for k: String in ["light", "mid", "dark", "mortar"]:
		if palette.has(k):
			p[k] = palette[k]
	return p


## 生成一整面石砖墙（不透明，RGB）。
## brick_size: 基准砖块像素尺寸；seed 控制整张砖排布。
## flat_light: true=俯视顶面（无左上受光/右下落影，砖色均匀+轻噪点——上表面
## 砖铺地的观感）；false=侧立面（斜向明暗塑体积）。
## palette: 可选色板覆盖（键 light/mid/dark/mortar；缺省用 PALE 浅色石板）。
static func make_wall(w: int, h: int, seed_value: int = 0,
		brick_size: Vector2i = Vector2i(64, 30), flat_light: bool = false,
		palette: Dictionary = {}) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var pal := _pal(palette)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	# 砖排布：逐行生成 [行y, 行高, 该行砖的x切分]
	var rows: Array = []
	var y := 0
	var row_idx := 0
	while y < h:
		var rh := clampi(int(brick_size.y * rng.randf_range(0.85, 1.15)), 10, 200)
		rows.append({"y": y, "h": rh, "cut": _row_cuts(rng, w, brick_size.x, row_idx)})
		y += rh
		row_idx += 1
	# 底色先铺浆（缝隙色）
	img.fill(pal["mortar"])
	# 逐砖绘制
	for r in rows:
		var row: Dictionary = r
		var cuts: Array = row["cut"]
		for i in cuts.size():
			var bx: int = cuts[i]
			var bw: int = (cuts[i + 1] - bx) if i + 1 < cuts.size() else (w - bx)
			var gap: int = 3
			_draw_brick(img, pal, rng, Rect2i(bx + gap / 2, row["y"] + gap / 2,
					maxi(bw - gap, 4), maxi(row["h"] - gap, 4)), flat_light)
	# 全墙斑驳（风化污渍：低频噪声明暗）
	_weather(img, rng, 0.10)
	return img


## 生成带拱门的城门立面（不透明，RGB）。门洞居中，拱顶半圆。
## opening: 门洞宽/高（高度从底边起算）。
static func make_gate(w: int, h: int, seed_value: int = 0, opening: Vector2i = Vector2i(150, 190),
		palette: Dictionary = {}) -> Image:
	var pal := _pal(palette)
	var img := make_wall(w, h, seed_value, Vector2i(64, 30), false, palette)
	var cx := w / 2
	var ow := opening.x / 2   # 半宽
	var oh := opening.y       # 直壁段高（从底边向上）
	# 门洞 = 直壁矩形 + 顶部半圆（半径 ow，圆心在直壁顶）
	for yy in range(h - oh, h):
		for xx in range(cx - ow, cx + ow):
			img.set_pixel(xx, yy, Color(0.20, 0.16, 0.12))
	for yy in range(h - oh - ow, h - oh):
		var dy := (h - oh) - yy
		var half := int(sqrt(maxf(float(ow * ow - dy * dy), 0.0)))
		for xx in range(cx - half, cx + half):
			img.set_pixel(xx, yy, Color(0.20, 0.16, 0.12))
	# 门洞边缘描一圈受光砖边（拱圈石：径向楔形石块的暗缝暗示）
	_ring(img, cx, h - oh, ow + 7, 10, pal)
	return img


## 生成墙段贴图（带顶部垛口 alpha 镂空）。
## 主体 h 像素墙身 + 顶部 merlon（垛口凸台）高 merlon_h，锯齿周期 merlon_w。
static func make_crenellated(w: int, h: int, seed_value: int = 0, merlon_h: int = 34,
		merlon_w: int = 56, brick_size: Vector2i = Vector2i(64, 30),
		palette: Dictionary = {}) -> Image:
	# 总高 = 垛口 + 墙身；先画整面再挖垛口豁口（alpha=0）
	var pal := _pal(palette)
	var img := make_wall(w, h + merlon_h, seed_value, brick_size, false, palette)
	# 顶部一条压顶石（颜色略浅、无砖缝感：盖掉最上排砖）
	for yy in range(0, 12):
		for xx in range(w):
			var base := img.get_pixel(xx, yy)
			img.set_pixel(xx, yy, base.lerp(pal["light"], 0.55))
	# 豁口：从顶部 merlon_h 深度挖，留出垛口齿（齿 68 > 豁 44——城垛防箭齿形）
	var gap_w: int = 44
	var period: int = 112
	var x: int = 24
	while x + gap_w <= w:
		for yy in range(0, merlon_h):
			for xx in range(x, mini(x + gap_w, w)):
				var c := img.get_pixel(xx, yy)
				c.a = 0.0
				img.set_pixel(xx, yy, c)
		x += period
	# 垛口齿顶也压一条受光边（只对 alpha>0 的像素）
	for yy in range(12, 16):
		for xx in range(w):
			var c := img.get_pixel(xx, yy)
			if c.a > 0.0:
				img.set_pixel(xx, yy, c.lerp(pal["light"], 0.35))
	return img


## ─────────────────── 石作结构件原语（批次 2：石头结构件化） ───────────────────

## 生成石带（水平整石腰线/层间带）：疏缝大石 + 蓝灰色调（区别于墙面暖石）
## + 上缘受光条/下缘落影条 + 底缘滴水痕（风化雨水渍）。
## palette 缺省用 BLUEBAND（蓝灰石带）；传墙面色板则得到同色系整石带。
static func make_band(w: int, h: int, seed_value: int = 0, palette: Dictionary = {},
		brick: Vector2i = Vector2i(110, 36)) -> Image:
	var eff: Dictionary = palette if not palette.is_empty() else BLUEBAND
	var img := make_wall(w, h, seed_value, brick, false, eff)
	# 上缘受光 2px / 下缘落影 3px（整石带的条石体积感）
	for xx in range(w):
		for i in 2:
			var c := img.get_pixel(xx, i)
			img.set_pixel(xx, i, c.lerp(Color(1, 1, 1), 0.22))
		for i in 3:
			var c2 := img.get_pixel(xx, h - 1 - i)
			img.set_pixel(xx, h - 1 - i, c2 * Color(0.72, 0.72, 0.75))
	# 滴水痕：底缘 3~5 处向上的暗色竖渍（宽 3~5px，向上渐隐）
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value * 7 + 13
	var drips := rng.randi_range(3, 5)
	for d in drips:
		var dx := rng.randi_range(8, w - 12)
		var up := rng.randi_range(int(h * 0.3), int(h * 0.8))
		var dw := rng.randi_range(3, 5)
		for yy in range(h - up, h):
			var fade := float(yy - (h - up)) / float(up)   # 0=痕顶 1=底缘
			for xx in range(dx, mini(dx + dw, w)):
				var c := img.get_pixel(xx, yy)
				var k := 0.30 * (0.4 + 0.6 * fade)
				img.set_pixel(xx, yy, c * Color(1.0 - k, 1.0 - k, 1.0 - k * 0.8))
	return img


## 在已有墙面 Image 上开拱形洞（窗/门），就地修改。
## cx 洞中心 x；bottom_y 洞底 y（含）；half_w 直壁半宽；opening_h 直壁段高度；
## 洞形 = 直壁矩形 + 顶部半圆（半径 half_w）。洞内填 depth 深暗色（窗洞幽暗感），
## 洞缘描拱圈石（上半环受光/暗缝交替，复用 _ring）+ 直壁两侧落影竖线。
static func carve_arch_opening(img: Image, cx: int, bottom_y: int, half_w: int,
		opening_h: int, depth: Color = Color(0.09, 0.08, 0.09)) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 直壁段
	for yy in range(maxi(bottom_y - opening_h, 0), mini(bottom_y + 1, h)):
		for xx in range(maxi(cx - half_w, 0), mini(cx + half_w, w)):
			img.set_pixel(xx, yy, depth)
	# 半圆拱顶
	var cy := bottom_y - opening_h   # 圆心 y
	for yy in range(maxi(cy - half_w, 0), maxi(cy, 0)):
		var dy := cy - yy
		var half := int(sqrt(maxf(float(half_w * half_w - dy * dy), 0.0)))
		for xx in range(maxi(cx - half, 0), mini(cx + half, w)):
			img.set_pixel(xx, yy, depth)
	# 拱圈石：外扩 2px 起的上半环描边（亮面/暗缝交替，厚 6px）
	_ring(img, cx, cy, half_w + 2, 6)
	# 直壁两侧落影竖线（洞口进深）
	for yy in range(maxi(bottom_y - opening_h, 0), mini(bottom_y, h)):
		for side in 2:
			var sx := cx - half_w - 2 if side == 0 else cx + half_w + 1
			if sx >= 0 and sx < w:
				var c := img.get_pixel(sx, yy)
				img.set_pixel(sx, yy, c * Color(0.72, 0.72, 0.72))


## 在墙面 Image 左/右缘画角石列（quoin，英式砌法：长短石交替的加强角）。
## col_w 角石列宽；角石面比墙面略亮/略暗交替，缘描暗缝；就地修改。
static func add_quoins(img: Image, left: bool, palette: Dictionary = {}, col_w: int = 30) -> void:
	var pal := _pal(palette)
	var w := img.get_width()
	var h := img.get_height()
	var rng := RandomNumberGenerator.new()
	rng.seed = 917 + (0 if left else 1)
	var y := 0
	var idx := 0
	while y < h:
		var seg := 64 if idx % 2 == 0 else 30   # 长石/短石交替
		var y1 := mini(y + seg, h)
		var brighten := 0.10 if idx % 2 == 0 else -0.05
		for yy in range(y, y1):
			for xx in range(0, col_w):
				var px := xx if left else w - 1 - xx
				var c := img.get_pixel(px, yy)
				var cc := Color(
					clampf(c.r + brighten, 0.0, 1.0),
					clampf(c.g + brighten, 0.0, 1.0),
					clampf(c.b + brighten * 0.9, 0.0, 1.0), c.a)
				if xx == col_w - 1:
					cc = pal["mortar"]   # 角石列内侧竖缝
				if yy == y1 - 1:
					cc = pal["mortar"].lerp(cc, 0.25)   # 层间横缝
				img.set_pixel(px, yy, cc)
		y = y1
		idx += 1
	_weather_stripe(img, left, col_w, rng)


## 角石列的局部风化（顺列向低频压暗，避免角石列比墙面新得突兀）
static func _weather_stripe(img: Image, left: bool, col_w: int, rng: RandomNumberGenerator) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var ox := rng.randf() * 100.0
	for yy in range(h):
		var n := sin(yy * 0.02 + ox) * 0.5 + 0.5
		var k := n * 0.12
		for xx in range(col_w):
			var px := xx if left else w - 1 - xx
			var c := img.get_pixel(px, yy)
			img.set_pixel(px, yy, Color(c.r * (1.0 - k), c.g * (1.0 - k), c.b * (1.0 - k), c.a))


# ─────────────────────────────── 内部实现 ────────────────────────────────

## 一行砖的 x 切分（错缝由调用方 row_idx 奇偶偏移 + 随机首砖宽实现）
static func _row_cuts(rng: RandomNumberGenerator, w: int, brick_w: int, row_idx: int) -> Array:
	var cuts: Array = []
	var x := -(row_idx % 2) * brick_w / 2 - rng.randi_range(0, brick_w / 3)
	while x < w:
		cuts.append(x)
		x += int(brick_w * rng.randf_range(0.78, 1.22))
	return cuts


## 画单块砖：受光渐变底色 + 手绘边缘起伏 + 斑驳 + 低概率裂纹（flat=俯视无光照）
static func _draw_brick(img: Image, pal: Dictionary, rng: RandomNumberGenerator, r: Rect2i,
		flat: bool = false) -> void:
	var tone := rng.randf_range(-0.10, 0.10)
	var base := pal["mid"].lerp(pal["light"], rng.randf_range(0.15, 0.6)) as Color
	base = Color(maxf(base.r + tone, 0.0), maxf(base.g + tone, 0.0), maxf(base.b + tone, 0.0))
	var dark: Color = pal["dark"]
	# 错缝排砖会产生越界砖（负 x/超出右缘），裁到画布内再画
	var x0: int = maxi(r.position.x, 0)
	var y0: int = maxi(r.position.y, 0)
	var x1: int = mini(r.position.x + r.size.x, img.get_width())
	var y1: int = mini(r.position.y + r.size.y, img.get_height())
	for yy in range(y0, y1):
		for xx in range(x0, x1):
			# 边缘起伏：到砖边的距离 + 噪声阈值（手绘轮廓）
			var edge := minf(minf(float(xx - r.position.x), float(r.position.x + r.size.x - 1 - xx)),
					minf(float(yy - r.position.y), float(r.position.y + r.size.y - 1 - yy)))
			var wob := sin((xx * 12.9 + yy * 7.7 + r.position.x * 3.1)) * 0.9
			if edge < 1.0 + wob * 0.5:
				continue   # 留给缝隙色
			var c := base
			if flat:
				# 俯视面：无斜向受光，仅极轻的逐砖明度呼吸
				c = c.lerp(dark, tone * 0.5 + 0.04)
			else:
				# 左上受光 / 右下落影（斜向明度梯度）
				var t := (float(xx - r.position.x) / r.size.x + float(yy - r.position.y) / r.size.y) * 0.5
				c = c.lerp(dark, clampf(t * 0.38, 0.0, 0.38))
			# 内部斑驳（伪随机颗粒+块状色斑）
			var grain := fmod(sin(xx * 12.9898 + yy * 78.233) * 43758.5453, 1.0)
			c = c.lerp(dark, absf(grain) * 0.10)
			img.set_pixel(xx, yy, c)
	# 低概率裂纹（从随机边中点向内折线）
	if rng.randf() < 0.14:
		var cx := r.position.x + rng.randi_range(4, r.size.x - 5)
		var cy := r.position.y
		var len := mini(rng.randi_range(6, r.size.y - 2), r.size.y - 2)
		for i in len:
			var yy := cy + i
			if yy >= img.get_height():
				break
			var xx := cx + int(sin(i * 1.7) * 1.6)
			if xx < 0 or xx >= img.get_width():
				break
			var c := img.get_pixel(xx, yy)
			img.set_pixel(xx, yy, Color(c.r * 0.55, c.g * 0.55, c.b * 0.55))


## 全图风化污渍：低频伪噪声压暗局部
static func _weather(img: Image, rng: RandomNumberGenerator, amount: float) -> void:
	var ox := rng.randf() * 100.0
	var oy := rng.randf() * 100.0
	for yy in range(img.get_height()):
		for xx in range(img.get_width()):
			var n := sin(xx * 0.013 + ox) * sin(yy * 0.017 + oy) + sin((xx + yy) * 0.007)
			var k := clampf(n * 0.25, 0.0, 1.0) * amount
			if k > 0.003:
				var c := img.get_pixel(xx, yy)
				img.set_pixel(xx, yy, Color(c.r * (1.0 - k), c.g * (1.0 - k), c.b * (1.0 - k)))


## 拱圈石：以 (cx, cy) 为圆心、半径 r0..r1 的圆环内描暗缝（径向短线）
static func _ring(img: Image, cx: int, cy: int, r0: int, r1: int, palette: Dictionary = {}) -> void:
	var pal := _pal(palette)
	for a in range(0, 180, 7):
		var rad := deg_to_rad(float(a))
		var dir := Vector2(cos(rad), -sin(rad))
		for rr in range(r0, r0 + r1):
			var p := Vector2(cx, cy) + dir * rr
			var x := int(p.x)
			var y := int(p.y)
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			if a % 28 < 7:
				img.set_pixel(x, y, Color(c.r * 0.6, c.g * 0.6, c.b * 0.6))
			else:
				img.set_pixel(x, y, c.lerp(pal["light"], 0.25))
