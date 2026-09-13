extends Node
## 音频管理器（BGM、SFX）。
##
## 提供 play_bgm / stop_bgm / play_event 等方法。
## 音量的唯一消费方：通道音量（master/bgm/sfx）应用到 AudioServer 总线
## （Master / BGM / SFX，缺总线时自动创建并路由到 Master），
## 播放器只挂总线、不再各自叠 volume_db；存储仍由 ConfigManager 统一持有。
##
## 音效：**唯一入口是 play_event(事件名, 世界坐标)**。事件→资产在 SFX_EVENTS，
## 播放策略（节流 / 同帧合并 / 声部预算 / 变体池 / 音高抖动 / 定位）在 SFX_POLICY，
## 两者是同一真相源——加音效不动调用点。触发时机与分层的设计依据见
## docs/技术/音频/音效触发规范.md。
##
## ⚠️ 音效资产状态：战斗系为 SWL 提取件、采集/UI 等为 Terraria 提取件、
## 其余程序合成（见 SFX_EVENTS 表）；提取件登记于 docs/项目/素材替换清单.md，
## 公开前须替换。

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

## 音乐压限**请求集**（具名 source → dB，如 {"pause": -9.0, "battle": -6.0}）。
## 生效值 = min(所有请求)，即"相加深者胜"：多个请求方（暂停 / 战斗 / 结算短句）
## 各自独立提出与撤销，互不覆盖。
##
## 为什么必须是集合：单标量下"最后写赢"——battle_started 时 TimeManager 先
## pause()（请求 -9），MusicDirector 后请求战斗档（-6），净结果只剩 -6dB，
## 即"战斗中暂停"拿不到暂停档的压限。放在这里而不是让请求方自己写总线的原因：
## **总线音量的唯一消费方是本管理器**（设置面板的音量滑条也走这里）。
var _duck_requests: Dictionary = {}
var _duck_tween: Tween = null


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
	_ensure_sfx_limiter()


## SFX 总线末端硬限幅（安全网）：单条音效自己不会削波，但人群战斗里十几路叠加
## 会在 Master 前越顶。限幅器只管"叠出来的峰"，不改单条音效的音色。
## ceiling 留 -1.0dBFS，比 Master 满刻度低一点，给后续叠加留余量。
const SFX_LIMITER_CEILING_DB := -1.0

func _ensure_sfx_limiter() -> void:
	var idx: int = AudioServer.get_bus_index(BUS_SFX)
	if idx < 0:
		return
	for i in AudioServer.get_bus_effect_count(idx):
		if AudioServer.get_bus_effect(idx, i) is AudioEffectHardLimiter:
			return
	var limiter := AudioEffectHardLimiter.new()
	limiter.ceiling_db = SFX_LIMITER_CEILING_DB
	limiter.pre_gain_db = 0.0
	AudioServer.add_bus_effect(idx, limiter)


## 通道音量 → AudioServer 总线（线性 0~1 → dB）。
## BGM 总线额外叠加音乐压限量（见 _duck_requests）。
func _apply_volumes_to_buses() -> void:
	_set_bus_volume_db(BUS_MASTER, float(_volumes["master"]))
	_set_bus_volume_db(BUS_BGM, float(_volumes["bgm"]), _effective_duck_db())
	_set_bus_volume_db(BUS_SFX, float(_volumes["sfx"]))


func _set_bus_volume_db(bus_name: String, linear: float,
		extra_db: float = 0.0) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_volume_db(idx, _to_db(linear) + extra_db)


## 提出/更新一个具名音乐压限请求（dB，负数=压低）。fade_s>0 时用等功率曲线
## 过渡，避免压限本身听出"台阶"。音量滑条变动时会自动带上当前的合成压限量。
func request_music_duck(source: StringName, db: float, fade_s: float = 0.0) -> void:
	if db >= 0.0:
		_duck_requests.erase(source)
	else:
		_duck_requests[source] = db
	_apply_duck(fade_s)


