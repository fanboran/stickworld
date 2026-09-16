extends RefCounted
## crowd_renderer 桶管理库（static，宿主首参显式传入）——MMI/材质着色器装配、
## 武器图集、容量扩缩、槽位清段、每刻阴影/血条喂入与上传。
##
## 是什么：crowd_renderer 的 MultiMesh 桶全部装配与每刻喂入逻辑。桶状态
## （MMI 引用/缓冲/容量/计数）全部留宿主成员，本库无状态；各函数以宿主
## crowd_renderer 实例为首参（弱类型 host，避免 preload 成环）直访其成员。
##
## packed 写回纪律：Packed*Array 按值语义，跨对象链上的下标写/resize 不写回
## 宿主。本库凡改宿主 packed 缓冲，一律「摘除宿主引用 → 局部独占写（零 COW
## 拷贝）→ 交还宿主」三步式；Dictionary/Node 等引用类型不受此限。
##
## 桶序铁律：同 z 下树序 = 绘制序，"描边先画、填充后画"，严禁 move_child
## （详见 build_layer 内长注释）。

const BatchRig := preload("res://modules/units/scripts/rig/stickman_batch_rig.gd")
const OverlayBucket := preload("res://modules/units/scripts/rig/crowd_renderer_overlay_bucket.gd")


# ─────────────────────────── 装配（setup 冷路径） ───────────────────────────

