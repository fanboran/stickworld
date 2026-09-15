extends Node
## 实机验证入口场景：把流程 runner 挂到 SceneTree.root（跨场景存活——
## change_scene_to_file 会释放当前场景，流程脚本绝不能长在场景根上，
## ui_shots_driver 同款教训）。

const RunnerScript := preload("res://tests/dev/verify_townlife_runner.gd")


func _ready() -> void:
	var runner: Node = RunnerScript.new()
	runner.name = "TownlifeVerifyRunner"
	get_tree().root.add_child.call_deferred(runner)
