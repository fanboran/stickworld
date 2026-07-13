class_name UIAPI
extends RefCounted
## UI 模块公共接口契约
##
## 本模块提供三层 UI 容器：
## - GlobalHUD       顶层常驻：时间速度、资源数、通知
## - ModePanel       模式相关：整体替换（Village/Battle/Possess）
## - ContextPanel    上下文相关：选中什么显示什么
## - ModalOverlay    弹窗（暂停菜单、组织架构总览、世界地图）
##
## 详见 docs/技术/架构/场景与战斗架构.md §十。

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