## 装配全部分桶：创建 4 带 × 4 桶 MMI（容器 Node2D，z=ENTITY 层；MMI 树序在
## 实体前——小兵 rig 已隐藏，仅武器 Sprite（若保留）会盖在其上）+ 阴影桶 +
## 血条 6 组桶 + 武器图集桶。**挂载父级 parent 必须与实体同 canvas 链**：
## 挂 battle_instance（纯 Node 下）实测身体桶整体不渲染（仅武器 Sprite 可见），
## 故由调用方传 map（实体所在树）。
static func build_layer(host, parent: Node2D) -> void:
	var container := Node2D.new()
	container.name = "CrowdLayer"
	parent.add_child(container)
	var names := ["CrowdStrokeRects", "CrowdStrokeCaps", "CrowdFillRects", "CrowdFillCaps"]
	var meshes := [BatchRig._get_quad_mesh(), BatchRig._get_circle_mesh(),
			BatchRig._get_quad_mesh(), BatchRig._get_circle_mesh()]
	for band in host.BAND_COUNT:
		for j in 4:
			var count: int = host._bucket_bidx[j].size()
			var idx: int = band * 4 + j
			host._mm.append(null)
			host._buf.append(PackedFloat32Array())
			if count <= 0:
				continue
			var mmi := MultiMeshInstance2D.new()
			mmi.name = "%s_B%d" % [names[j], band]
			mmi.texture = BatchRig._get_white_tex()
			mmi.z_index = 3  # 与 ENTITY 同层（光照 range 一致）；带间遮挡靠树序
			mmi.z_as_relative = false
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_2D
			mm.use_colors = true
			mm.mesh = meshes[j]
			mm.instance_count = 0
			# 关键：2D MultiMesh 的可视剔除基于 custom_aabb，默认空盒在原点——
			# 相机视野不含原点时整个桶被剔除（实测"身体消失仅剩武器"的根因）。
			# 覆盖全域（实例动态写入，逐帧精确盒不划算，给足冗余）。
			mm.custom_aabb = AABB(Vector3(-4096.0, -4096.0, 0.0), Vector3(16384.0, 16384.0, 0.0))
			mmi.multimesh = mm
			container.add_child(mmi)
			# 树序 = 绘制序：创建循环本身就是「带主序 × 桶次序」（低带先画保留
			# y 遮挡；带内 0/1 描边先画、2/3 填充后画盖在描边之上）。此前在此
			# 调 move_child(mmi, band) 把每 MMI 重插到 index=band，将已就位的
			# 桶整体后推——最终桶序错成"填充先画、描边后画"，而描边矩形与填充
			# 同长同中心更宽，白描边完全盖住深色填充 = 实心白身体（涂色定位
			# 实证：描边涂蓝可见、填充涂红被盖）。同 z 下靠树序，严禁再 move_child。
			host._mm[idx] = mmi
	# 阴影桶 MMI（z=1 DECORATION 层，与原 ContactShadow Sprite 同层同观感）
	var smmi := MultiMeshInstance2D.new()
	smmi.name = "CrowdShadows"
	smmi.texture = BatchRig._get_white_tex()  # 纯白兜底纹理：软边全靠多层实例色阶梯
	smmi.z_index = 1
	smmi.z_as_relative = false
	var smm := MultiMesh.new()
	smm.transform_format = MultiMesh.TRANSFORM_2D
	smm.use_colors = true
	smm.mesh = BatchRig._get_quad_mesh()
	smm.instance_count = 0
	smm.custom_aabb = AABB(Vector3(-4096.0, -4096.0, 0.0), Vector3(16384.0, 16384.0, 0.0))
	smmi.multimesh = smm
	container.add_child(smmi)
	host._shadow_mmi = smmi
	host._shadow_mm = smm
	# 血条桶：6 组 × (N 相位 + plain 直角退化槽) MMI（z=1000 顶层与原
	# indicator 同绝对层；组创建顺序 = 树序 = 绘制序：底色→描边①→残影/填充
	# →描边②→点填充→点描边）。环带材质按变体各带 DELTAS/COEFF 烘表
	# （shader 逐实例重建世界边向量——条实例非均匀缩放，法线随宽高比变化）。
	var wobble_shader: Shader = load("res://modules/units/scripts/rig/crowd_bar_wobble.gdshader")
	var fill_mat := ShaderMaterial.new()
	fill_mat.shader = wobble_shader
	fill_mat.set_shader_parameter("mode", 0.0)
	var dot_mat := ShaderMaterial.new()
	dot_mat.shader = wobble_shader
	dot_mat.set_shader_parameter("mode", 1.0)
	var ring_mats: Array = []
	for k in BatchRig.WOBBLE_VARIANTS:
		var rm := ShaderMaterial.new()
		rm.shader = wobble_shader
		rm.set_shader_parameter("mode", 0.0)
		rm.set_shader_parameter("DELTAS", BatchRig._bar_ring_deltas(k))
		rm.set_shader_parameter("COEFF", BatchRig._bar_ring_coeffs(k))
		ring_mats.append(rm)
	var ring_plain_mat := ShaderMaterial.new()
	ring_plain_mat.shader = wobble_shader
	ring_plain_mat.set_shader_parameter("mode", 0.0)
	ring_plain_mat.set_shader_parameter("DELTAS", _pad16(BatchRig._plain_ring_deltas()))
	var zero16 := PackedFloat32Array()
	zero16.resize(16)
	ring_plain_mat.set_shader_parameter("COEFF", zero16)
	var n := BatchRig.WOBBLE_VARIANTS
	var fill_meshes: Array = []
	var fill_mats: Array = []
	for k in n:
		fill_meshes.append(BatchRig._get_wobble_bar_mesh(k))
		fill_mats.append(fill_mat)
	fill_meshes.append(BatchRig._get_plain_bar_mesh())
	fill_mats.append(fill_mat)
	var ring_meshes: Array = []
	var ring_mats_all: Array = ring_mats.duplicate()
	for k in n:
		ring_meshes.append(BatchRig._get_wobble_bar_ring_mesh(k))
	ring_meshes.append(BatchRig._get_plain_bar_ring_mesh())
	ring_mats_all.append(ring_plain_mat)
	var dot_fill_meshes: Array = []
	var dot_ring_meshes: Array = []
	var dot_mats: Array = []
	for k in n:
		dot_fill_meshes.append(BatchRig._get_wobble_dot_mesh(k))
		dot_ring_meshes.append(BatchRig._get_wobble_dot_ring_mesh(k))
		dot_mats.append(dot_mat)
	host._bar_bg = _make_bucket(container, "CrowdBarBg", fill_meshes, fill_mats)
	host._bar_ring1 = _make_bucket(container, "CrowdBarR1", ring_meshes, ring_mats_all)
	host._bar_trail_fill = _make_bucket(container, "CrowdBarTf", fill_meshes, fill_mats)
	host._bar_ring2 = _make_bucket(container, "CrowdBarR2", ring_meshes, ring_mats_all)
	host._dot_fill = _make_bucket(container, "CrowdDotF", dot_fill_meshes, dot_mats)
	host._dot_ring = _make_bucket(container, "CrowdDotR", dot_ring_meshes, dot_mats)
	# 武器图集桶（z=18 浮于单位身体之上，原武器 Sprite 同层）
	host._weapon_mm = _make_weapon_mm(host, container)


