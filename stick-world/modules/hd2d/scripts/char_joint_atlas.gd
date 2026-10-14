extends Node
## char_joint_atlas.gd —— 3D 化关节烘焙路线的预烘关节贴图图集（裁决#15）。
##
## 是什么：把 rig 矢量部件的几何（stickman_skeleton 同款 Line2D 圆头
## 线段 / 40 边 Polygon2D 圆）按部件逐件画进一个一次性 SubViewport，回读成
## 一张白色胶囊/圆图集（RGB 恒白、形状在 alpha；实例色染身体色）。
## 几何两遍（裁决#24）：填充 + 描边双格位（描边 = 加宽胶囊，环带宽承运
## 在贴图像素里——宿主 char_rig_3d._build_specs）。
## 观感与烘焙卡同源的关键：形状由**引擎画布光栅化器**烘出（与 SubViewport
## 烘焙卡同一光栅路径），不是着色器解析形状（SDF 已裁决#13 无意义）也不是
## CPU 手撸覆盖曲线。
##
## 格位尺寸量化（CELL_QUANT）：格位按 4px 向上取整——宿主 quad 尺寸用格位
## 尺寸（恒定），实际宽度由贴图像素承运（胶囊居中绘制），无拉伸。
## 规格（specs）由首个宿主从 rig 实建矢量节点申报（名称/长度/宽/半径，
## 构建期一次——填充几何运行期不变）。每 hd2d_world 一份实例
##（挂 char_direct_buckets 下，同 char_bar_atlas）。

const PAD := 3.0          # 格位间透明垫（双线性/低 mip 不吃邻格）
const CELL_QUANT := 4.0   # 格位尺寸量化步（rig px）
const SUPERSAMPLE := 2    # 烘焙超采样倍率（与烘焙卡 px_scale 同级）

## 已烘焙规格指纹——宿主申报规格变化才重烘（现状构建期一次）
var _fp := ""
## 格位表：name -> {"origin": Vector2, "cell": Vector2, "uv": Rect2}
##（发布版＝宿主可见版；烘焙期先落 _pending_cells，publish() 原子换入）
var _cells: Dictionary = {}
var _atlas_size := Vector2i.ZERO
var _pending_cells: Dictionary = {}
var _pending_size := Vector2i.ZERO
var _pending_tex: ImageTexture = null
var _ready := false
var _vp: SubViewport = null
var _tex: ImageTexture = null
var _baking := false
var _pending_specs: Array = []
var _version := 0


static var _placeholder_cache: ImageTexture = null


## 首帧占位（全透明：部件不写深度不上屏，图集就绪后自然现身）
static func _placeholder_tex() -> ImageTexture:
	if _placeholder_cache == null or not is_instance_valid(_placeholder_cache):
		_placeholder_cache = ImageTexture.create_from_image(
				Image.create(1, 1, false, Image.FORMAT_RGBA8))
	return _placeholder_cache


# ─────────────────────────── 宿主接口 ───────────────────────────

## 规格申报/重烘触发（宿主 build 调用）。specs 元素：
##   {"name": String, "circle": bool, "length": float, "w_fill": float,
##    "r_fill": float}——线段取 length/w_fill，圆取 r_fill。
func ensure(specs: Array) -> void:
	var fp := fingerprint(specs)
	if fp == _fp and not _baking:
		return
	if OS.get_environment("STICK_TRACE_ATLAS") == "1":
		print("[AtlasTrace] f=%d 重烘 specs=%d 旧指纹=%s 新指纹=%.40s…" % [
				Engine.get_process_frames(), specs.size(), _fp.left(40), fp])
	_pending_specs = specs
	if _baking:
		return   # 烘焙中：留最新规格，完成后自动续烘
	_fp = fp
	_bake(specs)


func fingerprint(specs: Array) -> String:
	var parts := PackedStringArray()
	for s in specs:
		if bool(s.get("circle", false)):
			parts.append("%s:c%.2f" % [s["name"], s["r_fill"]])
		else:
			parts.append("%s:s%.2f,%.2f" % [s["name"], s["length"], s["w_fill"]])
	return ",".join(parts)


