@tool
class_name InteriorProps
extends RefCounted
## 室内家具程序化生成库 —— Interior/Props 的家具件工厂（批次 4 内饰系统）。
##
## 全静态方法，每件返回 Node2D，锚点 = 地面接触点（脚底中心，y=0），
## 调用方设 position 摆进 Props 容器（Building 局部坐标，地面线 y=0，向上为负）。
## 纹理走 TextureGenAPI（Sprite2D 路径，规避 Polygon2D uv 采样坍缩环境 bug）；
## Polygon2D 仅做纯色块细节（纯色不受该 bug 影响）。
## 生活感约定：错落/微倾 + 组合小物（碗/罐/灯）+ 暖光光晕，不做方块堆砌。

const WOOD_DARK := Color(0.34, 0.23, 0.13)
const WOOD_MID := Color(0.44, 0.30, 0.16)
const WOOD_LIGHT := Color(0.55, 0.40, 0.22)
const CLOTH_CREAM := Color(0.82, 0.76, 0.62)
const IRON := Color(0.30, 0.31, 0.35)


# ── 地面 ─────────────────────────────────────────────────────

## 室内地面：暗色纹理横条（夯土/木板由 base 色区分）+ 前缘压线。
## 返回 Sprite2D，中心锚点（调用方放 (width*16, -h/2) 附近）。
static func make_floor(w: int, h: int, base: Color) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = "FloorSlab"
	s.texture = TextureGenAPI.make_stone_dark(w, h, base)
	# 前缘暗线（地面向观者收边的阴影）
	var edge := Polygon2D.new()
	edge.name = "EdgeShade"
	edge.polygon = PackedVector2Array([
		Vector2(-w * 0.5, -3), Vector2(w * 0.5, -3), Vector2(w * 0.5, 3), Vector2(-w * 0.5, 3)])
	edge.color = base.darkened(0.35)
	s.add_child(edge)
	return s


## 暖光光晕（径向 alpha 渐变），挂光源家具中心
static func make_glow(node_name: String, size: int, color: Color, scale_v: Vector2 = Vector2(1, 1)) -> Sprite2D:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) - c + 0.5, float(y) - c + 0.5).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * a * a))
	var s := Sprite2D.new()
	s.name = node_name
	s.texture = ImageTexture.create_from_image(img)
	s.scale = scale_v
	return s


# ── 木作家具 ─────────────────────────────────────────────────

## 床：木床架 + 床垫 + 枕头 + 毯子（尾部翻折角）。w≈120 h≈46。
static func make_bed(node_name: String, blanket: Color) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var w := 120.0
	var frame_tex := TextureGenAPI.make_wood_plank(int(w), 14, WOOD_MID)
	# 床架（离地）：架板 + 四短腿
	_sprite(root, "Frame", Vector2(0, -30), frame_tex)
	for i in 2:
		_sprite(root, "Leg%d" % i, Vector2(-w * 0.5 + 8.0 + float(i) * (w - 16.0), -8),
				TextureGenAPI.make_wood_pillar(9, 24, WOOD_DARK))
	# 床头板（左端竖板，略高）
	_sprite(root, "Headboard", Vector2(-w * 0.5 + 4, -46), TextureGenAPI.make_wood_plank(10, 36, WOOD_DARK))
	# 床垫
	_poly_round(root, "Mattress", Rect2(-w * 0.5 + 6, -46, w - 12, 15), CLOTH_CREAM)
	# 枕头（床头小圆角块）
	_poly_round(root, "Pillow", Rect2(-w * 0.5 + 12, -52, 26, 10), Color(0.88, 0.86, 0.80))
	# 毯子（盖床垫右 2/3，尾部垂折角）
	_poly_round(root, "Blanket", Rect2(-w * 0.5 + 44, -46, w - 54, 15), blanket)
	var fold := Polygon2D.new()
	fold.name = "BlanketFold"
	fold.polygon = PackedVector2Array([
		Vector2(0, 0), Vector2(20, 0), Vector2(16, 9), Vector2(2, 9)])
	fold.color = blanket.darkened(0.18)
	fold.position = Vector2(-w * 0.5 + 44, -34)
	root.add_child(fold)
	return root


