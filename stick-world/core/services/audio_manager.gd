extends Node
## 音频管理器（BGM、SFX）。
##
## 提供 play_bgm / stop_bgm / play_sfx 等方法。
## 音量的唯一消费方：通道音量（master/bgm/sfx）应用到 AudioServer 总线
## （Master / BGM / SFX，缺总线时自动创建并路由到 Master），
## 播放器只挂总线、不再各自叠 volume_db；存储仍由 ConfigManager 统一持有。
##
## ⚠️ 音效资产状态：SFX 已接入（Terraria 提取件 + 程序合成，见 SFX_EVENTS 表）；
## 提取件登记于 docs/项目/素材替换清单.md，公开前须替换。

signal bgm_playing(path: String)
signal bgm_stopped()

## AudioServer 总线名（设置面板音量 → 总线的映射目标）
const BUS_MASTER := "Master"
const BUS_BGM := "BGM"
const BUS_SFX := "SFX"

# BGM 播放器（常驻，挂 BGM 总线）
var _bgm_player: AudioStreamPlayer = null
# 天气循环播放器（常驻，挂 SFX 总线；雨声等环境层）
var _weather_player: AudioStreamPlayer = null
# 同时播放中的 SFX 列表（挂 SFX 总线）
var _sfx_players: Array = []

var _current_bgm_path: String = ""
var _volumes: Dictionary = {
	"master": 1.0,
	"bgm": 0.7,
	"sfx": 0.9,
}

## 失焦静音（设置面板 audio/mute_when_unfocused）
var _mute_on_unfocus: bool = false
## 当前是否因失焦被静音
var _unfocused_muted: bool = false
## 静音前的主音量（恢复用）
var _master_before_mute: float = 1.0


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_ensure_buses()
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.bus = BUS_BGM
	_bgm_player.name = "_BGMPlayer"
	add_child(_bgm_player)
	_weather_player = AudioStreamPlayer.new()
	_weather_player.bus = BUS_SFX
	_weather_player.name = "_WeatherPlayer"
	add_child(_weather_player)

	_apply_initial_volumes()

	if ConfigManager and ConfigManager.has_signal("volume_changed"):
		ConfigManager.volume_changed.connect(_on_volume_changed)
	# 失焦静音（audio/mute_when_unfocused）
	if ConfigManager and ConfigManager.has_key("audio/mute_when_unfocused"):
		_mute_on_unfocus = bool(ConfigManager.get_value("audio/mute_when_unfocused"))
	var win := get_window()
	if win:
		win.focus_exited.connect(_on_focus_exited)
		win.focus_entered.connect(_on_focus_entered)
	if _mute_on_unfocus and win and not win.has_focus():
		_apply_mute()
	# SFX 事件接线（战斗/存档生命周期；音效资产未就位时静默）
	_wire_event_bus()


func _apply_initial_volumes() -> void:
	if not ConfigManager:
		return
	for ch in ["master", "bgm", "sfx"]:
		var key: String = "audio/%s_volume" % ch
		if ConfigManager.has_key(key):
			var raw = ConfigManager.get_value(key)
			if raw != null:
				_volumes[ch] = float(raw)
	_apply_volumes_to_buses()


func _on_volume_changed(channel: String, value: float) -> void:
	_volumes[channel] = value
	_apply_volumes_to_buses()


## 确保 BGM / SFX 总线存在并路由到 Master（默认工程只有 Master 一条总线）。
func _ensure_buses() -> void:
	for bus_name in [BUS_BGM, BUS_SFX]:
		if AudioServer.get_bus_index(bus_name) != -1:
			continue
		var idx: int = AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, BUS_MASTER)


## 通道音量 → AudioServer 总线（线性 0~1 → dB）。
func _apply_volumes_to_buses() -> void:
	_set_bus_volume_db(BUS_MASTER, float(_volumes["master"]))
	_set_bus_volume_db(BUS_BGM, float(_volumes["bgm"]))
	_set_bus_volume_db(BUS_SFX, float(_volumes["sfx"]))


