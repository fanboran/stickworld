@tool
extends BuildingExterior
## 议事厅（批次 5 变体二：地标级混合精修建筑）。
##
## 构图（对标《王国两位君主》镇中心地标建筑）：石砌基层（左右角石列 + 居中大拱门
## + 拱窗对）→ 宽悬挑楼板 + 二层半木框架灰泥墙（直棂窗 ×3）→ 深金茅草大坡双坡
## （v12 修长束笔触）→ 脊上钟楼（石塔身 + 钟窗 + 木构尖锥 + 旗帜）→ 左侧外部
## 木梯上二层阳台。全建筑集石作/半木/茅草/旗仪多材质于一身，为镇中最高天际线。
##
## 材质路径（批次 2 定案）：贴纹理面全走 Sprite2D + CPU 纹理；
## 装配复用批次 2/3 通用件（角石/石基 carve/半木框架/悬挑板/阳台/外梯/直棂窗）+
## 批次 5 通用件 _thatch_roof（v12 笔触）。
## 室内（批次 4 家具库）：议事长桌 ×2 + 长凳 ×4 + 火盆 ×2 + 武器架 + 地毯 + 挂串。

## 一层：石砌墙高
const STONE_H := 190
## 悬挑：二层比一层左右各出挑
const JETTY_OUT := 34
## 楼面标高
const FLOOR2_Y := -206.0
## 二层：半木墙高
const TIMBER_H := 150
## 屋顶：脊高与出挑
const RIDGE_Y := -560.0
const ROOF_OVERHANG := 30.0
## 钟楼（坐脊）：塔身宽/高 + 尖锥高
const TOWER_W := 110
const TOWER_H := 104
const SPIRE_H := 86
## 楼梯参数：级数/踏步宽/总高（顶面 = FLOOR2_Y）
const STAIR_STEPS := 12
const STAIR_STEP_W := 14.0
## 阳台范围（锚左出挑缘）
const BALCONY_SPAN := 236.0
## 纹理 seed
const GROUND_SEED := 47
const THATCH_SEED := 15
## v12 修长茅草笔触
const THATCH_V12 := {"slant": 0.42, "stretch": 1.9, "slender": 1.55, "taper_min": 0.45}


func _build_exterior() -> void:
	# 三重守卫（palette/ext/首次构建）
	var pal := _get_palette()
	if pal.is_empty():
		push_warning("[GrandHall] %s 未提供调色板" % name)
		return
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	if ext.get_child_count() > 0:
		return

	var right_edge: float = float(width) * 32.0 - EXT_OFFSET_X
	var left := -EXT_OFFSET_X
	var w1_px := int(right_edge - left)
	var l2_left := left - JETTY_OUT
	var l2_right := right_edge + JETTY_OUT
	var w2_px := int(l2_right - l2_left)
	var cx_mid := (left + right_edge) * 0.5
	var f2_top := FLOOR2_Y - float(TIMBER_H)
	var roof_l := left - ROOF_OVERHANG
	var roof_r := right_edge + ROOF_OVERHANG

	# ── L1 后景墙：石砌基层 + 二层灰泥底 ──
	var l1 := _nc("L1_BackWall", ext)
	_build_stone_ground(l1, w1_px, cx_mid)
	_plaster_wall(l1, "TimberWallBase", Vector2(cx_mid, (f2_top + FLOOR2_Y) * 0.5),
		w2_px, TIMBER_H, GROUND_SEED + 1, Color(0.80, 0.73, 0.60))

	# ── L2 后层挂件：半木框架 + 直棂窗 ×3 + 钟楼（坐脊，前坡盖不到）──
	var l2 := _nc("L2_BackItems", ext)
	_timber_frame(l2, "TimberFrame", l2_left, l2_right, f2_top, FLOOR2_Y, 92.0, pal)
	_mullion_window(l2, "Window1", cx_mid - 190.0, FLOOR2_Y - 44.0, 22.0, 56.0, pal)
	_mullion_window(l2, "Window2", cx_mid - 6.0, FLOOR2_Y - 34.0, 22.0, 56.0, pal)
	_mullion_window(l2, "Window3", cx_mid + 148.0, FLOOR2_Y - 34.0, 22.0, 56.0, pal)
	_build_belfry(l2, cx_mid, f2_top, pal)

	# ── L3 前景挂件：二层门板 + 阳台（外梯对接平台）──
	var l3 := _nc("L3_FrontItems", ext)
	_build_upper_door(l3, l2_left + 244.0, FLOOR2_Y, pal)
	_balcony(l3, "Balcony", l2_left, l2_left + BALCONY_SPAN, FLOOR2_Y, pal)

	# ── L4 前景：一层大门 + 外部楼梯 + 悬挑楼板 ──
	var l4 := _nc("L4_FrontWall", ext)
	_build_front_door(l4, cx_mid, pal)
	_exterior_stairs(l4, "Stairs", l2_left + 2.0, STAIR_STEPS, STAIR_STEP_W,
		-FLOOR2_Y, pal)
	_jetty_slab(l4, "JettySlab", l2_left, l2_right, FLOOR2_Y, pal)

	# ── L5 屋顶：v12 修长茅草双坡（沉金，地标庄重感）──
	var l5 := _nc("L5_Roof", ext)
	_thatch_roof(l5, roof_l, roof_r, f2_top, RIDGE_Y, cx_mid, THATCH_SEED,
		Color(0.85, 0.77, 0.62), THATCH_V12)

	_post_build(ext)


