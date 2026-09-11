@tool
extends BuildingExterior
## 城墙段程序化外观（批次 5：wall_tier 系列外壳化改造）。
##
## 原 wall_tier1/2/3 / wall_gate 四场景是「手绘单色 Polygon2D 耦合」模式；
## 本脚本统一迁到 BuildingExterior 子类 + 调色板模式，复用批次 2 石作装配
## （StoneBrickGen CPU 纹理 + Sprite2D——本环境唯一可靠显示路径）。
##
## ── 阶段 F 语义红线（改造不可破坏项）──
## 场景内 PassageBarrier / StandPlatform 节点及其碰撞几何逐字节保留；
## def 数据字段 wall_tier / can_stand_on / is_gate 与 building.gd 阶段 F
## 逻辑（demolish 时城墙 PassageBarrier 失效、站台查找）不受本脚本影响——
## 本脚本只重绘 Exterior 视觉。
##
## 规格（wall_kind 场景注入）：
##   1 = 夯土矮墙（tier1，64 高，草皮压顶，不能站人）
##   2 = 标准石墙（tier2 / 城门共用，128 高，垛口 + 箭缝窗）
##   3 = 大型石墙（tier3，192 高，垛口 + 双石带 + 双箭窗）
## gate_mode = true 时墙身居中开拱形门洞 + 木门板（wall_gate）。
##
## 拉伸模型：墙身纹理按 width 整张生成（静态缓存，key 含规格/宽度/色板），
## 宽度变化 → rebuild_exterior 换缓存键重生成。

## 城墙规格：1=夯土矮墙 2=标准石墙 3=大型石墙
@export_range(1, 3) var wall_kind: int = 1
## 城门模式：居中拱形门洞 + 木门板（wall_gate 专用，配合 wall_kind=2）
@export var gate_mode: bool = false

## 各规格墙身高（与场景 PassageBarrier/StandPlatform 碰撞几何对齐，勿随意改动）
const T1_H := 64
const T2_H := 128
const T3_H := 192
## 垛口凸台高（凸出墙顶上方的装饰剪影，不含在墙身碰撞高度内）
const MERLON_H := 20
## 纹理 seed（同规格稳定观感）
const SEED := 53
## 箭窗（拱缝窗）参数：半宽/直壁高
const ARROW_HALF_W := 3
const ARROW_H := 20


