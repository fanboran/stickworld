class_name StickmanSkeleton
extends RefCounted
## 火柴人骨骼数据 + 骨骼构建 + 矢量肢体渲染（批次 B 渲染重标，2026-09-10）。
##
## 数据源（单一真相源，禁止手调比例）：
## - `SpineSkeletonData.BONES`：56 骨 setup 几何（批次 A 从 APK Spine JSON 导入）
## - `SpineRenderData`：核心肢体/头的附件几何、躯干 mesh 轮廓、装备挂点、髋部锚点
##
## 坐标系：Spine（y-up、逆时针、度）→ Godot（y-down、顺时针、弧度）
##   position = (x, -y)；rotation = -deg_to_rad(rot)；length = len。
##
## 锚点：合成静态骨 `RigRoot`（SpineRenderData.RIG_ANCHOR 平移）把**髋骨对到 rig
## 原点**（保持实体原点 = 髋的既有语义）。锚点不能直接烘到 root 骨 setup——root
## 有 position:y 轨道（躯干起伏），每帧会把锚点覆写回 0；也无 position 外的替代位。
##
## 渲染架构（描边两遍渲染 + 链带 z + 根部开口，语义沿用批次 3/4 定稿）：
## - 每个渲染件 = 容器 Node2D，内含描边层（几何加宽 eff）与填充层。
## - 链带 z（描边/填充显式双表，底→顶）：远侧臂 → 躯干描边 → 远侧腿 → 近侧腿
##   → 躯干填充 → 头 → 近侧臂。效果：躯干描边沉在两条腿填充之下（胯部/髋部无线），
##   躯干填充盖住两腿描边（腿根融合在躯干里），近侧腿描边压远侧腿填充（两腿分界），
##   近侧臂描边压躯干填充（臂-躯分隔；肩关节圈由根部开口留隙裸出融合）。
## - 根部开口（U 形三件套：两侧线 + 端弧，根端无笔迹）：凡是"根部埋在上层件里"的
##   肢体段（近臂根埋躯干/头、各下段根埋上段）都必须开口，否则根端圆弧线会横在
##   关节上读作"白色缝线"（历史三次补丁方案失败教训）。
## - 描边屏幕像素恒定：由 StickmanRig 在画布缩放变化时批量调 apply_outline_zoom。
##
## 件几何全部从附件表直读：肢体 = 附件 w×h 圆头胶囊（沿骨轴、含跨关节的超出量，
## 原版关节融合就是这么来的），头 = 130×130×0.62 圆，躯干 = mesh 边界多边形。

const Data := preload("res://modules/units/scripts/rig/spine_skeleton_data.gd")
const Render := preload("res://modules/units/scripts/rig/spine_render_data.gd")

# ===== 描边参数 =====
## 描边宽度（逻辑像素，单侧）——zoom≥1 时的设计世界宽度
const OUTLINE_WIDTH: float = 2.0
## 描边屏幕像素下限（单侧）：相机拉远（画布缩放 <1）时按 1/缩放补偿
## （口径见批次 2 记录；1.0 与历史验收观感一致）
const OUTLINE_SCREEN_PX: float = 1.0

# ===== 渲染链带 z 表（描边，底→顶）=====
## 线性栈：远臂描边-7/填充-6 → 躯干描边-5 → 远腿描边-4/填充-3
## → 近腿描边-2/填充-1 → 头描边0 → 躯干填充1 → 头填充3 → 近臂描边4/填充5。
## 头描边**沉到躯干填充之下**（批次 B 视觉评审必修项）：头圆的底弧压在颈/躯干
## 填充上会读作"白色缝线横穿肩颈"——沉下去后由躯干剪影自然裁掉底弧，头的轮廓
## 到肩线为止（与"头坐在躯干上"的读法一致）；头填充仍在躯干填充之上盖住颈茬。
## z 取值范围 [-7, +5]：单位带 EntityHost z=3 → 全局 -4~8，严格低于前景层 10。
const CHAIN_STROKE_Z: Dictionary = {
	"minerarm3": -7, "minerarm4": -7,                                    # 远侧臂（最底）
	"minertorso1": -5,                                                   # 躯干描边（沉到两腿填充下）
	"minerleg2": -4, "minerleg1": -4, "minerfoot1": -4,                  # 远侧腿描边
	"minerleg3": -2, "minerleg4": -2, "minerfoot2": -2,                  # 近侧腿描边（压远腿填充=分界）
	"minerhead1": 0,                                                     # 头描边（沉到躯干填充下=底弧被剪影裁掉）
	"minerarm1": 4, "minerarm2": 4,                                      # 近侧臂描边（最顶）
}

