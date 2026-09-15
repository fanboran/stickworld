extends RefCounted
## SystemSetup UI 与面板装配助手 —— 承接宿主分帧步骤表中 UI 域各步骤的函数体
## （界面根 / 调试层 / 战斗·编队·组织面板 / 战略总览 / 指挥链视图 / 设置·暂停菜单 /
## TeamAi HUD / 班组卡 / 缩放条 / 背包）。
##
## 纪律：
## - 状态全部留在宿主（system_setup.gd），本助手经 _host 回引读写，不另立状态；
## - 跨模块 preload 属 composition root 豁免、全部留在宿主，此处经 _host 取用；
## - 各方法与宿主同名壳逐一对应（宿主壳只做一行转发），行为与拆分前逐行等价。

var _host: Node  ## SystemSetup 宿主（无 class_name，动态回引）


func bind(host: Node) -> void:
	_host = host


# ─────────────────────────────── UI / Debug 覆盖层装配 ────────────────────────────────

## 实例化 UIRoot 场景并挂为子节点。
## UI 覆盖层从 UI 模块自包含场景加载，不再内嵌于 game_root.tscn。
func _setup_ui_root() -> void:
	if _host._root.ui_root != null:
		return  # 场景中已存在（兼容旧场景）
	var ur: CanvasLayer = _host._UIRootScene.instantiate()
	ur.name = "UIRoot"
	_host._root.add_child(ur)
	_host._root.ui_root = ur
	# 注入依赖（不自行向上遍历查找）：InputDispatcher 切换时同步面板；
	# 模式→面板映射在本装配层完成（UIRoot 不依赖业务模块枚举，断 ui_global↔player_control 环）
	if ur.has_method("setup"):
		ur.setup(_host._root.input_dispatcher, _mode_to_panel_type)
	# GlobalHUD 注入 CameraRig / GameRoot（居中/脱困/编制/设置按钮）
	var hud: Control = ur.get_node_or_null(UIAPI.PATH_GLOBAL_HUD)
	if hud != null and hud.has_method("setup"):
		hud.setup(_host._root.camera_rig, _host._root)


## 模式 → UI 面板类型映射（UIAPI.PanelType），装配时注入 UIRoot。
func _mode_to_panel_type(mode: int) -> int:
	match mode:
		PlayerControlAPI.Mode.EXPLORE, PlayerControlAPI.Mode.INDOOR, PlayerControlAPI.Mode.BUILD:
			return UIAPI.PanelType.VILLAGE
		PlayerControlAPI.Mode.BATTLE:
			return UIAPI.PanelType.BATTLE
		PlayerControlAPI.Mode.POSSESS:
			return UIAPI.PanelType.POSSESS
		_:
			return UIAPI.PanelType.VILLAGE


## 实例化 DebugOverlay 场景并挂为子节点。
## 调试覆盖层从 debug_gui 模块自包含场景加载，不再内嵌于 game_root.tscn。
func _setup_debug_overlay() -> void:
	if _host._root.get_node_or_null("DebugOverlay") != null:
		return  # 已存在，避免重复添加
	var dop: CanvasLayer = _host._DebugOverlayScene.instantiate()
	_host._root.add_child(dop)


# ─────────────────────────────── 战斗 UI 装配（§15 阶段 0.6）────────────────────────────────

## 给场景中已存在的 BattlePanel 占位节点挂脚本，并注入系统引用。详见 §10.1。
func _setup_battle_panel() -> void:
	if _host._root.ui_root == null:
		return
	var mp: Control = _host._root.ui_root.get_node_or_null("ModePanel")
	if mp == null:
		return
	var bp: Control = mp.get_node_or_null("BattlePanel")
	if bp == null:
		return
	bp.set_script(_host._BattlePanelScript)
	_host._root._battle_panel = bp
	_host.call_deferred("_setup_battle_panel_deferred")


func _setup_battle_panel_deferred() -> void:
	if _host._root._battle_panel == null:
		return
	if _host._root._battle_panel.has_method("setup"):
		_host._root._battle_panel.setup(_host._root)


# ─────────────────────────────── 编制管理窗口装配 ────────────────────────────────

## 实例化 FormationPanel 并挂到 UIRoot.ModalOverlay（模态面板，open/close 控制可见性）。
func _setup_formation_panel() -> void:
	if _host._root.ui_root == null:
		return
	var fp := UIKit.full_rect(_host._FormationPanelScript, "FormationPanel")
	if not _host._root.ui_root.add_to_slot("ModalOverlay", fp):
		return
	_host._root._formation_panel = fp
	_host.call_deferred("_setup_formation_panel_deferred")


func _setup_formation_panel_deferred() -> void:
	if _host._root._formation_panel == null:
		return
	if _host._root._formation_panel.has_method("setup"):
		_host._root._formation_panel.setup(_host._root)


