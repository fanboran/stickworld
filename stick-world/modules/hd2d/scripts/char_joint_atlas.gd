extends Node
## char_joint_atlas.gd —— 3D 化关节烘焙路线的预烘关节贴图图集（裁决#15）。
##
## 是什么：把 rig 矢量部件的几何（stickman_skeleton 同款 Line2D 圆头线段 /
## 40 边 Polygon2D 圆）按部件逐件画进一个一次性 SubViewport，回读成一张
## 白色胶囊/圆图集（RGB 恒白、形状在 alpha；实例色染描边白/填充身体色）。
## 3D 侧每部件一对 quad：描边贴图垫底（实深度 ZB_STROKE）、填充贴图置顶
## ——两遍层序照抄矢量「全局两遍」语义。观感与烘焙卡同源的关键：形状由
## **引擎画布光栅化器**烘出（与 SubViewport 烘焙卡同一光栅路径），不是
## 着色器解析形状（SDF 已裁决#13 无意义）也不是 CPU 手撸覆盖曲线。
##
## 格位尺寸量化（CELL_QUANT）：描边宽随 zoom 补偿微变（w+2×eff），格位按
## 4px 向上取整——补偿变化落在同格位内时 UV 不动，重烘只换贴图像素，
## 零闪变；跨格位（极深 zoom）才有一次 UV+贴图同帧换。宿主 quad 尺寸用
## 格位尺寸（恒定），实际描边宽由贴图像素承运（胶囊居中绘制），无拉伸。
##
## 规格（specs）由首个宿主从 rig 实建矢量节点申报（名称/长度/宽/半径），
## 宽度变化（zoom 补偿）由宿主按指纹懒触发重烘。每 hd2d_world 一份实例
##（挂 char_direct_buckets 下，同 char_bar_atlas）。

const PAD := 3.0          # 格位间透明垫（双线性/低 mip 不吃邻格）
const CELL_QUANT := 4.0   # 格位尺寸量化步（rig px）
const SUPERSAMPLE := 2    # 烘焙超采样倍率（与烘焙卡 px_scale 同级）

## 已烘焙规格指纹（宽度集哈希）——宿主逐帧比对，变化才重烘
var _fp := ""
## 格位表：_key(name, stroke) -> {"origin": Vector2, "cell": Vector2, "uv": Rect2}
var _cells: Dictionary = {}
var _atlas_size := Vector2i.ZERO
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

## 规格申报/重烘触发（宿主 build 与逐帧指纹比对调用）。specs 元素：
##   {"name": String, "circle": bool, "length": float, "w_stroke": float,
##    "w_fill": float, "r_stroke": float, "r_fill": float}
## 线段取 length/w_*，圆取 r_*（另一侧字段忽略）。
func ensure(specs: Array) -> void:
	var fp := fingerprint(specs)
	if fp == _fp and not _baking:
		return
	_pending_specs = specs
	if _baking:
		return   # 烘焙中：留最新规格，完成后自动续烘
	_fp = fp
	_bake(specs)


func fingerprint(specs: Array) -> String:
	var parts := PackedStringArray()
	for s in specs:
		if bool(s.get("circle", false)):
			parts.append("%s:c%.2f,%.2f" % [s["name"], s["r_stroke"], s["r_fill"]])
		else:
			parts.append("%s:s%.2f,%.2f,%.2f" % [s["name"], s["length"], s["w_stroke"], s["w_fill"]])
	return ",".join(parts)


## 槽位 UV 子矩形（归一化；stroke=true 描边格，false 填充格）
func uv_rect(name: String, stroke: bool) -> Rect2:
	var e: Dictionary = _cells.get(_key(name, stroke), {})
	return e.get("uv", Rect2())


## 格位尺寸（rig px，宿主 quad 缩放用——恒定值，不随 zoom 微变）
func cell_size(name: String, stroke: bool) -> Vector2:
	var e: Dictionary = _cells.get(_key(name, stroke), {})
	return e.get("cell", Vector2.ONE)


func texture() -> Texture2D:
	return _tex if _tex != null else _placeholder_tex()


func version() -> int:
	return _version


static func _key(name: String, stroke: bool) -> String:
	return "%s|%s" % [name, "s" if stroke else "f"]


# ─────────────────────────── 预烘 ───────────────────────────