## 槽位 UV 子矩形（归一化）
func uv_rect(name: String) -> Rect2:
	var e: Dictionary = _cells.get(name, {})
	return e.get("uv", Rect2())


## 格位尺寸（rig px，宿主 quad 缩放用——恒定值）
func cell_size(name: String) -> Vector2:
	var e: Dictionary = _cells.get(name, {})
	return e.get("cell", Vector2.ONE)


func texture() -> Texture2D:
	return _tex if _tex != null else _placeholder_tex()


func version() -> int:
	return _version


# ─────────────────────────── 预烘 ───────────────────────────

## 格位量化：尺寸向上取整到 CELL_QUANT 的倍数（+双边 PAD）
static func _quant(v: float) -> float:
	return ceilf((v + PAD * 2.0) / CELL_QUANT) * CELL_QUANT


## 烘焙主体（异步：画完等一帧回读；期间旧贴图照常服务）。**原子发布**：
## 回读成功只暂存待发布格位表/贴图，真正的换新由 buckets(1200) 每帧调
## publish() 执行——格位表与贴图同帧落地，宿主下一帧(1100)才见新格位，
## 杜绝「格位已换、贴图未绑」的单帧错配窗口（缩放档变化重烘时描边行
## 会用新 UV 采旧贴图＝闪一帧乱线）。
func _bake(specs: Array) -> void:
	_baking = true
	_layout(specs)
	_rebuild_children(specs)
	# 等视口渲出这一版再回读；视口未就绪（空图）时有限重试（同 char_bar_atlas
	# 回读节奏的经验：刚建/刚改尺寸的视口首帧可能未渲）
	var img: Image = null
	for _attempt in 4:
		await RenderingServer.frame_post_draw
		img = _vp.get_texture().get_image()
		if img != null and not img.is_empty():
			break
		img = null
	if img != null:
		_whiten_rgb(img)         # 先白化再生成 mip（见函数注释），否则部件外缘发暗
		img.generate_mipmaps()   # 远档缩小的平滑由 mip 链承担（同烘焙卡）
		if OS.get_environment("STICK_DUMP_ATLAS") == "1":
			var dump := "user://atlas_dump_%d.png" % Engine.get_process_frames()
			img.save_png(dump)
			print("[AtlasDump] ", ProjectSettings.globalize_path(dump),
					" size=", img.get_size())
		_pending_tex = ImageTexture.create_from_image(img)
		_ready = true            # 待 buckets publish()（首烘前占位贴图顶班）
	else:
		_fp = ""   # 烘焙失败：清指纹，宿主下帧重报
	_baking = false
	# 烘焙期间规格又变了（zoom 连续变化）：续烘最新版
	if _pending_specs != specs:
		var next: Array = _pending_specs
		_fp = fingerprint(next)
		_bake.call_deferred(next)


## 原子发布（buckets._process 每帧调）：把最近一次烘焙成果（格位表 + 贴图）
## 一次性落地并 bump 版本——宿主与材质绑定的取值永远来自同一次烘焙。
func publish() -> void:
	if not _ready:
		return
	_ready = false
	_cells = _pending_cells
	_atlas_size = _pending_size
	_tex = _pending_tex
	_version += 1


## 白化：图集 RGB 恒白是既定口径（`char3d_body_opaque` 里 `ALBEDO = t.rgb × 实例色`，
## 形状信息全在 alpha），但视口回读出来的形状外是**透明黑垫**（PAD 区、圆角外、
## 圆外一律 (0,0,0,0)）。`generate_mipmaps()` 逐级平均时会把这些黑 RGB 混进形状
## 边缘——部件外缘一圈 albedo 被压暗，深色身体上表现为"面片边缘还有更深色的描边"
## （创始人 2026-10-11 点正）。烘焙期先把 RGB 全刷白再生成 mip：alpha 仍承运形状，
## 任何 mip 级别的混合 RGB 都是白，边缘不再发暗。
## 代价：一次 O(w×h) 遍历（图集 ~2.8k×48 量级、每个 hd2d_world 实例烘一次）。
static func _whiten_rgb(img: Image) -> void:
	var white := Color(1.0, 1.0, 1.0, 1.0)
	for y in img.get_height():
		for x in img.get_width():
			# 只改 RGB、保留 alpha——形状仍由 alpha 承运
			var a := img.get_pixel(x, y).a
			img.set_pixel(x, y, Color(white.r, white.g, white.b, a))