# ─────────────────────────────── 组织管理窗口装配 ────────────────────────────────

## 实例化 OrgPanel 并挂到 UIRoot.ModalOverlay 槽（FLOATING 浮动窗口，open/close 控制可见性）。
func _setup_org_panel() -> void:
	if _host._root.ui_root == null:
		return
	var op := UIKit.full_rect(_host._OrgPanelScript, "OrgPanel")
	if not _host._root.ui_root.add_to_slot("ModalOverlay", op):
		return
	_host._root._org_panel = op
	# 装配层接线：OrgPanel 选中变更 → 班组卡（UI-W4b 触发源补全，不跨模块 get_node）
	if op.has_signal("org_selection_changed") \
			and not op.org_selection_changed.is_connected(_on_org_selection_changed):
		op.org_selection_changed.connect(_on_org_selection_changed)
	_host.call_deferred("_setup_org_panel_deferred")


## OrgPanel 选中组织 → 班组卡联动（选中 L1 唤起；其余/取消/关面板收起）。
## 班组卡未装配（步骤表更靠后）时静默跳过，装配完成后自然生效。
func _on_org_selection_changed(org_id: String) -> void:
	var card: Control = _host._squad_card
	if card == null or not is_instance_valid(card):
		return
	var show: bool = false
	if not org_id.is_empty() and _host._root._organization_api != null \
			and _host._root._organization_api.has_method("get_organization"):
		var r: Dictionary = _host._root._organization_api.get_organization(org_id)
		show = r.get("ok", false) and int((r.get("data", {}) as Dictionary).get("tier", 0)) == 1
	if show and card.has_method("show_squad"):
		card.call("show_squad", org_id)
	elif card.has_method("hide_card"):
		card.call("hide_card")


func _setup_org_panel_deferred() -> void:
	if _host._root._org_panel == null:
		return
	if _host._root._org_panel.has_method("setup"):
		_host._root._org_panel.setup(_host._root)


# ─────────────────────────── 战略总览装配（UI-W4b §3.2.C）───────────────────────────

## 实例化 StrategicOverviewPanel（全屏根走 UIKit.full_rect 合规出口，OrgPanel 同款）
## 挂 UIRoot.ModalOverlay 槽；入口在 OrgPanel 顶部「总览」按钮（group 查找，
## 装配层不导引用）。数据自取：组织 api 报表 + report_filed/commander_assigned 时间线。
func _setup_strategic_overview() -> void:
	if _host._root.ui_root == null:
		return
	var sp := UIKit.full_rect(_host._StrategicOverviewPanelScript, "StrategicOverviewPanel")
	if not _host._root.ui_root.add_to_slot("ModalOverlay", sp):
		sp.queue_free()
		return
	if sp.has_method("setup"):
		sp.setup(_host._root)


# ─────────────────────────── 指挥链视图装配（UI-W3）───────────────────────────

## 实例化 CommandChainView 场景（command_chain_view.tscn，场景=布局唯一真相源）挂
## UIRoot.ModalOverlay 槽（独立 FLOATING 窗口，与 OrgPanel 并存不互嵌——方案 §五.2）。
## 视图自带 group("command_chain_view")，OrgPanel 顶部「指挥链」按钮按 group 打开，
## 装配层不导引用（不新增 GameRoot getter）。
func _setup_command_chain_view() -> void:
	if _host._root.ui_root == null:
		return
	var cv: Control = _host._CommandChainViewScene.instantiate()
	if not _host._root.ui_root.add_to_slot("ModalOverlay", cv):
		cv.queue_free()
		return
	if cv.has_method("setup"):
		cv.setup(_host._root)


# ─────────────────────────────── 设置菜单装配（齿轮/ESC 打开）────────────────────────────────

## 实例化 SettingsMenuPanel 并挂到 UIRoot.ModalOverlay 槽（全屏 UI 根走 UIKit.full_rect）。
func _setup_settings_menu_panel() -> void:
	if _host._root.ui_root == null:
		return
	var sp := UIKit.full_rect(_host._SettingsMenuPanelScript, "SettingsMenuPanel")
	if not _host._root.ui_root.add_to_slot("ModalOverlay", sp):
		return
	_host._root._settings_menu_panel = sp
	_host.call_deferred("_setup_settings_menu_panel_deferred")


func _setup_settings_menu_panel_deferred() -> void:
	if _host._root._settings_menu_panel == null:
		return
	if _host._root._settings_menu_panel.has_method("setup"):
		_host._root._settings_menu_panel.setup(_host._root)


# ─────────────────────────────── 暂停菜单装配（ESC 打开）────────────────────────────────