## 石砌基层：墙面 + 角石列（左右）+ 居中大拱门 + 门两侧拱窗
func _build_stone_ground(parent: Node2D, w_px: int, cx_mid: float) -> void:
	var spal := _stone_palette()
	var key := _stone_cache_key("hall_ground_v1", w_px, STONE_H, GROUND_SEED, spal)
	var tex: ImageTexture
	if _stone_tex_cache.has(key):
		tex = _stone_tex_cache[key]
	else:
		var img := StoneBrickGen.make_wall(w_px, STONE_H, GROUND_SEED, STONE_BRICK, false, spal)
		var w_center := int(float(w_px) * 0.5)
		var win_dark := Color(0.08, 0.08, 0.11)
		# 居中大拱门（直壁 96 + 半圆拱 44）
		StoneBrickGen.carve_arch_opening(img, w_center, STONE_H - 1, 44, 96, Color(0.10, 0.08, 0.08))
		# 门两侧拱窗
		StoneBrickGen.carve_arch_opening(img, w_center - 150, 104, 14, 44, win_dark)
		StoneBrickGen.carve_arch_opening(img, w_center + 150, 104, 14, 44, win_dark)
		# 左右角石列（英式砌法长短石交替）
		StoneBrickGen.add_quoins(img, true, spal, 26)
		StoneBrickGen.add_quoins(img, false, spal, 26)
		tex = _stone_tex_from(img, key)
	var s := _sprite2d("StoneGround", Vector2(cx_mid, -float(STONE_H) * 0.5), tex)
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, s)


