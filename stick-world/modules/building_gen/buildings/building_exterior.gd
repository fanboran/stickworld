@tool
class_name BuildingExterior
extends Building
## 程序化建筑外观装配器 —— 铁匠铺/兵营/仓库三兄弟公共实现（2026-08 去重）。
##
## 三个建筑脚本原先 133 行逐字节相同（仅 7 个颜色常量不同），
## 现统一为：本基类承载全部节点装配/纹理生成/helper 逻辑，子类只提供调色板。
##
## 子类提供：
##   场景根节点注入 palette（BuildingPalette .tres，7 色，键名见 BuildingPalette）。


## 子类调色板（BuildingPalette .tres；未注入时构建外观将告警并跳过）
@export var palette: BuildingPalette


## 调色板字典视图（消费点按键取色的统一入口）
func _get_palette() -> Dictionary:
	if palette == null:
		return {}
	return {
		"C_THATCH_BACK": palette.C_THATCH_BACK,
		"C_THATCH_MAIN": palette.C_THATCH_MAIN,
		"C_THATCH_LEFT": palette.C_THATCH_LEFT,
		"C_WOOD_FRONT": palette.C_WOOD_FRONT,
		"C_WOOD_BACK": palette.C_WOOD_BACK,
		"C_WOOD_BEAM": palette.C_WOOD_BEAM,
		"C_WOOD_STRUT": palette.C_WOOD_STRUT,
		# 石作三色（批次 2；旧 .tres 缺这些键时由脚本默认值兜底，向后兼容）
		"C_STONE_MAIN": palette.C_STONE_MAIN,
		"C_STONE_DARK": palette.C_STONE_DARK,
		"C_STONE_JOINT": palette.C_STONE_JOINT,
	}


# 纹理尺寸
const BW_TEX_W = 222; const BW_TEX_H = 102
const BP_TEX_W = 20;  const BP_TEX_H = 197
const FP_TEX_W = 21;  const FP_TEX_H = 246
const BM_TEX_W = 292; const BM_TEX_H = 16
const VS_TEX_W = 23;  const VS_TEX_H = 117
const SS_TEX_W = 144; const SS_TEX_H = 20

## 外观布局：左组合体锚左边界（固定）、右组合体锚右边界、中间拉伸。
## Exterior 节点在建筑内 position.x = 245，故建筑左边缘在 Exterior 局部 = -245，
## 右边缘 = width*32 - 245。
const EXT_OFFSET_X := 245.0
## 16 格（width=16）时右边界在 Exterior 局部坐标 = 512 - 245 = 267
const RIGHT_EDGE_16 := 267.0
## 前柱间距（原始 -205 / -0.5 / 204，间距 204.5）
const FRONT_PITCH := 204.5
## 后柱间距（原始 -166 / 166，间距 332）
const BACK_PITCH := 332.0

## 在固定左柱与右锚柱之间按给定间距均匀铺中间柱（间距上下浮动不大）。
## fixed_xs：左组合体固定柱位置；right_x：右锚柱位置；pitch：期望间距。
func _fill_pillars(fixed_xs: Array, right_x: float, pitch: float) -> Array:
	var xs: Array = fixed_xs.duplicate()
	var last: float = float(fixed_xs[fixed_xs.size() - 1])
	var mid_span: float = right_x - last
	if mid_span <= 0.0:
		xs.append(right_x)
		return xs
	var n_mid: int = maxi(0, int(round(mid_span / pitch)) - 1)
	for i in range(1, n_mid + 1):
		xs.append(last + mid_span * (float(i) / float(n_mid + 1)))
	xs.append(right_x)
	return xs


func _ready() -> void:
	super()
	_build_exterior()
	_apply_state_visual()


## 按当前 width 重建外观（ConstructionProject 注入实际宽度后调用）。
## 场景默认 width 与建造时拉伸出的宽度不同时，外观需按最终宽度重新生成。
## 注意：必须立即 remove_child 再释放——queue_free 是帧末才移除，_build_exterior
## 的"已有子节点则跳过"守卫会误判为未清空而跳过重建。
func rebuild_exterior() -> void:
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	for child in ext.get_children():
		ext.remove_child(child)
		child.queue_free()
	_build_exterior()
	_apply_state_visual()