## 撤销一个具名压限请求（其余请求仍在，音乐只回到"剩下的最深那个"）。
func release_music_duck(source: StringName, fade_s: float = 0.0) -> void:
	_duck_requests.erase(source)
	_apply_duck(fade_s)


## 当前生效压限量 = 最深的那条请求（无请求 = 0dB）。
func _effective_duck_db() -> float:
	var eff: float = 0.0
	for v in _duck_requests.values():
		eff = minf(eff, float(v))
	return eff


func _apply_duck(fade_s: float) -> void:
	var idx: int = AudioServer.get_bus_index(BUS_BGM)
	if idx < 0:
		return
	var target: float = _to_db(float(_volumes["bgm"])) + _effective_duck_db()
	if _duck_tween != null and _duck_tween.is_valid():
		_duck_tween.kill()
	if fade_s <= 0.0:
		AudioServer.set_bus_volume_db(idx, target)
		return
	_duck_tween = create_tween()
	_duck_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_duck_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_duck_tween.tween_method(
		func(v: float) -> void: AudioServer.set_bus_volume_db(idx, v),
		AudioServer.get_bus_volume_db(idx), target, fade_s)


## 兼容入口（旧签名：单请求方 MusicDirector 直接写标量）。
func set_music_duck_db(db: float, fade_s: float = 0.0) -> void:
	request_music_duck(&"music_director", db, fade_s)


func get_music_duck_db() -> float:
	return _effective_duck_db()


## 当前全部压限请求（调试/测试用，键为 source）。
func get_music_duck_requests() -> Dictionary:
	return _duck_requests.duplicate()


# ─────────────────────────────── BGM 播放 ────────────────────────────────
#
# 说明：游戏音乐的播放**已交给 MusicDirector**（分层/交叉淡化/自适应强度都在那边）。
# 本节的 play_bgm/stop_bgm 保留为"单文件直放"的底层能力（调试、单曲试听、
# 未来的一次性过场），不再被游戏流程调用。音量仍然走同一条 BGM 总线。

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

## 底层直放（**不走策略表也不受声部预算约束**：无节流/无合并/无优先级/无定位）。
## 仅供调试与一次性试听使用；游戏内的音效一律走 play_event(name, world_pos)。
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


func _on_sfx_finished(player: Node) -> void:
	if _sfx_players.find(player) != -1:
		_sfx_players.erase(player)
	_player_book.erase(player)
	if is_instance_valid(player):
		player.queue_free()


## 立即回收一个 SFX 播放器。手动 stop() 不触发 finished（Godot 语义：
## finished 仅自然播完时发出），必须显式出列+释放，否则节点永久泄漏。
func _discard_sfx_player(player: Node) -> void:
	player.stop()
	_sfx_players.erase(player)
	_player_book.erase(player)
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


# ─────────────────────────────── SFX 事件框架 ────────────────────────────────

