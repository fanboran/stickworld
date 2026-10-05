class_name TacticsAPI
extends RefCounted
## tactics 模块对外契约（L2 战术决策词汇：目标选择 + 战术号令）。
##
## 从 combat 聚合迁出（与 formation 同期的域拆分）：TargetFinder / TacticalOrders 是
## units（行为层选目标）、formation（小队共享目标 + 相位计划号令判定）、combat（战斗编排）
## 三方共用的战术词汇，独立成模块后三方全部向下依赖，combat⇄units 环（AR-2）根因消除。
##
## - TargetFinder：公共目标选择核心（find_target / find_weakest_ally / find_targets_in_arc；
##   规则经 opts 链式过滤表达——反编译参考实装 A，口径见 target_finder.gd 文件头）。
## - TacticalOrders：战术号令节点（OrderType 枚举 + issue / issue_to_org 送达，
##   经运行时注入的 formation/command_chain/org 引用回查，不静态依赖它们）。
## - CapturePoint：夺点结算原子（位置/半径/归属/进度，拉锯积分+冻结互消+满进度易主；
##   易主发模块信号 capture_owner_changed，旗点状态经 get_capture_state() 只读探测）。
## - SquadIntentPlanner：班级意图规划器（0.5s 节拍攻点/驻防/接火打分选意图，翻译
##   TacticalOrders 下发；tick(delta) 外部可驱动不宿主耦合；单位数据经调用方注入
##   provider 回传——L2 零出向；同局两台恰好一台 drives_settlement=true 管占领结算）。
##
## 跨模块消费一律经本文件常量（显式 preload 链，headless 防御惯例 §七.3）；
## 禁止 preload 本模块 scripts/ 内部文件（tools/audit_deps.py 越界 preload 棘轮按此口径计数）。

## 战术号令脚本（TacticalOrders：OrderType 枚举 / issue / issue_to_org）
const Orders: GDScript = preload("res://modules/tactics/scripts/tactical_orders.gd")
## 目标选择脚本（TargetFinder：find_target / find_weakest_ally / find_targets_in_arc）
const Finder: GDScript = preload("res://modules/tactics/scripts/target_finder.gd")
## 夺点结算脚本（CapturePoint：位置/半径/归属/进度 + 拉锯积分与易主信号）
const CapturePoint: GDScript = preload("res://modules/tactics/scripts/capture/capture_point.gd")
## 班级意图规划器（SquadIntentPlanner：0.5s 节拍打分选意图 + 号令翻译，外部 tick 驱动）
const IntentPlanner: GDScript = preload("res://modules/tactics/scripts/capture/squad_intent_planner.gd")
