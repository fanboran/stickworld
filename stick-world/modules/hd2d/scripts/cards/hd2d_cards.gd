extends RefCounted
## hd2d_cards.gd —— HD-2D 卡呈现域组件（hd2d_world 职责拆分）。
##
## 职责：卡（建筑/道具/自然物通用底层）的呈现——quad 装配与卡底贴地落位数学
## （base_cut / bottom_pad 透明留白扫描）、卡材质生成（日/夜/glow/伪法线参数）、
## 前排接地影 blob、画面宽查询（_cw）。卡库元数据字典（_cards/_props/_nature）
## 与贴图解析（_tex_abs 系）留在门面（多组件共享的词汇与加载出口）。
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

const BUILDING_SHADOW_SHADER := preload("res://modules/hd2d/shaders/building_shadow.gdshader")

## 宿主门面（hd2d_world）回引：门面 _ready 时注入。禁循环 preload（门面 preload 本文件），
## 故不标类型——拆分前所有函数都在门面类内，成员经 w 直访。
var w: Node3D = null

## 门面 _apply_light 按昼夜档遍历写 glow/night 参数（前排放全档、后景按折减档）
var _card_mats: Array[ShaderMaterial] = []
var _bg_card_mats: Array[ShaderMaterial] = []   # 后景卡材质：夜间窗光按低档给（见门面 _apply_light）

## 卡底透明留白缓存（世界格）：道具/自然物卡共用（键 = 目录+卡名）
var _pad_cache: Dictionary = {}
## 建筑卡 base_cut 缓存（占比）
var _card_pad_cache: Dictionary = {}


func _cam_basis() -> Basis:
	var t: float = deg_to_rad(w.TILT_DEG)
	return Basis(Vector3(1, 0, 0),
		Vector3(0, cos(t), -sin(t)), Vector3(0, sin(t), cos(t)))


## 建筑卡：**卡底贴地落位**（与 _spawn_prop 道具卡同口径）。
## 旧公式把 cards.json 的 anchor 当"画面中心"落位——anchor 实际是"前墙基线"
## （bake_export: kind="front_wall_baseline"），导致卡几何底边插进台面下方约 2 格，
## 卡面底部（台阶/台基带）被台面深度遮挡压暗——创始人指出的"最下方一段被截断"
## 与"地基上一圈浅灰方形"同源于此。现改为卡底贴地：可视底（裁掉台基后的墙脚线）
## 正好落在 ground 平面（台面 PLAT_H 或路面 0），z 落在 z_off。
func _spawn_card(card: String, x: float, z_off: float, skyline: bool = false,
		ground: float = 0.0) -> MeshInstance3D:
	var meta: Dictionary = w._cards.get(card, {})
	if meta.is_empty():
		push_warning("[hd2d] 无此卡: " + card)
		return null
	var units: Array = meta["units"]
	var q := QuadMesh.new()
	q.size = Vector2(float(units[0]) * w.S, float(units[1]) * w.S)
	var mi := MeshInstance3D.new()
	mi.mesh = q
	var t: float = deg_to_rad(w.TILT_DEG)
	# 可视半高：卡底被 base_cut 裁掉后，以"墙脚线"为落地点取 quad 中心
	var half: float = q.size.y * (0.5 - _card_base_cut(card))
	mi.position = Vector3(x, ground + cos(t) * half, z_off - sin(t) * half)
	mi.basis = _cam_basis()
	var m := _card_material(card)
	if skyline:
		# 远景剪影层：① 不投真阴影 —— 卡片会按 alpha 剪影向地面投真影，一张 17 格高的
		# 塔会在中部空地上拖出一大片斜影，而那片空地没有别的东西来"接住"它，读作脏斑；
		# ② 用一份独立材质做距离染色（tint 由 _spawn_bg_card 按层分档），从前排
		# _card_mats 撤下、登记进 _bg_card_mats——夜间窗光按低档给（后景窗火
		# 只做点缀，不与前排抢），夜版月光贴图照常生效（创始人：后景建筑也给灯光）。
		_card_mats.erase(m)
		m = m.duplicate()
		_bg_card_mats.append(m)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = m
	mi.name = "Card_" + card
	w._card_root.add_child(mi)
	return mi


