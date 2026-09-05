class_name SketchTextures
extends RefCounted
## 手绘贴图集 —— assets/ui/sketch 的沸腾帧贴图（tools 生成：见 temp/gen_sketch_ui_a10.py）。
##
## AnimatedTexture 在 StyleBoxTexture 渲染路径不推进帧 → 全局 _FrameDriver
## 定时把注册的九宫格 stylebox 换到下一帧贴图（真沸腾）。

const DIR := "res://assets/ui/sketch/"
const FRAMES := 3
const FPS := 7.5
## 九宫格边距（与生成脚本 MARGIN 同值）
const MARGIN := 10

static var _frame_sets: Dictionary = {}
static var _boxes: Array[StyleBoxTexture] = []
static var _slot_map: Dictionary = {}
static var _step: int = 0
static var _driver: Node


static func ensure_driver(tree: SceneTree) -> void:
	if _driver != null and is_instance_valid(_driver):
		return
	_driver = _FrameDriver.new()
	tree.root.add_child(_driver)


## 注册九宫格 stylebox 到帧轮换（SketchStyle._box 内部调用）
static func register_box(sb: StyleBoxTexture, slot: StringName) -> void:
	if _frame_sets.is_empty():
		_load_all()
	_boxes.append(sb)
	_slot_map[sb] = slot
	if _frame_sets.has(slot):
		sb.texture = (_frame_sets[slot] as Array)[_step]


static func _advance() -> void:
	_step = (_step + 1) % FRAMES
	for sb in _boxes:
		if sb == null or not is_instance_valid(sb):
			continue
		var frames: Array = _frame_sets.get(_slot_map.get(sb, &"panel"), [])
		if not frames.is_empty():
			sb.texture = frames[_step]


static func _load_all() -> void:
	for slot in ["panel", "panel_light", "groove", "groove_focus",
			"btn_normal", "btn_hover", "btn_pressed", "btn_disabled",
			"accent_normal", "accent_hover", "accent_pressed",
			"danger_normal", "danger_hover",
			"tab_selected", "tab_hover",
			"progress_bg", "progress_fill", "sep_h", "sep_v"]:
		var frames: Array[Texture2D] = []
		for i in FRAMES:
			var tex := load("%s%s_f%d.png" % [DIR, slot, i]) as Texture2D
			if tex == null:
				push_warning("[SketchTextures] 贴图缺失：%s_f%d" % [slot, i])
				return
			frames.append(tex)
		_frame_sets[StringName(slot)] = frames


class _FrameDriver extends Node:
	var _t: float = 0.0
	func _process(delta: float) -> void:
		_t += delta
		if _t < 1.0 / SketchTextures.FPS:
			return
		_t = 0.0
		SketchTextures._advance()
