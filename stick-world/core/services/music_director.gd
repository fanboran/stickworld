extends Node
## 音乐总监 —— 自适应音乐的运行时状态机。
##
## 与 AudioManager 的分工：AudioManager 管"音量/音效/事件表"，音乐总监管
## "放哪首曲子、放几层、怎么切换"。音量仍然只有一个消费方（AudioManager 把
## 通道音量写到 AudioBus），总监只调**每个层自己的 volume_db**与请求整体压限。
##
## 设计要点（详见 docs/技术/音频/音乐系统.md 与 docs/设计/音乐/音乐设计文档.md）：
##
## 1. **一 cue 多层、同帧开播**：每个 cue 由若干个"层"（layer）组成，每层一个
##    AudioStreamPlayer，全部在**同一帧** play()。因为同采样率、同长度、同起点，
##    它们天然保持采样级同步；运行时只调层的音量，就得到"强度"的变化
##    （纵向混音 / vertical remixing）。层与层不需要 AudioStreamSynchronized：
##    那个类在运行时无法逐层调音量，反而不满足需求。
##
## 2. **强度 = tier**：层在清单里标了 tier（0 地基 / 1 常规 / 2 点亮）。
##    tier 之外的层淡到静音。所以"从安静变热闹"是同一首曲子在叠层，
##    不是换曲——听感连续，且不会出现换曲时的调性/速度跳变。
##
## 3. **曲目由状态解析，不由调用点硬编码**：调用方只报告"现在在哪、在干什么"
##    （set_context），解析规则集中在 _resolve_cue()。散落各处的 play_music("x")
##    是音乐系统最容易腐烂的写法。
##
## 4. **循环点来自清单**：OGG 文件里不存循环信息，清单里的 bpm/beat_count/
##    bar_beats 在加载时赋给 AudioStreamOggVorbis。单一真相源。
##
## 5. **stinger 独立播放器**：战斗结算等一次性短句叠在主曲之上，不打断主曲，
##    也不参与层音量管理。
##
## 6. **节点恒为 PROCESS_MODE_ALWAYS**：游戏暂停（SceneTree.paused）时音乐
##    继续播放，只做压限（duck）。音乐被暂停切断会非常突兀。

signal cue_changed(cue_id: String)
signal tier_changed(tier: int)
signal context_changed(context: Dictionary)

const MANIFEST_PATH := "res://assets/audio/bgm/music_manifest.json"
const AMBIENCE_DIR := "res://assets/audio/ambience/"

## 静音电平：层的"关"不是一个开关，而是淡到听不见（-60dB），
## 这样淡入淡出永远是连续的，不会出现开关式的爆音。
const SILENT_DB := -60.0

## 交叉淡化时长（秒）。按"量化到小节"的直觉：1~4 小节。
## 72BPM 4/4 下 1 小节 ≈ 3.3 秒。
const FADE_CUE := 3.0
const FADE_TIER := 2.0
const FADE_STINGER := 0.35
const FADE_AMBIENCE := 4.0
const FADE_DUCK := 0.6

## 压限档位（dB）
const DUCK_PAUSE := -9.0
const DUCK_BATTLE_SFX := -6.0

## 环境音层 → 声压（线性）。环境音只是"底噪"，比音乐低很多。
const AMBIENCE_LEVEL := 0.34

## 游戏状态 → 曲目的解析表。
## 键是"情境"（由 set_context 维护），值优先匹配"最具体的键在前"。
## 单独一个函数表达规则，比散在各处的事件回调可读、可测。
const CUE_FOR_MAP_TYPE := {
	0: "village",        # WorldAPI.MapType.VILLAGE
	1: "battle",         # BATTLEFIELD
	2: "field_day",      # ROAD
	3: "interior",       # INDOOR
	4: "interior",       # MEGA_INTERIOR
}

var _manifest: Dictionary = {}
var _cue: String = ""
var _players: Dictionary = {}          # layer_name -> AudioStreamPlayer
var _layer_db: Dictionary = {}         # layer_name -> 当前目标 dB
var _tier: int = 0
var _context: Dictionary = {
	"map_type": -1,
	"strategic": false,
	"interior": false,
	"battle": false,
	"night": false,
	"started": false,
}
var _duck_db: float = 0.0
var _stinger: AudioStreamPlayer = null
var _ambience: AudioStreamPlayer = null
var _ambience_name: String = ""
var _tween: Tween = null
var _enabled: bool = true
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	# 暂停时音乐不中断（见类注释第 6 条）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.seed = 20260913
	_load_manifest()

	_stinger = AudioStreamPlayer.new()
	_stinger.name = "_StingerPlayer"
	_stinger.bus = AudioManager.BUS_BGM
	add_child(_stinger)

	_ambience = AudioStreamPlayer.new()
	_ambience.name = "_AmbiencePlayer"
	_ambience.bus = AudioManager.BUS_SFX
	_ambience.volume_db = SILENT_DB
	add_child(_ambience)

	_wire_event_bus()


