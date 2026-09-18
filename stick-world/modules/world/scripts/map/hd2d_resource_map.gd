extends Hd2dStreetMap
class_name Hd2dResourceMap
## HD-2D 城外资源图 —— 城门传送目的地（西郊/东郊各一张，创始人 2026-09-15：
## 左右城墙各自传送到一个城外资源点地图）。
##
## 3D 层走 proto 的战场式开阔模式（battlefield=true：无城墙/街灯/楼群）+
## resource_field=true（无战争遗物、无解包天空剪影）；资源点走 resource_gen
## 算法全域密布（密度 0.35——主街墙外带只露两三个，真正的采集在这里）。
## 出口：内缘一道触发器回主街（从对应城门侧落，出城门就是回城口）。
##
## 村民不出图（采集经济在主街墙外带），本图无 NPC 出生、无工位。

@export var resource_side: int = -1   # -1 = 西郊（主街西门出），+1 = 东郊

## ── map_id → 参数解析（共享壳收敛）───────────────────────────────────
## 东西两张资源 tscn 收敛为一张壳（hd2d_resource.tscn），唯一参数差异
## resource_side 由 SceneLoader 注入的 map_id 推导（键=历史 map_id，不改）。
const SIDE_BY_MAP_ID := {
	"hd2d_resource_w": -1,
	"hd2d_resource_e": 1,
}


## 按注入的 map_id 解析 resource_side（_ready 开头调用）。
## 无 meta / 非资源图 id（未经 SceneLoader 的直接实例化）保留现有值。
func _apply_side_from_map_id() -> void:
	if not has_meta(WorldAPI.META_MAP_ID):
		return
	var mid: String = str(get_meta(WorldAPI.META_MAP_ID))
	if SIDE_BY_MAP_ID.has(mid):
		resource_side = int(SIDE_BY_MAP_ID[mid])


func _configure_hd(hd: Node3D) -> void:
	hd.set("battlefield", true)
	hd.set("resource_field", true)


func _ready() -> void:
	_apply_side_from_map_id()
	resource_density = 0.35
	forest_clear_cells = 2
	forest_ramp_cells = 8
	super()


func wants_villager_npcs() -> bool:
	return false


func get_npc_spawn_points() -> Array:
	return []


func get_open_work_sites() -> Array:
	return []


## 出口链：内缘单口回主街（resource_side 对应的城门侧落）
func _exit_specs() -> Array:
	var to_side: int = WorldAPI.EntrySide.LEFT if resource_side < 0 else WorldAPI.EntrySide.RIGHT
	var inner_x: float = (map_right - 48.0) if resource_side < 0 else (map_left + 48.0)
	return [
		{"name": "ExitInner", "x": inner_x, "target": "hd2d_street",
		 "entry": to_side},
	]
