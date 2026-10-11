extends Node
## char_outline_post.gd —— 角色描边后处理（屏幕空间掩码膨胀，裁决#20）。
##
## 是什么：逐肢体描边烘焙的接缝类缺陷（邻件填充盖不住环带的姿势期白缝——
## 逐件环带的覆盖竞争，与深度垫后无关）的结构性根治：描边不再进几何，
## 身体桶只写填充行，描边在屏幕空间对「角色剪影掩码」膨胀生成——
## 剪影内部无描边概念，关节内透线整类消失。描边恒定屏幕宽（SWL 口径），
## 逐件描边的 zoom 补偿子系统（set_outline_zoom 广播）随之退役。
##
## 管线（零 RenderingDevice 手搓，全常规节点）：
##   掩码视口 SubViewport（共享主 World3D）× 掩码相机（逐帧镜像主相机，
##   只看 MASK_LAYER，挂中性 Environment——世界 tonemap 会改写深度打包值）
##   → 桶的掩码孪生（char_direct_buckets.enable_outline_mask：同一
##   MultiMesh 双宿主，主视口正常材质 / 掩码视口深度打包材质）
##   → 合成层 CanvasLayer(90，主后处理 100 之下——描边随全屏分级走)
##   ColorRect 方阵膨胀描边。
## 层序实况（与旧注释不符，勿按旧注释改）：HUD 是 LayerOrder.HUD = 1，故 90 的
## 合成层在 HUD **之上**——"HUD 恒在其上"做不到，除非把 UIRoot 抬到 100 之上
## （那会连带改掉"HUD 一起被后处理分级"这条既有观感）。现状副作用：角色描边
## 会画到压在其上的 HUD 部件上；HUD 与 3D 世界重叠区域才有感，暂留待裁决。
## 深度语义：正交相机下同卡面部件视深 = 屏幕高度的线性函数 ⇒ 屏内重叠
## 必等深，单角色内部永不因深度出线（平面剪影）；前后角色按深度差出
## 分隔线；被建筑挡住的角色由建筑遮挡块孪生（hd2d_world._spawn_card
## 挂的 blocker）在掩码视口内深度拒掉，描边不穿墙。
const COMPOSITE_SHADER := preload("res://modules/hd2d/shaders/char_outline_composite.gdshader")
const MASK_LAYER := 1 << 19
const CANVAS_LAYER_IDX := 90

var _main_cam: Camera3D = null
var _buckets: Node = null
var _vp: SubViewport = null
var _cam: Camera3D = null
var _rect: ColorRect = null
var _mat: ShaderMaterial = null
var _neutral_env := Environment.new()
var _enabled := true

func _ready() -> void:
	# 掩码相机要在主相机驱动源（hd2d_map_base._process，默认优先级 0）与
	# 桶清尾(1200) 之后同步——镜像到的是当帧终值
	process_priority = 1350


## 装配（hd2d_world 建桶时调一次）：掩码视口 + 镜像相机 + 合成层 + 桶孪生
func setup(main_cam: Camera3D, buckets: Node, world: World3D) -> void:
	_main_cam = main_cam
	_buckets = buckets
	_main_cam.cull_mask &= ~MASK_LAYER   # 主视口不看掩码孪生
	_vp = SubViewport.new()
	_vp.name = "CharMaskVP"
	_vp.transparent_bg = true
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.world_3d = world
	add_child(_vp)
	_cam = Camera3D.new()
	_cam.name = "MaskCam"
	_cam.cull_mask = MASK_LAYER
	_cam.environment = _neutral_env
	_vp.add_child(_cam)
	_cam.current = true
	var layer := CanvasLayer.new()
	layer.name = "CharOutlineLayer"
	layer.layer = CANVAS_LAYER_IDX
	add_child(layer)
	_mat = ShaderMaterial.new()
	_mat.shader = COMPOSITE_SHADER
	_mat.set_shader_parameter("mask_tex", _vp.get_texture())
	_rect = ColorRect.new()
	_rect.name = "OutlineRect"
	_rect.material = _mat
	_rect.color = Color(1, 1, 1, 1)
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_rect)
	buckets.enable_outline_mask()
	_sync()


func _process(_delta: float) -> void:
	if _vp == null:
		return
	_sync()


func _sync() -> void:
	if _main_cam == null or not is_instance_valid(_main_cam):
		return
	_cam.global_transform = _main_cam.global_transform
	_cam.projection = _main_cam.projection
	_cam.size = _main_cam.size
	_cam.near = _main_cam.near
	_cam.far = _main_cam.far
	_cam.keep_aspect = _main_cam.keep_aspect
	var far: float = _main_cam.far
	_mat.set_shader_parameter("cam_far", far)
	if _buckets != null and _buckets.has_method("set_mask_far"):
		_buckets.set_mask_far(far)
	var sz: Vector2i = Vector2i(get_viewport().get_visible_rect().size)
	if sz != _vp.size:
		_vp.size = sz
	_mat.set_shader_parameter("vp_size", Vector2(sz))


## 描边显隐（A/B 对照出图用；掩码视口停渲省一份角色趟）
func set_enabled(v: bool) -> void:
	_enabled = v
	_rect.visible = v
	_vp.render_target_update_mode = \
			SubViewport.UPDATE_ALWAYS if v else SubViewport.UPDATE_DISABLED
