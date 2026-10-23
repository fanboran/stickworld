extends RefCounted
## hd2d_minimap_baker.gd —— HD-2D 小地图烘焙域组件（hd2d_world 职责拆分）。
##
## 职责：小地图两张供给面——
##   · 数据平面图 get_minimap_layout（地表色带 + 建筑真占地，格→px 换算由
##     调用方传入；缓存与脏失效状态在门面 _minimap_layout_cache）；
##   · 照片式底图烘焙 bake_minimap_strip（共享主视口 World3D 的 SubViewport +
##     专用正交相机真渲染降采样；烘焙 rig 状态在门面 _bake_vp/_bake_cam，
##     临烘排除层 BAKE_EXCLUDE_LAYER 常量与归层逻辑随本组件）。
## 门面保留 get_minimap_layout/bake_minimap_strip 同名转发壳（Hd2dMapBase
## 按方法名 duck 调用，签名不变）。
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

var w: Node3D = null   # 门面回引（_ready 注入；禁循环 preload 故不标门面类型）

## ── 小地图地表色账（消费见 get_minimap_layout）──
## 地表材质 → 代表色：贴图平均色的手填近似（贴图无从运行期采样），
## 实际色 = 本表 × 该条带的 albedo_color 染色（见 get_minimap_layout）。
## 键 = 纹理名去 `_128` 与 `_alb` 后缀（grass_alb_128.png → grass）。
const SURFACE_COLORS: Dictionary = {
	"grass": Color(0.46, 0.60, 0.34),
	"flagstone": Color(0.60, 0.58, 0.55),
	"band_road_stone": Color(0.55, 0.56, 0.58),
	"band_shoulder_stone": Color(0.70, 0.69, 0.66),
	"band_kerb_stone": Color(0.62, 0.61, 0.58),
}
const SURFACE_COLOR_FALLBACK := Color(0.46, 0.60, 0.34)
## 小地图只收"大尺度"地表条带（格）：路肩 8.7 格、门前径 3.6 格这类细条带上图
## 只会把主街糊成杂色——小地图要表达的是"城中石板 / 城外草地"这种一眼可辨的分区。
const MINIMAP_MIN_BAND_CELLS := 20.0
## 烘焙排除层（第 20 层渲染层）：临烘排除内容（火柴人 billboard / 自然物与
## 道具 / 云牌 / 背景排剪影）的可视件归入此层，烘焙相机 cull_mask 挖掉它。
## 按相机剔除而非全局隐藏——主画面零闪烁，重烘可在游戏内随时发。
const BAKE_EXCLUDE_LAYER := 1 << 19


