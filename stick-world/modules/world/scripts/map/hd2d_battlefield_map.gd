extends Hd2dStreetMap
class_name Hd2dBattlefieldMap
## HD-2D 战场图 —— 主街东门外的城郊战场（旧 12V12 战场图的 HD-2D 重建）。
##
## 3D 层走 Hd2dWorld 战场模式（battlefield=true）：无城墙/门洞/街灯/楼群，
## 开阔野地 + 战痕散布（proto 侧 BF_PROPS/BF_NATURE_SPOTS）；资源点仍走
## resource_gen 算法全域撒布（调稀——野地要开阔可列阵，东缘渐入林带）。
## 2D 宿主逻辑（碰撞映射/昼夜/相机镜像/角色进 3D/城门引导）与主街同一套，
## 只换旅行链、资源密度与出生点语义。
##
## 旅行链：左出回主街（从其东缘落，走东路野地穿东门洞进城）、右出去
## forest_zone（保留原 战场↔森林 链）。进图不自动刷敌开战（出征与领地架构
## §4.3：战斗走出征系统；dev 验证走 tests/dev/verify_battle.gd 直达调
## InitialContent.spawn_battlefield_enemies）。

func _configure_hd(hd: Node3D) -> void:
	hd.set("battlefield", true)


func _ready() -> void:
	# 战场野地资源稀于主街墙外带，且**西半不开树**：中央偏西全为硬化区
	# （resource_gen 净空带机制，复用主街"算法就在那"的对接），林线从东半
	# 渐密——战场开阔可列阵，树丛只做"往森林去"的方向感
	resource_density = 0.12
	forest_clear_cells = 6
	forest_ramp_cells = 30
	super()


## 出口链：左出回主街（东缘落）、右出去森林附属图
func _exit_specs() -> Array:
	return [
		{"name": "ExitLeft", "x": map_left + 48.0, "target": "hd2d_street",
		 "entry": WorldAPI.EntrySide.RIGHT},
		{"name": "ExitRight", "x": map_right - 48.0, "target": "forest_zone",
		 "entry": WorldAPI.EntrySide.LEFT},
	]


## 地形硬化分布：cx < 8（西半含两缘入口带）= 硬化开阔地（算法净空区不长
## 树）；东半野外——距硬化带 6 格净空、再 30 格渐密，林线只出现在战场东缘
func get_terrain_type_at_cell(cx: int) -> int:
	return TERRAIN_DIRT_ROAD if cx < 8 else 0


## 战场无"街中心"语义：按进入方向落在对应边缘入口（来自主街=西缘、
## 来自森林=东缘）。主街的固定出生点（返回街中心）是开局直连语义，
## 中转图不适用——读 SceneLoader 最后进入方向还原入口公式。
func get_spawn_point() -> Vector2:
	var side: int = WorldAPI.EntrySide.LEFT
	var gr := _find_game_root()
	if gr != null:
		var sl: Node = gr.get("scene_loader")
		if sl != null and sl.has_method("get_last_entry_side"):
			side = int(sl.get_last_entry_side())
	var x: float = map_left + 150.0 if side == WorldAPI.EntrySide.LEFT \
			else map_right - 150.0
	return Vector2(x, 1010.0)


## 无村民（战场无劳作设施；supports_village_facilities 继承主街=false）
func wants_villager_npcs() -> bool:
	return false


func _find_game_root() -> Node:
	var p: Node = get_parent()
	while p != null:
		if p.has_method("request_map_travel"):
			return p
		p = p.get_parent()
	return null