## 填充层 z（必须显式：躯干填充要越过两条腿的描边才谈得上"腿根融合"）
const CHAIN_FILL_Z: Dictionary = {
	"minerarm3": -6, "minerarm4": -6,
	"minertorso1": 1,
	"minerleg2": -3, "minerleg1": -3, "minerfoot1": -3,
	"minerleg3": -1, "minerleg4": -1, "minerfoot2": -1,
	"minerhead1": 3,
	"minerarm1": 5, "minerarm2": 5,
}

## 根部开口留隙（本地 px，自根端起沿肢向；两侧对称）——该段根端埋在
## 上层件里（近臂根埋躯干/头、下段根埋上段），开口去掉根端弧线即可读作融合。
## 上半体：臂根 ≈30（肩关节圈 + 头圆口径）、下段根 ≈ 上段超出量（肘 34 / 膝 36）；
## 腿根 ≈40（胯下融合区）。
const OPEN_ROOT_GAP: Dictionary = {
	"minerarm1": 30.0,   # 近臂上段根（肩；运行时另有头圆动态裁剪兜底）
	"minerarm2": 34.0,   # 近臂下段根（肘）
	"minerarm4": 34.0,   # 远臂下段根（肘）
	"minerleg2": 40.0,   # 远腿上段根（胯）
	"minerleg4": 40.0,   # 近腿上段根（胯）
	"minerleg1": 36.0,   # 远腿下段根（膝）
	"minerleg3": 36.0,   # 近腿下段根（膝）
}

## 运行时按头圆动态裁剪侧线的件（静息留隙对手臂摆动失准：摆向头侧=线进脑袋）
const HEAD_CLIP_LIMBS: Array = ["minerarm1", "minerarm2"]

## 合成锚点骨名（= SpineRenderData.RIG_ROOT；动画轨道路径前缀）
const RIG_ROOT_NAME := "RigRoot"

# ===== 武器挂载骨骼（Spine 骨名；武器跟武器手骨甩动的动画通道）=====
## 武器手 = pickaxe1（原版 weapon 槽挂骨）；盾手 = Arrow1（原版 Arrow1 槽挂骨）
const WEAPON_ATTACH_R := "pickaxe1"
const WEAPON_ATTACH_L := "Arrow1"
## 躯干多边形挂骨（mesh 附件所属槽 bone）
const TORSO_BONE := "minertorso1"
## 头骨（圆附件）
const HEAD_BONE := "minerhead1"

# ===== 默认颜色 =====
const DEFAULT_BODY := Color(0.82, 0.82, 0.85, 1.0)
const DEFAULT_WEAPON := Color(0.72, 0.74, 0.78, 1.0)
const DEFAULT_GUARD := Color(0.65, 0.45, 0.18, 1.0)
const DEFAULT_OUTLINE := Color.WHITE


# ============================================================
#  骨骼构建
# ============================================================