## 建筑卡接地影：贴在路肩带**之上**（y=0.07，高过所有分带面）的程序化软影。
## 为什么必须补：卡片里烘的接触阴影在卡的深度面上（z≈-1.5），而路肩面（z∈[0,4]）
## 比它更靠近相机 → 深度测试判路肩赢，烘的接触阴影会被路肩**整片盖掉**，
## 建筑就"浮"在路肩上、基线读不准。补一张贴地的程序化软影，把建筑钉在路肩上。
func _spawn_building_shadow(card: String, x: float, mi: MeshInstance3D) -> void:
	var meta: Dictionary = w._cards.get(card, {})
	if meta.is_empty() or mi == null:
		return
	var sw: float = float(meta["units"][0]) * w.S
	var sq := QuadMesh.new()
	sq.size = Vector2(sw * 0.86, w.BSHADOW_DEPTH)
	var sh := MeshInstance3D.new()
	sh.mesh = sq
	var sm := ShaderMaterial.new()
	sm.shader = BUILDING_SHADOW_SHADER
	sh.material_override = sm
	sh.position = Vector3(x, 0.07, w.BSHADOW_Z)
	sh.rotation = Vector3(deg_to_rad(-90), 0, 0)
	sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sh.name = "BShadow_" + card
	w._shadow_root.add_child(sh)


func _card_material(card: String) -> ShaderMaterial:
	var meta: Dictionary = w._cards.get(card, {})
	var base: String = w._temp + w.CARD_DIR
	var alb: Texture2D = w._tex_abs(base + card + ".png")
	var glo: Texture2D = w._tex_abs(base + card + "_glow.png")
	if alb == null:
		return null
	# 夜版卡（Blender 月夜灯位烘的 <卡>_night.png）：缺失回退日版不报错——
	# 未重烘卡库的机器上夜间档安全退化为"日版卡+场景光压暗"的旧行为
	var ngt: Texture2D = w._tex_abs_soft(base + card + "_night.png")
	if ngt == null:
		ngt = alb
	var m := ShaderMaterial.new()
	m.shader = w.CARD_SHADER
	m.set_shader_parameter("albedo_tex", alb)
	m.set_shader_parameter("albedo_night_tex", ngt)
	m.set_shader_parameter("glow_tex", glo)
	var px: Array = meta.get("px", [1024, 1024])
	m.set_shader_parameter("tex_px", Vector2(float(px[0]), float(px[1])))
	m.set_shader_parameter("relief", 4.5)
	m.set_shader_parameter("alpha_cut", 0.4)
	m.set_shader_parameter("glow_energy", 0.0)
	m.set_shader_parameter("tint", Color(1, 1, 1))
	m.set_shader_parameter("base_cut", _card_base_cut(card))   # 浅灰台基整段删除
	_card_mats.append(m)
	return m


