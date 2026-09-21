## Formation 模块公共接口契约（战斗中的阵列）
##
## 本模块承载"战斗阵列"整条业务：小队与编队槽位（FormationSystem）→ 槽位几何
## （FormationGeometry）→ 编队动态跟队（SquadFollowDirector）→ 相位跃进计划
## （SquadPhasePlan）→ 编制快照/权威值择班/信息上报，以及编制 UI
## （ui/formation_panel 编制窗口、ui/squad_card 班组卡、ui/squad_member_row 成员行）。
##
## 边界（与 combat 模块的分工）：号令的语义与下发（TacticalOrders / CommandChain）
## 属 combat——本模块只回答"人站在哪、阵列怎么排、何时算到位"，号令经
## get_squad_dest(…, "formation") 取落点。
##
## 外部模块通过本契约交互：
##   - FormationAPI.SEPARATION_RADIUS / SPREAD_SPACING_DEFAULT / ROW_GAP_DEFAULT /
##     UNITS_PER_COLUMN / FOLLOW_DEADZONE / ARRIVE_TOLERANCE
##       间距与物理分离的**单一真相源**（不变式见 scripts/formation_spacing.gd）。
##       units（实体分离）与 combat（批模拟）经本文件跨模块读取——禁止再抄副本常量。
##   - 运行期实例 FormationSystem（class_name 全局）由装配层创建并注入消费方：
##     game_root.get_formation_system()、实体 set_formation_system()、
##     BattleDirector.set_formation_system()。实例方法面（create_squad / assign_leader /
##     get_squad_dest / set_squad_follow_squad / is_unit_in_formation / get_squad_target …）
##     即对外契约，消费方一律 duck 调用。
##
## ⚠️ 契约说明：实现全在 scripts/ 内部脚本；本文件是契约声明层 + 常量转发，
## 外部模块禁止直接 preload 模块内部脚本路径（audit_deps 口径）。
class_name FormationAPI
extends RefCounted

const _Spacing := preload("res://modules/formation/scripts/formation_spacing.gd")

## 分离检测半径（px；units 实体链与 combat 批模拟同源）
const SEPARATION_RADIUS: float = _Spacing.SEPARATION_RADIUS
## 横向间距默认值（px；调参表 var_spread_spacing 覆盖）
const SPREAD_SPACING_DEFAULT: float = _Spacing.SPREAD_SPACING_DEFAULT
## 列间距默认值（px；调参表 var_row_gap 覆盖）
const ROW_GAP_DEFAULT: float = _Spacing.ROW_GAP_DEFAULT
## 每列人数（SWL Formation.UNITS_PER_COLUMN 直译）
const UNITS_PER_COLUMN: int = _Spacing.UNITS_PER_COLUMN
## 跟队重下发/落定死区（px）
const FOLLOW_DEADZONE: float = _Spacing.FOLLOW_DEADZONE
## 相位计划到位容差默认值（px；config/ai/squad_phase_plan.tres 覆盖）
const ARRIVE_TOLERANCE: float = _Spacing.ARRIVE_TOLERANCE
