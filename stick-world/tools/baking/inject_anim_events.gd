@tool
extends Node
## 只把 Spine 内嵌事件（Hit/Sound/Drawn/Mine）注入已存在的动画 .tres 元数据，
## 不重算任何骨骼曲线。
##
## 为什么需要单独的注入器：
##   spine_import.gd 会**整份重建**动画（覆盖现有 .tres），而仓库里的动画曲线
##   是 spine_import → wash_anims 两步产线的结果（洗稿后的扰动曲线 + 循环闭合），
##   直接重跑第一步会把洗稿成果冲掉。本工具只写 metadata/*，曲线原样保留。
##
## 典型用法：
##   1. 调整了 spine_import 的事件提取逻辑，想同步到已洗稿的动画上；
##   2. 手工修过某条曲线的关键帧，需要补回事件元数据。
##
## 写入的元数据键（与 spine_import._write_event_meta 一致）：
##   "anim_events"  : Array[Dictionary] 全量事件 {name,time,string}
##   "hit_time"     : float  首个 Hit 事件的绝对秒（无则 -1）
##   "sound_events" : Array[[time, sfx_name], ...]
##
## 运行方式：
##   godot --headless --path "F:/VSCode/game-2-aux/stick-world" res://tools/baking/inject_anim_events.tscn

const SpineImportGd := preload("res://tools/baking/spine_import.gd")
const OUTPUT_DIR: String = SpineImportGd.OUTPUT_DIR
const SPINE_FILE: String = SpineImportGd.SPINE_FILE
const ANIM_MAP: Dictionary = SpineImportGd.ANIM_MAP


func _ready() -> void:
	print("=== 开始注入 Spine 动画事件元数据（不动曲线） ===")
	if not FileAccess.file_exists(SPINE_FILE):
		printerr("Spine 文件不存在: " + SPINE_FILE)
		get_tree().quit(1)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SPINE_FILE))
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		printerr("Spine JSON 解析失败")
		get_tree().quit(1)
		return
	var animations: Dictionary = (parsed as Dictionary).get("animations", {})
	var ok: int = 0
	var skipped: int = 0
	for godot_name in ANIM_MAP.keys():
		var path: String = OUTPUT_DIR + str(godot_name) + ".tres"
		if not ResourceLoader.exists(path):
			printerr("  跳过（动画不存在）: %s" % path)
			skipped += 1
			continue
		var spine_name: String = ANIM_MAP[godot_name]["spine"]
		var events: Array = []
		if animations.has(spine_name):
			events = SpineImportGd._extract_events(animations[spine_name])
		else:
			printerr("  警告：Spine 动画 %s 不存在，按空事件写入" % spine_name)
		var anim: Animation = load(path)
		SpineImportGd._write_event_meta(anim, events)
		var err := ResourceSaver.save(anim, path)
		if err != OK:
			printerr("  保存失败: %s (err=%d)" % [path, err])
			skipped += 1
			continue
		ok += 1
		print("  OK  %s.tres  events=%s" % [
			godot_name, SpineImportGd._event_summary(events)])
	print("=== 注入完成: %d 成功 / %d 跳过 ===" % [ok, skipped])
	get_tree().quit(0 if skipped == 0 else 1)
