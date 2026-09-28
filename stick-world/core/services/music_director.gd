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
##
## 7. **预览模式供原声带页**（界内曲目表点播）：曲目由人点名而非情境解析，
##    期间情境解析让位（否则玩家的状态变化会把正在听的曲子换掉），退场还原。

signal cue_changed(cue_id: String)
signal tier_changed(tier: int)
signal context_changed(context: Dictionary)
## 预览起播（页面选中态由点播路径自行维护，此信号供测试/工具观测）；
## 非循环预览播到末尾发 preview_finished（原声带页据此自动下一曲）
signal preview_started(cue_id: String)
signal preview_finished(cue_id: String)

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
## 预览（原声带页）入场/退场：比换曲短，点曲目要"立刻响"
const FADE_PREVIEW := 0.6
## 预览固定满层：听的是完整编制，不是某个强度档
const PREVIEW_TIER := 2

## 压限档位（dB）。**按来源具名请求**（见 AudioManager.request_music_duck）：
## 暂停 / 战斗 / 结算短句各自独立，生效值取最深的那条，互不覆盖。
const DUCK_PAUSE := -9.0
const DUCK_BATTLE_SFX := -6.0
## 结算短句期间的压限与保持时长（s）：sting 的尾巴不该被全音量音乐盖掉
const DUCK_STINGER := -4.0
const DUCK_STINGER_HOLD_S := 2.5

## 环境音层 → 声压（线性）。环境音只是"底噪"，比音乐低很多。
const AMBIENCE_LEVEL := 0.34

