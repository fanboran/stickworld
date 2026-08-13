class_name UIAPI
extends RefCounted
## 全局 UI 层公共接口契约
##
## 本层提供三层 UI 容器：
## - GlobalHUD       顶层常驻：时间速度、资源数、通知
## - ModePanel       模式相关：整体替换（Village/Battle/Possess 槽位）
## - ContextPanel    上下文相关：选中什么显示什么
## - ModalOverlay    弹窗（暂停菜单、组织架构总览、世界地图）
##
## 业务面板（BuildMenu/BattlePanel/FormationPanel/PossessPanel 等）归属各模块
## `ui/` 子目录，由 SystemSetup 装配到本层容器槽位，详见 modules/README.md。

# ─────────────────────────────── 模式面板 ID ────────────────────────────────
enum PanelType {
	VILLAGE,    ## 村落/城镇面板（建设菜单、村民管理、库存）
	BATTLE,     ## 战斗面板（框选信息、指令按钮、编制树）
	POSSESS,    ## 附身面板（角色控制 HUD）
}

# ─────────────────────────────── 节点路径 ────────────────────────────────
const PATH_GLOBAL_HUD := "GlobalHUD"
const PATH_MODE_PANEL := "ModePanel"
const PATH_CONTEXT_PANEL := "ContextPanel"
const PATH_MODAL_OVERLAY := "ModalOverlay"

# ─────────────────────────────── 面板工厂 ────────────────────────────────
## 创建存档面板实例（全屏模态）。挂载与生命周期由装配方负责（ModalOverlay 槽）。
## world 等模块经此工厂获取，不直接引用 ui_global 内部脚本。
static func create_save_panel() -> Control:
	const SavePanelScript := preload("res://modules/ui_global/scripts/menus/save_panel.gd")
	return UIKit.full_rect(SavePanelScript, "SavePanel")

# ─────────────────────────────── HUD 布局常量 ────────────────────────────────
## 小地图/缩放条共享布局参数（跨文件对齐，避免各处硬编码散落）
const HUD_MINIMAP_WIDTH: float = 240.0
const HUD_MINIMAP_HEIGHT: float = 80.0
## 小地图左上角 Y（屏幕顶部留白）
const HUD_MINIMAP_Y: float = 4.0
## 缩放条 Y（= 小地图 Y + 高度 + 4px 间距）
const HUD_ZOOMBAR_Y: float = 88.0