## 卡底部透明留白（世界格）——卡底贴地公式只把卡底边放地面，卡内容
## 底部若留白就浮空；按留白行数下沉。PNG px → 格用卡元数据密度换算：
## 烘卡 px 是建模 px 的 2 倍（如 market_stall px=566 对 units=283），
## 旧公式 rows/32 再乘 S 双重偏差（偏小 16 倍），浮空修复实际未生效。
## 道具/自然物卡通用（传入各自的元数据表与贴图目录）。缓存避免重复扫图。
func _card_bottom_pad(card: String, cards: Dictionary, dir: String) -> float:
	var key := dir + card
	if _pad_cache.has(key):
		return float(_pad_cache[key])
	var pad := 0.0
	for base_path: String in [w._temp + dir + card + ".png",
			"res://tests/dev/proto_hd2d/tex/" + dir + card + ".png"]:
		if not FileAccess.file_exists(base_path):
			continue
		var img := Image.new()
		var gp: String = ProjectSettings.globalize_path(base_path) if base_path.begins_with("res://") else base_path
		if img.load(gp) != OK:
			continue
		var img_w := img.get_width()
		var img_h := img.get_height()
		if img_h == 0 or img_w == 0:
			break
		var rows := 0
		for yy in range(img_h - 1, -1, -1):
			var any := false
			for xx in range(0, img_w, maxi(1, img_w / 32)):
				if img.get_pixel(xx, yy).a > 0.12:
					any = true
					break
			if any:
				break
			rows += 1
		var meta: Dictionary = cards.get(card, {})
		var units_a: Array = meta.get("units", [])
		var px_a: Array = meta.get("px", [])
		if not units_a.is_empty() and not px_a.is_empty() and float(px_a[0]) > 1.0:
			pad = float(rows) * float(units_a[0]) / (32.0 * float(px_a[0]))
		else:
			pad = float(rows) / 64.0   # 元数据缺失兜底：现烘卡 2px/建模px（zoom2）
		break
	_pad_cache[key] = pad
	return pad


## 建筑卡底部透明留白占比 = base_cut（卡底贴地的落位修正量）。
## 台基已退役（烘端 PLINTH_ENABLED=False），但烘卡四周仍有 PAD 透明留白——
## 不裁不沉，卡底贴地贴的就是留白的底，墙脚悬空 ~0.3 格（创始人指认"浮空"）。
## 口径同 _card_bottom_pad：alpha 自底向上扫第一行内容（墙脚/台阶，接触阴影
## 已在烘端剥除，扫不到残影），占比既作 shader 裁剪也作落位下沉量。
## 下沉后墙脚回到 (ground, z_off)——与台基时代同一条基线，接地影 blob 不用动。
func _card_base_cut(card: String) -> float:
	if _card_pad_cache.has(card):
		return float(_card_pad_cache[card])
	var cut := 0.0
	var img := _card_image(card)
	if img != null:
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		var h := img.get_height()
		var img_w := img.get_width()
		var data := img.get_data()
		var row_bytes := img_w * 4
		var y := h - 1
		while y >= 0:
			var row0 := y * row_bytes
			var hit := false
			for i in range(3, row_bytes, 4):
				if data[row0 + i] > 16:
					hit = true
					break
			if hit:
				break
			y -= 1
		cut = clampf(float(h - 1 - y) / float(h), 0.0, 0.3)
	_card_pad_cache[card] = cut
	return cut


## 建筑卡 albedo 图（temp 优先，缺失回退 tex/ 入库副本；都不在返回 null）
func _card_image(card: String) -> Image:
	for p in [w._temp + w.CARD_DIR + card + ".png",
			"res://tests/dev/proto_hd2d/tex/" + w.CARD_DIR + card + ".png"]:
		if FileAccess.file_exists(p):
			var img := Image.new()
			if img.load(p) == OK:
				return img
	return null


## 卡可见高（px）：picture 高扣掉 base_cut 的地下裁切——卡底贴地落位后
## 从基线到卡顶的屏幕高度（F3 建筑直立框用）
func _card_visual_height(card: String) -> float:
	var units: Array = w._cards.get(card, {}).get("units", [0.0, 0.0])
	return float(units[1]) * (1.0 - _card_base_cut(card))


## 画面宽（格）：cards.json units 投影宽（含出檐）——摆位推挤/接地影宽同源。
## 元数据缺失兜底 8 格（与摆位求解器同口径）。
func _cw(card: String) -> float:
	var meta: Dictionary = w._cards.get(card, {})
	if meta.is_empty():
		return 8.0
	return float(meta["units"][0]) * w.S
