class_name SiegeWall
extends Node2D
## 城墙 —— 垂直穿过画面的城防立面（城市一侧 / 战场一侧两种视角）。
##
## 城墙本体竖直走向（沿画面竖直方向延伸），厚 8 格（256px）。城门开在墙上、
## 朝向城内/战场方向——游戏内角色沿墙走到门位穿行，上帝视角看不到门洞，
## 因此不画门：出城交互=走到墙边触发出城选项（siege_gate_prompt）。
##
## TOWN（城内侧）：城内地面高（占屏 1/3），只见矮立面+顶部压顶条——
##   看不到马道（马道面在自己头顶视角外）。
## FIELD（战场侧）：同一堵墙在低处的视角——墙从战场地面向上垂直延伸很长：
##   上段=马道面（俯视砖铺竖带：弓箭手沿它上下巡走）
##        +马道前沿（朝战场一侧）的矮墙条（亮顶帽+窄侧身）
##   下段=侧砖立面，一直垂到战场地面（地图边缘的地面）。
##
## 挂载点 = 墙中心；top_y=墙顶线（战场=地平线上 5 格；城内=城内地平线上 5 格），
## foot_y=墙脚。贴图 region 1:1 平铺（tools/bake_siege_textures.gd 烘焙）。

enum Form { TOWN, FIELD }

const StoneBrickGenScript := preload("res://modules/texture_gen/scripts/stone_brick_gen.gd")
const SEG_TEX_PATH := "res://assets/environment/siege_wall_seg.png"
const TOP_TEX_PATH := "res://assets/environment/siege_top_face.png"

## 城墙厚度：8 格
const WALL_W: float = 256.0
## FIELD 马道面带高（俯视上表面的竖向长度）
const MARCH_H: float = 380.0
## 压顶/矮墙帽亮色（石顶条）
const CAP_COLOR := Color(0.90, 0.87, 0.79)

@export var form: Form = Form.TOWN
## 墙脚世界 y（TOWN=城内地面带内；FIELD=战场地面）
@export var foot_y: float = 1040.0
## 墙顶线世界 y（地平线上方若干格）
@export var top_y: float = 650.0


func _ready() -> void:
	z_index = WorldZ.BUILDING
	_build()


func _build() -> void:
	if form == Form.FIELD:
		_build_field()
	else:
		_build_town()


## 城内侧：矮立面 + 顶部压顶条
func _build_town() -> void:
	var tex := _load_tex(SEG_TEX_PATH)
	if tex == null:
		return
	var h: float = foot_y - top_y
	position = Vector2(position.x, top_y)
	# 侧砖立面（region 竖向平铺）
	_tiled(tex, Rect2(0.0, 0.0, WALL_W, h), Rect2(-WALL_W * 0.5, 0.0, WALL_W, h), "WallBody")
	# 顶部压顶条（墙顶封线）
	_cap_strip(-WALL_W * 0.5, -14.0, WALL_W, 14.0)
	_mount_shadow(WALL_W, h, 30.0)


## 战场侧：马道面带 + 前沿矮墙条 + 长立面（从墙顶垂到战场地面）
func _build_field() -> void:
	var tex := _load_tex(SEG_TEX_PATH)
	var top_tex := _load_tex(TOP_TEX_PATH)
	if tex == null:
		return
	var h: float = foot_y - top_y
	position = Vector2(position.x, top_y)
	# 上段：马道面（俯视砖铺竖带——墙顶的上表面）
	if top_tex != null:
		_tiled(top_tex, Rect2(0.0, 0.0, WALL_W - 46.0, MARCH_H),
				Rect2(-WALL_W * 0.5, 0.0, WALL_W - 46.0, MARCH_H), "MarchFace")
	# 马道前沿（朝战场=右侧）矮墙条：亮顶帽 + 窄侧身
	var px: float = WALL_W * 0.5 - 46.0
	_cap_strip(px, 0.0, 46.0, 12.0)
	_tiled(tex, Rect2(0.0, 0.0, 46.0, MARCH_H - 12.0),
			Rect2(px, 12.0, 46.0, MARCH_H - 12.0), "ParapetBody")
	# 马道带上缘封线
	_cap_strip(-WALL_W * 0.5, -10.0, WALL_W - 46.0, 10.0)
	# 下段：侧砖立面（马道带以下一直垂到战场地面）
	_tiled(tex, Rect2(0.0, 0.0, WALL_W, h - MARCH_H),
			Rect2(-WALL_W * 0.5, MARCH_H, WALL_W, h - MARCH_H), "WallBody")
	_mount_shadow(WALL_W, h, 46.0)


## 平铺 sprite：region（贴图像素坐标，超出部分 repeat）→ dest（局部矩形 1:1）
func _tiled(tex: Texture2D, region: Rect2, dest: Rect2, node_name: String) -> Sprite2D:
	var spr := Sprite2D.new()
	spr.name = node_name
	spr.texture = tex
	spr.centered = false
	spr.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	spr.region_enabled = true
	spr.region_rect = region
	spr.position = dest.position
	spr.scale = Vector2(dest.size.x / region.size.x, dest.size.y / region.size.y)
	add_child(spr)
	return spr


## 石顶帽条（亮色压顶/矮墙帽）
func _cap_strip(x: float, y: float, w: float, h: float) -> void:
	var cap := ColorRect.new()
	cap.name = "CapStrip"
	cap.color = CAP_COLOR
	cap.position = Vector2(x, y)
	cap.size = Vector2(w, h)
	add_child(cap)


## 墙脚接地阴影
func _mount_shadow(w: float, h: float, depth: float) -> void:
	var shadow := ColorRect.new()
	shadow.name = "FootShadow"
	shadow.color = Color(0.0, 0.0, 0.0, 0.25)
	shadow.size = Vector2(w, depth)
	shadow.position = Vector2(-w * 0.5, h - depth)
	add_child(shadow)


## 巡走弓箭手 x 槽（相对墙中心；FIELD 偏马道内侧避开前沿矮墙）
func get_archer_slots() -> Array[float]:
	if form == Form.FIELD:
		return [-WALL_W * 0.28, -WALL_W * 0.06, WALL_W * 0.16]
	return [-WALL_W * 0.22, 0.0, WALL_W * 0.22]


## 巡走 y 范围（世界 y）：FIELD=马道带内上下往返；TOWN=墙顶带
func get_patrol_range() -> Vector2:
	var span: float = (MARCH_H - 70.0) if form == Form.FIELD else 130.0
	return Vector2(top_y + 36.0, top_y + 36.0 + span)


## 墙中心世界 x
func get_wall_x() -> float:
	return global_position.x


func _load_tex(path: String) -> Texture2D:
	if ResourceLoader.exists(path):
		return load(path)
	if path == SEG_TEX_PATH:
		push_warning("[SiegeWall] 烘焙贴图缺失，运行时重生成: " + path)
		var img := StoneBrickGenScript.make_wall(512, 512, 20260906, Vector2i(64, 30), false)
		return ImageTexture.create_from_image(img)
	return null
