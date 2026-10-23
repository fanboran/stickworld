class_name PlayerControlAPI
extends RefCounted
## PlayerControl 模块公共接口契约
##
## 本模块提供玩家输入与控制：
## - InputDispatcher 输入模式分发
## - UserControlInterface User Control 操控 -- P0.7 阶段
##
## 框选/编队/战术指令（SelectionSystem/FormationSystem/TacticalOrders）
## 实现在 combat 模块 scripts/command/，经 GameRoot 装配注入协同。
##
## 详见 docs/技术/架构/场景与战斗/战斗与AI.md §7.1.3、§7.5、§8.3。
##
## UserControlInterface 公共 API：
##   - get_user_controlled_entity() -> Node2D    获取当前接管实体
##   - control(entity: Node2D) -> void     主动接管指定实体
##   - release() -> void                   释放接管并退出 USER_CONTROL 模式
##
## 接管流程：
##   1. BATTLE 模式框选单位
##   2. BattlePanel 点击"接管选中单位"按钮 -> InputDispatcher.enter_user_control_mode()
##   3. UserControlInterface._on_mode_activated 从 SelectionSystem 取选中单位
##   4. entity.set_user_controlled(true) + CameraRig 居中跟随 + TimeManager 降速
##   5. WASD 移动 / 鼠标左键攻击 / ESC 退出
##   6. 退出时恢复之前模式和时间速度

# ─────────────────────────────── 输入模式 ────────────────────────────────
enum Mode {
	NONE,       ## 未激活（初始状态，等地图加载完再切到 EXPLORE）
	EXPLORE,    ## 探索模式（默认，城镇/聚落自由移动）
	BUILD,      ## 建设模式（选址中，鼠标控制 ghost 建筑）
	BATTLE,     ## 战斗模式（可框选/编队/下令）
	USER_CONTROL, ## User Control 模式（直接控制单一火柴人）
	INDOOR,     ## 室内模式（玩家在建筑交互区内）
	UI,         ## UI 模式（弹窗打开时屏蔽游戏输入）
}

# ─────────────────────────────── InputDispatcher 注册表 ────────────────────────────────
## 由 GameRoot 装配时注册。units 等模块经本 api 获取（替代 group 反查，方向 units→player_control）。
## 生命周期：GameRoot._ready 注册（register_input_dispatcher）→ InputDispatcher._exit_tree
## 自注销（unregister_input_dispatcher，formation/api.gd _active_host 同款对称模式）——
## GameRoot 退出/重建时不清，静态持有旧节点悬置引用。
static var _input_dispatcher: Node = null


static func register_input_dispatcher(dispatcher: Node) -> void:
	_input_dispatcher = dispatcher


## 生命周期出口：被注册节点退出场景树时自注销（InputDispatcher._exit_tree 调用）。
## 仅当前注册者才清——防误清后注册的新实例。
static func unregister_input_dispatcher(dispatcher: Node) -> void:
	if _input_dispatcher == dispatcher:
		_input_dispatcher = null


static func get_input_dispatcher() -> Node:
	return _input_dispatcher


# ─────────────────────────────── 信号契约 ────────────────────────────────
## InputDispatcher 发射的信号：
##   - mode_changed(old_mode: int, new_mode: int)
##
## 模式切换规则：
##   EXPLORE <-> BUILD: 玩家按 B 键或点击建造菜单
##   EXPLORE <-> INDOOR: 玩家进入/离开建筑交互区
##   EXPLORE -> BATTLE: 城镇被袭或玩家进入战场地图
##   BATTLE -> USER_CONTROL: 玩家接管某单位
##   任意 -> UI: 打开模态弹窗