## 语义化事件 → 音效资产映射表（值可单路径或路径数组=随机变体池）。
## **音效的唯一真相源**：加/换音效只动这张表 + 放资产，调用点零改动。
## 条目按响亮层级分组，配套策略见 SFX_POLICY，设计依据见
## docs/技术/音频/音效触发规范.md §五（层级）与 §六（节流合并）。
## 提取件（Terraria/SWL）登记于 docs/项目/素材替换清单.md，公开前须全部替换。
const SFX_EVENTS := {
	# ── L1 关键反馈 · UI（最短、干燥、不定位）─────────────────────
	"ui_hover":           "res://assets/audio/sfx/ui_hover.wav",
	"ui_click":           "res://assets/audio/sfx/ui_click.wav",
	"ui_confirm":         "res://assets/audio/sfx/ui_confirm.wav",
	"ui_denied":          "res://assets/audio/sfx/ui_denied.wav",
	# ── L1 关键反馈 · 生命周期与仪式（与音乐并存、不抖动）─────────
	"game_started":       "res://assets/audio/sfx/game_started.wav",
	"game_saved":         "res://assets/audio/sfx/game_saved.wav",
	"build_complete":     "res://assets/audio/sfx/build_complete.wav",
	"quest_done":         "res://assets/audio/sfx/quest_done.wav",
	"victory_fanfare":    "res://assets/audio/sfx/victory_fanfare.wav",
	"battle_started":     "res://assets/audio/sfx/battle_started.wav",
	"battle_ended_win":   "res://assets/audio/sfx/battle_ended_win.wav",
	"battle_ended_lose":  "res://assets/audio/sfx/battle_ended_lose.wav",
	# ── L3 采集/劳作 · 材质敲击（变体池随机；建造与采集分键，互不掐断）──
	"harvest_hit": [
		"res://assets/audio/sfx/harvest_hit_a.wav",
		"res://assets/audio/sfx/harvest_hit_b.wav",
		"res://assets/audio/sfx/harvest_hit_c.wav",
	],
	"build_hit": [
		"res://assets/audio/sfx/harvest_hit_a.wav",
		"res://assets/audio/sfx/harvest_hit_b.wav",
		"res://assets/audio/sfx/harvest_hit_c.wav",
	],
	"harvest_wood":       "res://assets/audio/sfx/harvest_wood.wav",
	"harvest_gain":       "res://assets/audio/sfx/harvest_gain.wav",
	# ── L2 战斗反馈 · 世界物理事件（可按坐标定位；靠节流+合并控密度）──
	"unit_hurt": [
		"res://assets/audio/sfx/unit_hurt_a.wav",
		"res://assets/audio/sfx/unit_hurt_b.wav",
		"res://assets/audio/sfx/unit_hurt_c.wav",
	],
	"weapon_swoosh": [
		"res://assets/audio/sfx/swoosh_a.wav",
		"res://assets/audio/sfx/swoosh_b.wav",
		"res://assets/audio/sfx/swoosh_c.wav",
		"res://assets/audio/sfx/swoosh_d.wav",
	],
	"weapon_thump": [
		"res://assets/audio/sfx/thump_a.wav",
		"res://assets/audio/sfx/thump_b.wav",
	],
	"weapon_clang": [
		"res://assets/audio/sfx/clang_a.wav",
		"res://assets/audio/sfx/clang_b.wav",
	],
	"weapon_fall": [
		"res://assets/audio/sfx/bodyfall_a.wav",
		"res://assets/audio/sfx/bodyfall_b.wav",
		"res://assets/audio/sfx/bodyfall_c.wav",
	],
	"weapon_headbutt":    "res://assets/audio/sfx/headbutt.wav",
	"weapon_blast": [
		"res://assets/audio/sfx/magikill_blast_a.wav",
		"res://assets/audio/sfx/magikill_blast_b.wav",
	],
	# ── L4 环境（整片天空/世界，故意不做定位）────────────────────
	"bird_chirp": [
		"res://assets/audio/sfx/bird_chirp_a.wav",
		"res://assets/audio/sfx/bird_chirp_b.wav",
		"res://assets/audio/sfx/bird_chirp_c.wav",
	],
}