## 布局：填充行 + 描边行横带。两步走：先量格位（行高/总宽），再落原点、
## 写**待发布**格位表（烘焙期私有），贴图回读成功后与格位表一起 publish
## 原子落地（宿主/材质绑定永远取到同一次烘焙的格位与贴图）。
func _layout(specs: Array) -> void:
	_pending_cells.clear()
	var h := 0.0
	var x := PAD
	for s in specs:
		var name: String = s["name"]
		var cell: Vector2
		if bool(s.get("circle", false)):
			cell = Vector2(_quant(s["r_fill"] * 2.0), _quant(s["r_fill"] * 2.0))
		else:
			cell = Vector2(_quant(s["length"] + s["w_fill"]), _quant(s["w_fill"]))
		_pending_cells[name] = {"origin": Vector2(x, PAD), "cell": cell, "uv": Rect2()}
		x += cell.x + PAD
		h = maxf(h, cell.y)
	_pending_size = Vector2i(int(ceil(x)), int(ceil(PAD * 2.0 + h)))
	if _vp == null:
		_vp = SubViewport.new()
		_vp.name = "JointBakeViewport"
		_vp.transparent_bg = true
		_vp.disable_3d = true
		_vp.msaa_2d = Viewport.MSAA_DISABLED   # MSAA 必须关：画布组缓冲直读出彩散（历史实测教训）
		_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		add_child(_vp)
	_vp.size = Vector2i(_pending_size.x * SUPERSAMPLE, _pending_size.y * SUPERSAMPLE)
	var aw := float(_pending_size.x)
	var ah := float(_pending_size.y)
	for e in _pending_cells.values():
		var cell: Vector2 = e["cell"]
		var org: Vector2 = e["origin"]
		e["uv"] = Rect2(org.x / aw, org.y / ah, cell.x / aw, cell.y / ah)


## 重建视口子件：每部件一填充形状（Line2D 圆头线段 / 40 边圆），白色、
## 居中画在格位内（实际宽度/半径承运在像素里，格位只是恒定外框）。
func _rebuild_children(specs: Array) -> void:
	if _vp == null:
		return
	for c in _vp.get_children():
		c.free()
	for s in specs:
		var name: String = s["name"]
		var e: Dictionary = _pending_cells[name]
		var center: Vector2 = (e["origin"] + (e["cell"] as Vector2) * 0.5) * SUPERSAMPLE
		var node: Node2D
		if bool(s.get("circle", false)):
			var r: float = s["r_fill"] * SUPERSAMPLE
			var poly := Polygon2D.new()
			var pts := PackedVector2Array()
			for i in range(40):
				var a := TAU * float(i) / 40.0
				pts.append(Vector2(cos(a), sin(a)) * r)
			poly.polygon = pts
			poly.color = Color.WHITE
			node = poly
		else:
			var length: float = s["length"] * SUPERSAMPLE
			var w: float = s["w_fill"] * SUPERSAMPLE
			var line := Line2D.new()
			line.points = PackedVector2Array([
				Vector2(-length * 0.5, 0.0), Vector2(length * 0.5, 0.0)])
			line.width = w
			line.default_color = Color.WHITE
			line.begin_cap_mode = Line2D.LINE_CAP_ROUND
			line.end_cap_mode = Line2D.LINE_CAP_ROUND
			node = line
		node.position = center
		_vp.add_child(node)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