func _build_exterior() -> void:
	# 与基类/其他子类相同的三重守卫（palette/ext/首次构建）
	var pal := _get_palette()
	if pal.is_empty():
		push_warning("[WallSegment] %s 未提供调色板" % name)
		return
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	if ext.get_child_count() > 0:
		return

	# 城墙 Exterior position=(16,0)：左缘 -16、右缘 width*32-16（width=1 → x∈[-16,16]）
	var left := -16.0
	var right: float = float(width) * 32.0 - 16.0
	var w_px := int(right - left)
	var cx := (left + right) * 0.5

	var h: int
	match wall_kind:
		1: h = T1_H
		3: h = T3_H
		_: h = T2_H

	# ── L1 主墙身（垛口/箭缝窗/门洞都烘进一张纹理，静态缓存）──
	var l1 := _nc("L1_BackWall", ext)
	var spal := _stone_palette()
	var mode := "seg%d%s" % [wall_kind, "_gate" if gate_mode else ""]
	var key := _stone_cache_key(mode, w_px, h, SEED, spal)
	var tex: ImageTexture
	if _stone_tex_cache.has(key):
		tex = _stone_tex_cache[key]
	else:
		var img: Image
		var merl := MERLON_H + (4 if wall_kind == 3 else 0)
		if wall_kind == 1:
			# 夯土矮墙：大板块土墙（板块明显大于石砖 → 夯土填版感），无垛口
			img = StoneBrickGen.make_wall(w_px, T1_H, SEED, Vector2i(92, 34), false, spal)
			# 底部踢脚污渍带（接地端 6 行压暗）
			for yy in range(T1_H - 6, T1_H):
				for xx in w_px:
					img.set_pixel(xx, yy, img.get_pixel(xx, yy).darkened(0.18))
		else:
			# 石墙 + 垛口凸台（alpha 镂空锯齿）
			img = StoneBrickGen.make_crenellated(w_px, h, SEED, merl, 24, STONE_BRICK, spal)
			if w_px < 112:
				# make_crenellated 的豁口周期（112px）按宽墙设计，窄墙段挖不出豁口；
				# 手工在中央挖一个小豁口，形成两齿垛口剪影
				var gw := maxi(10, w_px / 3)
				var x0 := (w_px - gw) / 2
				for yy in merl:
					for xx in range(x0, mini(x0 + gw, w_px)):
						var c := img.get_pixel(xx, yy)
						c.a = 0.0
						img.set_pixel(xx, yy, c)
			var win_dark := Color(0.08, 0.08, 0.11)
			if gate_mode:
				# 居中拱形门洞（直壁 + 半圆拱；洞底贴纹理底边）——
				# 视觉洞形与原 GateOpening（24 宽 × 64 高）对齐：直壁 52 + 半圆 12
				StoneBrickGen.carve_arch_opening(img, w_px / 2, h - 1, 12, 52, Color(0.12, 0.09, 0.08))
			elif wall_kind == 2:
				# 标准石墙：墙身中上部一条箭缝窗
				StoneBrickGen.carve_arch_opening(img, w_px / 2, merl + 62, ARROW_HALF_W, ARROW_H, win_dark)
			else:
				# 大型石墙：上下两条箭缝窗（中段留给石带）
				StoneBrickGen.carve_arch_opening(img, w_px / 2, merl + 58, ARROW_HALF_W, ARROW_H, win_dark)
				StoneBrickGen.carve_arch_opening(img, w_px / 2, h - 26, ARROW_HALF_W, ARROW_H, win_dark)
		tex = _stone_tex_from(img, key)
	var body := _sprite2d("WallBody", Vector2(cx, -float(h + (MERLON_H + (4 if wall_kind == 3 else 0))) * 0.5), tex)
	body.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(l1, body)

	# ── L2 后层挂件 ──
	var l2 := _nc("L2_BackItems", ext)
	if wall_kind == 1:
		# 夯土墙顶草皮帽（straw 纹理染绿，Sprite2D 笔触可靠）
		var turf := _sprite2d("TurfCap", Vector2(cx, -float(T1_H) + 4.0),
			TextureGenAPI.make_straw_thatch(w_px, 11, Color(0.40, 0.50, 0.26)))
		turf.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_a(l2, turf)

	# ── L4 前景挂件 ──
	var l4 := _nc("L4_FrontWall", ext)
	if wall_kind == 3:
		# 大墙双石带：蓝灰整石腰线（同色系取自调色板，微压暗退半步）
		for i in 2:
			var band := _stone_band(l4, "Band%d" % i, Vector2(cx, -float(T3_H) * (0.62 - 0.34 * float(i))),
				w_px, 12, SEED + 3 + i)
			band.self_modulate = Color(0.85, 0.85, 0.90)
	if gate_mode:
		_build_gate_door(l4, cx, pal)

	_post_build(ext)


## 城门木门板（掩在门洞内的双开板门，关闭态）：纯色几何 + 板缝线（窄门细节从简）。
func _build_gate_door(parent: Node2D, cx: float, pal: Dictionary) -> void:
	var root := _nc("GateDoor", parent)
	root.position = Vector2(cx, 0)
	var wood: Color = pal.get("C_WOOD_BEAM", Color(0.30, 0.21, 0.12))
	# 门板：直壁 + 小拱顶（比门洞各边缩 2px，露出洞深）
	var half := 10.0
	var body_h := 50.0
	var door := Polygon2D.new()
	door.name = "Door"
	door.polygon = PackedVector2Array([
		Vector2(-half, 0), Vector2(-half, -body_h),
		Vector2(-half * 0.72, -body_h - 5.0), Vector2(0, -body_h - 8.0),
		Vector2(half * 0.72, -body_h - 5.0), Vector2(half, -body_h),
		Vector2(half, 0)])
	door.color = wood
	root.add_child(door)
	# 中缝（双开门）+ 横板条 ×2
	var seam := Line2D.new()
	seam.name = "Seam"
	seam.points = PackedVector2Array([Vector2(0, -8), Vector2(0, -body_h - 4.0)])
	seam.width = 1.6
	seam.default_color = wood.darkened(0.45)
	root.add_child(seam)
	for i in 2:
		var bar := Line2D.new()
		bar.name = "Plank%d" % i
		var y := -16.0 - float(i) * 22.0
		bar.points = PackedVector2Array([Vector2(-half + 2, y), Vector2(half - 2, y)])
		bar.width = 1.6
		bar.default_color = wood.darkened(0.35)
		root.add_child(bar)
	# 门环铁件 ×2
	var iron := Color(0.20, 0.20, 0.23)
	for i in 2:
		var ring := Polygon2D.new()
		ring.name = "Ring%d" % i
		var px := -half * 0.5 if i == 0 else half * 0.5
		ring.polygon = PackedVector2Array([
			Vector2(px - 1.5, -30), Vector2(px + 1.5, -30),
			Vector2(px + 1.5, -40), Vector2(px - 1.5, -40)])
		ring.color = iron
		root.add_child(ring)
