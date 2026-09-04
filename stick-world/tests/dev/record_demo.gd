extends Node
## 演示视频录制（dev 层）——配合 --write-movie PNG 序列 + PIL 合成 GIF。
## 流程：开局（提示+目标卡）→ 传送至资源点按住 E 连采（飘字+弹跳+绿闪）
## → 松开向右移动（天空/远山/贴图/后处理全程入镜）。
## 用法：godot --path . --write-movie F:/tmp/frames/rec.png --fixed-fps 24
##       --quit-after 220 res://tests/dev/record_demo.tscn

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null
var _frame: int = 0


func _ready() -> void:
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)


func _physics_process(_delta: float) -> void:
	_frame += 1
	match _frame:
		45:
			_teleport_to_resource()
		50:
			_hold_key(KEY_E, true)
		160:
			_hold_key(KEY_E, false)
		170:
			_hold_key(KEY_D, true)
		205:
			_hold_key(KEY_D, false)


## 传送到最近资源点旁（采集画面入镜）
func _teleport_to_resource() -> void:
	var player := _find_player()
	if player == null:
		return
	var best: Node2D = null
	var best_d: float = 1e9
	for n in get_tree().get_nodes_in_group("resource_node"):
		var rn := n as Node2D
		if rn == null or not is_instance_valid(rn):
			continue
		var d: float = absf(rn.global_position.x - player.global_position.x)
		if d < best_d:
			best_d = d
			best = rn
	if best != null:
		player.global_position = best.global_position + Vector2(-52.0, 0.0)
		print("[REC] teleported to resource at ", best.global_position)


## 合成按键按下/抬起（项目用 Input.is_key_pressed 轮询，parse_input_event 可更新状态）
func _hold_key(keycode: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = pressed
	ev.echo = false
	Input.parse_input_event(ev)
	print("[REC] key ", keycode, " ", "down" if pressed else "up", " @frame ", _frame)


func _find_player() -> Node2D:
	var m: Node2D = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
	if m == null or not m.has_method("get_entities"):
		return null
	for e in m.get_entities():
		var ent := e as Node2D
		if ent != null and ent.has_method("is_possessed") and ent.is_possessed():
			return ent
	return null