func _set_bus_volume_db(bus_name: String, linear: float) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_volume_db(idx, _to_db(linear))


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
	_bgm_player.play()
	_current_bgm_path = path
	bgm_playing.emit(path)


func stop_bgm() -> void:
	if _bgm_player and _bgm_player.playing:
		_bgm_player.stop()
		_current_bgm_path = ""
		bgm_stopped.emit()


func is_bgm_playing() -> bool:
	return _bgm_player and _bgm_player.playing


# ─────────────────────────────── SFX 播放 ────────────────────────────────

func play_sfx(path: String) -> AudioStreamPlayer:
	var stream: AudioStream = load(path)
	if stream == null:
		push_warning("[AudioManager] 加载 SFX 失败: %s" % path)
		return null
	var player: AudioStreamPlayer = AudioStreamPlayer.new()
	player.bus = BUS_SFX
	player.stream = stream
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


# ─────────────────────────────── 天气环境层（雨声等循环）────────────────────────────────

## 循环播放天气音（雨声）；volume_linear 随强度刷新，切 asset 幂等
func play_weather(path: String, volume_linear: float = 0.5) -> void:
	if _weather_player == null or not ResourceLoader.exists(path):
		return
	var stream: AudioStream = _weather_player.stream
	if stream == null or stream.resource_path != path:
		stream = load(path)
		if stream == null:
			return
		if stream is AudioStreamWAV:
			# WAV 无缝循环：loop_end=帧数（16bit 单声道 → 字节数/2）
			(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
			(stream as AudioStreamWAV).loop_begin = 0
			(stream as AudioStreamWAV).loop_end = (stream as AudioStreamWAV).data.size() / 2
		_weather_player.stream = stream
	_weather_player.volume_db = _to_db(clampf(volume_linear, 0.001, 1.0))
	if not _weather_player.playing:
		_weather_player.play()


func stop_weather() -> void:
	if _weather_player != null and _weather_player.playing:
		_weather_player.stop()


# ─────────────────────────────── 失焦静音 ────────────────────────────────

## 设置失焦静音开关（设置面板 audio/mute_when_unfocused）。
## 关闭时立即恢复被静音的主音量；开启且当前失焦时立即静音。
func set_mute_on_unfocus(enabled: bool) -> void:
	_mute_on_unfocus = enabled
	if not enabled:
		if _unfocused_muted:
			_restore_master()
	elif get_window() != null and not get_window().has_focus():
		_apply_mute()


func _on_focus_exited() -> void:
	if _mute_on_unfocus:
		_apply_mute()


func _on_focus_entered() -> void:
	if _unfocused_muted:
		_restore_master()


## 静音主总线（记住当前主音量供恢复）
func _apply_mute() -> void:
	_unfocused_muted = true
	_master_before_mute = float(_volumes.get("master", 1.0))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), -80.0)


## 恢复主音量
func _restore_master() -> void:
	_unfocused_muted = false
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), _to_db(_master_before_mute))


# ─────────────────────────────── SFX 事件框架（2026-08-22）────────────────────────────────

