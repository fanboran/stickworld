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