## 兵营通铺（双层）：立柱 + 上下铺板 + 各一床铺盖。w≈190。
static func make_bunk(node_name: String, blanket: Color) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var w := 190.0
	for i in 2:  # 两侧立柱（贯通上下铺）
		_sprite(root, "Post%d" % i, Vector2(-w * 0.5 + 6.0 + float(i) * (w - 12.0), -55),
				TextureGenAPI.make_wood_pillar(11, 110, WOOD_DARK))
	_sprite(root, "LowerFrame", Vector2(0, -28), TextureGenAPI.make_wood_plank(int(w), 12, WOOD_MID))
	_sprite(root, "UpperFrame", Vector2(0, -82), TextureGenAPI.make_wood_plank(int(w), 12, WOOD_MID))
	# 下铺：床垫+毯
	_poly_round(root, "LowerMattress", Rect2(-w * 0.5 + 8, -44, w - 16, 13), CLOTH_CREAM)
	_poly_round(root, "LowerBlanket", Rect2(-w * 0.5 + 60, -44, w - 76, 13), blanket)
	# 上铺：床垫+毯
	_poly_round(root, "UpperMattress", Rect2(-w * 0.5 + 8, -98, w - 16, 13), CLOTH_CREAM)
	_poly_round(root, "UpperBlanket", Rect2(-w * 0.5 + 60, -98, w - 76, 13), blanket)
	# 爬凳（右端两级）
	for i in 2:
		_sprite(root, "Step%d" % i, Vector2(w * 0.5 + 14.0, -10.0 - float(i) * 22.0),
				TextureGenAPI.make_wood_plank(24, 8, WOOD_LIGHT))
	return root


