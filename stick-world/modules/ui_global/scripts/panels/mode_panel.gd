class_name ModePanel
extends Control
## 模式面板 —— 根据当前游戏模式整体替换。
##
## P0 阶段：通过 switch_to(panel_type) 切换子面板占位。
## 子面板需要：VillagePanel / BattlePanel / PossessPanel
## 当前阶段仅切换可见性，不实例化（场景里预置占位 Control）。

# UIAPI 是全局 class_name，无需 preload

# ─────────────────────────────── 子节点引用 ────────────────────────────────
## 三种模式面板占位（在 .tscn 中预置）
@onready var village_panel: Control = get_node_or_null("VillagePanel")
@onready var battle_panel: Control = get_node_or_null("BattlePanel")
@onready var possess_panel: Control = get_node_or_null("PossessPanel")


# ─────────────────────────────── 公共 API ────────────────────────────────

## 切换到指定面板类型
func switch_to(panel_type: int) -> void:
	_hide_all()
	match panel_type:
		UIAPI.PanelType.VILLAGE:
			if village_panel:
				village_panel.visible = true
		UIAPI.PanelType.BATTLE:
			if battle_panel:
				battle_panel.visible = true
		UIAPI.PanelType.POSSESS:
			if possess_panel:
				possess_panel.visible = true


## 获取当前显示的面板类型（P0 阶段简化为查询可见性）
func get_active_panel_type() -> int:
	if village_panel and village_panel.visible:
		return UIAPI.PanelType.VILLAGE
	if battle_panel and battle_panel.visible:
		return UIAPI.PanelType.BATTLE
	if possess_panel and possess_panel.visible:
		return UIAPI.PanelType.POSSESS
	return UIAPI.PanelType.VILLAGE


# ─────────────────────────────── 内部 ────────────────────────────────

func _hide_all() -> void:
	if village_panel:
		village_panel.visible = false
	if battle_panel:
		battle_panel.visible = false
	if possess_panel:
		possess_panel.visible = false


func _ready() -> void:
	# 默认显示村落面板
	switch_to(UIAPI.PanelType.VILLAGE)
