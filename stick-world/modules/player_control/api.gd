class_name PlayerControlAPI
extends RefCounted
## PlayerControl 模块公共接口契约
##
## 本模块提供玩家输入与控制：
## - InputDispatcher 输入模式分发
## - SelectionSystem 框选/选择 —— P0.6 阶段
## - FormationSystem 编队 —— P0.6 阶段
## - TacticalOrders 战术指令 —— P0.6 阶段
## - PossessionInterface 附身操控 —— P0.7 阶段
##
## 详见 docs/技术/架构/场景与战斗架构.md §七.3、§八.3。

# ─────────────────────────────── 输入模式 ────────────────────────────────
enum Mode {
	NONE,       ## 未激活（初始状态，等地图加载完再切到 EXPLORE）
	EXPLORE,    ## 探索模式（默认，城镇/村落自由移动）
	BUILD,      ## 建设模式（选址中，鼠标控制 ghost 建筑）
	BATTLE,     ## 战斗模式（可框选/编队/下令）
	POSSESS,    ## 附身模式（直接控制单一火柴人）
	INDOOR,     ## 室内模式（玩家在建筑交互区内）
	UI,         ## UI 模式（弹窗打开时屏蔽游戏输入）
}

# ─────────────────────────────── 信号契约 ────────────────────────────────
## InputDispatcher 发射的信号：
##   - mode_changed(old_mode: int, new_mode: int)
##
## 模式切换规则：
##   EXPLORE <-> BUILD: 玩家按 B 键或点击建造菜单
##   EXPLORE <-> INDOOR: 玩家进入/离开建筑交互区
##   EXPLORE -> BATTLE: 城镇被袭或玩家进入战场地图
##   BATTLE -> POSSESS: 玩家附身某单位
##   任意 -> UI: 打开模态弹窗
