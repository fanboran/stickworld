extends Node
## 夜空演示录制（dev 层）——配合 --write-movie PNG 序列 + PIL 合成 GIF。
## 流程：开场运镜（zoom 0.45 缓推）中切入 23:00 → 星野淡入 + 月亮升起
## → 飞鸟群从画面内横穿（星月鸟同框）。
## 用法：godot --path . --write-movie F:/tmp/night_frames/rec.png --fixed-fps 24
##       --quit-after 240 res://tests/dev/record_night.tscn

const GameRootScene := preload("res://modules/world/scenes/game_root.tscn")

var _game_root: Node = null
var _frame: int = 0


func _ready() -> void:
	_game_root = GameRootScene.instantiate()
	add_child(_game_root)


func _physics_process(_delta: float) -> void:
	_frame += 1
	match _frame:
		10:
			_disable_grain()
		20:
			_set_night()
		95:
			_spawn_birds()


## 关胶片颗粒：逐帧噪声会让 GIF 增量压缩失效（体积爆炸），录制时静音该层
func _disable_grain() -> void:
	var post: Node = _game_root.get_node_or_null("PostProcess")
	if post != null and post.has_method("set_grain_override"):
		post.set_grain_override(0.0)
		print("[REC] grain disabled for recording")


func _set_night() -> void:
	var env: Node = _game_root.get_node_or_null("EnvironmentSystem")
	if env != null and env.has_method("set_time_of_day"):
		env.set_time_of_day(23.0)
		print("[REC] switched to 23:00")


func _spawn_birds() -> void:
	var m: Node = _game_root.get_current_map() if _game_root.has_method("get_current_map") else null
	if m == null:
		return
	var birds: Node = m.get_node_or_null("SkyDecor/Birds")
	if birds != null and birds.has_method("spawn_flock"):
		birds.spawn_flock(true)
		print("[REC] birds in view")
