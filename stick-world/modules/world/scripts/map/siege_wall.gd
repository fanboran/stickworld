class_name SiegeWall
extends Node2D
## 守城战城墙布景 —— 正侧方视角的石砖城墙（2D 立面），可站弓箭手。
##
## 布局约定（局部坐标，原点=墙脚线中点，y 向上为负）：
##   墙身铺贴 siege_wall_seg.png 的墙身区（region 裁切），顶部一行垛口带；
##   中段嵌城门立面（siege_gate.png，含拱门洞视觉）。门洞纯视觉、无碰撞：
##   守城 Demo 里敌我从城门前开阔地交战，我方也可出击穿门。
##
## 站位：get_platform_y() 为墙顶承重线（弓箭手脚部 y），get_archer_slots()
## 给出沿墙均匀的站位 x（跳过门洞区），由 SiegeDirector 用于布弓箭手。
##
## 贴图由 tools/bake_siege_textures.gd 离线烘焙（StoneBrickGen CPU 石砖算法），
## 贴图缺失时运行时用同一算法兜底重生成（烘焙=运行时同一代码路径）。

const StoneBrickGenScript := preload("res://modules/texture_gen/scripts/stone_brick_gen.gd")
const SEG_TEX_PATH := "res://assets/environment/siege_wall_seg.png"
const GATE_TEX_PATH := "res://assets/environment/siege_gate.png"

## 烘焙贴图内部布局（与 bake_siege_textures.gd 参数对应）
const TEX_SEG_W := 512
const TEX_MERLON_H := 34
const TEX_WALL_H := 478
const GATE_W := 440
const GATE_H := 280

## 墙身可见高度（世界 px；墙脚 y=0，墙顶 y=-wall_height）
@export var wall_height: float = 300.0
## 城墙总宽（含城门）
@export var total_width: float = 1400.0
## 是否带城门（居中嵌门立面）
@export var has_gate: bool = true

var _gate_half_w: float = GATE_W * 0.5


func _ready() -> void:
	z_index = WorldZ.BUILDING
	_build()


func _build() -> void:
	var tex: Texture2D = _load_or_bake_seg()
	var gate_tex: Texture2D = null
	if has_gate and ResourceLoader.exists(GATE_TEX_PATH):
		gate_tex = load(GATE_TEX_PATH)
	# 墙身：region 裁贴图墙身区，横向平铺到总宽（低于垛口带的整立面）
	var wall_top := -wall_height
	var body := Sprite2D.new()
	body.name = "WallBody"
	body.texture = tex
	body.centered = false
	body.region_enabled = true
	body.region_rect = Rect2(0, TEX_MERLON_H, TEX_SEG_W, TEX_WALL_H)
	body.position = Vector2(-total_width * 0.5, wall_top)
	body.scale = Vector2(total_width / float(TEX_SEG_W), wall_height / float(TEX_WALL_H))
	add_child(body)
	# 垛口带：铺在墙顶上方（豁口 alpha 镂空直接来自贴图）
	if tex != null:
		var merlons := Sprite2D.new()
		merlons.name = "Merlons"
		merlons.texture = tex
		merlons.centered = false
		merlons.region_enabled = true
		merlons.region_rect = Rect2(0, 0, TEX_SEG_W, TEX_MERLON_H)
		merlons.position = Vector2(-total_width * 0.5, wall_top - TEX_MERLON_H)
		merlons.scale = Vector2(total_width / float(TEX_SEG_W), 1.0)
		add_child(merlons)
	# 城门立面（底边对齐墙脚、居中）
	if gate_tex != null:
		var gate := Sprite2D.new()
		gate.name = "Gate"
		gate.texture = gate_tex
		gate.centered = false
		gate.position = Vector2(-GATE_W * 0.5, -float(gate_tex.get_height()))
		add_child(gate)


## 墙顶承重线（相对节点原点的高度；弓箭手 global y = global_position.y + 此值）
func get_platform_y() -> float:
	return -wall_height - 10.0


## 弓箭手站位槽（局部 x 列表）：沿墙均匀分布，跳过门洞半宽区
func get_archer_slots() -> Array[float]:
	var slots: Array[float] = []
	var half := total_width * 0.5
	var x := -half + 60.0
	var gate_clear := (_gate_half_w + 80.0) if has_gate else 0.0
	while x <= half - 60.0:
		if gate_clear <= 0.0 or absf(x) > gate_clear:
			slots.append(x)
		x += 90.0
	return slots


## 贴图缺失时用 StoneBrickGen 兜底烘焙（与离线烘焙同一算法）
func _load_or_bake_seg() -> Texture2D:
	if ResourceLoader.exists(SEG_TEX_PATH):
		return load(SEG_TEX_PATH)
	push_warning("[SiegeWall] 烘焙贴图缺失，运行时重生成: " + SEG_TEX_PATH)
	var img := StoneBrickGenScript.make_crenellated(TEX_SEG_W, TEX_WALL_H, 20260906,
			TEX_MERLON_H, 56, Vector2i(64, 30))
	return ImageTexture.create_from_image(img)