## 语义化事件 → 音效资产映射表（值可单路径或路径数组=随机变体）。
## 采集/UI 等反馈音为 Terraria 提取件，其余由 tools/ai/gen_sfx.py 程序化合成
## （WAV），按表放入 res://assets/audio/sfx/ 即生效，调用点零改动。
const SFX_EVENTS := {
	"ui_click":           "res://assets/audio/sfx/ui_click.wav",
	"ui_confirm":         "res://assets/audio/sfx/ui_confirm.wav",
	"game_started":       "res://assets/audio/sfx/game_started.wav",
	"game_saved":         "res://assets/audio/sfx/game_saved.wav",
	"build_complete":     "res://assets/audio/sfx/build_complete.wav",
	"battle_started":     "res://assets/audio/sfx/battle_started.wav",
	"battle_ended_win":   "res://assets/audio/sfx/battle_ended_win.wav",
	"battle_ended_lose":  "res://assets/audio/sfx/battle_ended_lose.wav",
	# 采集/UI 反馈音为 Terraria 提取件（tools/ai/extract_terraria_sfx.py，
	# 登记于 docs/项目/素材替换清单.md）；敲击用 Dig 三变体随机、树木用砍草音
	"harvest_hit": [
		"res://assets/audio/sfx/harvest_hit_a.wav",
		"res://assets/audio/sfx/harvest_hit_b.wav",
		"res://assets/audio/sfx/harvest_hit_c.wav",
	],
	"harvest_wood":       "res://assets/audio/sfx/harvest_wood.wav",
	"harvest_gain":       "res://assets/audio/sfx/harvest_gain.wav",
	"quest_done":         "res://assets/audio/sfx/quest_done.wav",
	"ui_hover":           "res://assets/audio/sfx/ui_hover.wav",
	"unit_hurt":          "res://assets/audio/sfx/unit_hurt.wav",
	# 天空生命感：远处鸟啁啾（与飞鸟群生成配对，三变体随机）
	"bird_chirp_a":       "res://assets/audio/sfx/bird_chirp_a.wav",
	"bird_chirp_b":       "res://assets/audio/sfx/bird_chirp_b.wav",
	"bird_chirp_c":       "res://assets/audio/sfx/bird_chirp_c.wav",
}

## 每事件最后一次播放器（重触发先停旧实例，防同音效叠成音墙）
var _event_players: Dictionary = {}
## 随机音高抖动幅度（Terraria LegacySoundPlayer 的 Pitch 抖动同构：
## 相同音效连播时靠音高微差避免"机关枪式的机械重复感"）
const PITCH_JITTER := 0.05


## 按语义事件名播放（Terraria LegacySoundPlayer.PlaySound 同构）：
## 同事件重触发先停上一个实例（Stop-and-restart 防叠音），并加随机音高抖动。
## 值为数组时 = 变体池随机挑一（Dig_0/1/2 同构）。资产未就位时静默跳过。
func play_event(event_name: String) -> void:
	if not SFX_EVENTS.has(event_name):
		push_warning("[AudioManager] 未注册的音效事件: %s" % event_name)
		return
	var entry: Variant = SFX_EVENTS[event_name]
	var paths: Array = entry if entry is Array else [entry]
	var path: String = ""
	for p in paths:
		if ResourceLoader.exists(p):
			path = p
			break
	if paths.size() > 1 and not path.is_empty():
		path = paths[randi() % paths.size()]
	if path.is_empty():
		print_verbose("[AudioManager] 音效资产未就位，跳过: %s" % event_name)
		return
	var prev = _event_players.get(event_name)
	if prev != null and is_instance_valid(prev) and prev.playing:
		prev.stop()
	var player := play_sfx(path)
	if player == null:
		return
	player.pitch_scale = 1.0 + randf_range(-PITCH_JITTER, PITCH_JITTER)
	_event_players[event_name] = player


## 接线 EventBus 全局生命周期信号（战斗/存档；UI 点击由 StickKit 直接调 play_event）
func _wire_event_bus() -> void:
	if not EventBus or not EventBus.has_signal("battle_started"):
		return
	EventBus.game_started.connect(func() -> void:
		play_event("game_started")
		play_bgm("res://assets/audio/bgm/ambient_pad.wav"))
	EventBus.game_saved.connect(func(_slot: int) -> void: play_event("game_saved"))
	EventBus.battle_started.connect(func(_battle_id: String) -> void: play_event("battle_started"))
	EventBus.battle_ended.connect(func(_battle_id: String, victory: bool) -> void:
		play_event("battle_ended_win" if victory else "battle_ended_lose"))


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
	_apply_volumes_to_buses()


func get_volume(channel: String) -> float:
	if _volumes.has(channel):
		return float(_volumes[channel])
	return 1.0


# ─────────────────────────────── 工具 ───────────────────────────────────

static func _to_db(linear: float) -> float:
	if linear <= 0.0:
		return -80.0
	return 20.0 * (log(linear) / log(10.0))