class_name AchievementRecord
extends RefCounted
## 成就解锁记录 —— 图章数据形状（07-成就系统 §四：图章附带获得日期与帝国状态快照）。
##
## 图章是存档绑定的（07 边缘情况）：记录随档走，覆盖存档重新收集，不跨档继承。

var def_id := ""
var unlocked_at := 0.0      ## 获得时刻（游戏内时间，由调用方注入——api 层取 WorldState）
var empire_snapshot := {}   ## 获得时帝国状态快照（叙事载体；字段结构随消费方定，骨架存原样）


func to_dict() -> Dictionary:
	return {
		"def_id": def_id,
		"unlocked_at": unlocked_at,
		"empire_snapshot": empire_snapshot,
	}


static func from_dict(d: Dictionary) -> AchievementRecord:
	var r := AchievementRecord.new()
	r.def_id = String(d.get("def_id", ""))
	r.unlocked_at = float(d.get("unlocked_at", 0.0))
	var snap: Dictionary = d.get("empire_snapshot", {})
	r.empire_snapshot = snap.duplicate()
	return r
