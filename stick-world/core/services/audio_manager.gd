extends Node
## 音频管理器（BGM、SFX）。
##
## 提供 play_bgm / stop_bgm / play_sfx 等方法。
## 所有音量受 ConfigManager 统一控制。
##
## ⚠️ 接线状态（2026-08 审计）：全项目无消费方（音效未实现），autoload 注册保留，
## P1 音效接入时启用。

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

## 失焦静音（设置面板 audio/mute_when_unfocused）
var _mute_on_unfocus: bool = false
## 当前是否因失焦被静音
var _unfocused_muted: bool = false
## 静音前的主音量（恢复用）
var _master_before_mute: float = 1.0


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.bus = "Master"
	_bgm_player.name = "_BGMPlayer"
	add_child(_bgm_player)

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

## 语义化事件 → 音效资产映射表（PLACEHOLDER：项目尚无音频文件，路径为约定占位；
## 资产到位后按此表放入 res://assets/audio/sfx/ 即生效，调用点零改动）。
## 替换清单见 docs/项目/待办事项.md「PLACEHOLDER 素材替换」。
const SFX_EVENTS := {
	"ui_click":           "res://assets/audio/sfx/ui_click.ogg",
	"ui_confirm":         "res://assets/audio/sfx/ui_confirm.ogg",
	"game_started":       "res://assets/audio/sfx/game_started.ogg",
	"game_saved":         "res://assets/audio/sfx/game_saved.ogg",
	"build_complete":     "res://assets/audio/sfx/build_complete.ogg",
	"battle_started":     "res://assets/audio/sfx/battle_started.ogg",
	"battle_ended_win":   "res://assets/audio/sfx/battle_ended_win.ogg",
	"battle_ended_lose":  "res://assets/audio/sfx/battle_ended_lose.ogg",
}

## 按语义事件名播放。资产未就位时静默跳过（print_verbose，不刷警告）。
func play_event(event_name: String) -> void:
	if not SFX_EVENTS.has(event_name):
		push_warning("[AudioManager] 未注册的音效事件: %s" % event_name)
		return
	var path: String = SFX_EVENTS[event_name]
	if not ResourceLoader.exists(path):
		print_verbose("[AudioManager] 音效资产未就位，跳过: %s" % path)
		return
	play_sfx(path)


## 接线 EventBus 全局生命周期信号（战斗/存档；UI 点击由 StickKit 直接调 play_event）
func _wire_event_bus() -> void:
	if not EventBus or not EventBus.has_signal("battle_started"):
		return
	EventBus.game_started.connect(func() -> void: play_event("game_started"))
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