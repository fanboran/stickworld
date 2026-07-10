extends Node
## 游戏配置管理（音量、显示、语言等用户设置）。
##
## 使用 Godot 内置的 ConfigFile（类 INI 格式）将玩家设置持久化到 user://settings.cfg。
## 任何设置的变更都会发出对应信号，方便 UI/音频/渲染等系统即时响应。

const SETTINGS_PATH := "user://settings.cfg"

# 音量通道
const VOLUME_CHANNELS := ["master", "bgm", "sfx"]

# 默认值表。首次启动用这些值初始化。
var _defaults: Dictionary = {
	"audio/master_volume": 0.8,
	"audio/bgm_volume": 0.7,
	"audio/sfx_volume": 0.9,
	"display/fullscreen": false,
	"display/vsync": true,
	"display/resolution_width": 1280,
	"display/resolution_height": 720,
	"game/language": "zh",
	"game/auto_save_interval_sec": 60,
}

# 内存副本
var _data: Dictionary

# 设置变更信号。
signal config_changed(key: String, value)
signal volume_changed(channel: String, value: float)
signal display_changed(key: String, value)


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_data = _defaults.duplicate(true)
	load_from_disk()


## 从磁盘加载配置。文件不存在或损坏则使用默认值并立即写一份。
func load_from_disk() -> void:
	_data = _defaults.duplicate(true)
	var cfg: ConfigFile = ConfigFile.new()
	var err: int = cfg.load(SETTINGS_PATH)
	if err != OK:
		save_to_disk()
		return
	# 合并：文件中的值覆盖默认值
	for section_key in cfg.get_sections():
		for key in cfg.get_section_keys(section_key):
			var full_key: String = "%s/%s" % [section_key, key]
			var def_val = null
			if _defaults.has(full_key):
				def_val = _defaults[full_key]
			_data[full_key] = cfg.get_value(section_key, key, def_val)


## 立即把当前内存中的配置写入磁盘。
func save_to_disk() -> void:
	var cfg: ConfigFile = ConfigFile.new()
	for key in _data.keys():
		var s: String = key
		var idx: int = s.find("/")
		if idx < 0:
			continue
		var section: String = s.substr(0, idx)
		var k: String = s.substr(idx + 1, -1)
		cfg.set_value(section, k, _data[key])
	var err: int = cfg.save(SETTINGS_PATH)
	if err != OK:
		push_warning("[ConfigManager] 保存配置失败: %s" % SETTINGS_PATH)


## 重置为默认值并立即落盘。
func reset_to_defaults() -> void:
	_data = _defaults.duplicate(true)
	save_to_disk()
	config_changed.emit("", null)


# ─────────────────────────────── 通用读写 ───────────────────────────────

## 读取任意键的值。
func get_value(key: String):
	if _data.has(key):
		return _data[key]
	return null


## 设置任意键的值，自动落盘并发出 config_changed。
func set_value(key: String, value) -> void:
	if (not _data.has(key)) or _data[key] != value:
		_data[key] = value
		save_to_disk()
		config_changed.emit(key, value)


## 键是否存在。
func has_key(key: String) -> bool:
	return _data.has(key)


# ─────────────────────────────── 音量相关快捷函数 ─────────────────────────────

func get_volume(channel: String) -> float:
	var key: String = "audio/%s_volume" % channel
	if _data.has(key):
		return float(_data[key])
	return 0.8


func set_volume(channel: String, value: float) -> void:
	if VOLUME_CHANNELS.find(channel) == -1:
		push_warning("[ConfigManager] 未知音量通道: %s" % channel)
		return
	var clamped: float = clamp(value, 0.0, 1.0)
	var key: String = "audio/%s_volume" % channel
	set_value(key, clamped)
	volume_changed.emit(channel, clamped)
	if channel == "master":
		AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"),
			linear_to_db(clamped))


static func linear_to_db(value: float) -> float:
	if value <= 0.0:
		return -80.0
	return 20.0 * (log(value) / log(10.0))


# ─────────────────────────────── 显示相关快捷函数 ─────────────────────────────

func is_fullscreen() -> bool:
	if _data.has("display/fullscreen"):
		return bool(_data["display/fullscreen"])
	return false


func set_fullscreen(value: bool) -> void:
	set_value("display/fullscreen", value)
	display_changed.emit("fullscreen", value)
	if value:
		get_window().mode = Window.MODE_FULLSCREEN
	else:
		get_window().mode = Window.MODE_WINDOWED


func is_vsync() -> bool:
	if _data.has("display/vsync"):
		return bool(_data["display/vsync"])
	return true


func set_vsync(value: bool) -> void:
	set_value("display/vsync", value)
	display_changed.emit("vsync", value)
	if value:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


func get_resolution() -> Vector2i:
	var w: int = 1280
	var h: int = 720
	if _data.has("display/resolution_width"):
		w = int(_data["display/resolution_width"])
	if _data.has("display/resolution_height"):
		h = int(_data["display/resolution_height"])
	return Vector2i(w, h)


func set_resolution(size: Vector2i) -> void:
	set_value("display/resolution_width", size.x)
	set_value("display/resolution_height", size.y)
	display_changed.emit("resolution", size)
	if not is_fullscreen():
		get_window().size = size


# ─────────────────────────────── 游戏相关快捷函数 ─────────────────────────────

func get_language() -> String:
	if _data.has("game/language"):
		return String(_data["game/language"])
	return "zh"


func set_language(lang: String) -> void:
	set_value("game/language", lang)


func get_auto_save_interval() -> int:
	if _data.has("game/auto_save_interval_sec"):
		return int(_data["game/auto_save_interval_sec"])
	return 60


func set_auto_save_interval(sec: int) -> void:
	set_value("game/auto_save_interval_sec", int(clamp(sec, 0, 3600)))