extends Node
## 音频管理器（BGM、SFX）。
##
## 提供 play_bgm / stop_bgm / play_sfx 等方法。
## 所有音量受 ConfigManager 统一控制。

signal bgm_playing(path: String)
signal bgm_stopped()

# BGM 播放器（常驻）
var _bgm_player: AudioStreamPlayer = null
# 同时播放中的 SFX 列表
var _sfx_players: Array = []

var _current_bgm_path: String = ""
var _volumes: Dictionary = {
	"master": 1.0,
	"bgm": 0.7,
	"sfx": 0.9,
}


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.bus = "Master"
	_bgm_player.name = "_BGMPlayer"
	add_child(_bgm_player)

	_apply_initial_volumes()

	if ConfigManager and ConfigManager.has_signal("volume_changed"):
		ConfigManager.volume_changed.connect(_on_volume_changed)


func _apply_initial_volumes() -> void:
	if not ConfigManager:
		return
	for ch in ["master", "bgm", "sfx"]:
		var key: String = "audio/%s_volume" % ch
		if ConfigManager.has_key(key):
			var raw = ConfigManager.get_value(key)
			if raw != null:
				_volumes[ch] = float(raw)
	_apply_volumes_to_players()


func _on_volume_changed(channel: String, value: float) -> void:
	_volumes[channel] = value
	_apply_volumes_to_players()


func _apply_volumes_to_players() -> void:
	if _bgm_player:
		_bgm_player.volume_db = _to_db(float(_volumes["master"]) * float(_volumes["bgm"]))
	for p in _sfx_players:
		if p and is_instance_valid(p):
			p.volume_db = _to_db(float(_volumes["master"]) * float(_volumes["sfx"]))


# ─────────────────────────────── BGM 播放 ────────────────────────────────

func play_bgm(path: String, loop: bool = true) -> void:
	if _bgm_player == null:
		return
	if _current_bgm_path == path and _bgm_player.playing:
		return
	var stream: AudioStream = load(path)
	if stream == null:
		push_warning("[AudioManager] 加载 BGM 失败: %s" % path)
		return
	if stream is AudioStreamMP3:
		stream.loop = loop
	elif stream is AudioStreamOggVorbis:
		stream.loop = loop
	_bgm_player.stream = stream
	_bgm_player.volume_db = _to_db(float(_volumes["master"]) * float(_volumes["bgm"]))
	_bgm_player.play()
	_current_bgm_path = path
	emit_signal("bgm_playing", path)


func stop_bgm() -> void:
	if _bgm_player and _bgm_player.playing:
		_bgm_player.stop()
		_current_bgm_path = ""
		emit_signal("bgm_stopped")


func is_bgm_playing() -> bool:
	return _bgm_player and _bgm_player.playing


# ─────────────────────────────── SFX 播放 ────────────────────────────────

func play_sfx(path: String) -> AudioStreamPlayer:
	var stream: AudioStream = load(path)
	if stream == null:
		push_warning("[AudioManager] 加载 SFX 失败: %s" % path)
		return null
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.bus = "Master"
	player.stream = stream
	player.volume_db = _to_db(float(_volumes["master"]) * float(_volumes["sfx"]))
	add_child(player)
	_sfx_players.append(player)
	player.finished.connect(_on_sfx_finished.bind(player))
	player.play()
	return player


func _on_sfx_finished(player: AudioStreamPlayer) -> void:
	if _sfx_players.find(player) != -1:
		_sfx_players.erase(player)
	if is_instance_valid(player):
		player.queue_free()


func stop_all_sfx() -> void:
	var snapshot: Array = []
	for p in _sfx_players:
		snapshot.append(p)
	for p in snapshot:
		if p and is_instance_valid(p):
			p.stop()


# ─────────────────────────────── 音量控制 ────────────────────────────────

func set_volume(channel: String, value: float) -> void:
	var clamped: float = clamp(value, 0.0, 1.0)
	if _volumes.has(channel):
		_volumes[channel] = clamped
	if ConfigManager:
		ConfigManager.set_volume(channel, clamped)
	_apply_volumes_to_players()


func get_volume(channel: String) -> float:
	if _volumes.has(channel):
		return float(_volumes[channel])
	return 1.0


# ─────────────────────────────── 工具 ───────────────────────────────────

static func _to_db(linear: float) -> float:
	if linear <= 0.0:
		return -80.0
	return 20.0 * (log(linear) / log(10.0))