## 覆盖层 MMI 构造（血条桶共用；z=1000 绝对层与原 indicator 一致）
static func _make_overlay_mm(container: Node2D, mm_name: String, mesh: Mesh, mat: ShaderMaterial) -> MultiMeshInstance2D:
	var mmi := MultiMeshInstance2D.new()
	mmi.name = mm_name
	mmi.texture = BatchRig._get_white_tex()
	mmi.z_index = 1000
	mmi.z_as_relative = false
	mmi.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 0
	mm.custom_aabb = AABB(Vector3(-4096.0, -4096.0, 0.0), Vector3(16384.0, 16384.0, 0.0))
	mmi.multimesh = mm
	container.add_child(mmi)
	return mmi


## 血条桶组构造：逐槽（N 相位 + plain 退化槽）网格/材质配对 + 空缓冲
static func _make_bucket(container: Node2D, prefix: String, meshes: Array, mats: Array) -> OverlayBucket:
	var b := OverlayBucket.new()
	for k in meshes.size():
		b.mmis.append(_make_overlay_mm(container, "%s%d" % [prefix, k], meshes[k], mats[k]))
		b.bufs.append(PackedFloat32Array())
		b.caps.append(0)
		b.cnt.append(0)
		b.prev.append(0)
	return b


## 补齐 PackedVector2Array 到 16 项（shader uniform 数组定长）
static func _pad16(arr: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(arr)
	while out.size() < 16:
		out.append(Vector2.ZERO)
	return out


## 武器图集桶 MMI（use_custom_data 传 UV 子区域，shader 顶点期映射）
static func _make_weapon_mm(host, container: Node2D) -> MultiMesh:
	var mmi := MultiMeshInstance2D.new()
	mmi.name = "CrowdWeapons"
	mmi.texture = null  # 图集就绪后由 rebuild_atlas 赋
	mmi.z_index = 18
	mmi.z_as_relative = false
	var mat := ShaderMaterial.new()
	mat.shader = load("res://modules/units/scripts/rig/crowd_weapon_atlas.gdshader")
	mmi.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = BatchRig._get_quad_mesh()
	mm.instance_count = 0
	mm.custom_aabb = AABB(Vector3(-4096.0, -4096.0, 0.0), Vector3(16384.0, 16384.0, 0.0))
	mmi.multimesh = mm
	container.add_child(mmi)
	host._weapon_mmi = mmi
	return mm


# ─────────────────────────── 武器图集 ───────────────────────────

## 图集构建（注册期收集，首 tick 前一次；dirty 早退）：扫描线摆放，宽 256 高 1024
static func rebuild_atlas(host) -> void:
	if not host._atlas_dirty:
		return
	host._atlas_dirty = false
	const AW := 256
	const AH := 1024
	if host._atlas_img == null:
		host._atlas_img = Image.create(AW, AH, false, Image.FORMAT_RGBA8)
	var x := 0
	var y := 0
	var row_h := 0
	for path in host._atlas_pending.keys():
		var tex: Texture2D = load(path)
		if tex == null:
			continue
		var img: Image = tex.get_image()
		img.decompress()
		img.convert(Image.FORMAT_RGBA8)
		var sz := img.get_size()
		if x + sz.x > AW:
			x = 0
			y += row_h
			row_h = 0
		if y + sz.y > AH:
			push_error("[CrowdRenderer] 武器图集溢出，跳过 " + path)
			continue
		host._atlas_img.blit_rect(img, Rect2i(Vector2i.ZERO, sz), Vector2i(x, y))
		host._atlas_entries[path] = Rect2i(x, y, sz.x, sz.y)
		x += sz.x
		row_h = maxi(row_h, sz.y)
	host._atlas_pending.clear()
	host._atlas_tex = ImageTexture.create_from_image(host._atlas_img)
	host._weapon_mmi.texture = host._atlas_tex


# ─────────────────────────── 容量扩缩 ───────────────────────────

## 武器桶容量按需翻倍扩（stride 16：变换 8 + 色 4 + custom 4）。
## 返回 true = 本刻发生了扩容（调用方如持旧 buffer 引用需重取）。
static func ensure_weapon_cap(host, n: int) -> bool:
	if n <= host._weapon_cap:
		return false
	while host._weapon_cap < n:
		host._weapon_cap = maxi(host._weapon_cap * 2, 16)
	host._weapon_mm.instance_count = host._weapon_cap
	var buf: PackedFloat32Array = host._weapon_buf
	host._weapon_buf = PackedFloat32Array()  # 摘除宿主引用：buf 独占，resize 零拷贝
	buf.resize(host._weapon_cap * 16)
	host._weapon_buf = buf  # 交还宿主
	return true


## 阴影桶容量按需翻倍扩（零变换行=隐形，instance_count 恒为容量）。
## 返回 true = 本刻发生了扩容（调用方如持旧 buffer 引用需重取）。
static func ensure_shadow_cap(host, n: int) -> bool:
	if n <= host._shadow_cap:
		return false
	while host._shadow_cap < n:
		host._shadow_cap = maxi(host._shadow_cap * 2, 16)
	host._shadow_mm.instance_count = host._shadow_cap
	var buf: PackedFloat32Array = host._shadow_buf
	host._shadow_buf = PackedFloat32Array()  # 摘除宿主引用：buf 独占，resize 零拷贝
	buf.resize(host._shadow_cap * 12)
	host._shadow_buf = buf  # 交还宿主
	return true


## 带容量按需扩容（带内已分配段数 count 只增不减；buffer 一次扩到位、
## 新位默认 0 = 零缩放阵，防 identity 簇拥原点）
static func grow_band(host, band: int, count: int) -> void:
	for j in 4:
		var holder = host._mm[band * 4 + j]
		var mm: MultiMesh = (holder.multimesh if holder is MultiMeshInstance2D else null)
		if mm == null:
			continue
		var per_unit: int = host._bucket_bidx[j].size()
		if per_unit <= 0:
			continue
		var need: int = maxi(mm.instance_count / per_unit, count) * per_unit
		if mm.instance_count >= need:
			continue
		mm.instance_count = need
		var buf: PackedFloat32Array = host._buf[band * 4 + j]
		host._buf[band * 4 + j] = null  # 摘除宿主引用：buf 独占，resize 零拷贝
		buf.resize(need * 12)
		host._buf[band * 4 + j] = buf  # 交还宿主
		mm.buffer = buf


# ─────────────────────────── 槽位清段 ───────────────────────────

## 清槽位实例（该槽位段零缩放 + 全透明，一次写入）
static func clear_slot_instances(host, slot: Dictionary) -> void:
	var band: int = slot.get("band", 0)
	var band_idx: int = slot.get("band_idx", 0)
	for j in 4:
		var holder = host._mm[band * 4 + j]
		var mm: MultiMesh = (holder.multimesh if holder is MultiMeshInstance2D else null)
		if mm == null:
			continue
		var per_unit: int = host._bucket_bidx[j].size()
		if per_unit <= 0 or band_idx * per_unit >= mm.instance_count:
			continue
		var buf: PackedFloat32Array = host._buf[band * 4 + j]
		host._buf[band * 4 + j] = null  # 摘除宿主引用：buf 独占，下标写零拷贝
		var base_i: int = band_idx * per_unit * 12
		for o in range(base_i, base_i + per_unit * 12):
			buf[o] = 0.0
		host._buf[band * 4 + j] = buf  # 交还宿主
		mm.buffer = buf


# ─────────────────────────── 每刻喂入与上传 ───────────────────────────

## 每刻阴影桶喂入与上传：全部活单位写入（变换布局与身体桶一致：
## [xx,yx,0,ox, xy,yy,0,oy, rgba]）。quad 基准 1×1、白纹理 4px——软边观感用
## 3 层同心椭圆阶梯叠加（alpha 合成中心 ≈0.34 边缘 0.08，逼近原渐变 Sprite）；
## 带 alpha 的自绘纹理在 MMI 管线实测不渲染（白纹对照实验定位），故纹理只用
## 纯白、明暗全走实例色
static func write_shadows(host) -> void:
	if host._shadow_mm == null:
		return
	var ts: float = 64.0
	var n: int = 0
	var sbuf: PackedFloat32Array = host._shadow_buf
	host._shadow_buf = PackedFloat32Array()  # 摘除宿主引用：sbuf 独占，本刻写零拷贝
	for idx in host._slots.size():
		var slot = host._slots[idx]
		if slot == null or slot.is_empty() or bool(slot["hidden"]):
			continue
		var entity: Node = slot["entity"]
		if entity == null or not is_instance_valid(entity):
			continue
		if ensure_shadow_cap(host, n + 3):
			sbuf = host._shadow_buf            # 扩容后 buffer 已重建，取新引用
			host._shadow_buf = PackedFloat32Array()  # 再次摘除，续写零拷贝
		var fo = entity.get("foot_offset")
		var oy: float = (float(fo) if fo != null else 45.0) + 2.0
		var px: float = entity.global_position.x
		var py: float = entity.global_position.y + oy
		for layer in 3:
			var r: float = [1.0, 0.72, 0.46][layer]
			var a: float = [0.08, 0.13, 0.16][layer]
			var o := (n + layer) * 12
			sbuf[o] = 0.9 * ts * r
			sbuf[o + 1] = 0.0
			sbuf[o + 2] = 0.0
			sbuf[o + 3] = px
			sbuf[o + 4] = 0.0
			sbuf[o + 5] = 0.26 * ts * r
			sbuf[o + 6] = 0.0
			sbuf[o + 7] = py
			sbuf[o + 8] = 0.0
			sbuf[o + 9] = 0.0
			sbuf[o + 10] = 0.0
			sbuf[o + 11] = a
		n += 3
	host._shadow_buf = sbuf  # 交还宿主
	host._shadow_mm.buffer = sbuf


## 每刻血条桶喂入与上传：6 组 × N 相位（层序/手绘感对齐见宿主成员区注释）。
## 行几何/绘制门与原版 _draw_bar/_draw_dot 逐层同构；相位组 = wobble seed % N
## （原版 0.12s 重掷 → 换组跳相）
static func write_bars(host) -> void:
	host._bar_bg.begin_tick()
	host._bar_ring1.begin_tick()
	host._bar_trail_fill.begin_tick()
	host._bar_ring2.begin_tick()
	host._dot_fill.begin_tick()
	host._dot_ring.begin_tick()
	for idx in host._slots.size():
		var slot2 = host._slots[idx]
		if slot2 == null or slot2.is_empty() or bool(slot2["hidden"]):
			continue
		var ind = slot2.get("_bar")
		if ind == null or not is_instance_valid(ind) or not ind._data_mode:
			continue
		var st: Dictionary = ind.get_bar_state()
		if not bool(st["active"]):
			continue
		var bs: float = float(st["scale"])
		var cx: float = ind.global_position.x
		var cy: float = ind.global_position.y
		var shown: float = float(st["shown"])
		var seed_k: int = int(st["wobble"]) % BatchRig.WOBBLE_VARIANTS
		# 圆点（原版 _draw_dot：expand<0.999 才画，本体/描边 alpha 同乘 1-expand；
		# 几何全烘焙，CUSTOM 无用）
		if float(st["expand"]) < 0.999:
			var dot_a: float = shown * (1.0 - float(st["expand"]))
			var rr: float = HealthBarIndicator.DOT_RADIUS * bs
			var dc: Color = st["color"]
			host._dot_fill.row(seed_k, cx, cy, rr, rr, Color(dc.r, dc.g, dc.b, dc.a * dot_a), 0.0, 0.0, 0.0)
			var olc: Color = HealthBarIndicator.COLOR_OUTLINE
			host._dot_ring.row(seed_k, cx, cy, rr, rr, Color(olc.r, olc.g, olc.b, olc.a * dot_a), 0.0, 0.0, 0.0)
		# 横条（原版 _draw_bar 层序：底→描边①→残影→填充→描边②；受击抖动同式）
		var half: float = float(st["width"]) * 0.5 * float(st["expand"]) * bs
		if half >= bs:  # 原版局部 half<1.0 早退（世界 px = 局部×bs）
			var t: float = float(st["anim_time"])
			var se: float = float(st["shake"])
			var shk: float = sin(t * HealthBarIndicator.SHAKE_FREQ) * se * HealthBarIndicator.SHAKE_MAX_OFFSET \
					+ sin(t * HealthBarIndicator.SHAKE_FREQ * 2.3) * se * HealthBarIndicator.SHAKE_MAX_OFFSET * 0.3
			var cx2: float = cx + shk
			var bw: float = half * 2.0
			var hh: float = HealthBarIndicator.BAR_HEIGHT * bs
			var left: float = cx2 - half
			var plain: bool = bw / bs < 6.0  # 原版 _draw_wobbly_rect 窄矩形回退门
			# plain 路由到直角退化网格槽（桶尾槽 = BatchRig.WOBBLE_VARIANTS）
			var kbg: int = BatchRig.WOBBLE_VARIANTS if plain else seed_k
			var bgc: Color = HealthBarIndicator.COLOR_BG
			host._bar_bg.row(kbg, cx2, cy, bw, hh, _colc(HealthBarIndicator.COLOR_BG, shown), bw, plain, hh)
			host._bar_ring1.row(kbg, cx2, cy, bw, hh, _colc(HealthBarIndicator.COLOR_OUTLINE, shown), bw, plain, hh)
			var trail: float = float(st["trail"])
			if trail > float(st["ratio"]) + 0.005:  # 原版残影绘制门
				var tw := bw * trail
				var kt: int = BatchRig.WOBBLE_VARIANTS if tw / bs < 6.0 else seed_k
				host._bar_trail_fill.row(kt, left + tw * 0.5, cy, tw, hh,
						_colc(HealthBarIndicator.COLOR_TRAIL, shown), tw, tw / bs < 6.0, hh)
			var fw := bw * float(st["ratio"])
			if fw > 0.5 * bs:  # 原版填充绘制门（局部 0.5px）
				var kf: int = BatchRig.WOBBLE_VARIANTS if fw / bs < 6.0 else seed_k
				host._bar_trail_fill.row(kf, left + fw * 0.5, cy, fw, hh,
						_colc(st["color"], shown), fw, fw / bs < 6.0, hh)
			host._bar_ring2.row(kbg, cx2, cy, bw, hh, _colc(HealthBarIndicator.COLOR_OUTLINE, shown), bw, plain, hh)
	host._bar_bg.end_tick()
	host._bar_ring1.end_tick()
	host._bar_trail_fill.end_tick()
	host._bar_ring2.end_tick()
	host._dot_fill.end_tick()
	host._dot_ring.end_tick()


## 武器图集桶上传（_weapon_count 压实行数；未用行=零变换隐形）
static func upload_weapon(host) -> void:
	if host._weapon_mm != null and host._weapon_cap > 0 and host._atlas_tex != null:
		host._weapon_mm.buffer = host._weapon_buf


## 颜色 × 显示系数（渐隐 shown；rgb 不动，仅乘 alpha）
static func _colc(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, c.a * a)