## 一层大门（双开板条 + 门环，嵌在石砌拱门洞内）
func _build_front_door(parent: Node2D, cx_mid: float, pal: Dictionary) -> void:
	var root := _nc("FrontDoor", parent)
	root.position = Vector2(cx_mid, 0)
	var wood: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var half := 40.0
	var body_h := 94.0
	var door := Polygon2D.new()
	door.name = "Door"
	door.polygon = PackedVector2Array([
		Vector2(-half, 0), Vector2(-half, -body_h),
		Vector2(-half * 0.86, -body_h - 13.0), Vector2(-half * 0.5, -body_h - 34.0),
		Vector2(0, -body_h - 42.0), Vector2(half * 0.5, -body_h - 34.0),
		Vector2(half * 0.86, -body_h - 13.0), Vector2(half, -body_h), Vector2(half, 0)])
	door.color = wood
	root.add_child(door)
	var seam := Line2D.new()
	seam.name = "Seam"
	seam.points = PackedVector2Array([Vector2(0, -8), Vector2(0, -body_h - 30.0)])
	seam.width = 2.0
	seam.default_color = wood.darkened(0.45)
	root.add_child(seam)
	for i in 3:
		var bar := Line2D.new()
		bar.name = "Plank%d" % i
		var y := -22.0 - float(i) * 28.0
		bar.points = PackedVector2Array([Vector2(-half + 3, y), Vector2(half - 3, y)])
		bar.width = 2.0
		bar.default_color = wood.darkened(0.35)
		root.add_child(bar)
	# 门环铁件 ×2
	var iron := Color(0.20, 0.20, 0.23)
	for i in 2:
		var ring := Polygon2D.new()
		ring.name = "Ring%d" % i
		var px := -half * 0.55 if i == 0 else half * 0.55
		ring.polygon = PackedVector2Array([
			Vector2(px - 3, -50), Vector2(px + 3, -50),
			Vector2(px + 3, -64), Vector2(px - 3, -64)])
		ring.color = iron
		root.add_child(ring)


## 二层门板（对接阳台，平顶门 + 横板条 + 门楣）
func _build_upper_door(parent: Node2D, cx: float, floor_y: float, pal: Dictionary) -> void:
	var root := _nc("UpperDoor", parent)
	root.position = Vector2(cx, floor_y)
	var wood: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var half := 24.0
	var h := 54.0
	var door := Polygon2D.new()
	door.name = "Door"
	door.polygon = PackedVector2Array([
		Vector2(-half, 0), Vector2(-half, -h), Vector2(half, -h), Vector2(half, 0)])
	door.color = wood.lightened(0.08)
	root.add_child(door)
	for i in 2:
		var bar := Line2D.new()
		bar.name = "Plank%d" % i
		var y := -16.0 - float(i) * 18.0
		bar.points = PackedVector2Array([Vector2(-half + 2, y), Vector2(half - 2, y)])
		bar.width = 2.0
		bar.default_color = wood.darkened(0.4)
		root.add_child(bar)
	var lintel := Polygon2D.new()
	lintel.name = "Lintel"
	lintel.polygon = PackedVector2Array([
		Vector2(-half - 5.0, -h - 10.0), Vector2(half + 5.0, -h - 10.0),
		Vector2(half + 5.0, -h), Vector2(-half - 5.0, -h)])
	lintel.color = wood.darkened(0.2)
	root.add_child(lintel)