## 从零构建骨骼 + 矢量肢体层级（SpineSkeletonData.BONES 全量 56 骨）
static func build_from_scratch(skeleton: Skeleton2D, thickness_scale: float = 1.0, colors: Dictionary = {}) -> Dictionary:
	var bones: Dictionary = {}
	var bones_data: Dictionary = Data.BONES

	# 合成锚点骨：承载"髋骨对齐 rig 原点"的平移（无任何动画轨道，永不被覆写）
	var anchor := Bone2D.new()
	anchor.name = Render.RIG_ROOT
	anchor.position = Render.RIG_ANCHOR
	anchor.rest = Transform2D(0.0, anchor.position)
	anchor.auto_calculate_length_and_angle = false
	anchor.length = 1.0
	skeleton.add_child(anchor)

	for name in _topo_sort(bones_data):
		var d: Dictionary = bones_data[name]
		var node := Bone2D.new()
		node.name = name
		node.position = Vector2(float(d["x"]), -float(d["y"]))
		node.rotation = -deg_to_rad(float(d["rot"]))
		node.scale = Vector2(float(d["sx"]), float(d["sy"]))
		# rest 显式设置：Bone2D 默认 rest 是零矩阵（引擎"未设 rest"标记），
		# Skeleton2D._update_bone_setup 对 rest 求 affine_inverse 会报 det==0
		node.rest = Transform2D(node.rotation, node.position).scaled_local(node.scale)
		# 关掉自动计算（否则叶骨/纯挂载骨每帧刷 "No Bone2D children" 警告）
		node.auto_calculate_length_and_angle = false
		node.length = float(d["len"])
		var parent: String = str(d.get("parent", ""))
		if parent.is_empty() or not bones.has(parent):
			anchor.add_child(node)
		else:
			(bones[parent] as Bone2D).add_child(node)
		bones[name] = node

	var sprites := build_limbs(skeleton, bones, thickness_scale, colors)
	return {"bones": bones, "sprites": sprites}


## 为已有骨骼（.tscn 路径）构建矢量肢体层 + 槽位承接节点
static func build_limbs(_skeleton: Skeleton2D, bones: Dictionary, thickness_scale: float, colors: Dictionary) -> Dictionary:
	var sprites: Dictionary = {}
	var made_slots: Dictionary = {}
	for name in Render.CORE_ATTACH:
		var bone: Node2D = bones.get(name)
		if bone == null:
			continue
		var slot: String = str(Render.CORE_ATTACH[name].get("slot", name))
		made_slots[slot] = true
		sprites[name] = _build_attachment(bone, name,
				Render.CORE_ATTACH[name], thickness_scale, colors)
	if bones.has(TORSO_BONE):
		made_slots["torso"] = true
		sprites[TORSO_BONE] = _build_torso(bones[TORSO_BONE], thickness_scale, colors)
	# 其余带 visible 语义的槽位（Arrow1/Arrow2/legdangle 等）建空承接节点：
	# 动画的 attach_<槽>:visible 轨道才有落点，否则引擎每帧刷 track 解析警告。
	# 装备/武器（后续批次）挂进这些节点即自动跟随骨骼与被隐藏。
	for slot in Render.VISIBLE_SLOTS:
		if made_slots.has(slot):
			continue
		var owner_name: String = str(Render.SLOT_BONE.get(slot, ""))
		var owner: Node2D = bones.get(owner_name)
		if owner == null:
			continue
		var holder := Node2D.new()
		holder.name = "attach_%s" % slot
		owner.add_child(holder)
	return sprites


## 扫描 Skeleton2D 中已有的骨骼节点（按 Spine 骨名收集）
static func collect_nodes(skeleton: Skeleton2D) -> Dictionary:
	var bones: Dictionary = {}
	_scan(skeleton, bones)
	return {"bones": bones}


# ============================================================
#  矢量件创建
# ============================================================