func _build_exterior() -> void:
	var pal := _get_palette()
	if pal.is_empty():
		push_warning("[BuildingExterior] %s 未提供调色板（_get_palette 返回空）" % name)
		return
	var ext := get_node_or_null("Exterior") as Node2D
	if ext == null:
		return
	# 只在首次构建（避免编辑器反复重建）
	if ext.get_child_count() > 0:
		return
	# 布局：左组合体锚左边界（不动）、右组合体锚右边界、中间拉伸
	var right_edge: float = float(width) * 32.0 - EXT_OFFSET_X

	# 生成纹理
	var tex_bw   = TextureGenAPI.make_straw_thatch(BW_TEX_W, BW_TEX_H, pal.C_THATCH_BACK)
	var tex_bp   = TextureGenAPI.make_wood_pillar(BP_TEX_W, BP_TEX_H, pal.C_WOOD_BACK)
	var tex_fp   = TextureGenAPI.make_wood_pillar(FP_TEX_W, FP_TEX_H, pal.C_WOOD_FRONT)
	var tex_bm   = TextureGenAPI.make_wood_pillar(BM_TEX_W, BM_TEX_H, pal.C_WOOD_BEAM)
	var tex_vs   = TextureGenAPI.make_wood_pillar(VS_TEX_W, VS_TEX_H, pal.C_WOOD_BEAM)
	var tex_ss   = TextureGenAPI.make_wood_pillar(SS_TEX_W, SS_TEX_H, pal.C_WOOD_STRUT)
	var tex_sb   = _make_slanted_beam_tex(pal.C_WOOD_BEAM)
	var tex_th_main  = TextureGenAPI.make_straw_thatch(64, 64, pal.C_THATCH_MAIN)
	var tex_th_left  = TextureGenAPI.make_straw_thatch(64, 64, pal.C_THATCH_LEFT)

	# ── L1 后景墙（左端固定 + 右端锚右边界 + 中间拉伸）──
	var l1 := _nc("L1_BackWall", ext)
	# 后墙顶多边形：左点固定、右点锚右边界（保留原右端斜度）
	_a(l1, _poly4("BackWallTop",
		Vector2(-53, -210), Vector2(right_edge - (RIGHT_EDGE_16 - 227.0), -210),
		Vector2(right_edge - (RIGHT_EDGE_16 - 150.0), -330), Vector2(13, -330), tex_bw))
	# 后柱：BackPillarL 固定 -166、BackPillarR 锚右边界、中间按间距铺
	var back_xs: Array = _fill_pillars([-166.0], right_edge - (RIGHT_EDGE_16 - 166.0), BACK_PITCH)
	for i in back_xs.size():
		_a(l1, _sprite2d("BackPillar%d" % i, Vector2(back_xs[i], -124), tex_bp))

	# ── L2 / L3 空层（预留内部物品）──
	_nc("L2_BackItems", ext)
	_nc("L3_FrontItems", ext)

	# ── L4 前景柱（左组合体固定 + 右柱锚右边界 + 中间按间距铺）──
	var l4 := _nc("L4_FrontWall", ext)
	var front_xs: Array = _fill_pillars([-205.0, -0.5], right_edge - (RIGHT_EDGE_16 - 204.0), FRONT_PITCH)
	for i in front_xs.size():
		_a(l4, _sprite2d("FrontPillar%d" % i, Vector2(front_xs[i], -123), tex_fp))

	# ── L5 屋顶（左组合体固定、右组合体锚右、RoofMain 中间拉伸）──
	# 绘制顺序与原始手稿一致：SlantedBeam → VerticalStrut → Beam → RoofMain → SlantedStrut → RoofLeftGroup1（最上层）
	var l5 := _nc("L5_Roof", ext)
	# 左组合体（固定）
	_a(l5, _sprite2d("SlantedBeam", Vector2(60, -258), tex_sb, 0.712094, Vector2(1, 0.491)))
	_a(l5, _sprite2d("VerticalStrut", Vector2(37.5, -281.5), tex_vs))

	# 中间拉伸体：Beam（左锚左组、右锚右组）
	var beam_left: float = -65.0
	var beam_right: float = right_edge - (RIGHT_EDGE_16 - 227.0)
	var beam_center_x: float = (beam_left + beam_right) * 0.5
	var beam_w: float = maxf(beam_right - beam_left, 8.0)
	_a(l5, _sprite2d("Beam", Vector2(beam_center_x, -229), tex_bm, 0.0, Vector2(beam_w / float(BM_TEX_W), 1.0)))

	# RoofMain（节点 0/5 固定、1/2/3/4 锚右，0-1 与 4-5 线段拉长）
	var rm_poly: PackedVector2Array = [
		Vector2(59.796, -346),                                  # 0 固定(左上)
		Vector2(right_edge - (RIGHT_EDGE_16 - 164.909), -346),  # 1 锚右
		Vector2(right_edge - (RIGHT_EDGE_16 - 245.909), -206),  # 2 锚右
		Vector2(right_edge - (RIGHT_EDGE_16 - 209.909), -206),  # 3 锚右
		Vector2(right_edge - (RIGHT_EDGE_16 - 194.957), -232),  # 4 锚右
		Vector2(125.844, -232),                                 # 5 固定(左下)
	]
	var rm_uv: PackedVector2Array = [
		Vector2(0, 0), Vector2(1, 0), Vector2(1, 1),
		Vector2(0.75, 1), Vector2(0.65, 0.35), Vector2(0.2, 0.35),
	]
	_a(l5, _poly("RoofMain", rm_poly, rm_uv, tex_th_main))

	# 左组合体（续）：SlantedStrut / RoofLeftGroup1（最上层）
	_a(l5, _sprite2d("SlantedStrut", Vector2(80.34, -290.65), tex_ss, 1.047))
	var rl1 := _poly("RoofLeftGroup1", PackedVector2Array([
		Vector2(-182, -361), Vector2(59, -361), Vector2(-44, -182), Vector2(-285, -182),
	]), PackedVector2Array([Vector2(0, 0), Vector2(3.765625, 0), Vector2(3.765625, 1), Vector2(0, 1)]), tex_th_left)
	rl1.position = Vector2(-6, 3)
	_a(l5, rl1)

	# 子类差异化挂件（旗帜/货箱等；2026-08-22 兵营/仓库脱离共用外壳）
	_post_build(ext)


