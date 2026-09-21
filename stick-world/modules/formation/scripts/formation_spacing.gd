class_name FormationSpacing
extends RefCounted
## 编队阵列与物理分离的**间距单一真相源**（formation 模块内；units/combat 经 api.gd 读取）。
##
## 为什么集中：分离半径曾有三份副本（实体壳 / entity_motion 真身 / battle_sim 批模拟），
## 24px 换轨只改到壳——真身残留旧体型值 54，分离力持续对抗编队槽位，队列被推散抖动
## （"阵型混乱"的直接根因）。此后再不抄副本：数值与不变式只在本文件维护。
##
## 不变式（改任何数值前先读，顺序不可破坏）：
##   碰撞体宽 < 分离半径 < 横向间距 ≤ 列间距，且
##   跟队死区 < 横向间距（否则站错一格的成员被判已落定、编队失修），
##   到位容差 ≥ 2×横向间距（槽位随小队质心每拍重算、锚向可翻转，容差过紧会出现
##   "站在线上却永远不到位"）。
## 碰撞体宽 = 83 × BASE_SCALE（24px 换轨后 BASE_SCALE 0.375 → ≈31）。
##
## 运行时覆盖：横向/列间距走 BalanceConfig `balance.variables`（var_spread_spacing /
## var_row_gap，formation_system._apply_balance_tuning 装载）；到位容差走
## config/ai/squad_phase_plan.tres（arrive_tolerance）。分离半径与死区是物理/判定
## 不变式，不进调参表——调小叠身、调大挤散，必须与间距联动改。

## 分离检测半径（px）：战内实体链与 BattleSim 批模拟同源取值
const SEPARATION_RADIUS: float = 40.5
## 横向间距默认值（px，调参表 var_spread_spacing 覆盖）
const SPREAD_SPACING_DEFAULT: float = 48.0
## 列间距默认值（px，调参表 var_row_gap 覆盖）
const ROW_GAP_DEFAULT: float = 56.0
## 每列人数（SWL Formation.UNITS_PER_COLUMN 直译；无 dump 真值，按三班 8~10 人取 3）
const UNITS_PER_COLUMN: int = 3
## 跟队重下发/落定死区（px）
const FOLLOW_DEADZONE: float = 40.0
## 小队相位计划到位容差默认值（px，config/ai/squad_phase_plan.tres 覆盖）
const ARRIVE_TOLERANCE: float = 96.0