## 格位量化：尺寸向上取整到 CELL_QUANT 的倍数（+双边 PAD）
static func _quant(v: float) -> float:
	return ceilf((v + PAD * 2.0) / CELL_QUANT) * CELL_QUANT


## 烘焙主体（异步：画完等一帧回读；期间旧贴图照常服务，完成后原子换新）
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
		img.generate_mipmaps()   # 远档缩小的平滑由 mip 链承担（同烘焙卡）
		_tex = ImageTexture.create_from_image(img)
		_version += 1
	else:
		_fp = ""   # 烘焙失败：清指纹，宿主下帧重报
	_baking = false
	# 烘焙期间规格又变了（zoom 连续变化）：续烘最新版
	if _pending_specs != specs:
		var next: Array = _pending_specs
		_fp = fingerprint(next)
		_bake.call_deferred(next)


## 布局：描边行 + 填充行两条横带。两遍走：先量格位（行高/总宽），
## 再落原点、写格位表（同步——宿主立刻取 UV/尺寸），贴图异步跟上。
func _layout(specs: Array) -> void:
	_cells.clear()
	var row_s: Array = []   # [name, cell(Vector2)]（描边行）
	var row_f: Array = []   # [name, cell]（填充行）
	for s in specs:
		var name: String = s["name"]
		if bool(s.get("circle", false)):
			row_s.append([name, Vector2(_quant(s["r_stroke"] * 2.0), _quant(s["r_stroke"] * 2.0))])
			row_f.append([name, Vector2(_quant(s["r_fill"] * 2.0), _quant(s["r_fill"] * 2.0))])
		else:
			var length: float = s["length"]
			row_s.append([name, Vector2(_quant(length + s["w_stroke"]), _quant(s["w_stroke"]))])
			row_f.append([name, Vector2(_quant(length + s["w_fill"]), _quant(s["w_fill"]))])
	var h_s := 0.0
	var h_f := 0.0
	for pair in row_s:
		h_s = maxf(h_s, pair[1].y)
	for pair in row_f:
		h_f = maxf(h_f, pair[1].y)
	var y_s := PAD
	var y_f := PAD + h_s + PAD
	var w := 0.0
	var x := PAD
	for pair in row_s:
		_cells[_key(pair[0], true)] = {"origin": Vector2(x, y_s), "cell": pair[1], "uv": Rect2()}
		x += pair[1].x + PAD
	w = maxf(w, x)
	x = PAD
	for pair in row_f:
		_cells[_key(pair[0], false)] = {"origin": Vector2(x, y_f), "cell": pair[1], "uv": Rect2()}
		x += pair[1].x + PAD
	w = maxf(w, x)
	_atlas_size = Vector2i(int(ceil(w)), int(ceil(y_f + h_f + PAD)))
	if _vp == null:
		_vp = SubViewport.new()
		_vp.name = "JointBakeViewport"
		_vp.transparent_bg = true
		_vp.disable_3d = true
		_vp.msaa_2d = Viewport.MSAA_DISABLED   # MSAA 必须关：画布组缓冲直读出彩散（历史实测教训）
		_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		add_child(_vp)
	_vp.size = Vector2i(_atlas_size.x * SUPERSAMPLE, _atlas_size.y * SUPERSAMPLE)
	var aw := float(_atlas_size.x)
	var ah := float(_atlas_size.y)
	for e in _cells.values():
		var cell: Vector2 = e["cell"]
		var org: Vector2 = e["origin"]
		e["uv"] = Rect2(org.x / aw, org.y / ah, cell.x / aw, cell.y / ah)


## 重建视口子件：每部件描边/填充各一形状（Line2D 圆头线段 / 40 边圆），
## 白色、居中画在格位内（实际宽度/半径承运在像素里，格位只是恒定外框）。
func _rebuild_children(specs: Array) -> void:
	if _vp == null:
		return
	for c in _vp.get_children():
		c.free()
	for s in specs:
		var name: String = s["name"]
		for stroke in [true, false]:
			var e: Dictionary = _cells[_key(name, stroke)]
			var center: Vector2 = (e["origin"] + (e["cell"] as Vector2) * 0.5) * SUPERSAMPLE
			var node: Node2D
			if bool(s.get("circle", false)):
				var r: float = (s["r_stroke"] if stroke else s["r_fill"]) * SUPERSAMPLE
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
				var w: float = (s["w_stroke"] if stroke else s["w_fill"]) * SUPERSAMPLE
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