## 事件策略表（与 SFX_EVENTS 并列，同一真相源）。字段：
##   prio        声部预算权重：10 关键反馈 / 7 战斗与奖励 / 4 采集挥击 / 1 环境
##   min_ms      同事件两次触发的最小间隔（ms），未到即丢弃（不排队）
##   merge_slots 30ms 合并窗口内最多并成几路声部
##   jitter      音高抖动幅度（±）：UI 要稳（0~2%）、高频战斗要大（8~12%）、仪式音 0
##   spatial     是否按世界坐标定位（需调用点传 world_pos 且已注册 sfx 宿主）
##   instant     true=不进合并窗口（UI/仪式音，避免手感发闷）
## 数值为【提案/待定】，待观感验收标定。
const SFX_POLICY := {
	"ui_hover":          {"prio":  4, "min_ms": 70,   "merge_slots": 1, "jitter": 0.02, "spatial": false, "instant": true},
	"ui_click":          {"prio": 10, "min_ms": 40,   "merge_slots": 1, "jitter": 0.02, "spatial": false, "instant": true},
	"ui_confirm":        {"prio": 10, "min_ms": 120,  "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"ui_denied":         {"prio": 10, "min_ms": 150,  "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"game_started":      {"prio": 10, "min_ms": 1000, "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"game_saved":        {"prio": 10, "min_ms": 500,  "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"build_complete":    {"prio": 10, "min_ms": 400,  "merge_slots": 1, "jitter": 0.00, "spatial": true,  "instant": true},
	"quest_done":        {"prio": 10, "min_ms": 500,  "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"victory_fanfare":   {"prio": 10, "min_ms": 3000, "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"battle_started":    {"prio": 10, "min_ms": 2000, "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"battle_ended_win":  {"prio": 10, "min_ms": 2000, "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"battle_ended_lose": {"prio": 10, "min_ms": 2000, "merge_slots": 1, "jitter": 0.00, "spatial": false, "instant": true},
	"harvest_hit":       {"prio":  4, "min_ms": 60,   "merge_slots": 2, "jitter": 0.10, "spatial": true},
	"build_hit":         {"prio":  4, "min_ms": 60,   "merge_slots": 2, "jitter": 0.10, "spatial": true},
	"harvest_wood":      {"prio":  4, "min_ms": 60,   "merge_slots": 2, "jitter": 0.10, "spatial": true},
	"harvest_gain":      {"prio":  7, "min_ms": 150,  "merge_slots": 1, "jitter": 0.04, "spatial": false},
	"unit_hurt":         {"prio":  7, "min_ms": 90,   "merge_slots": 2, "jitter": 0.12, "spatial": true},
	"weapon_swoosh":     {"prio":  4, "min_ms": 50,   "merge_slots": 2, "jitter": 0.12, "spatial": true},
	"weapon_thump":      {"prio":  7, "min_ms": 120,  "merge_slots": 2, "jitter": 0.10, "spatial": true},
	"weapon_clang":      {"prio":  4, "min_ms": 80,   "merge_slots": 2, "jitter": 0.08, "spatial": true},
	"weapon_fall":       {"prio":  7, "min_ms": 120,  "merge_slots": 1, "jitter": 0.08, "spatial": true},
	"weapon_headbutt":   {"prio":  7, "min_ms": 120,  "merge_slots": 1, "jitter": 0.08, "spatial": true},
	"weapon_blast":      {"prio":  7, "min_ms": 150,  "merge_slots": 2, "jitter": 0.08, "spatial": true},
	"bird_chirp":        {"prio":  1, "min_ms": 1200, "merge_slots": 1, "jitter": 0.05, "spatial": false, "instant": true},
}

## 未登记事件的兜底策略（新加音效没写策略也能响，按低优先级处理）。
const DEFAULT_SFX_POLICY := {
	"prio": 4, "min_ms": 80, "merge_slots": 1, "jitter": 0.05,
	"spatial": false, "instant": false,
}

## 同帧合并窗口（s）：与 30Hz 物理帧同拍（core/autoload/time_manager.gd）。
## 窗口内同一事件的 N 次请求并成 1~2 路声部，而不是叠 N 路（人群战斗）。
const MERGE_WINDOW_S := 0.03
## 合并成 2 路且 N > 6 时的错峰延迟（s）：避免相干叠加过冲，听成"一片"而非"一记重击"
const MERGE_STAGGER_MIN_S := 0.020
const MERGE_STAGGER_MAX_S := 0.035
## 全局声部预算：超限时新请求抢占"最低优先级里最早起播"的声部
const MAX_VOICES := 24
## 空间化参数默认值（【提案/待定】）：约半屏距离、明显衰减、满强度左右定位。
## 实际半径由相机按"半对角线 × 1.05"实时推送（见 set_spatial_max_distance）——
## 可视范围随缩放 4 倍变化，写死会在拉远时把看得见的单位也静音。
const SPATIAL_MAX_DISTANCE := 1100.0
const SPATIAL_ATTENUATION := 1.5
## 听觉半径的合法区间（防上游传 0/∞）
const SPATIAL_DISTANCE_MIN := 400.0
const SPATIAL_DISTANCE_MAX := 4000.0

## 每事件最后一次播放器（instant 事件重触发先停旧实例；非 instant 走合并窗口）
var _event_players: Dictionary = {}
## 事件 → 上次真正起播时刻（ms），min_ms 节流记账
var _event_last_ms: Dictionary = {}
## 合并窗口累加器：event -> {"count": int, "world_pos": Vector2}
var _merge_pending: Dictionary = {}
var _merge_timer: Timer = null
## 声部记账：播放器 -> {"prio": int, "start_ms": int}
var _player_book: Dictionary = {}
## 事件 → 实际起播声部数（测试/调试用）
var _play_counts: Dictionary = {}
## 暂停时被静音的声部（恢复时逐个接回）
var _paused_voices: Array = []
var _weather_paused: bool = false
## 空间化宿主（Node2D）。AudioManager 自身是 Node，2D 播放器挂它下面会触发
## "父节点不是 CanvasItem"告警 → 由世界侧在地图加载时注册、卸载时清空。
var _sfx_host: Node2D = null
## 当前听觉半径（由相机按可视范围推送，见 set_spatial_max_distance）
var _spatial_max_distance: float = SPATIAL_MAX_DISTANCE


## 取事件策略（未登记事件回落到 DEFAULT_SFX_POLICY）。
func _policy_for(event_name: String) -> Dictionary:
	var raw: Variant = SFX_POLICY.get(event_name)
	if raw == null:
		return DEFAULT_SFX_POLICY
	return raw


## 注册/清空空间化宿主（世界侧地图加载时调用；传 null 即注销）
func set_sfx_host(node: Node2D) -> void:
	_sfx_host = node


func get_sfx_host() -> Node2D:
	return _sfx_host


## 设置空间化听觉半径（相机在缩放变化时推送"半对角线 × 1.05"）。
## 实测依据：`AudioStreamPlayer2D` 的监听点是**屏幕中心**，超出 max_distance 即静音，
## 因此半径必须跟着可视范围走（见 docs/技术/音频/音效触发规范.md §八）。
func set_spatial_max_distance(distance: float) -> void:
	var want: float = clampf(distance, SPATIAL_DISTANCE_MIN, SPATIAL_DISTANCE_MAX)
	if absf(want - _spatial_max_distance) < 1.0:
		return
	_spatial_max_distance = want
	# 在播的 2D 声部同步跟上（否则缩放后要等下一声才生效）
	for p in _sfx_players:
		if p is AudioStreamPlayer2D and is_instance_valid(p):
			(p as AudioStreamPlayer2D).max_distance = _spatial_max_distance


func get_spatial_max_distance() -> float:
	return _spatial_max_distance


## 按语义事件名播放（Terraria LegacySoundPlayer.PlaySound 同构）。
## world_pos 给定时，spatial=true 的事件走 2D 定位播放（距离衰减 + 左右定位）。
## 节流 / 同帧合并 / 声部预算 / 音高抖动 / 定位**全部由 SFX_POLICY 表驱动**：
## 调用点只报"发生了什么、发生在哪"，不各自写限流（见 音效触发规范.md §六.4）。
func play_event(event_name: String, world_pos: Vector2 = Vector2.ZERO) -> void:
	if not SFX_EVENTS.has(event_name):
		push_warning("[AudioManager] 未注册的音效事件: %s" % event_name)
		return
	var policy: Dictionary = _policy_for(event_name)
	if bool(policy.get("instant", false)):
		# 直通路径：UI/仪式音必须零延迟（进窗口会让点击手感发闷）
		if _throttle_ok(event_name, policy):
			_spawn_event(event_name, policy, world_pos, 0.0)
		return
	if get_tree() != null and get_tree().paused:
		# 暂停中的世界音效一律不响，否则会在恢复瞬间"补响"一串延迟音
		return
	_accumulate(event_name, world_pos)


## min_ms 节流：未到最小间隔即丢弃（不排队）——UI 手感靠"丢弃"而不是"延迟"。
func _throttle_ok(event_name: String, policy: Dictionary) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	var min_ms: int = int(policy.get("min_ms", 0))
	if min_ms > 0 and _event_last_ms.has(event_name):
		if now_ms - int(_event_last_ms[event_name]) < min_ms:
			return false
	_event_last_ms[event_name] = now_ms
	return true


func _accumulate(event_name: String, world_pos: Vector2) -> void:
	_ensure_merge_timer()
	var slot: Dictionary = _merge_pending.get(
		event_name, {"count": 0, "world_pos": world_pos})
	slot["count"] = int(slot["count"]) + 1
	# 定位取本批第一路的位置（同批请求几乎同帧同地；跨屏的两批不会进同一窗口）
	if slot["world_pos"] == Vector2.ZERO:
		slot["world_pos"] = world_pos
	_merge_pending[event_name] = slot
	if _merge_timer.is_stopped():
		_merge_timer.start(MERGE_WINDOW_S)


func _ensure_merge_timer() -> void:
	if _merge_timer != null and is_instance_valid(_merge_timer):
		return
	_merge_timer = Timer.new()
	_merge_timer.name = "_SfxMergeTimer"
	_merge_timer.one_shot = true
	# ALWAYS：暂停中窗口也必须能收尾，否则累加器卡死（与 MusicDirector 同款纪律）。
	# Timer 自身不发声，设 ALWAYS 不会让音效穿透暂停。
	_merge_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_merge_timer.timeout.connect(_flush_merge_window)
	add_child(_merge_timer)


## 窗口收尾：把每个事件的 N 次请求并成 1~2 路声部——
##   N=1 → 1 路 0dB；N=2~4 → 2 路各 -3dB；N>4 → 2 路各 -10log10(N/2)（下限 -8dB）。
## 即"人越多单个越轻"，总能量不超过 +3dB（人群战斗的听感是"很多人在受伤"，
## 而不是"一记重击"或"机关枪顿挫"）。
func _flush_merge_window() -> void:
	var batch: Dictionary = _merge_pending
	_merge_pending = {}
	for event_name in batch.keys():
		var slot: Dictionary = batch[event_name]
		var n: int = int(slot.get("count", 0))
		if n <= 0:
			continue
		var policy: Dictionary = _policy_for(event_name)
		if not _throttle_ok(event_name, policy):
			continue
		var slots: int = 1 if n == 1 else maxi(1, mini(2, int(policy.get("merge_slots", 1))))
		var gain_db: float = 0.0
		if n > 1:
			gain_db = -3.0 if n <= 4 \
				else clampf(-10.0 * (log(float(n) / 2.0) / log(10.0)), -8.0, 0.0)
		var world_pos: Vector2 = slot.get("world_pos", Vector2.ZERO)
		_spawn_event(event_name, policy, world_pos, gain_db)
		if slots > 1 and n > 6:
			_spawn_event_delayed(event_name, policy, world_pos, gain_db,
				randf_range(MERGE_STAGGER_MIN_S, MERGE_STAGGER_MAX_S))


## 错峰起播第二路（合并路数 > 1 且请求数多时）。
func _spawn_event_delayed(event_name: String, policy: Dictionary,
		world_pos: Vector2, gain_db: float, delay_s: float) -> void:
	if get_tree() == null:
		return
	await get_tree().create_timer(delay_s, true, false, true).timeout
	_spawn_event(event_name, policy, world_pos, gain_db)


## 真正起播一路声部（instant 直通与合并窗口共用）。
func _spawn_event(event_name: String, policy: Dictionary, world_pos: Vector2,
		gain_db: float) -> void:
	var entry: Variant = SFX_EVENTS[event_name]
	var paths: Array = entry if entry is Array else [entry]
	# 先收集存在资产再随机：变体池"部分就位"时会随机选中缺失资产而静默丢音
	var valid: Array = []
	for p in paths:
		if ResourceLoader.exists(p):
			valid.append(p)
	if valid.is_empty():
		print_verbose("[AudioManager] 音效资产未就位，跳过: %s" % event_name)
		return
	var prio: int = int(policy.get("prio", 4))
	if not _try_reserve_voice(prio):
		return
	# instant（UI/仪式）是"一次一生"的事件：重触发先停旧实例，避免两句长音叠着响。
	# 高频战斗音**不做**这一步——那正是"机关枪顿挫"的来源，交给合并窗口处理。
	if bool(policy.get("instant", false)):
		var prev: Variant = _event_players.get(event_name)
		if prev != null and is_instance_valid(prev) and prev.playing:
			_discard_sfx_player(prev)
	var player: Node = _make_sfx_player(policy, world_pos, gain_db)
	if player == null:
		return
	var jitter: float = float(policy.get("jitter", 0.0))
	player.pitch_scale = 1.0 + randf_range(-jitter, jitter)
	player.stream = load(valid[randi() % valid.size()])
	player.play()
	_sfx_players.append(player)
	_player_book[player] = {
		"event": event_name, "prio": prio, "start_ms": Time.get_ticks_msec(),
	}
	_play_counts[event_name] = int(_play_counts.get(event_name, 0)) + 1
	if bool(policy.get("instant", false)):
		_event_players[event_name] = player
	player.finished.connect(_on_sfx_finished.bind(player))


## 建一路播放器：spatial 且坐标已知 → AudioStreamPlayer2D 挂宿主（引擎自带
## 距离衰减/左右定位）；否则退回非定位播放器（UI / 仪式 / 环境音）。
func _make_sfx_player(policy: Dictionary, world_pos: Vector2, gain_db: float) -> Node:
	var spatial: bool = bool(policy.get("spatial", false)) \
		and _sfx_host != null and is_instance_valid(_sfx_host) \
		and world_pos != Vector2.ZERO
	if spatial:
		var p2 := AudioStreamPlayer2D.new()
		p2.bus = BUS_SFX
		p2.max_distance = _spatial_max_distance
		p2.attenuation = SPATIAL_ATTENUATION
		p2.panning_strength = 1.0
		p2.volume_db = gain_db
		_sfx_host.add_child(p2)
		p2.global_position = world_pos
		return p2
	var player := AudioStreamPlayer.new()
	player.bus = BUS_SFX
	player.volume_db = gain_db
	# instant（UI）声部必须能在暂停菜单里响 → 不随树暂停
	if bool(policy.get("instant", false)):
		player.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(player)
	return player


## 声部预算：未满即放行；已满则抢占"最低优先级里最早起播"的声部，
## 新请求优先级不高于它则丢弃（HDR 的简化版：优先级不做在音量上，做在占位上）。
func _try_reserve_voice(prio: int) -> bool:
	var live: Array = []
	for p in _sfx_players:
		if p != null and is_instance_valid(p):
			live.append(p)
	_sfx_players = live
	if live.size() < MAX_VOICES:
		return true
	var victim: Node = null
	var victim_prio: int = 99
	var victim_ms: int = 0
	for p in live:
		var book: Dictionary = _player_book.get(p, {})
		var pr: int = int(book.get("prio", 0))
		var ms: int = int(book.get("start_ms", 0))
		if pr < victim_prio or (pr == victim_prio and (victim == null or ms < victim_ms)):
			victim = p
			victim_prio = pr
			victim_ms = ms
	if victim == null or victim_prio >= prio:
		# 同为最低优先级时不抢占：让既有声部自然播完，避免高频重启的顿挫
		return false
	_discard_sfx_player(victim)
	return true


## 暂停：世界音效与天气 loop 一并静音——暂停不该有雨声、战斗残响。
## 用 stream_paused 而不是 stop：恢复时接着响，不从头重放、不丢循环相位。
## instant（UI）声部走 PROCESS_MODE_ALWAYS，暂停菜单里的点击音照常响。
func _on_game_paused() -> void:
	_paused_voices.clear()
	for p in _sfx_players:
		if p == null or not is_instance_valid(p):
			continue
		if p.process_mode == Node.PROCESS_MODE_ALWAYS:
			continue
		if p.playing and not p.stream_paused:
			p.stream_paused = true
			_paused_voices.append(p)
	if _weather_player != null and _weather_player.playing \
			and not _weather_player.stream_paused:
		_weather_player.stream_paused = true
		_weather_paused = true


func _on_game_resumed() -> void:
	for p in _paused_voices:
		if p != null and is_instance_valid(p):
			p.stream_paused = false
	_paused_voices.clear()
	if _weather_player != null and _weather_paused:
		_weather_player.stream_paused = false
		_weather_paused = false


## 接线 EventBus 全局生命周期信号（战斗/存档/暂停；UI 点击由 StickKit 直接调 play_event）。
## 音乐不在这里放：曲目选择与分层由 MusicDirector 负责（见 core/services/music_director.gd），
## 本管理器只管音量与音效。
func _wire_event_bus() -> void:
	if not EventBus or not EventBus.has_signal("battle_started"):
		return
	EventBus.game_started.connect(func() -> void: play_event("game_started"))
	EventBus.game_saved.connect(func(_slot: int) -> void: play_event("game_saved"))
	EventBus.battle_started.connect(func(_battle_id: String) -> void: play_event("battle_started"))
	EventBus.battle_ended.connect(func(_battle_id: String, victory: bool) -> void:
		play_event("battle_ended_win" if victory else "battle_ended_lose"))
	if EventBus.has_signal("game_paused"):
		EventBus.game_paused.connect(_on_game_paused)
	if EventBus.has_signal("game_resumed"):
		EventBus.game_resumed.connect(_on_game_resumed)


func stop_all_sfx() -> void:
	var snapshot: Array = []
	for p in _sfx_players:
		snapshot.append(p)
	for p in snapshot:
		if p and is_instance_valid(p):
			_discard_sfx_player(p)
	_sfx_players.clear()
	_player_book.clear()
	_merge_pending.clear()
	_paused_voices.clear()
	_event_players.clear()


## 当前在播 SFX 声部数（测试/调试用）
func get_active_sfx_count() -> int:
	var n: int = 0
	for p in _sfx_players:
		if p != null and is_instance_valid(p):
			n += 1
	return n


## 在播声部快照（测试/调试用）：事件名 / 优先级 / 音量 / 是否定位 / 是否被暂停。
## 空间化与暂停处置无法靠"听"验收，只能靠这份可观测数据。
func get_voice_report() -> Array:
	var out: Array = []
	for p in _sfx_players:
		if p == null or not is_instance_valid(p):
			continue
		var book: Dictionary = _player_book.get(p, {})
		out.append({
			"event": String(book.get("event", "")),
			"prio": int(book.get("prio", 0)),
			"db": p.volume_db,
			"playing": p.playing,
			"paused": p.stream_paused,
			"spatial": p is AudioStreamPlayer2D,
			"pitch": p.pitch_scale,
		})
	return out


## 实际起播声部数（合并后的路数，不是请求数）——测试用：验证节流与合并是否生效
func get_play_count(event_name: String) -> int:
	return int(_play_counts.get(event_name, 0))


func reset_play_counts() -> void:
	_play_counts.clear()


## 清空运行期记账（节流记忆 / 合并窗口 / 播放中声部 / 计数）。**测试用**：
## 游戏里这些记账本就该跨帧累积，只有测试需要在用例之间拿干净起点。
func reset_runtime_state() -> void:
	stop_all_sfx()
	_event_last_ms.clear()
	_merge_pending.clear()
	_play_counts.clear()


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