## 子类可选覆盖：在标准外壳构建完成后追加差异化挂件。
## ext 为 Exterior 节点；调色板经 _get_palette() 自取。PLACEHOLDER 素材（程序化几何），
## 替换清单见 docs/项目/待办事项.md「PLACEHOLDER 素材替换」。
func _post_build(_ext: Node2D) -> void:
	pass


# ── helpers ──

func _nc(node_name: String, parent: Node2D) -> Node2D:
	var n := Node2D.new()
	n.name = node_name
	parent.add_child(n)
	return n

func _a(parent: Node, child: Node) -> void:
	parent.add_child(child)

func _sprite2d(node_name: String, pos: Vector2, tex, rot: float = 0.0, sc: Vector2 = Vector2(1, 1)) -> Sprite2D:
	var s := Sprite2D.new()
	s.name = node_name; s.centered = true
	s.position = pos; s.texture = tex; s.rotation = rot; s.scale = sc
	return s

func _poly4(node_name: String, top_left: Vector2, top_right: Vector2, bottom_right: Vector2, bottom_left: Vector2, tex) -> Polygon2D:
	return _poly(node_name, PackedVector2Array([top_left, top_right, bottom_right, bottom_left]), _full_uv(4), tex)

func _poly(node_name: String, pts: PackedVector2Array, uvs: PackedVector2Array, tex) -> Polygon2D:
	var p := Polygon2D.new()
	p.name = node_name; p.polygon = pts; p.uv = uvs; p.texture = tex
	return p

func _full_uv(n: int) -> PackedVector2Array:
	match n:
		4: return PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
		6: return PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0.75, 1), Vector2(0.65, 0.35), Vector2(0.2, 0.35)])
	return PackedVector2Array()

func _make_slanted_beam_tex(color: Color) -> ImageTexture:
	var slant  := 64.0
	var height := 110.0
	var length := sqrt(slant * slant + height * height)
	return TextureGenAPI.make_wood_pillar(23, ceili(length), color)


# ═══════════════ 石作装配（批次 2：石头结构件化） ═══════════════
# 材质路径结论（详见交接档「渲染环境关键发现」）：本环境 Polygon2D 的纹理 uv
# 采样与 ShaderMaterial 均坍缩为平均色（tools/baking/render_stone_probe.gd 实测），
# Sprite2D 是唯一可靠显示路径。石作一律 CPU 生成纹理（StoneBrickGen）+ Sprite2D。

## 石作纹理静态缓存（跨实例/跨建筑复用；key 含尺寸/seed/色板摘要）
static var _stone_tex_cache: Dictionary = {}

