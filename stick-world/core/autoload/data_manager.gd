extends Node

var data_path: String:
	get:
		if OS.has_feature("editor") or OS.has_feature("debug"):
			return ProjectSettings.globalize_path("res://../export/savegame.json")
		else:
			return ProjectSettings.globalize_path("user://data/savegame.json")

var _data: Dictionary = {}

func _ready() -> void:
	load_data()

## 加载数据
func load_data() -> void:
	_data = FileUtils.load_json(data_path)

## 读取
func data_get(key: String, default = null):
	return _data.get(key, default)

## 写入
func data_set(key: String, value) -> void:
	_data[key] = value

## 保存
func save_data() -> void:
	FileUtils.save_json(data_path, _data)