## 附件 → 胶囊件。附件在**骨局部系**里给出 (x, y, rot, scale, w, h)：
## 先按 (w,h) 取长轴两端点，再经 y 取反 + 旋转 -rot 落到容器的本地系
## （容器为骨子节点），最后重定心 + 对齐方向，使所有件的填充层都是
## "沿本地 x 轴、关于原点对称、-x 端为根端"——描边/开口/裁剪逻辑因此统一。
static func _build_attachment(bone: Node2D, name: String, geo: Dictionary,
		thickness_scale: float, colors: Dictionary) -> Node2D:
	var ew: float = float(geo["w"]) * float(geo["sx"])
	var eh: float = float(geo["h"]) * float(geo["sy"])
	var rot: float = -deg_to_rad(float(geo["rot"]))
	var fill_c: Color = colors.get("body", DEFAULT_BODY)
	var outline: Color = colors.get("outline", DEFAULT_OUTLINE)
	var sz: int = CHAIN_STROKE_Z.get(name, 1)
	var fz: int = CHAIN_FILL_Z.get(name, sz + 1)

	var container := Node2D.new()
	# 件名 = attach_<槽位>：动画的 attach_<槽>:visible 轨道（原版 attachment NULL
	# 语义——僵尸系碎肢/箭矢显隐）直接打在件本身上，无需额外转发节点。
	container.name = "attach_%s" % str(geo.get("slot", name))
	bone.add_child(container)
	container.position = Vector2(float(geo["x"]), -float(geo["y"]))

	if str(geo.get("slot", "")) == "head":
		# 头 = 圆附件
		var r: float = minf(ew, eh) * 0.5 * thickness_scale
		container.set_meta("eff_kind", "circle")
		container.set_meta("eff_radius", r)
		var st := _make_circle("stroke", r + OUTLINE_WIDTH, outline)
		st.z_index = sz
		var fi := _make_circle("fill", r, fill_c)
		fi.z_index = fz
		container.add_child(st)
		container.add_child(fi)
		return container

	# 长轴两端点（附件局部系，Spine y-up）
	var e0: Vector2
	var e1: Vector2
	var thick: float
	if eh >= ew:
		e0 = Vector2(0.0, -eh * 0.5)
		e1 = Vector2(0.0, eh * 0.5)
		thick = ew
	else:
		e0 = Vector2(-ew * 0.5, 0.0)
		e1 = Vector2(ew * 0.5, 0.0)
		thick = eh
	var p0 := _rotv(rot, Vector2(e0.x, -e0.y))
	var p1 := _rotv(rot, Vector2(e1.x, -e1.y))
	# 根端 = 骨局部 x 较小的一端（贴近骨原点）
	var root: Vector2 = p0 if p0.x <= p1.x else p1
	var tip: Vector2 = p1 if p0.x <= p1.x else p0
	var mid: Vector2 = (root + tip) * 0.5
	var half_len: float = (tip - root).length() * 0.5
	var w: float = maxf(thick * thickness_scale, 1.0)

	container.position += mid
	container.rotation = (tip - root).angle()
	container.set_meta("eff_kind", "seg")
	container.set_meta("eff_half_len", half_len)
	container.set_meta("eff_fill_w", w)

	var pts := PackedVector2Array([Vector2(-half_len, 0.0), Vector2(half_len, 0.0)])
	var fill := _make_line("fill", pts, w, fill_c)
	fill.z_index = fz
	var stroke: CanvasItem
	if OPEN_ROOT_GAP.has(name):
		container.set_meta("eff_kind", "open")
		container.set_meta("eff_gap", float(OPEN_ROOT_GAP[name]))
		stroke = _make_open_root_stroke("stroke", half_len, w, OUTLINE_WIDTH,
				outline, float(OPEN_ROOT_GAP[name]))
	else:
		stroke = _make_line("stroke", pts, w + OUTLINE_WIDTH * 2.0, outline)
	stroke.z_index = sz
	container.add_child(stroke)
	container.add_child(fill)
	return container