## 石墙基准砖尺寸（像素，桌面结构件观感）
const STONE_BRICK := Vector2i(56, 28)


## 从调色板组装 StoneBrickGen 色板 dict（light 由 MAIN 提亮派生，保证同色系）
func _stone_palette() -> Dictionary:
	var pal := _get_palette()
	var main: Color = pal.get("C_STONE_MAIN", Color(0.62, 0.585, 0.52))
	return {
		"light": main.lightened(0.10),
		"mid": main,
		"dark": pal.get("C_STONE_DARK", Color(0.45, 0.42, 0.37)),
		"mortar": pal.get("C_STONE_JOINT", Color(0.33, 0.30, 0.26)),
	}


static func _stone_cache_key(mode: String, w: int, h: int, seed_value: int, spal: Dictionary) -> String:
	var ck := ""
	for k: String in ["light", "mid", "dark", "mortar"]:
		var c: Color = spal[k]
		ck += "%d_%d_%d;" % [int(c.r8), int(c.g8), int(c.b8)]
	return "%s_%d_%d_%d_%s" % [mode, w, h, seed_value, ck]


## Image → ImageTexture（进静态缓存；同参数重复装配零开销）
func _stone_tex_from(img: Image, key: String) -> ImageTexture:
	if _stone_tex_cache.has(key):
		return _stone_tex_cache[key]
	var tex := ImageTexture.create_from_image(img)
	_stone_tex_cache[key] = tex
	return tex


## 生成石墙面 Image（未缓存版，供开洞/角石等定制面在手改后自行 _stone_tex_from）
func _stone_wall_img(w: int, h: int, seed_value: int) -> Image:
	return StoneBrickGen.make_wall(w, h, seed_value, STONE_BRICK, false, _stone_palette())


## 整面石墙纹理（缓存版）
func _stone_wall_tex(w: int, h: int, seed_value: int) -> ImageTexture:
	var spal := _stone_palette()
	return _stone_tex_from(
		StoneBrickGen.make_wall(w, h, seed_value, STONE_BRICK, false, spal),
		_stone_cache_key("wall", w, h, seed_value, spal))


## 垛口石墙纹理（顶部城垛 alpha 镂空；墙身 h + 垛口 merlon_h）
func _stone_crenellated_tex(w: int, h: int, seed_value: int, merlon_h: int = 30) -> ImageTexture:
	var spal := _stone_palette()
	return _stone_tex_from(
		StoneBrickGen.make_crenellated(w, h, seed_value, merlon_h, 56, STONE_BRICK, spal),
		_stone_cache_key("cren_%d" % merlon_h, w, h, seed_value, spal))


## 石带纹理（蓝灰整石腰线 + 滴水痕；与暖石墙面对比出楼层分隔）
func _stone_band_tex(w: int, h: int, seed_value: int) -> ImageTexture:
	var spal := _stone_palette()
	return _stone_tex_from(
		StoneBrickGen.make_band(w, h, seed_value, {}, Vector2i(maxi(w / 4, 60), maxi(h, 20))),
		_stone_cache_key("band", w, h, seed_value, spal))


## 石墙段 Sprite2D（centered 于 pos）
func _stone_wall(parent: Node2D, node_name: String, pos: Vector2,
		w: int, h: int, seed_value: int) -> Sprite2D:
	var s := _sprite2d(node_name, pos, _stone_wall_tex(w, h, seed_value))
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, s)
	return s


## 垛口石墙段 Sprite2D（centered 于 pos；纹理含顶部垛口，故 Sprite 顶对齐 pos.y - h）
func _stone_crenellated(parent: Node2D, node_name: String, pos: Vector2,
		w: int, h: int, seed_value: int, merlon_h: int = 30) -> Sprite2D:
	var s := _sprite2d(node_name, pos, _stone_crenellated_tex(w, h, seed_value, merlon_h))
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, s)
	return s


## 石带 Sprite2D（centered 于 pos）
func _stone_band(parent: Node2D, node_name: String, pos: Vector2,
		w: int, h: int, seed_value: int) -> Sprite2D:
	var s := _sprite2d(node_name, pos, _stone_band_tex(w, h, seed_value))
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, s)
	return s