## ── 小地图数据供给（宿主 Hd2dMapBase 转发，签名含格→px 换算口径）──
## 为什么在这里换算：1 格 = 多少 px 是"宿主地图"的口径（Hd2dMapBase.CELL_PX），
## 本类只认格；由调用方传入既避免 hd2d 反向依赖 world 层的常量，也不复制一份。
##
## 返回（世界 px，原点 = 世界 x=0）：
##   surfaces  = [{x0, x1, color}]  地面材质色带，**按铺设顺序**排列（后铺者压前，
##               小地图照序重放即得正确叠色）
##   buildings = [{x, width, y, depth, terrain, def, type, color}]  x = 中心；
##               y = 占地后沿（基线）、depth = 占地纵深 —— 小地图据此画**真占地**
##               而非图标（建筑是 3D 立体，缩略图上是俯视占地块）；
##               type/color 语义见 Hd2dMinimapStyle
##
## 只报前排临街排：后排（bg1~bg3）是远景布景，缩略图上会叠成一团糊块。
func get_minimap_layout(cell_px: float = 24.0) -> Dictionary:
	if is_equal_approx(float(w._minimap_layout_cache.get("cell_px", -1.0)), cell_px) \
			and not w._minimap_layout_cache.is_empty():
		return w._minimap_layout_cache
	var surfaces: Array = []
	for s in w.ground._ground_strips:
		var sw: float = float(s[1])
		if sw < MINIMAP_MIN_BAND_CELLS:
			continue
		var cx: float = float(s[0])
		var tint: Color = s[3]
		var base: Color = minimap_surface_color(str(s[2]))
		surfaces.append({
			"x0": (cx - sw * 0.5) * cell_px,
			"x1": (cx + sw * 0.5) * cell_px,
			"color": Color(base.r * tint.r, base.g * tint.g, base.b * tint.b),
		})
	var buildings: Array = []
	for occ in w._front_occ:
		var meta: Dictionary = w._cards.get(str(occ[2]), {})
		var def: String = str(meta.get("def", ""))
		var x0: float = float(occ[0]) * cell_px
		var x1: float = float(occ[1]) * cell_px
		# 占地纵深沿用 F3 碰撞带的同一口径（_building_solid_rect：烘焙实测 footprint
		# 全深，下限 2 格防扁片，后沿不越行走带深端）——小地图与碰撞盒同源不出双份
		var band: Array = w._building_solid_rect(occ)
		buildings.append({
			"x": (x0 + x1) * 0.5,
			"width": x1 - x0,
			"y": float(band[3]),
			"depth": maxf(float(band[3]) - float(band[2]), cell_px * 2.0),
			"terrain": false,
			"baked": true,   # 前排会烘进照片底图 → 照片模式下不重复画（见 minimap_painter）
			"def": def,
			"type": Hd2dMinimapStyle.type_for(def),
			"color": Hd2dMinimapStyle.color_for(def),
		})
	w._minimap_layout_cache = {
		"cell_px": cell_px,
		"surfaces": surfaces,
		"buildings": buildings,
	}
	return w._minimap_layout_cache


## 地表纹理名 → 代表色（去 `_128`/`_alb` 后缀查 SURFACE_COLORS，未收录走兜底草色）
static func minimap_surface_color(tex_name: String) -> Color:
	var key: String = tex_name.get_basename().replace("_128", "").trim_suffix("_alb")
	return SURFACE_COLORS.get(key, SURFACE_COLOR_FALLBACK)


# ─────────────────────────── 小地图底图烘焙（照片式）───────────────────────────