## 方桌：桌面板 + 双腿 + 横撑。
static func make_table(node_name: String, w: float = 110.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	_sprite(root, "Top", Vector2(0, -56), TextureGenAPI.make_wood_plank(int(w), 12, WOOD_LIGHT))
	for i in 2:
		_sprite(root, "Leg%d" % i, Vector2(-w * 0.5 + 10.0 + float(i) * (w - 20.0), -28),
				TextureGenAPI.make_wood_pillar(10, 56, WOOD_MID))
	var brace := Polygon2D.new()
	brace.name = "Brace"
	brace.polygon = PackedVector2Array([
		Vector2(-w * 0.5 + 10, -3), Vector2(w * 0.5 - 10, -3),
		Vector2(w * 0.5 - 10, 3), Vector2(-w * 0.5 + 10, 3)])
	brace.color = WOOD_DARK
	brace.position = Vector2(0, -20)
	root.add_child(brace)
	return root


## 长凳
static func make_bench(node_name: String, w: float = 96.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	_sprite(root, "Top", Vector2(0, -26), TextureGenAPI.make_wood_plank(int(w), 10, WOOD_MID))
	for i in 2:
		_sprite(root, "Leg%d" % i, Vector2(-w * 0.5 + 8.0 + float(i) * (w - 16.0), -10),
				TextureGenAPI.make_wood_pillar(8, 20, WOOD_DARK))
	return root


## 凳子（单人情侣凳：面 + 三腿可见二）
static func make_stool(node_name: String) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	_sprite(root, "Top", Vector2(0, -22), TextureGenAPI.make_wood_plank(26, 8, WOOD_LIGHT))
	for i in 2:
		var leg := Sprite2D.new()
		leg.name = "Leg%d" % i
		leg.texture = TextureGenAPI.make_wood_pillar(6, 18, WOOD_DARK)
		leg.position = Vector2(-7.0 + float(i) * 14.0, -9)
		leg.rotation = -0.08 + float(i) * 0.16
		root.add_child(leg)
	return root


## 货架：双侧立柱 + 多层横板 + 格内杂物（罐/箱/叠布，seed 稳定随机）。
static func make_shelf(node_name: String, w: float = 130.0, h: float = 150.0, rows: int = 4, seed_value: int = 7) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	for i in 2:
		_sprite(root, "Post%d" % i, Vector2(-w * 0.5 + 5.0 + float(i) * (w - 10.0), -h * 0.5),
				TextureGenAPI.make_wood_pillar(10, int(h), WOOD_DARK))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var row_h := (h - 16.0) / float(rows)
	for r in rows:
		var y := -14.0 - float(r) * row_h
		_sprite(root, "Board%d" % r, Vector2(0, y), TextureGenAPI.make_wood_plank(int(w) - 14, 7, WOOD_MID))
		# 每格 2~3 件杂物：箱/罐/叠布，尺寸位置带随机抖动
		var n := rng.randi_range(2, 3)
		for k in n:
			var px := -w * 0.5 + 18.0 + float(k) * (w - 36.0) / float(maxi(n - 1, 1)) + rng.randf_range(-5, 5)
			var pick := rng.randi_range(0, 2)
			match pick:
				0:  # 小木箱
					var c := crate_prop("Item%d_%d" % [r, k], rng.randf_range(16, 22))
					c.position = Vector2(px, y - 4)
					root.add_child(c)
				1:  # 陶罐
					var j := jug("Item%d_%d" % [r, k], rng.randf_range(9, 13))
					j.position = Vector2(px, y - 7)
					root.add_child(j)
				2:  # 叠布/麻布卷
					var cw := rng.randf_range(16, 24)
					var cloth := Polygon2D.new()
					cloth.name = "Item%d_%d" % [r, k]
					cloth.polygon = PackedVector2Array([
						Vector2(-cw * 0.5, 0), Vector2(cw * 0.5, 0), Vector2(cw * 0.4, -7), Vector2(-cw * 0.4, -7)])
					cloth.color = Color(0.6 + rng.randf() * 0.2, 0.45 + rng.randf() * 0.2, 0.30)
					cloth.position = Vector2(px, y - 10)
					root.add_child(cloth)
	return root


## 武器架：双立柱 + 双横杆 + 斜靠长矛×3 + 挂剑×1
static func make_weapon_rack(node_name: String, w: float = 120.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	for i in 2:
		_sprite(root, "Post%d" % i, Vector2(-w * 0.5 + 5.0 + float(i) * (w - 10.0), -40),
				TextureGenAPI.make_wood_pillar(9, 80, WOOD_DARK))
	_sprite(root, "BarLow", Vector2(0, -22), TextureGenAPI.make_wood_plank(int(w) - 8, 6, WOOD_MID))
	_sprite(root, "BarHigh", Vector2(0, -50), TextureGenAPI.make_wood_plank(int(w) - 8, 6, WOOD_MID))
	# 长矛：斜杆 + 矛头，杆底抵下横杆
	for i in 3:
		var px := -w * 0.28 + float(i) * w * 0.26
		var shaft := Line2D.new()
		shaft.name = "SpearShaft%d" % i
		shaft.points = PackedVector2Array([Vector2(px + 6, -22), Vector2(px - 8, -78)])
		shaft.width = 3.0
		shaft.default_color = Color(0.52, 0.38, 0.22)
		root.add_child(shaft)
		var tip := Polygon2D.new()
		tip.name = "SpearTip%d" % i
		tip.polygon = PackedVector2Array([
			Vector2(px - 12, -80), Vector2(px - 4, -92), Vector2(px - 2, -78)])
		tip.color = Color(0.62, 0.64, 0.70)
		root.add_child(tip)
	# 挂剑：竖剑剪影（柄护手刃）
	var sword := Node2D.new()
	sword.name = "Sword"
	sword.position = Vector2(w * 0.32, -50)
	var blade := Polygon2D.new()
	blade.name = "Blade"
	blade.polygon = PackedVector2Array([
		Vector2(-2.5, 0), Vector2(2.5, 0), Vector2(1.5, -30), Vector2(-1.5, -30)])
	blade.color = Color(0.62, 0.64, 0.70)
	sword.add_child(blade)
	var guard := Polygon2D.new()
	guard.name = "Guard"
	guard.polygon = PackedVector2Array([Vector2(-7, 0), Vector2(7, 0), Vector2(7, 3), Vector2(-7, 3)])
	guard.color = Color(0.45, 0.35, 0.18)
	sword.add_child(guard)
	var grip := Polygon2D.new()
	grip.name = "Grip"
	grip.polygon = PackedVector2Array([Vector2(-2, 3), Vector2(2, 3), Vector2(2, 12), Vector2(-2, 12)])
	grip.color = Color(0.36, 0.24, 0.14)
	sword.add_child(grip)
	root.add_child(sword)
	return root


## 储物矮箱（带盖木箱，盖沿+锁扣）
static func make_chest(node_name: String, w: float = 56.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	_sprite(root, "Body", Vector2(0, -18), TextureGenAPI.make_wood_plank(int(w), 30, WOOD_MID))
	# 盖沿（略宽、深色）
	var lid := Polygon2D.new()
	lid.name = "Lid"
	lid.polygon = PackedVector2Array([
		Vector2(-w * 0.5 - 4, -4), Vector2(w * 0.5 + 4, -4), Vector2(w * 0.5 + 4, 4), Vector2(-w * 0.5 - 4, 4)])
	lid.color = WOOD_DARK
	lid.position = Vector2(0, -34)
	root.add_child(lid)
	# 锁扣（黄铜小块）
	var lock := Polygon2D.new()
	lock.name = "Lock"
	lock.polygon = PackedVector2Array([
		Vector2(-4, -6), Vector2(4, -6), Vector2(4, 6), Vector2(-4, 6)])
	lock.color = Color(0.72, 0.58, 0.26)
	lock.position = Vector2(0, -32)
	root.add_child(lock)
	return root


## 木桶：桶身竖纹 + 铁箍×2 + 顶盖椭圆
static func make_barrel(node_name: String, h: float = 52.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var w := h * 0.78
	_sprite(root, "Body", Vector2(0, -h * 0.5), TextureGenAPI.make_wood_pillar(int(w), int(h), WOOD_MID))
	for i in 2:
		var hoop := Polygon2D.new()
		hoop.name = "Hoop%d" % i
		hoop.polygon = PackedVector2Array([
			Vector2(-w * 0.5, -2.5), Vector2(w * 0.5, -2.5), Vector2(w * 0.5, 2.5), Vector2(-w * 0.5, 2.5)])
		hoop.color = IRON
		hoop.position = Vector2(0, -h * (0.26 + float(i) * 0.44))
		root.add_child(hoop)
	# 顶盖
	var top := Polygon2D.new()
	top.name = "TopLid"
	var pts := PackedVector2Array()
	for i in 10:
		var a := PI * float(i) / 9.0
		pts.append(Vector2(-cos(a) * w * 0.5, -sin(a) * 5.0))
	top.polygon = pts
	top.color = WOOD_LIGHT
	top.position = Vector2(0, -h)
	root.add_child(top)
	return root


## 淬火桶（木桶 + 桶口水面反光）
static func make_quench_barrel(node_name: String) -> Node2D:
	var root := make_barrel(node_name, 58.0)
	var water := Polygon2D.new()
	water.name = "Water"
	var pts := PackedVector2Array()
	for i in 10:
		var a := PI * float(i) / 9.0
		pts.append(Vector2(-cos(a) * 20.0, -sin(a) * 4.0))
	water.polygon = pts
	water.color = Color(0.42, 0.58, 0.66)
	water.position = Vector2(0, -57)
	root.add_child(water)
	var glint := Polygon2D.new()
	glint.name = "Glint"
	glint.polygon = PackedVector2Array([Vector2(-8, 0), Vector2(4, 0), Vector2(0, -2.5), Vector2(-6, -2.5)])
	glint.color = Color(0.78, 0.88, 0.92, 0.85)
	glint.position = Vector2(2, -58)
	root.add_child(glint)
	return root


# ── 杂货 ─────────────────────────────────────────────────────

## 木箱（堆叠用小箱：面板 + 压条 + 对角板缝）
static func crate_prop(node_name: String, s: float = 46.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var half := s * 0.5
	var panel := Polygon2D.new()
	panel.name = "Panel"
	panel.polygon = PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)])
	panel.color = WOOD_LIGHT
	root.add_child(panel)
	for i in 2:
		var bar := Polygon2D.new()
		bar.name = "Bar%d" % i
		var y := -half * 0.45 + float(i) * half * 0.9
		bar.polygon = PackedVector2Array([
			Vector2(-half, y - 3), Vector2(half, y - 3), Vector2(half, y + 3), Vector2(-half, y + 3)])
		bar.color = WOOD_DARK
		root.add_child(bar)
	var diag := Line2D.new()
	diag.name = "Diag"
	diag.points = PackedVector2Array([Vector2(-half, -half), Vector2(half, half)])
	diag.width = 2.5
	diag.default_color = WOOD_DARK
	root.add_child(diag)
	return root


## 麻袋（胖椭圆 + 扎口）
static func make_sack(node_name: String, color: Color = Color(0.72, 0.64, 0.46)) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var body := Polygon2D.new()
	body.name = "Body"
	var pts := PackedVector2Array()
	for i in 12:
		var a := TAU * float(i) / 12.0
		pts.append(Vector2(cos(a) * 26.0, sin(a) * 19.0))
	body.polygon = pts
	body.color = color
	root.add_child(body)
	var tie := Polygon2D.new()
	tie.name = "Tie"
	tie.polygon = PackedVector2Array([
		Vector2(-7, -21), Vector2(7, -21), Vector2(4, -29), Vector2(-4, -29)])
	tie.color = color.darkened(0.35)
	root.add_child(tie)
	return root


## 陶罐（圆腹 + 罐口 + 高光）
static func jug(node_name: String, r: float = 11.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var body := Polygon2D.new()
	body.name = "Body"
	var pts := PackedVector2Array()
	for i in 12:
		var a := TAU * float(i) / 12.0
		pts.append(Vector2(cos(a) * r * (1.0 if sin(a) < 0.4 else 0.8), -sin(a) * r * 1.25))
	body.polygon = pts
	body.color = Color(0.52, 0.40, 0.30)
	root.add_child(body)
	var mouth := Polygon2D.new()
	mouth.name = "Mouth"
	mouth.polygon = PackedVector2Array([
		Vector2(-r * 0.4, -r * 1.3), Vector2(r * 0.4, -r * 1.3), Vector2(r * 0.3, -r * 1.15), Vector2(-r * 0.3, -r * 1.15)])
	mouth.color = Color(0.30, 0.22, 0.16)
	root.add_child(mouth)
	return root


## 碗（下半椭圆 + 碗口线）
static func make_bowl(node_name: String, r: float = 12.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var body := Polygon2D.new()
	body.name = "Body"
	var pts := PackedVector2Array()
	for i in 10:
		var a := PI * float(i) / 9.0
		pts.append(Vector2(-cos(a) * r, sin(a) * r * 0.55))
	body.polygon = pts
	body.color = Color(0.42, 0.36, 0.30)
	root.add_child(body)
	return root


## 草席/地毯（双层椭圆）
static func make_rug(node_name: String, w: float = 130.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var outer := Polygon2D.new()
	outer.name = "Outer"
	outer.polygon = _ellipse_pts(w * 0.5, 13.0, 14)
	outer.color = Color(0.58, 0.42, 0.26)
	root.add_child(outer)
	var inner := Polygon2D.new()
	inner.name = "Inner"
	inner.polygon = _ellipse_pts(w * 0.36, 8.5, 12)
	inner.color = Color(0.70, 0.54, 0.34)
	root.add_child(inner)
	return root


## 原木堆（3 根圆木截面 + 滚落一根）
static func make_log_pile(node_name: String) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var spots := [Vector2(-26, -14), Vector2(2, -14), Vector2(-12, -34), Vector2(34, -10)]
	for i in spots.size():
		var log := Node2D.new()
		log.name = "Log%d" % i
		log.position = spots[i]
		var body := Polygon2D.new()
		body.name = "Body"
		body.polygon = _ellipse_pts(16, 11, 10)
		body.color = Color(0.48, 0.34, 0.19)
		log.add_child(body)
		var ring := Polygon2D.new()
		ring.name = "Ring"
		ring.polygon = _ellipse_pts(9, 6, 10)
		ring.color = Color(0.68, 0.54, 0.34)
		log.add_child(ring)
		var core := Polygon2D.new()
		core.name = "Core"
		core.polygon = _ellipse_pts(3, 2, 8)
		core.color = Color(0.52, 0.38, 0.22)
		log.add_child(core)
		root.add_child(log)
	return root


## 煤堆（黑色多峰堆 + 炭块高光）
static func make_coal_pile(node_name: String, w: float = 70.0) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var pile := Polygon2D.new()
	pile.name = "Pile"
	pile.polygon = PackedVector2Array([
		Vector2(-w * 0.5, 0), Vector2(-w * 0.30, -26), Vector2(-w * 0.08, -34),
		Vector2(w * 0.16, -24), Vector2(w * 0.34, -30), Vector2(w * 0.5, 0)])
	pile.color = Color(0.13, 0.13, 0.14)
	root.add_child(pile)
	for i in 4:
		var chunk := Polygon2D.new()
		chunk.name = "Chunk%d" % i
		var s := 3.0 + float(i % 3) * 1.5
		chunk.polygon = PackedVector2Array([
			Vector2(-s, 0), Vector2(0, -s), Vector2(s, 0), Vector2(0, s)])
		chunk.color = Color(0.30, 0.30, 0.33)
		chunk.position = Vector2(-w * 0.26 + float(i) * w * 0.16, -8.0 - float(i % 2) * 12.0)
		root.add_child(chunk)
	return root


## 火盆（三足盆 + 炭火 + 光晕 + 双火苗）
static func make_fire_basket(node_name: String) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var glow := make_glow("Glow", 64, Color(1.0, 0.55, 0.18, 0.55), Vector2(2.4, 1.9))
	glow.position = Vector2(0, -34)
	root.add_child(glow)
	# 盆体（梯形碗）
	var bowl := Polygon2D.new()
	bowl.name = "Bowl"
	bowl.polygon = PackedVector2Array([
		Vector2(-24, -22), Vector2(24, -22), Vector2(17, -2), Vector2(-17, -2)])
	bowl.color = IRON
	root.add_child(bowl)
	# 三足（可见二）
	for i in 2:
		var leg := Polygon2D.new()
		leg.name = "Leg%d" % i
		var x := -12.0 + float(i) * 24.0
		leg.polygon = PackedVector2Array([Vector2(x - 3, -4), Vector2(x + 3, -4), Vector2(x + 5, 2), Vector2(x - 5, 2)])
		leg.color = IRON.darkened(0.25)
		root.add_child(leg)
	# 炭层
	var coals := Polygon2D.new()
	coals.name = "Coals"
	coals.polygon = PackedVector2Array([
		Vector2(-20, -22), Vector2(-6, -28), Vector2(8, -25), Vector2(20, -22), Vector2(0, -18)])
	coals.color = Color(0.85, 0.32, 0.08)
	root.add_child(coals)
	# 双火苗
	for i in 2:
		var f := Polygon2D.new()
		f.name = "Flame%d" % i
		var fx := -5.0 + float(i) * 10.0
		f.polygon = PackedVector2Array([
			Vector2(fx - 5, -24), Vector2(fx, -40 - float(i) * 6), Vector2(fx + 5, -24)])
		f.color = Color(1.0, 0.72, 0.20, 0.9)
		root.add_child(f)
	return root


## 油灯（小碟 + 焰 + 光晕；放桌上）
static func make_lamp(node_name: String) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var glow := make_glow("Glow", 48, Color(1.0, 0.72, 0.30, 0.5), Vector2(2.0, 2.0))
	glow.position = Vector2(0, -14)
	root.add_child(glow)
	var dish := Polygon2D.new()
	dish.name = "Dish"
	var pts := PackedVector2Array()
	for i in 9:
		var a := PI * float(i) / 8.0
		pts.append(Vector2(-cos(a) * 9.0, sin(a) * 4.0))
	dish.polygon = pts
	dish.color = Color(0.36, 0.30, 0.24)
	root.add_child(dish)
	var flame := Polygon2D.new()
	flame.name = "Flame"
	flame.polygon = PackedVector2Array([
		Vector2(-2.5, -4), Vector2(0, -13), Vector2(2.5, -4)])
	flame.color = Color(1.0, 0.80, 0.35)
	flame.position = Vector2(0, -6)
	root.add_child(flame)
	return root


# ── 墙面挂件（挂 Interior，显示在后墙之前）───────────────────

## 挂串（绳 + 一列三角串：干辣椒/蒜/干鱼，color 定调）
static func make_hang_string(node_name: String, color: Color) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var rope := Line2D.new()
	rope.name = "Rope"
	rope.points = PackedVector2Array([Vector2(0, 0), Vector2(0, 8)])
	rope.width = 2.0
	rope.default_color = Color(0.42, 0.34, 0.22)
	root.add_child(rope)
	for i in 5:
		var item := Polygon2D.new()
		item.name = "Item%d" % i
		var y := 10.0 + float(i) * 11.0
		var sway := (0.0 if i % 2 == 0 else 3.0)
		item.polygon = PackedVector2Array([
			Vector2(-4, y), Vector2(4 + sway, y + 1), Vector2(sway * 0.5, y + 11)])
		item.color = color.darkened(0.05 * float(i % 3))
		root.add_child(item)
	return root


## 墙挂工具（锤 + 火钳剪影，挂钩横杆）
static func make_hang_tools(node_name: String) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var bar := Line2D.new()
	bar.name = "Bar"
	bar.points = PackedVector2Array([Vector2(-26, 0), Vector2(26, 0)])
	bar.width = 3.0
	bar.default_color = WOOD_DARK
	root.add_child(bar)
	# 锤：斜柄 + 方头
	var handle := Line2D.new()
	handle.name = "HammerHandle"
	handle.points = PackedVector2Array([Vector2(-14, 2), Vector2(-6, 24)])
	handle.width = 3.5
	handle.default_color = Color(0.50, 0.36, 0.20)
	root.add_child(handle)
	var head := Polygon2D.new()
	head.name = "HammerHead"
	head.polygon = PackedVector2Array([
		Vector2(-11, 20), Vector2(-1, 16), Vector2(3, 24), Vector2(-7, 28)])
	head.color = Color(0.40, 0.42, 0.48)
	root.add_child(head)
	# 火钳：两根细杆
	var tongs := Line2D.new()
	tongs.name = "Tongs"
	tongs.points = PackedVector2Array([Vector2(8, 2), Vector2(14, 26)])
	tongs.width = 2.5
	tongs.default_color = Color(0.45, 0.47, 0.52)
	root.add_child(tongs)
	var tongs2 := Line2D.new()
	tongs2.name = "Tongs2"
	tongs2.points = PackedVector2Array([Vector2(16, 2), Vector2(20, 26)])
	tongs2.width = 2.5
	tongs2.default_color = Color(0.45, 0.47, 0.52)
	root.add_child(tongs2)
	return root


## 墙挂圆盾（八边形近似：木缘 + 盾面 + 铆钉心）
static func make_wall_shield(node_name: String, radius: float = 22.0, face: Color = Color(0.55, 0.42, 0.26)) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	var rim := Polygon2D.new()
	rim.name = "Rim"
	rim.polygon = _poly_pts(8, radius, TAU / 16.0)
	rim.color = Color(0.24, 0.16, 0.10)
	root.add_child(rim)
	var front := Polygon2D.new()
	front.name = "Face"
	front.polygon = _poly_pts(8, radius * 0.78, TAU / 16.0)
	front.color = face
	root.add_child(front)
	var boss := Polygon2D.new()
	boss.name = "Boss"
	boss.polygon = _poly_pts(8, radius * 0.22, 0.0)
	boss.color = Color(0.55, 0.57, 0.62)
	root.add_child(boss)
	return root


## 墙挂交叉剑（两把斜剑交叉 + 挂钉）
static func make_wall_swords(node_name: String) -> Node2D:
	var root := Node2D.new()
	root.name = node_name
	for i in 2:
		var dir := 1.0 if i == 0 else -1.0
		var blade := Line2D.new()
		blade.name = "Blade%d" % i
		blade.points = PackedVector2Array([Vector2(-14.0 * dir, 16), Vector2(14.0 * dir, -18)])
		blade.width = 3.5
		blade.default_color = Color(0.62, 0.64, 0.70)
		root.add_child(blade)
		var guard := Line2D.new()
		guard.name = "Guard%d" % i
		guard.points = PackedVector2Array([Vector2(-8.0 * dir, 10), Vector2(-2.0 * dir, 16)])
		guard.width = 3.0
		guard.default_color = Color(0.45, 0.35, 0.18)
		root.add_child(guard)
	var nail := Polygon2D.new()
	nail.name = "Nail"
	nail.polygon = _poly_pts(6, 3.0, 0.0)
	nail.color = Color(0.35, 0.30, 0.22)
	root.add_child(nail)
	return root


# ── helpers ─────────────────────────────────────────────────

static func _sprite(parent: Node, node_name: String, pos: Vector2, tex: Texture2D) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = node_name
	s.texture = tex
	s.position = pos
	parent.add_child(s)
	return s


## 圆角矩形（8 点近似，中心在 rect 中心）
static func _poly_round(parent: Node, node_name: String, rect: Rect2, color: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.name = node_name
	var hw := rect.size.x * 0.5
	var hh := rect.size.y * 0.5
	var cx := rect.position.x + hw
	var cy := rect.position.y + hh
	p.polygon = PackedVector2Array([
		Vector2(cx - hw + 3, cy - hh), Vector2(cx + hw - 3, cy - hh),
		Vector2(cx + hw, cy - hh + 3), Vector2(cx + hw, cy + hh - 3),
		Vector2(cx + hw - 3, cy + hh), Vector2(cx - hw + 3, cy + hh),
		Vector2(cx - hw, cy + hh - 3), Vector2(cx - hw, cy - hh + 3)])
	p.color = color
	parent.add_child(p)
	return p


static func _ellipse_pts(rx: float, ry: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		pts.append(Vector2(cos(a) * rx, sin(a) * ry))
	return pts


static func _poly_pts(n: int, radius: float, offset: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n) + offset
		pts.append(Vector2(cos(a) * radius, sin(a) * radius))
	return pts