## 躯干：mesh 边界环 → 填充 Polygon2D + 闭合描边 Line2D（描边居中于边界，
## 内侧半幅被填充盖住 → 外露 eff）。挂在 mesh 所属槽的骨上（minertorso1）。
static func _build_torso(bone: Node2D, thickness_scale: float, colors: Dictionary) -> Node2D:
	var container := Node2D.new()
	container.name = "attach_torso"
	bone.add_child(container)
	var poly := PackedVector2Array()
	var pts := PackedVector2Array()
	for v: Vector2 in Render.TORSO_POLY:
		poly.append(Vector2(v.x * thickness_scale, -v.y * thickness_scale))
		pts.append(Vector2(v.x * thickness_scale, -v.y * thickness_scale))
	var sz: int = CHAIN_STROKE_Z.get(TORSO_BONE, 1)
	var fz: int = CHAIN_FILL_Z.get(TORSO_BONE, sz + 1)
	var stroke := Line2D.new()
	stroke.name = "stroke"
	stroke.points = pts
	stroke.closed = true
	stroke.width = OUTLINE_WIDTH * 2.0
	stroke.default_color = colors.get("outline", DEFAULT_OUTLINE)
	stroke.joint_mode = Line2D.LINE_JOINT_ROUND
	stroke.begin_cap_mode = Line2D.LINE_CAP_ROUND
	stroke.end_cap_mode = Line2D.LINE_CAP_ROUND
	stroke.z_index = sz
	var fill := Polygon2D.new()
	fill.name = "fill"
	fill.polygon = poly
	fill.color = colors.get("body", DEFAULT_BODY)
	fill.z_index = fz
	container.add_child(stroke)
	container.add_child(fill)
	container.set_meta("eff_kind", "torso")
	return container


## 根部真开口描边（Node2D 容器）：两侧 Line2D（平头帽，自留隙起笔）+ 末端半环
## Polygon2D。根端无任何笔迹（平口），填充根帽直接融进上层件。
## 局部坐标：-x 朝根、+x 朝端。
static func _make_open_root_stroke(lname: String, half_len: float, fill_w: float,
		eff: float, color: Color, gap: float) -> Node2D:
	var box := Node2D.new()
	box.name = lname
	box.set_meta("open_root_half_len", half_len)
	box.set_meta("open_root_fill_w", fill_w)
	box.set_meta("open_root_gap", gap)
	var y: float = fill_w / 2.0 + eff / 2.0
	for side in [-1.0, 1.0]:
		var x0: float = -half_len + gap
		var ln := _make_line("side_%s" % ("top" if side < 0 else "bottom"),
				PackedVector2Array([Vector2(x0, side * y), Vector2(half_len, side * y)]),
				eff, color)
		ln.begin_cap_mode = Line2D.LINE_CAP_NONE
		ln.end_cap_mode = Line2D.LINE_CAP_NONE
		box.add_child(ln)
	var arc := Polygon2D.new()
	arc.name = "tip_arc"
	arc.color = color
	arc.polygon = _tip_arc_pts(half_len, fill_w / 2.0, eff)
	box.add_child(arc)
	return box