## 游戏状态 → 曲目的解析表。
## 键是"情境"（由 set_context 维护），值优先匹配"最具体的键在前"。
## 单独一个函数表达规则，比散在各处的事件回调可读、可测。
const CUE_FOR_MAP_TYPE := {
	0: "village",        # WorldAPI.MapType.VILLAGE
	1: "battlefield",    # BATTLEFIELD：**地图本身**是荒原（交战由 battle 情境压过）
	2: "field_day",      # ROAD
	3: "interior",       # INDOOR（小房间：独奏钢琴）
	4: "interior_hall",  # MEGA_INTERIOR（大建筑内部：加弦乐与钢片琴、大混响）
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
## 当前正在播的短句 id（""=没有）
var _stinger_cue: String = ""
## 变奏族轮换进度：族基准 cue → 当前轮到的成员下标
var _rotation: Dictionary = {}
## 上一次解析出的"族基准"（含非族 cue）：只有它变化才算"进入了新场景"，据此轮换
var _last_base: String = ""
## 跨图抵达时是否要打一个"抵达"标点（travel_started 置位、下一次 map_loaded 消费）
var _expect_arrival: bool = false
## 短句播放器组（多层短句 = 多个播放器同时起播，各层音量已在交付件里配平）
var _stinger_players: Array = []
var _ambience: AudioStreamPlayer = null
var _ambience_name: String = ""
var _enabled: bool = true
var _rng := RandomNumberGenerator.new()

## 预览模式（原声带页）：非空 = 正在预览该 cue
var _preview: String = ""
## 预览是否循环（页面「循环」开关；关 = 播完发 preview_finished 让页面走下一曲）
var _preview_looped: bool = true
var _preview_paused: bool = false
## 一次性结束通知的去重（各层同长，会各自 finished）
var _preview_finished_sent: bool = false
## 入场前在放的曲目/强度，退场时原样还原（""=原本静默）
var _preview_backup_cue: String = ""
var _preview_backup_tier: int = 0


func _ready() -> void:
	# 暂停时音乐不中断（见类注释第 6 条）
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.seed = 20260913
	_load_manifest()

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
	_safe_connect("battle_started", _on_battle_started)
	_safe_connect("battle_ended", _on_battle_ended)
	_safe_connect("game_paused", _on_paused)
	_safe_connect("game_resumed", _on_resumed)
	_safe_connect("map_unloaded", _on_map_unloaded)
	_safe_connect("travel_started", _on_travel_started)


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
	# 预览期间情境解析让位：原声带页点的是"这首"，任何状态变化都不该把它换掉
	if _preview != "":
		return
	var want := _resolve_cue()
	if want != "" and want != _cue:
		play_cue(want)
	# 战斗/暂停时音乐让路（音效与语音优先）
	if _context["battle"]:
		request_duck(&"battle", DUCK_BATTLE_SFX, FADE_DUCK)
	else:
		release_duck(&"battle", FADE_DUCK)
	_update_ambience()


## 曲目解析：从"最具体"到"最一般"逐层回退。
## 优先级：战斗 > 室内 > 战略图 > 地图类型 > 户外（昼夜）。
##
## 最后一步走**变奏族轮换**：同一个场景第二次进入时，同族的另一版（换主奏乐器）
## 会被选中——长时停留/反复进出同一张图时，这是最有效的抗疲劳手段
## （族由作曲侧在 compose/cues.py 声明，随清单下发，见 _pick_variant）。
func _resolve_cue() -> String:
	var base := _resolve_base_cue()
	if base == "":
		return base
	return _pick_variant(base)


func _resolve_base_cue() -> String:
	if _context["battle"]:
		return "battle"
	if _context["interior"]:
		return "interior"
	if _context["strategic"]:
		return "strategic"
	var mt: int = int(_context["map_type"])
	if mt >= 0 and CUE_FOR_MAP_TYPE.has(mt):
		var cue: String = CUE_FOR_MAP_TYPE[mt]
		# 村落也有夜曲（与野外同一套昼夜手法：同主题级数、换调式）
		if bool(_context["night"]):
			if cue == "field_day":
				return "field_night"
			if cue == "village":
				return "village_night"
		return cue
	return "field_night" if bool(_context["night"]) else "field_day"


## 变奏族轮换：**进入**某个场景时取族内的下一版。
##
## 关键在"什么算进入"：`_resolve_cue()` 会在每次情境变化时被调用（同一个场景常常
## 被重复解析），所以不能按"解析次数"轮换——那会让曲目在同一次停留里来回翻。
## 这里只在**族基准变化**时推进指针：同一场景的重复解析保持当前那一版。
##
## 为什么不按"每次循环"轮换：那要么在循环点硬切（把折回处理过的循环尾巴切掉），
## 要么交叉淡化（需要双套播放器 + 逐帧对齐），代价与风险都大；按进入轮换零时序风险，
## 效果同样是"每次回到这里听到的不一样"。族成员同调同速同长，轮换无跳变。
func _pick_variant(base: String) -> String:
	var members: Array = _manifest.get("variation_sets", {}).get(base, [])
	var same_scene: bool = (base == _last_base)
	_last_base = base
	if members.size() < 2:
		return base
	if same_scene and _cue != "" and members.has(_cue):
		return _cue                    # 场景没变：保持正在播的那一版
	var idx: int = int(_rotation.get(base, 0)) % members.size()
	_rotation[base] = (idx + 1) % members.size()
	return str(members[idx])


# ─────────────────────────────── 事件回调 ────────────────────────────────

func _on_game_started() -> void:
	_context["started"] = true
	_apply_context()


func _on_map_loaded(_map_id: String, map_type: int) -> void:
	set_context("map_type", map_type)
	# 跨图抵达：给一声短标点（"抬头看了一眼新地方"）。首发加载不响——
	# 那时候该由标题曲淡出、场景曲淡入自己完成交接。
	if _expect_arrival:
		_expect_arrival = false
		play_stinger("sting_arrival")


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


func _on_battle_started(_battle_id: String) -> void:
	set_context("battle", true)


func _on_battle_ended(_battle_id: String, victory: bool) -> void:
	# 先叠一句结算短句，再回到场景音乐（短句不打断主曲，主曲仍按情境解析）
	play_stinger("sting_victory" if victory else "sting_defeat")
	set_context("battle", false)


## travel_started 带三个参数（from_id, to_id, mode）——签名必须一致，
## 否则 Godot 直接报参数错、回调不会执行（"抵达标点从不触发"）。
func _on_travel_started(_from_id: String, _to_id: String, _mode: int) -> void:
	# 跨图出发：下一次 map_loaded = "抵达了一个新地方"（首发加载不打标点）
	_expect_arrival = true
	_rotation.clear()      # 换了地方，变奏族从头轮（下一族首进用基础版）


func _on_paused() -> void:
	request_duck(&"pause", DUCK_PAUSE, FADE_DUCK)


func _on_resumed() -> void:
	release_duck(&"pause", FADE_DUCK)
	if _context["battle"]:
		request_duck(&"battle", DUCK_BATTLE_SFX, FADE_DUCK)


# ─────────────────────────────── 播放曲目 ──────────────────────────────

## 切到指定 cue。分层淡入淡出：新 cue 的层从静音起播，
## 旧 cue 的层同时淡出，淡化结束再释放旧播放器。
## loop_override：-1 = 依清单（默认）；0/1 = 强制不循环/循环（原声带页的循环开关）。
func play_cue(cue_id: String, fade_s: float = FADE_CUE, loop_override: int = -1) -> void:
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
	# 腾位：树上任何还叫 L_<层名> 的旧层先改名（本轮换下来的 + 上一轮 stop_all 后仍在
	# 淡出的遗留）。退役层还要活约 1s，同父同名会害 Godot 把**新**建的播放器改名成
	# @AudioStreamPlayer@N，"L_<层名>" 的身份就落到退役层头上（按名查层的工具/测试会
	# 读到旧层状态）。扫树而不是只看老字典，孤儿层也不漏。
	for child in get_children():
		if child is AudioStreamPlayer and str(child.name).begins_with("L_"):
			child.name = "Fading_" + str(child.name)

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
		_configure_loop(stream, entry, loop_override)
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


func _configure_loop(stream: AudioStream, entry: Dictionary, loop_override: int = -1) -> void:
	## 循环参数来自清单，不手工填：OGG 不读内嵌循环点，
	## 只有这里一处赋值，避免"文件里的值"与"代码里的值"不一致。
	if not (stream is AudioStreamOggVorbis):
		return
	var ogg := stream as AudioStreamOggVorbis
	ogg.loop = bool(entry.get("loop", true)) if loop_override < 0 else loop_override == 1
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
##
## **多层短句要整叠播**：交付件是按层落盘的（sting_victory = piano+strings+bells
## 三个文件，各层已带配平好的音量），只播 layers[0] 会得到一个"只剩钟琴/只剩弦乐"
## 的残句——既存的胜利/失败短句就踩过这个坑（一直只响了字母序第一层）。
func play_stinger(cue_id: String, fade_s: float = FADE_STINGER) -> void:
	if not _enabled:
		return
	var entry := _cue_entry(cue_id)
	var layers: Array = entry.get("layers", [])
	if layers.is_empty():
		push_warning("[MusicDirector] 清单里没有 stinger：%s" % cue_id)
		return
	stop_stinger()          # 同一时刻只允许一句短句（新句接管旧句）
	var started := 0
	for l in layers:
		var stream: AudioStream = load("res://assets/audio/bgm/" + str(l["file"]))
		if stream == null:
			continue
		if stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = false
		var p := AudioStreamPlayer.new()
		p.name = "_Stinger_%s" % str(l["name"])
		p.bus = AudioManager.BUS_BGM
		p.stream = stream
		p.volume_db = SILENT_DB
		add_child(p)
		p.play()
		_fade_player(p, 0.0, fade_s)
		if started == 0:
			# 各层等长：以第一层播完作为整句结束（若已被新短句接管则忽略）
			p.finished.connect(func() -> void: _on_stinger_finished(cue_id))
		_stinger_players.append(p)
		started += 1
	if started == 0:
		return
	_stinger_cue = cue_id
	# 短句期间把音乐压低，**保持时长按短句实际长度**——固定 2.5s 会让长标点
	# （如"入主" 8 小节 ≈25s）的后半句在音乐回到全音量后被盖掉。
	request_duck(&"sting", DUCK_STINGER, FADE_DUCK)
	_release_sting_duck_later(float(entry.get("duration_s", 0.0)) + FADE_DUCK)


func _release_sting_duck_later(hold_s: float = DUCK_STINGER_HOLD_S) -> void:
	await get_tree().create_timer(maxf(hold_s, 0.5), true, false, true).timeout
	release_duck(&"sting", FADE_DUCK)


## 短句自然播完：清状态并回收播放器（若已被新短句接管则不动它）
func _on_stinger_finished(cue_id: String) -> void:
	if _stinger_cue != cue_id:
		return
	stop_stinger()


## 当前正在播的短句 id（""=没有）；供测试/调试观测
func get_stinger_cue() -> String:
	return _stinger_cue


## 立即停掉短句（场景切换/预览入场时用；正常流程让它自然播完）
func stop_stinger() -> void:
	for p in _stinger_players:
		if p != null and is_instance_valid(p):
			p.stop()
			p.queue_free()
	_stinger_players.clear()
	_stinger_cue = ""


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

## 具名压限请求（source 是"谁在压"：battle / pause / sting / music_director）。
## 多个来源同时存在时取最深的那条——所以"战斗中暂停"能同时拿到暂停档。
func request_duck(source: StringName, db: float, fade_s: float = FADE_DUCK) -> void:
	if AudioManager and AudioManager.has_method("request_music_duck"):
		AudioManager.request_music_duck(source, db, fade_s)
	else:
		_duck_db = minf(_duck_db, db)
		return
	_duck_db = AudioManager.get_music_duck_db()


func release_duck(source: StringName, fade_s: float = FADE_DUCK) -> void:
	if AudioManager and AudioManager.has_method("release_music_duck"):
		AudioManager.release_music_duck(source, fade_s)
	# 状态查询用：以 AudioManager 的实际合成值为准（它是唯一真相源）
	_duck_db = AudioManager.get_music_duck_db() \
		if AudioManager and AudioManager.has_method("get_music_duck_db") else 0.0


## 兼容入口：单来源调用方（旧签名）直接传 dB。
func duck(db: float, fade_s: float = FADE_DUCK) -> void:
	if db >= 0.0:
		release_duck(&"music_director", fade_s)
	else:
		request_duck(&"music_director", db, fade_s)


func unduck(fade_s: float = FADE_DUCK) -> void:
	release_duck(&"music_director", fade_s)


# ───────────────────────── 预览模式（原声带页点播）─────────────────────────
# 与情境解析的分工：解析回答"现在该放哪首"（游戏在跑时由状态决定），预览回答
# "人要听哪首"（曲目表点名）。两者都要拥有一套分层播放，所以共用本类的播放路径
# （play_cue 的分层/淡化/清单循环），只多一个"谁说了算"的开关。

## 曲目表 —— 原声带页的唯一数据源 = 清单本身（唱片序 = 清单声明序）。
## 加一首曲子只改 tools/music 渲染出的清单，界面自动多一行（本节不维护第二份曲目表）。
## 每项：id / 曲名 / 调性 / 速度 / 时长 / 是否循环体 / 层数 / 编制明细（层名 + 强度档）。
func get_track_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for cue_id: String in _manifest.get("cues", {}).keys():
		var entry := _cue_entry(cue_id)
		var lineup: Array[Dictionary] = []
		for layer: Dictionary in entry.get("layers", []):
			lineup.append({"name": str(layer.get("name", "")), "tier": int(layer.get("tier", 0))})
		out.append({
			"id": cue_id,
			"title": str(entry.get("title", cue_id)),
			"key": str(entry.get("key", "")),
			"bpm": float(entry.get("bpm", 0.0)),
			"duration_s": float(entry.get("duration_s", 0.0)),
			"loop": bool(entry.get("loop", true)),
			"layer_count": lineup.size(),
			"lineup": lineup,
		})
	return out


func is_previewing() -> bool:
	return _preview != ""


func get_preview_track() -> String:
	return _preview


func is_preview_paused() -> bool:
	return _preview_paused


## 起播预览：绕过情境解析，固定满层（听的是完整编制），循环与否由页面开关决定。
## 首次入场记住"本来在放什么"，退场原样还原（见 stop_preview）。
func start_preview(cue_id: String, looped: bool = true) -> bool:
	if not has_cue(cue_id):
		push_warning("[MusicDirector] 预览失败，清单里没有 cue：%s" % cue_id)
		return false
	if _preview == "":
		_preview_backup_cue = _cue
		_preview_backup_tier = _tier
	_preview = cue_id
	_preview_looped = looped
	_preview_paused = false
	_preview_finished_sent = false
	# 直接改档位而不走 set_tier：set_tier 会给**旧**层挂淡化，与 play_cue 的
	# 旧层淡出叠成两条 tween 抢同一个 volume_db（先改档再起播一次算对目标音量）
	_tier = PREVIEW_TIER
	play_cue(cue_id, FADE_PREVIEW, 1 if looped else 0)
	# 非循环预览播到末尾要通知页面走下一曲：各层同长同起点，任一层收尾即整曲收尾。
	# 绑定发送者：换曲后退役层（Fading_ 前缀）拖尾播完也会触发 finished，回调里甄别
	for name in _players.keys():
		var p: AudioStreamPlayer = _players[name]
		p.finished.connect(_on_preview_layer_finished.bind(p))
	preview_started.emit(cue_id)
	return true


## 退出预览：还原入场前的曲目与强度；原本静默则淡出静音。
## 原声带页在离开场景（返回主菜单）时调用——预览是"过路状态"，不该留在系统里。
func stop_preview(fade_s: float = FADE_CUE) -> void:
	if _preview == "":
		return
	_preview = ""
	_preview_paused = false
	_preview_finished_sent = false
	var restore_cue := _preview_backup_cue
	var restore_tier := _preview_backup_tier
	_preview_backup_cue = ""
	if restore_cue != "":
		_tier = restore_tier     # 先复位强度，play_cue 才按旧档取层目标
		play_cue(restore_cue, fade_s)
	else:
		stop_all(fade_s)


## 预览暂停/继续（走带按钮）。暂停不释放层：继续播放要从原位置接上。
func set_preview_paused(paused: bool) -> void:
	if _preview == "":
		return
	_preview_paused = paused
	for name in _players.keys():
		var p: AudioStreamPlayer = _players[name]
		if is_instance_valid(p):
			p.stream_paused = paused


## 拖动进度条：各层同帧 seek 到同一点（同长同起点，采样级同步不破）
func preview_seek(sec: float) -> void:
	if _preview == "":
		return
	var pos := clampf(sec, 0.0, preview_duration())
	for name in _players.keys():
		var p: AudioStreamPlayer = _players[name]
		if is_instance_valid(p):
			p.seek(pos)


## 当前播放位置（秒）。循环曲取模：引擎位置跨 loop 边界回绕，取模后进度条
## 单调走到头再回零（否则进度条会越过总时长）。
func preview_position() -> float:
	var p := _first_layer_player()
	if p == null:
		return 0.0
	var dur := preview_duration()
	var pos: float = p.get_playback_position()
	if dur <= 0.0:
		return pos
	return fposmod(pos, dur) if _preview_looped else minf(pos, dur)


## 当前预览曲目时长（秒）；非预览态返回 0
func preview_duration() -> float:
	if _preview == "":
		return 0.0
	return float(_cue_entry(_preview).get("duration_s", 0.0))


func _first_layer_player() -> AudioStreamPlayer:
	for name in _players.keys():
		var p: AudioStreamPlayer = _players[name]
		if is_instance_valid(p):
			return p
	return null


## 只认当前在放的层：换曲后旧层改名 Fading_ 拖尾淡出（约 0.9s 后释放），期间播到
## EOF 仍会发 finished——不甄别会把上一曲的收尾算到当前预览头上，页面凭空跳下一曲
func _on_preview_layer_finished(p: AudioStreamPlayer) -> void:
	if _preview == "" or _preview_looped or _preview_finished_sent:
		return
	if not is_instance_valid(p) or not _players.values().has(p):
		return
	_preview_finished_sent = true
	preview_finished.emit(_preview)


# ─────────────────────────────── 工具 ────────────────────────────────

func stop_all(fade_s: float = 1.0) -> void:
	for name in _players.keys():
		var p: AudioStreamPlayer = _players[name]
		_fade_player(p, SILENT_DB, fade_s)
		_free_after(p, fade_s + 0.3)
	_players = {}
	_layer_db = {}
	_cue = ""
	_preview = ""
	_preview_paused = false
	_preview_finished_sent = false
	_preview_backup_cue = ""
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
		"preview": _preview,
		"preview_paused": _preview_paused,
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