# ═══════════════ 多层装配结构件（批次 3：Layers[0..N] 二层框架） ═══════════════
# 设计图纸：docs/技术/架构/建筑模块化设计.md §三 Layers[0..N] / §十五 B3 楼梯模块。
# 全部结构件沿用批次 2 定案：贴纹理面一律 Sprite2D + CPU 纹理（Polygon2D uv 采样
# 在本环境坍缩），纯色块几何（Polygon2D 无 texture / Line2D）安全。
# 消费范例：manor.gd（二层半木悬挑宅邸）。

## 坡面纹理：layered 茅草按梯形/平行四边形坡面逐行裁剪、坡面外透明，Sprite2D 显示。
## 四个占比参数为顶行/底行左右边界（0..1 相对包围盒宽），行间线性过渡。
## （原 smithy_lv1._make_slope_thatch_tex，批次 3 提升为基类通用件）
func _slope_thatch_tex(w: int, h: int, top_l: float, top_r: float, bot_l: float, bot_r: float, seed_value: int) -> ImageTexture:
	var src := TextureGenAPI.make_thatch_layered(w, h, seed_value).get_image()
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var t := float(y) / float(h - 1)  # 0=顶 1=底
		var left := int(round(w * lerpf(top_l, bot_l, t)))
		var right := int(round(w * lerpf(top_r, bot_r, t)))
		for x in range(left, right):
			var c := src.get_pixel(x, y)
			c.a = 1.0
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)


## 灰泥/泥灰墙面纹理（半木结构底色；细噪点+轻水平污渍带，避免大面积平涂死板）
func _plaster_tex(w: int, h: int, seed_value: int, base: Color) -> ImageTexture:
	var key := "plaster_%d_%d_%d_%d_%d_%d" % [w, h, seed_value, int(base.r8), int(base.g8), int(base.b8)]
	if _stone_tex_cache.has(key):
		return _stone_tex_cache[key]
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for y in h:
		var band := 1.0 + 0.03 * sin(float(y) * 0.05 + float(seed_value % 7))
		for x in w:
			var c := base * (band + rng.randf_range(-0.045, 0.045))
			c.a = 1.0
			img.set_pixel(x, y, c)
	var tex := ImageTexture.create_from_image(img)
	_stone_tex_cache[key] = tex
	return tex


## 灰泥墙面 Sprite2D（centered 于 pos）
func _plaster_wall(parent: Node2D, node_name: String, pos: Vector2,
		w: int, h: int, seed_value: int, base: Color) -> Sprite2D:
	var s := _sprite2d(node_name, pos, _plaster_tex(w, h, seed_value, base))
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_a(parent, s)
	return s


## 半木结构框架（叠加在灰泥墙前景）：竖柱按间距均布 + 顶/底横梁 + 跨间交替斜撑。
## x_l/x_r/y_top/y_bot 为墙面四缘（局部坐标，y 向上为负）。
func _timber_frame(parent: Node2D, node_name: String, x_l: float, x_r: float,
		y_top: float, y_bot: float, stud_pitch: float, pal: Dictionary) -> Node2D:
	var root := _nc(node_name, parent)
	var beam: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var w := int(x_r - x_l)
	var h := int(y_bot - y_top)
	var cy := (y_top + y_bot) * 0.5
	# 顶/底横梁（板纹）
	_a(root, _sprite2d("BeamTop", Vector2((x_l + x_r) * 0.5, y_top + 9.0),
		TextureGenAPI.make_wood_plank(w, 18, beam)))
	_a(root, _sprite2d("BeamBottom", Vector2((x_l + x_r) * 0.5, y_bot - 9.0),
		TextureGenAPI.make_wood_plank(w, 18, beam)))
	# 竖柱（柱纹，两端嵌进横梁）
	var stud_tex := TextureGenAPI.make_wood_pillar(16, h + 8, beam)
	var xs: Array = _fill_pillars([x_l + 8.0], x_r - 8.0, stud_pitch)
	for i in xs.size():
		_a(root, _sprite2d("Stud%d" % i, Vector2(xs[i], cy), stud_tex))
	# 跨间斜撑（交替方向，柱纹斜放；纯剪影构件）
	if xs.size() >= 2:
		var diag_len := sqrt(stud_pitch * stud_pitch * 0.64 + (h * 0.55) * (h * 0.55))
		var diag_tex := TextureGenAPI.make_wood_pillar(12, ceili(diag_len), beam.darkened(0.15))
		for i in range(xs.size() - 1):
			var cx: float = (float(xs[i]) + float(xs[i + 1])) * 0.5
			var dy := h * 0.55
			var dx := stud_pitch * 0.8
			var s := _sprite2d("Brace%d" % i, Vector2(cx, cy),
				diag_tex, atan2(-dy, dx) if i % 2 == 0 else atan2(dy, dx))
			s.flip_h = i % 2 == 1
			_a(root, s)
	return root