## 清单是作曲家与引擎的唯一契约（循环点/分层/音量都在里面）。
## 缺清单时整条链路安静降级：不报错刷屏，只警告一次。
func _load_manifest() -> void:
	if not FileAccess.file_exists(MANIFEST_PATH):
		push_warning("[MusicDirector] 找不到音乐清单：%s（先跑 tools/music/render_all.py）"
			% MANIFEST_PATH)
		return
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY or not (parsed as Dictionary).has("cues"):
		push_warning("[MusicDirector] 音乐清单格式不对：%s" % MANIFEST_PATH)
		return
	_manifest = parsed


# ─────────────────────────────── 事件接线 ────────────────────────────────

func _wire_event_bus() -> void:
	if not EventBus:
		return
	_safe_connect("game_started", _on_game_started)
	_safe_connect("map_loaded", _on_map_loaded)
	_safe_connect("strategic_map_opened", _on_strategic_opened)
	_safe_connect("strategic_map_closed", _on_strategic_closed)
	_safe_connect("interior_entered", _on_interior_entered)
	_safe_connect("interior_exited", _on_interior_exited)
	_safe_connect("mega_interior_entered", _on_mega_interior_entered)
	_safe_connect("mega_interior_exited", _on_mega_interior_exited)
	_safe_connect("battle_started", _on_battle_started)
	_safe_connect("battle_ended", _on_battle_ended)
	_safe_connect("game_paused", _on_paused)
	_safe_connect("game_resumed", _on_resumed)
	_safe_connect("map_unloaded", _on_map_unloaded)


func _safe_connect(sig_name: String, cb: Callable) -> void:
	if EventBus.has_signal(sig_name):
		EventBus.connect(sig_name, cb)


# ─────────────────────────────── 情境维护 ────────────────────────────────

## 由游戏流程更新情境；每次更新后重新解析曲目。
func set_context(key: String, value: Variant) -> void:
	if not _context.has(key):
		push_warning("[MusicDirector] 未知情境键：%s" % key)
		return
	if _context[key] == value:
		return
	_context[key] = value
	context_changed.emit(_context.duplicate())
	_apply_context()


## 昼夜目前没有驱动源（游戏还没有昼夜系统），先提供入口：
## 需要时由时间系统调用 set_time_of_day(true/false) 即可生效。
func set_time_of_day(night: bool) -> void:
	set_context("night", night)


func get_context() -> Dictionary:
	return _context.duplicate()


func _apply_context() -> void:
	if not _context["started"]:
		return
	var want := _resolve_cue()
	if want != "" and want != _cue:
		play_cue(want)
	# 战斗/暂停时音乐让路（音效与语音优先）
	if _context["battle"]:
		duck(DUCK_BATTLE_SFX, FADE_DUCK)
	else:
		unduck(FADE_DUCK)
	_update_ambience()


## 曲目解析：从"最具体"到"最一般"逐层回退。
## 优先级：战斗 > 室内 > 战略图 > 地图类型 > 户外（昼夜）。
func _resolve_cue() -> String:
	if _context["battle"]:
		return "battle"
	if _context["interior"]:
		return "interior"
	if _context["strategic"]:
		return "strategic"
	var mt: int = int(_context["map_type"])
	if mt >= 0 and CUE_FOR_MAP_TYPE.has(mt):
		var cue: String = CUE_FOR_MAP_TYPE[mt]
		if cue == "field_day" and bool(_context["night"]):
			return "field_night"
		return cue
	return "field_night" if bool(_context["night"]) else "field_day"


# ─────────────────────────────── 事件回调 ────────────────────────────────

func _on_game_started() -> void:
	_context["started"] = true
	_apply_context()


func _on_map_loaded(_map_id: String, map_type: int) -> void:
	set_context("map_type", map_type)


func _on_map_unloaded(_map_id: String) -> void:
	set_context("map_type", -1)


func _on_strategic_opened() -> void:
	set_context("strategic", true)


func _on_strategic_closed() -> void:
	set_context("strategic", false)


func _on_interior_entered(_building_id: int) -> void:
	set_context("interior", true)


func _on_interior_exited(_building_id: int) -> void:
	set_context("interior", false)


func _on_mega_interior_entered(_building_id: int, _map_id: String) -> void:
	set_context("interior", true)


func _on_mega_interior_exited(_return_map_id: String) -> void:
	set_context("interior", false)


func _on_battle_started(_battle_id: String) -> void:
	set_context("battle", true)