## 脊上钟楼：石塔身（钟窗 carve）+ 塔檐板 + 木构尖锥 + 旗杆三角旗。
## 塔底坐在脊梁上（RIDGE_Y），绘制顺序在屋顶前（L2），前坡/脊梁不遮挡。
func _build_belfry(parent: Node2D, cx_mid: float, f2_top: float, pal: Dictionary) -> void:
	var root := _nc("Belfry", parent)
	var spal := _stone_palette()
	var w_px := TOWER_W
	var key := _stone_cache_key("belfry_v1", w_px, TOWER_H, GROUND_SEED + 4, spal)
	var tex: ImageTexture
	if _stone_tex_cache.has(key):
		tex = _stone_tex_cache[key]
	else:
		var img := StoneBrickGen.make_wall(w_px, TOWER_H, GROUND_SEED + 4, STONE_BRICK, false, spal)
		StoneBrickGen.carve_arch_opening(img, w_px / 2, TOWER_H - 18, 15, 34, Color(0.07, 0.07, 0.10))
		tex = _stone_tex_from(img, key)
	var tower_y := RIDGE_Y - float(TOWER_H) * 0.5
	var tower := _sprite2d("TowerBody", Vector2(cx_mid, tower_y), tex)
	tower.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(root, tower)
	# 塔檐板（塔身与尖锥过渡）
	_a(root, _sprite2d("TowerCornice", Vector2(cx_mid, RIDGE_Y - float(TOWER_H) - 6.0),
		TextureGenAPI.make_wood_plank(TOWER_W + 22, 12, Color(0.33, 0.22, 0.12))))
	# 木构尖锥（三角，深木色 + 中棱亮线）
	var spire_base := RIDGE_Y - float(TOWER_H) - 12.0
	var spire := Polygon2D.new()
	spire.name = "Spire"
	spire.polygon = PackedVector2Array([
		Vector2(cx_mid - float(TOWER_W) * 0.5 - 6.0, spire_base),
		Vector2(cx_mid + float(TOWER_W) * 0.5 + 6.0, spire_base),
		Vector2(cx_mid, spire_base - float(SPIRE_H))])
	spire.color = Color(0.30, 0.19, 0.11)
	_a(root, spire)
	var ridge_line := Line2D.new()
	ridge_line.name = "SpireRidge"
	ridge_line.points = PackedVector2Array([
		Vector2(cx_mid, spire_base - float(SPIRE_H)), Vector2(cx_mid + float(TOWER_W) * 0.28, spire_base)])
	ridge_line.width = 2.5
	ridge_line.default_color = Color(0.46, 0.33, 0.19)
	_a(root, ridge_line)
	# 旗杆 + 三角旗（锥顶）
	var pole_top := spire_base - float(SPIRE_H)
	var pole := _sprite2d("Pole", Vector2(cx_mid, pole_top - 26.0),
		TextureGenAPI.make_wood_pillar(6, 52, Color(0.36, 0.25, 0.14)))
	_a(root, pole)
	var flag := Polygon2D.new()
	flag.name = "Flag"
	flag.polygon = PackedVector2Array([
		Vector2(cx_mid + 2.0, pole_top - 50.0), Vector2(cx_mid + 40.0, pole_top - 43.0),
		Vector2(cx_mid + 2.0, pole_top - 36.0)])
	flag.color = Color(0.60, 0.20, 0.15)
	_a(root, flag)


# ── 内饰（批次 4 家具库）：议事大厅布局 ──

func _furnish_floor(floor_node: Node2D) -> void:
	var w := float(width) * 32.0 - 24.0
	var slab := InteriorProps.make_floor(int(w), 24, Color(0.36, 0.27, 0.17))
	slab.position = Vector2(float(width) * 16.0, -12)
	floor_node.add_child(slab)


func _furnish_interior(props: Node2D) -> void:
	var w := float(width) * 32.0
	# 中轴：议事长桌 ×2 对拼 + 长凳 ×4（两侧）
	for i in 2:
		var table := InteriorProps.make_table("Table%d" % i, 150.0)
		table.position = Vector2(170.0 + float(i) * 160.0, 0)
		props.add_child(table)
	for i in 4:
		var bench := InteriorProps.make_bench("Bench%d" % i, 120.0)
		bench.position = Vector2(120.0 + float(i % 2) * 190.0, float(i / 2) * -52.0 - 34.0)
		props.add_child(bench)
	# 两侧火盆（暖光对称）
	for i in 2:
		var fire := InteriorProps.make_fire_basket("FireBasket%d" % i)
		fire.position = Vector2(74.0 + float(i) * 396.0, 0)
		props.add_child(fire)
	# 左墙武器架（卫队值房气）+ 右墙货架（文书档案）
	var rack := InteriorProps.make_weapon_rack("WeaponRack", 120.0)
	rack.position = Vector2(74.0, 0)
	props.add_child(rack)
	var shelf := InteriorProps.make_shelf("Shelf", 130.0, 150.0, 4, 31)
	shelf.position = Vector2(470.0, 0)
	props.add_child(shelf)
	# 地毯通铺（中轴）+ 后墙挂串（庆典饰）
	var rug := InteriorProps.make_rug("Rug", 300.0)
	rug.position = Vector2(250.0, -10)
	props.add_child(rug)
	var hang := InteriorProps.make_hang_string("HangBunting", Color(0.62, 0.34, 0.20))
	hang.position = Vector2(250.0, -260)
	props.add_child(hang)