## 悬挑楼板（上层比下层出挑的 jettying）：出挑底板 + 底部交替托架斜撑。
## y_face = 上层地面（板顶面）；板厚向下 16。
func _jetty_slab(parent: Node2D, node_name: String, x_l: float, x_r: float,
		y_face: float, pal: Dictionary) -> Node2D:
	var root := _nc(node_name, parent)
	var front: Color = pal.get("C_WOOD_FRONT", Color(0.52, 0.36, 0.19))
	var beam: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var w := int(x_r - x_l)
	var cx := (x_l + x_r) * 0.5
	# 托架斜撑（先画，藏在板后；直角贴下层墙面、斜边托板底）
	var span := x_r - x_l
	var n_brace := clampi(int(span / 130.0), 2, 4)
	for i in n_brace:
		var bx := lerpf(x_l + 46.0, x_r - 46.0, float(i) / float(n_brace - 1))
		var brace := Polygon2D.new()
		brace.name = "Brace%d" % i
		var lean := 34.0 if i % 2 == 0 else -34.0
		brace.polygon = PackedVector2Array([
			Vector2(bx, y_face + 16.0),
			Vector2(bx + lean, y_face + 16.0),
			Vector2(bx, y_face + 50.0),
		])
		brace.color = beam
		root.add_child(brace)
	# 出挑底板（板纹，厚 16）
	_a(root, _sprite2d("Slab", Vector2(cx, y_face + 8.0),
		TextureGenAPI.make_wood_plank(w, 16, front)))
	return root


## 阳台：平台板 + 栏杆（扶手+竖栏柱）+ 底部托架斜撑。y_face = 阳台地面。
func _balcony(parent: Node2D, node_name: String, x_l: float, x_r: float,
		y_face: float, pal: Dictionary) -> Node2D:
	var root := _nc(node_name, parent)
	var front: Color = pal.get("C_WOOD_FRONT", Color(0.52, 0.36, 0.19))
	var beam: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var w := int(x_r - x_l)
	var cx := (x_l + x_r) * 0.5
	# 托架斜撑 ×2（板底向前下撑）
	for i in 2:
		var bx := lerpf(x_l + 30.0, x_r - 30.0, float(i))
		var brace := Polygon2D.new()
		brace.name = "Brace%d" % i
		brace.polygon = PackedVector2Array([
			Vector2(bx, y_face + 12.0), Vector2(bx + 26.0, y_face + 12.0),
			Vector2(bx, y_face + 46.0)])
		brace.color = beam
		root.add_child(brace)
	# 平台板（板纹，厚 12）
	_a(root, _sprite2d("Slab", Vector2(cx, y_face + 6.0),
		TextureGenAPI.make_wood_plank(w, 12, front)))
	# 栏杆：竖栏柱（柱纹细杆）+ 扶手（板纹细条）
	var post_tex := TextureGenAPI.make_wood_pillar(6, 38, beam)
	var post_n := clampi(int(w / 24.0), 3, 10)
	for i in post_n:
		var px := lerpf(x_l + 4.0, x_r - 4.0, float(i) / float(post_n - 1))
		_a(root, _sprite2d("Post%d" % i, Vector2(px, y_face - 19.0), post_tex))
	_a(root, _sprite2d("Handrail", Vector2(cx, y_face - 38.0),
		TextureGenAPI.make_wood_plank(w, 7, front)))
	return root