## 末端半环顶点：外弧（圆心 (H,0) 半径 R，-90°→+90°）+ 内弧（半径 r，+90°→-90°）
static func _tip_arc_pts(half_len: float, inner_r: float, eff: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := 12
	var ro: float = inner_r + eff
	for i in range(n + 1):
		var a := -PI / 2.0 + PI * float(i) / float(n)
		pts.append(Vector2(half_len, 0) + Vector2(cos(a), sin(a)) * ro)
	for i in range(n, -1, -1):
		var a := -PI / 2.0 + PI * float(i) / float(n)
		pts.append(Vector2(half_len, 0) + Vector2(cos(a), sin(a)) * inner_r)
	return pts


static func _make_line(lname: String, pts: PackedVector2Array, width: float, color: Color) -> Line2D:
	var l := Line2D.new()
	l.name = lname
	l.points = pts
	l.width = width
	l.default_color = color
	l.begin_cap_mode = Line2D.LINE_CAP_ROUND
	l.end_cap_mode = Line2D.LINE_CAP_ROUND
	# 不开 Line2D 自带抗锯齿：其羽化边在相机缩小后呈半透明发虚（"断断续续"）。
	# 项目已开 msaa_2d（批次 1 修复），几何边缘由 MSAA 平滑。
	return l


static func _make_circle(cname: String, radius: float, color: Color) -> Polygon2D:
	var p := Polygon2D.new()
	p.name = cname
	p.color = color
	p.polygon = _circle_pts(radius)
	return p


static func _circle_pts(radius: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(40):
		var a := TAU * float(i) / 40.0
		pts.append(Vector2(cos(a), sin(a)) * radius)
	return pts


## 颜色更新（只改颜色，不重建节点几何）
static func apply_colors(sprites: Dictionary, colors: Dictionary) -> void:
	for key in sprites.keys():
		var piece: Node2D = sprites[key]
		if not is_instance_valid(piece):
			continue
		for cname in ["stroke", "fill"]:
			var node := piece.get_node_or_null(cname)
			var col: Color = colors.get("outline", DEFAULT_OUTLINE) if cname == "stroke" \
					else colors.get("body", DEFAULT_BODY)
			if node is Line2D:
				(node as Line2D).default_color = col
			elif node is Polygon2D:
				(node as Polygon2D).color = col
		var box := piece.get_node_or_null("stroke")
		if box is Node2D and box.has_meta("open_root_fill_w"):
			for side in ["side_top", "side_bottom"]:
				var ln := box.get_node_or_null(side) as Line2D
				if ln != null:
					ln.default_color = colors.get("outline", DEFAULT_OUTLINE)
			var arc := box.get_node_or_null("tip_arc") as Polygon2D
			if arc != null:
				arc.color = colors.get("outline", DEFAULT_OUTLINE)


# ============================================================
#  描边缩放补偿（屏幕像素恒定）
# ============================================================

## 描边单侧世界宽度（屏幕像素恒定补偿，思路同 world_map b443c26a）：
## 画布缩放 s 下拉远时按 1/s 放大，保持屏幕 ~OUTLINE_SCREEN_PX 像素；
## 放大（s>1）时不低于设计宽度 OUTLINE_WIDTH（肢体比例不变）。
static func outline_world_width(canvas_scale: float) -> float:
	var s: float = maxf(canvas_scale, 0.0001)
	return maxf(OUTLINE_WIDTH, OUTLINE_SCREEN_PX / s)


## 描边宽度补偿刷新（画布缩放变化时由 StickmanRig 批量调用，低频）：
## 按件的 eff_kind 重建描边几何（胶囊加宽 / 圆重算半径 / 开口三件套 / 躯干闭线）。
static func apply_outline_zoom(sprites: Dictionary, eff: float) -> void:
	for key in sprites.keys():
		var piece: Node2D = sprites[key]
		if not is_instance_valid(piece):
			continue
		match str(piece.get_meta("eff_kind", "")):
			"circle":
				var r: float = float(piece.get_meta("eff_radius", 0.0))
				var st := piece.get_node_or_null("stroke") as Polygon2D
				if st != null and r > 0.0:
					st.polygon = _circle_pts(r + eff)
			"torso":
				var ln := piece.get_node_or_null("stroke") as Line2D
				if ln != null:
					ln.width = eff * 2.0
			"open":
				var box := piece.get_node_or_null("stroke")
				if box is Node2D:
					_refresh_open_root(box, eff)
			"seg":
				var sl := piece.get_node_or_null("stroke") as Line2D
				var fl := piece.get_node_or_null("fill") as Line2D
				if sl != null and fl != null:
					sl.width = fl.width + eff * 2.0


static func _refresh_open_root(box: Node2D, eff: float) -> void:
	var fw: float = float(box.get_meta("open_root_fill_w", 0.0))
	var hl: float = float(box.get_meta("open_root_half_len", 0.0))
	var gap: float = float(box.get_meta("open_root_gap", 0.0))
	var y: float = fw / 2.0 + eff / 2.0
	for side in [-1.0, 1.0]:
		var sl := box.get_node_or_null("side_top" if side < 0 else "side_bottom") as Line2D
		if sl != null:
			sl.width = eff
			sl.points = PackedVector2Array([
				Vector2(-hl + gap, side * y), Vector2(hl, side * y)])
	var arc := box.get_node_or_null("tip_arc") as Polygon2D
	if arc != null:
		arc.polygon = _tip_arc_pts(hl, fw / 2.0, eff)


## 开口描边侧线对头圆的动态裁剪（StickmanRig._process 每帧调）：
## 手臂摆动时静息标定的留隙会失准（摆向头侧=线进脑袋），每帧把侧线起点钳到
## 头圆轮廓外——起点在圆内则沿段方向求出口交点外移，起点在圆外则不动。
static func clip_open_root_sides_to_head(sprites: Dictionary, head_key: String) -> void:
	var head_piece: Node2D = sprites.get(head_key)
	if head_piece == null or not is_instance_valid(head_piece):
		return
	var head_fill := head_piece.get_node_or_null("fill") as Polygon2D
	if head_fill == null:
		return
	var head_xform := head_fill.get_global_transform()
	var head_center: Vector2 = head_xform.origin
	var head_r: float = float(head_piece.get_meta("eff_radius", 0.0)) * head_xform.get_scale().x
	if head_r <= 0.0:
		return
	for key in HEAD_CLIP_LIMBS:
		var piece: Node2D = sprites.get(key)
		if piece == null or not is_instance_valid(piece):
			continue
		var box := piece.get_node_or_null("stroke")
		if not (box is Node2D):
			continue
		var box_node := box as Node2D
		var lx := box_node.get_global_transform()
		var inv: Transform2D = lx.affine_inverse()
		for side_name in ["side_top", "side_bottom"]:
			var ln := box_node.get_node_or_null(side_name) as Line2D
			if ln == null or ln.points.size() < 2:
				continue
			var pts := ln.points
			var p0w: Vector2 = lx * pts[0]
			var d: Vector2 = p0w - head_center
			if d.length() > head_r:
				continue
			var p1w: Vector2 = lx * pts[1]
			var seg: Vector2 = p1w - p0w
			if seg.length_squared() <= 0.0001:
				continue
			var b: float = 2.0 * d.dot(seg) / seg.length_squared()
			var c: float = (d.length_squared() - head_r * head_r) / seg.length_squared()
			var disc: float = b * b - 4.0 * c
			if disc < 0.0:
				continue
			var t: float = (-b + sqrt(disc)) / 2.0
			t = clampf(t, 0.0, 1.0)
			pts[0] = inv * (p0w + seg * t)
			ln.points = pts


# ============================================================
#  内部辅助
# ============================================================

## Godot 旋转矩阵作用于向量（θ 弧度，y-down）
static func _rotv(theta: float, v: Vector2) -> Vector2:
	var c := cos(theta)
	var s := sin(theta)
	return Vector2(v.x * c - v.y * s, v.x * s + v.y * c)


static func _scan(parent: Node, bones: Dictionary) -> void:
	for child in parent.get_children():
		if child is Bone2D and Data.BONES.has(child.name):
			bones[child.name] = child
		_scan(child, bones)


static func _topo_sort(data: Dictionary) -> Array:
	var result: Array = []
	var visited: Dictionary = {}
	for name in data.keys():
		_visit(name, data, visited, result)
	return result


static func _visit(name: String, data: Dictionary, visited: Dictionary, result: Array) -> void:
	if visited.has(name):
		return
	visited[name] = true
	var parent: String = str(data[name].get("parent", ""))
	if not parent.is_empty() and data.has(parent):
		_visit(parent, data, visited, result)
	result.append(name)
