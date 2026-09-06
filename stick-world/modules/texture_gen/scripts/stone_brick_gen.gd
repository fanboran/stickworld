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


## 生成一整面石砖墙（不透明，RGB）。
## brick_size: 基准砖块像素尺寸；seed 控制整张砖排布。
## flat_light: true=俯视顶面（无左上受光/右下落影，砖色均匀+轻噪点——上表面
## 砖铺地的观感）；false=侧立面（斜向明暗塑体积）。
static func make_wall(w: int, h: int, seed_value: int = 0,
		brick_size: Vector2i = Vector2i(64, 30), flat_light: bool = false) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
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
	img.fill(PALE["mortar"])
	# 逐砖绘制
	for r in rows:
		var row: Dictionary = r
		var cuts: Array = row["cut"]
		for i in cuts.size():
			var bx: int = cuts[i]
			var bw: int = (cuts[i + 1] - bx) if i + 1 < cuts.size() else (w - bx)
			var gap: int = 3
			_draw_brick(img, rng, Rect2i(bx + gap / 2, row["y"] + gap / 2,
					maxi(bw - gap, 4), maxi(row["h"] - gap, 4)), flat_light)
	# 全墙斑驳（风化污渍：低频噪声明暗）
	_weather(img, rng, 0.10)
	return img


## 生成带拱门的城门立面（不透明，RGB）。门洞居中，拱顶半圆。
## opening: 门洞宽/高（高度从底边起算）。
static func make_gate(w: int, h: int, seed_value: int = 0, opening: Vector2i = Vector2i(150, 190)) -> Image:
	var img := make_wall(w, h, seed_value)
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
	_ring(img, cx, h - oh, ow + 7, 10)
	return img


## 生成墙段贴图（带顶部垛口 alpha 镂空）。
## 主体 h 像素墙身 + 顶部 merlon（垛口凸台）高 merlon_h，锯齿周期 merlon_w。
static func make_crenellated(w: int, h: int, seed_value: int = 0, merlon_h: int = 34,
		merlon_w: int = 56, brick_size: Vector2i = Vector2i(64, 30)) -> Image:
	# 总高 = 垛口 + 墙身；先画整面再挖垛口豁口（alpha=0）
	var img := make_wall(w, h + merlon_h, seed_value, brick_size)
	# 顶部一条压顶石（颜色略浅、无砖缝感：盖掉最上排砖）
	for yy in range(0, 12):
		for xx in range(w):
			var base := img.get_pixel(xx, yy)
			img.set_pixel(xx, yy, base.lerp(PALE["light"], 0.55))
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
				img.set_pixel(xx, yy, c.lerp(PALE["light"], 0.35))
	return img


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
static func _draw_brick(img: Image, rng: RandomNumberGenerator, r: Rect2i,
		flat: bool = false) -> void:
	var tone := rng.randf_range(-0.10, 0.10)
	var base := PALE["mid"].lerp(PALE["light"], rng.randf_range(0.15, 0.6)) as Color
	base = Color(maxf(base.r + tone, 0.0), maxf(base.g + tone, 0.0), maxf(base.b + tone, 0.0))
	var dark := PALE["dark"]
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
static func _ring(img: Image, cx: int, cy: int, r0: int, r1: int) -> void:
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
				img.set_pixel(x, y, c.lerp(PALE["light"], 0.25))