func _on_battle_ended(_battle_id: String, victory: bool) -> void:
	# 先叠一句结算短句，再回到场景音乐（短句不打断主曲，主曲仍按情境解析）
	play_stinger("sting_victory" if victory else "sting_defeat")
	set_context("battle", false)


func _on_paused() -> void:
	duck(DUCK_PAUSE, FADE_DUCK)


func _on_resumed() -> void:
	if _context["battle"]:
		duck(DUCK_BATTLE_SFX, FADE_DUCK)
	else:
		unduck(FADE_DUCK)


# ─────────────────────────────── 播放曲目 ──────────────────────────────

## 切到指定 cue。分层淡入淡出：新 cue 的层从静音起播，
## 旧 cue 的层同时淡出，淡化结束再释放旧播放器。
func play_cue(cue_id: String, fade_s: float = FADE_CUE) -> void:
	var entry: Dictionary = _cue_entry(cue_id)
	if entry.is_empty():
		push_warning("[MusicDirector] 清单里没有 cue：%s" % cue_id)
		return
	# 状态先更新，再决定是否真的出声：set_enabled(false) 只应关掉**声音**，
	# 不该让"当前应该在放哪首"这件事失真——否则关闭音乐后整个情境解析就聋了
	# （测试与调试都会读到空曲目，而这其实不是故障）。
	_cue = cue_id
	if not _enabled:
		cue_changed.emit(cue_id)
		return

	var old_players := _players
	_players = {}
	_layer_db = {}

	for layer in entry.get("layers", []):
		var p := AudioStreamPlayer.new()
		p.name = "L_" + str(layer["name"])
		p.bus = AudioManager.BUS_BGM
		var path := "res://assets/audio/bgm/" + str(layer["file"])
		var stream: AudioStream = load(path)
		if stream == null:
			push_warning("[MusicDirector] 加载失败：%s" % path)
			p.queue_free()
			continue
		_configure_loop(stream, entry)
		p.stream = stream
		p.volume_db = SILENT_DB
		add_child(p)
		p.play()
		_players[layer["name"]] = p
		_layer_db[layer["name"]] = float(layer.get("db", 0.0))

	for name in _players.keys():
		_fade_player(_players[name], _target_db(name), fade_s)
	for name in old_players.keys():
		var op: AudioStreamPlayer = old_players[name]
		_fade_player(op, SILENT_DB, fade_s)
		_free_after(op, fade_s + 0.3)
	cue_changed.emit(cue_id)


func _configure_loop(stream: AudioStream, entry: Dictionary) -> void:
	## 循环参数来自清单，不手工填：OGG 不读内嵌循环点，
	## 只有这里一处赋值，避免"文件里的值"与"代码里的值"不一致。
	if not (stream is AudioStreamOggVorbis):
		return
	var ogg := stream as AudioStreamOggVorbis
	ogg.loop = bool(entry.get("loop", true))
	ogg.loop_offset = float(entry.get("loop_offset", 0.0))
	ogg.bpm = float(entry.get("bpm", 72.0))
	ogg.bar_beats = int(entry.get("bar_beats", 4))
	ogg.beat_count = int(entry.get("beat_count", 0))


## 设置强度档位：tier 之外的层淡到静音。
func set_tier(tier: int, fade_s: float = FADE_TIER) -> void:
	tier = clampi(tier, 0, 9)
	if tier == _tier:
		return
	_tier = tier
	for name in _players.keys():
		_fade_player(_players[name], _target_db(name), fade_s)
	tier_changed.emit(_tier)


func _target_db(layer_name: String) -> float:
	if not _players.has(layer_name):
		return SILENT_DB
	var layer_tier := _layer_tier(_cue, layer_name)
	if layer_tier > _tier:
		return SILENT_DB
	return float(_layer_db.get(layer_name, 0.0))


func _layer_tier(cue_id: String, layer_name: String) -> int:
	var entry := _cue_entry(cue_id)
	for layer in entry.get("layers", []):
		if str(layer["name"]) == layer_name:
			return int(layer.get("tier", 0))
	return 0


func _cue_entry(cue_id: String) -> Dictionary:
	if _manifest.is_empty():
		return {}
	var cues: Dictionary = _manifest.get("cues", {})
	return cues.get(cue_id, {})


# ─────────────────────────────── stinger ──────────────────────────────

## 一次性短句：叠在主曲之上，不参与层管理，播完即止。
func play_stinger(cue_id: String, fade_s: float = FADE_STINGER) -> void:
	if not _enabled:
		return
	var entry := _cue_entry(cue_id)
	var layers: Array = entry.get("layers", [])
	if layers.is_empty():
		push_warning("[MusicDirector] 清单里没有 stinger：%s" % cue_id)
		return
	var path := "res://assets/audio/bgm/" + str(layers[0]["file"])
	var stream: AudioStream = load(path)
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = false
	_stinger.stream = stream
	_stinger.volume_db = SILENT_DB
	_stinger.play()
	_fade_player(_stinger, 0.0, fade_s)


