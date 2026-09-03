class_name HitstopController
extends RefCounted
## 命中顿帧控制器 —— 从 weapon_mount 拆出（持有节流状态）。
##
## 全局 time_scale 冻结只在**玩家附身单位命中**时触发：48 人观察场每 0.3s
## 冻结全世界 0.06s = "又加速又卡顿掉帧"的元凶（2026-08-31 四轮审计结论）。
## AI 互殴的打击感由受击硬直/击退/红闪承担（原版 SWL 也不冻结全场）。

## 上次触发时刻（msec），跨命中共享做全局节流
var _last_hitstop_ms: int = -999000


## 尝试触发顿帧：headless 短路；仅附身单位命中触发；min_interval 节流。
## 恢复定时器 ignore_time_scale=true，不受冻结影响。
func try_trigger(owner_entity: CharacterBody2D, tree: SceneTree,
		time_scale: float, duration: float, min_interval: float) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if owner_entity == null or not owner_entity.is_possessed():
		return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_hitstop_ms < int(min_interval * 1000.0):
		return
	_last_hitstop_ms = now_ms
	Engine.time_scale = time_scale
	if tree != null:
		tree.create_timer(duration, true, false, true).timeout.connect(func():
			Engine.time_scale = 1.0
		)