## 实例化 PauseMenuPanel 并挂到 UIRoot.ModalOverlay 槽（全屏 UI 根走 UIKit.full_rect）。
func _setup_pause_menu_panel() -> void:
	if _host._root.ui_root == null:
		return
	var pp := UIKit.full_rect(_host._PauseMenuPanelScript, "PauseMenuPanel")
	if not _host._root.ui_root.add_to_slot("ModalOverlay", pp):
		return
	_host._root._pause_menu_panel = pp
	_host.call_deferred("_setup_pause_menu_panel_deferred")


func _setup_pause_menu_panel_deferred() -> void:
	if _host._root._pause_menu_panel == null:
		return
	if _host._root._pause_menu_panel.has_method("setup"):
		_host._root._pause_menu_panel.setup(_host._root)


# ─────────────────────────────── TeamAi 状态 HUD 装配（W1 观测接线批）────────────────────────────────

## 挂 TeamAi 姿态 HUD（combat/ui/team_ai_hud.tscn，场景=布局唯一真相源）到
## HudOverlay 槽并注入 BattleDirector 引用（数据自取，本层只装配）。显隐走
## DebugApi drawer "team_ai_hud"（F3 开关族，注册见宿主 register_debug_drawers）；
## 槽位路由见 UI.md §10.7，模块专属 UI 归 combat/ui（组织界面与AI状态接线 §2.2）。
func _setup_team_ai_hud() -> void:
	if _host._root.ui_root == null or _host._root.battle_director == null:
		return
	var hud := _host._TeamAiHudScene.instantiate()
	if not _host._root.ui_root.add_to_slot("HudOverlay", hud):
		hud.queue_free()
		return
	if hud.has_method("setup"):
		hud.setup(_host._root.battle_director)


# ─────────────────────────────── L1 班组卡装配（W2 · 组织界面）────────────────────────────────

## 挂 L1 班组卡（combat/ui/squad_card.tscn，场景=布局唯一真相源）到 ContextPanel 的
## SquadInspector 具名槽（槽在 context_panel.tscn 声明，UI.md §10.1 层级图），
## 并注入 GameRoot（卡片数据自取：框选解析小队 → 编制/相位/士气 duck 取数）。
## 显隐由卡片自管（框选到小队即有、清空即收），装配层不参与业务判断。
## 走 add_to_slot 的路径形式——槽在 ContextPanel 之下（UI.md §10.1 组织层级），
## 槽名即 UIRoot 下的相对 NodePath。
func _setup_squad_card() -> void:
	if _host._root.ui_root == null:
		return
	var card := _host._SquadCardScene.instantiate()
	if not _host._root.ui_root.add_to_slot("ContextPanel/SquadInspector", card):
		card.queue_free()
		return
	_host._squad_card = card
	if card.has_method("setup"):
		card.setup(_host._root)


## 创建 ZoomBar 并挂到 UIRoot，钉进 top_center stack（Minimap 正下方，见 hud_zone_layout.gd）。
func _setup_zoom_bar() -> void:
	if _host._root.ui_root == null:
		return
	var zb := UIKit.widget(_host._ZoomBarScript, "ZoomBar")
	_host._root.ui_root.add_to_slot("HudOverlay", zb)
	_host._root.ui_root.place_in_zone(&"top_center", zb)
	_host._root._zoom_bar = zb
	if zb.has_method("setup"):
		zb.setup(_host._root.camera_rig)


# ─────────────────────────────── 背包装备系统装配（modules/inventory）────────────────────────────────

## 装配背包装备系统四件套：
##   1. InventoryService（GameRoot 子节点：玩家背包 + 装备→附身实体桥接）
##   2. Hotbar（HudOverlay 底部常驻物品栏：主副手/Hotbar 物品/动作快捷键三组）
##   3. InventoryScreen（ModalOverlay 模态背包：E 键开关，UIModalStack.INVENTORY）
##   4. StatsScreen（ModalOverlay 角色属性面板：C 键开关，UIModalStack.STATS）
func _setup_inventory() -> void:
	if _host._root.ui_root == null:
		return
	var service := Node.new()
	service.set_script(_host._InventoryServiceScript)
	service.name = "InventoryService"
	_host._root.add_child(service)
	if service.has_method("setup"):
		service.setup(_host._root)
	_host._root.inventory_service = service
	var hb := UIKit.widget(_host._HotbarScript, "Hotbar")
	_host._root.ui_root.add_to_slot("HudOverlay", hb)
	if hb.has_method("setup"):
		hb.setup(_host._root, service)
	var inv := UIKit.full_rect(_host._InventoryScreenScript, "InventoryScreen")
	if not _host._root.ui_root.add_to_slot("ModalOverlay", inv):
		return
	_host._root._inventory_screen = inv
	if inv.has_method("setup"):
		inv.setup(_host._root, service)
	var stats := UIKit.full_rect(_host._StatsScreenScript, "StatsScreen")
	if not _host._root.ui_root.add_to_slot("ModalOverlay", stats):
		return
	_host._root._stats_panel = stats
	if stats.has_method("setup"):
		stats.setup(_host._root, service)