## 小地图底图烘焙 —— "干净管线"：只留**前排建筑 + 地面**的真渲染，降采样成贴图。
##
## 与 get_minimap_layout（数据平面图）的区别：这里不做任何近似——颜色与形状是
## 烘卡的真实美术，直接由渲染管线产出。
##
## 临烘排除（创始人 2026-10：火柴人与野外树木都烘掉）：火柴人（_char_entities_root
## 实体 billboard 容器 + _char_host 演示宿主）、自然物与道具（_prop_root 含野外
## 树木/矿物/摊位）、云牌、背景楼群（_card_root 里前排之后的 68 张剪影）的可视件
## **独占**归入 BAKE_EXCLUDE_LAYER 渲染层（赋值 = ：留在第 1 层会漏进烘焙相机，
## 云与实体火柴人两次泄漏的教训），烘焙相机 cull_mask 挖掉该层——**按相机剔除
## 而非全局隐藏，主画面零闪烁**，游戏内随时可重烘（昼夜换档防抖重烘即走本口）。
## 天幕与月盘是主相机子节点、后处理层是 CanvasLayer——都不在 SubViewport 的
## 渲染里，天然不进烘焙图。
## 背景清成透明（transparent_bg + 默认清屏色 alpha 0）＝"去天空"。
## 后处理（DOF/辉光/雾）全关——景深远焦起点锚在世界线上，一开整幅糊掉。
##
## 参数：world_x0/x1 = 地图世界 x 范围（px）；canvas_ground_y/bottom = 2D 画布的
## 地面带上下沿（点位换算与裁切基准）；（target_w, target_h）= 目标贴图尺寸，
## 宽高比即裁切比（街带按该比从行走带前沿往上取）。
##
## 返回（相机/viewport 不可用或烘焙失败返回空字典）：
##   texture      ImageTexture（已裁已降采样）
##   x_ref        [world_x0, world_x1]
##   y_ref        [canvas_y_back, t_back, canvas_y_front, t_front]（t 为 0..1 归一纵坐标）
##   lift_ratio   台面抬升的竖直占比（城内点按台面标高画；墙外点不加）
##   wall_x       台面抬升的 x 边界（px；|x| ≤ 它为城内）
## 调用约定：相机接管只发生在烘焙 SubViewport 内部（专用烘焙相机，主相机与
## 逐帧镜像不受影响）；清屏色在捕获后即还原。加载期与游戏内重烘同走本口。
func bake_minimap_strip(world_x0: float, world_x1: float,
		canvas_ground_y: float, canvas_ground_bottom: float,
		tex_w: int, tex_h: int) -> Dictionary:
	if w._cam == null or tex_w <= 0 or tex_h <= 0 or world_x1 <= world_x0:
		return {}
	var rig: Array = _ensure_bake_rig(tex_w, tex_h)
	var bake_cam: Camera3D = rig[1]
	var bake_vp: SubViewport = rig[0]
	if bake_cam == null or bake_vp == null:
		return {}
	# 平时 DISABLED（不留常驻渲染通道）；烘焙期开渲染
	bake_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var map_w: float = world_x1 - world_x0

	# ── 临烘排除：可视件独占归烘焙排除层（相机剔除，不动 visible）──
	var saved_clear: Color = RenderingServer.get_default_clear_color()
	# 背景清成透明（"去天空"）：烘焙视口透明的处露出小地图自己的背衬色
	RenderingServer.set_default_clear_color(Color(0.0, 0.0, 0.0, 0.0))
	_bake_exclude_layer(w._char_entities_root)   # 实体 billboard（游戏图的火柴人全在这）
	_bake_exclude_layer(w._char_host)            # 演示宿主（游戏图常空，防御性排除）
	_bake_exclude_layer(w._prop_root)
	# 云牌：整个容器归排除层（云贴图异步烘制——逐节点排除会漏掉烘焙后才入树的那些）
	_bake_exclude_layer(w._cloud_root)
	var front_n: int = w._front_occ.size()
	if w._card_root != null:
		for i in w._card_root.get_child_count():
			if i >= front_n:
				_bake_exclude_layer(w._card_root.get_child(i))
	# ── 全宽取景（含少量边距，防边缘卡裁）──
	w._apply_cam_framing(map_w * 1.02 / 24.0, bake_cam)
	bake_cam.position.x = (world_x0 + world_x1) * 0.5 / 24.0
	for i in 2:
		await w.get_tree().process_frame
	await RenderingServer.frame_post_draw

	var img: Image = (rig[0] as SubViewport).get_texture().get_image()
	var result: Dictionary = {}
	if img != null and img.get_width() > 0:
		# 画布 y ↔ 世界 z 口径：canvas_y = 516 + z*24（全图统一，见 _building_solid_rect）
		var y_front: float = _bake_screen_y(bake_cam, canvas_ground_bottom)
		var y_back: float = _bake_screen_y(bake_cam, canvas_ground_y)
		var h_px: float = float(maxi(img.get_height(), 1))
		result = {
			"texture": ImageTexture.create_from_image(img),
			"x_ref": [world_x0, world_x1],
			"y_ref": [canvas_ground_y, y_back / h_px, canvas_ground_bottom, y_front / h_px],
			"lift_ratio": _bake_lift_ratio(bake_cam, h_px, canvas_ground_bottom),
			"wall_x": w._wall_x() * 24.0,
		}
	# ── 还原清屏色/烘焙视口渲染（层标记幂等无需还原；相机留在烘焙取景，
	#    下次烘焙自行重设；可见性全程未动）──
	RenderingServer.set_default_clear_color(saved_clear)
	bake_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return result