## 外部木楼梯（B3 楼梯模块 P0：层间通行可见件）——实心阶梯剖面（纯色块）+
## 斜侧梁 + 扶手。从 (x_start, 0) 地面向 x 正方向爬升 rise_total，
## 顶面落在 y = -rise_total（对接上层楼面）。
func _exterior_stairs(parent: Node2D, node_name: String, x_start: float,
		steps: int, step_w: float, rise_total: float, pal: Dictionary) -> Node2D:
	var root := _nc(node_name, parent)
	var front: Color = pal.get("C_WOOD_FRONT", Color(0.52, 0.36, 0.19))
	var beam: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var step_h := rise_total / float(steps)
	# 阶梯剖面：第 i 级矩形从第 i 级顶面直落地面（实心，避免透出下层墙）
	for i in steps:
		var stair := Polygon2D.new()
		stair.name = "Step%d" % i
		var x0 := x_start + float(i) * step_w
		var y_top := -step_h * float(i + 1)
		stair.polygon = PackedVector2Array([
			Vector2(x0, 0.0), Vector2(x0 + step_w, 0.0),
			Vector2(x0 + step_w, y_top), Vector2(x0, y_top)])
		stair.color = front.darkened(0.08 + 0.012 * float(i % 3))
		root.add_child(stair)
		# 踏面亮线（板色提亮，强化台阶可读性）
		var tread := Line2D.new()
		tread.name = "Tread%d" % i
		tread.points = PackedVector2Array([
			Vector2(x0, y_top - 1.5), Vector2(x0 + step_w, y_top - 1.5)])
		tread.width = 3.0
		tread.default_color = front.lightened(0.22)
		root.add_child(tread)
	# 斜侧梁（沿阶梯斜边，柱纹旋转）
	var span := step_w * float(steps)
	var mid := Vector2(x_start + span * 0.5, -rise_total * 0.5)
	var length := sqrt(span * span + rise_total * rise_total)
	_a(root, _sprite2d("Stringer", mid,
		TextureGenAPI.make_wood_pillar(11, ceili(length) + 6, beam.darkened(0.1)),
		-atan2(rise_total, span)))
	# 扶手：平行于阶梯斜边的扶手条（上方 44）+ 竖扶手段 ×2
	var rail := Line2D.new()
	rail.name = "Rail"
	rail.points = PackedVector2Array([
		Vector2(x_start + 4.0, -44.0),
		Vector2(x_start + span - 4.0, -rise_total - 44.0)])
	rail.width = 5.0
	rail.default_color = beam
	root.add_child(rail)
	for i in 2:
		var t := 0.2 + 0.6 * float(i)
		var face_y := -rise_total * t          # 该处阶梯面 y
		var post := Polygon2D.new()
		post.name = "RailPost%d" % i
		var px := x_start + span * t
		post.polygon = PackedVector2Array([
			Vector2(px - 2.5, face_y), Vector2(px + 2.5, face_y),
			Vector2(px + 2.5, face_y - 44.0), Vector2(px - 2.5, face_y - 44.0)])
		post.color = beam
		root.add_child(post)
	return root


## 直棂窗（叠在墙面上的前景件）：木框 + 暗洞 + 竖棂 ×2。
## cx/cy_b 为窗洞中心 x 与窗洞底 y（向上开窗高 opening_h）。
func _mullion_window(parent: Node2D, node_name: String, cx: float, cy_bottom: float,
		half_w: float, opening_h: float, pal: Dictionary) -> Node2D:
	var root := _nc(node_name, parent)
	var beam: Color = pal.get("C_WOOD_BEAM", Color(0.34, 0.24, 0.14))
	var cy := cy_bottom - opening_h * 0.5
	# 木框（外矩形）+ 暗洞（内矩形缩 5）
	var frame := Polygon2D.new()
	frame.name = "Frame"
	frame.polygon = PackedVector2Array([
		Vector2(cx - half_w, cy_bottom + 5.0), Vector2(cx + half_w, cy_bottom + 5.0),
		Vector2(cx + half_w, cy_bottom - opening_h - 5.0), Vector2(cx - half_w, cy_bottom - opening_h - 5.0)])
	frame.color = beam
	root.add_child(frame)
	var hole := Polygon2D.new()
	hole.name = "Hole"
	var hw := half_w - 5.0
	var hh := opening_h * 0.5
	hole.polygon = PackedVector2Array([
		Vector2(cx - hw, cy + hh), Vector2(cx + hw, cy + hh),
		Vector2(cx + hw, cy - hh), Vector2(cx - hw, cy - hh)])
	hole.color = Color(0.09, 0.09, 0.12)
	root.add_child(hole)
	# 竖棂 ×2（暖灰白，逆光剪影可读）
	for i in 2:
		var mull := Line2D.new()
		mull.name = "Mullion%d" % i
		var mx := cx - hw * 0.34 + float(i) * hw * 0.68
		mull.points = PackedVector2Array([Vector2(mx, cy - hh + 2.0), Vector2(mx, cy + hh - 2.0)])
		mull.width = 2.5
		mull.default_color = Color(0.62, 0.58, 0.50)
		root.add_child(mull)
	return root