# ─────────────────────────────── 环境音层 ──────────────────────────────

## 环境音随情境切换（见 _ambience_for_context）。文件缺失时静默跳过——
## 环境音是"锦上添花"，不能因为它没就位就让音乐系统报错。
func _update_ambience() -> void:
	var want := _ambience_for_context()
	if want == _ambience_name:
		return
	_ambience_name = want
	if want == "":
		_fade_player(_ambience, SILENT_DB, FADE_AMBIENCE)
		return
	# 环境音在循环播放 WAV 与一次性 OGG 中挑一个存在者
	var path := ""
	for ext: String in [".wav", ".ogg"]:
		var cand: String = AMBIENCE_DIR + want + ext
		if ResourceLoader.exists(cand):
			path = cand
			break
	if path == "":
		return
	var stream: AudioStream = load(path)
	if stream == null:
		return
	_ambience.stream = stream
	if stream is AudioStreamWAV:
		var w := stream as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = w.data.size() / 2      # 16bit 单/立体声：字节数/2 = 帧数×声道
	_ambience.play()
	_fade_player(_ambience, _linear_to_db(AMBIENCE_LEVEL), FADE_AMBIENCE)


func _ambience_for_context() -> String:
	if _context["battle"] or _context["interior"]:
		return ""                     # 战斗与室内不要环境音抢戏
	if _context["strategic"]:
		return "wind_calm"
	if bool(_context["night"]):
		return "night_insects"
	var mt: int = int(_context["map_type"])
	if mt == 0:                       # VILLAGE
		return "birds_day"
	if mt == 3 or mt == 4:            # INDOOR / MEGA_INTERIOR
		return ""
	return "birds_day"


# ─────────────────────────────── 压限（duck）──────────────────────────────

## 把音乐整体压低（暂停、战斗音效让路）。音量唯一消费方仍是 AudioManager，
## 这里只转发请求，避免两处都写 AudioBus 造成彼此覆盖。
func duck(db: float, fade_s: float = FADE_DUCK) -> void:
	_duck_db = db
	if AudioManager and AudioManager.has_method("set_music_duck_db"):
		AudioManager.set_music_duck_db(db, fade_s)


func unduck(fade_s: float = FADE_DUCK) -> void:
	duck(0.0, fade_s)


# ─────────────────────────────── 工具 ────────────────────────────────

func stop_all(fade_s: float = 1.0) -> void:
	for name in _players.keys():
		var p: AudioStreamPlayer = _players[name]
		_fade_player(p, SILENT_DB, fade_s)
		_free_after(p, fade_s + 0.3)
	_players = {}
	_layer_db = {}
	_cue = ""
	_fade_player(_ambience, SILENT_DB, fade_s)
	_ambience_name = ""


func _fade_player(p: AudioStreamPlayer, to_db: float, dur: float) -> void:
	if p == null or not is_instance_valid(p):
		return
	if dur <= 0.0:
		p.volume_db = to_db
		return
	var t := p.create_tween()
	t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	t.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	t.tween_property(p, "volume_db", to_db, dur)


func _free_after(p: AudioStreamPlayer, delay: float) -> void:
	if p == null or not is_instance_valid(p):
		return
	var t := create_tween()
	t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	t.tween_interval(delay)
	t.tween_callback(p.queue_free)


func _linear_to_db(linear: float) -> float:
	if linear <= 0.0:
		return SILENT_DB
	return 20.0 * (log(linear) / log(10.0))


# ─────────────────────────────── 状态查询（测试/调试用）──────────────────

func get_state_report() -> Dictionary:
	return {
		"enabled": _enabled,
		"cue": _cue,
		"tier": _tier,
		"duck_db": _duck_db,
		"layers": _players.keys().duplicate(),
		"layer_db": _layer_db.duplicate(),
		"ambience": _ambience_name,
		"context": _context.duplicate(),
		"manifest_cues": _manifest.get("cue_count", 0),
		"playing": is_playing(),
	}


func is_playing() -> bool:
	for name in _players.keys():
		if is_instance_valid(_players[name]) and _players[name].playing:
			return true
	return false


func get_cue() -> String:
	return _cue


func get_tier() -> int:
	return _tier


func set_enabled(on: bool) -> void:
	_enabled = on
	if not on:
		stop_all(0.4)


func has_cue(cue_id: String) -> bool:
	return not _cue_entry(cue_id).is_empty()