## 画布 y 在烘焙相机下的屏幕 y（含台面抬升；以 x=0 处标高作统一基准，
## 墙外低地面点位由 lift_ratio 在消费侧修正）
func _bake_screen_y(bake_cam: Camera3D, canvas_y: float) -> float:
	var z: float = (canvas_y - 516.0) / 24.0
	var lift: float = w.get_ground_lift_world(0.0, z)
	return bake_cam.unproject_position(Vector3(0.0, lift, z)).y


## 台面抬升在街带里的竖直占比（消费侧：|x| > wall_x 的点加上它——墙外地面
## 比城内台面低这一档）。取"抬升后 / 未抬升"同一 canvas z 的屏幕 y 之差，
## 是正交俯角下该抬升的精确屏上落差。
func _bake_lift_ratio(bake_cam: Camera3D, h_px: float, canvas_ground_bottom: float) -> float:
	var z: float = (canvas_ground_bottom - 516.0) / 24.0
	var lifted: float = bake_cam.unproject_position(
			Vector3(0.0, w.get_ground_lift_world(0.0, z), z)).y
	var flat: float = bake_cam.unproject_position(Vector3(0.0, 0.0, z)).y
	return absf(flat - lifted) / maxf(h_px, 1.0)


## 烘焙 rig（懒建）：SubViewport 共享主视口的 World3D → 只渲染 3D 世界，
## 不含任何 CanvasLayer（UI/加载屏/后处理），尺寸即目标贴图尺寸（与玩家窗口解耦），
## 专用相机不带相机属性 → 无景深；天幕/月盘挂在主相机上，天然不入图；
## cull_mask 挖掉烘焙排除层（排除内容只对玩家相机可见）。
## rig 节点（_bake_vp/_bake_cam）挂在门面上，状态留门面经 w 读写。返回 [SubViewport, Camera3D]。
func _ensure_bake_rig(tex_w: int, tex_h: int) -> Array:
	if w._bake_vp == null or not is_instance_valid(w._bake_vp):
		w._bake_vp = SubViewport.new()
		w._bake_vp.name = "MinimapBakeViewport"
		w._bake_vp.disable_3d = false
		w._bake_vp.transparent_bg = true
		w._bake_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		w._bake_vp.msaa_3d = Viewport.MSAA_DISABLED
		w.add_child(w._bake_vp)
		w._bake_cam = Camera3D.new()
		w._bake_cam.name = "MinimapBakeCamera"
		w._bake_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		w._bake_cam.keep_aspect = Camera3D.KEEP_WIDTH
		w._bake_cam.near = 0.05
		w._bake_cam.far = 600.0
		w._bake_cam.cull_mask = 0xFFFFF & ~BAKE_EXCLUDE_LAYER
		if w._cam != null:
			w._bake_cam.rotation = w._cam.rotation
			w._bake_cam.position.y = w._cam.position.y
		w._bake_vp.add_child(w._bake_cam)
	# 共享主视口的世界（World3D 同一份 → 渲染同一批 3D 节点与灯光/环境）
	var main_vp: Viewport = w.get_viewport()
	if main_vp != null:
		w._bake_vp.world_3d = main_vp.world_3d
	w._bake_vp.size = Vector2i(maxi(tex_w, 1), maxi(tex_h, 1))
	w._bake_cam.current = true
	return [w._bake_vp, w._bake_cam]


## 把节点子树里的可视件（GeometryInstance3D）**独占**归入烘焙排除层：
## 赋值（=）而非叠加（|=）——节点若仍留在第 1 层，烘焙相机（掩码 1..19）
## 照样渲染它，云就是这么漏进去的（实测教训）。独占后：主相机全层照见、
## 烘焙相机挖掉。幂等（重复赋同值），运行期新入树的排除件下次烘焙自然归层。
## 火柴人 billboard 的外壳 quad、卡片、云全是 MeshInstance3D/Sprite3D 系；
## billboard 内部的 SubViewport/逻辑节点按类型自然跳过。
func _bake_exclude_layer(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	if n is GeometryInstance3D:
		(n as GeometryInstance3D).layers = BAKE_EXCLUDE_LAYER
	for c in n.get_children():
		_bake_exclude_layer(c)
