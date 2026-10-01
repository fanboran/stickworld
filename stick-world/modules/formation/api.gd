## Formation 模块公共接口契约（战斗中的阵列）
##
## 本模块承载"战斗阵列"整条业务：小队与编队槽位（FormationSystem）→ 槽位几何
## （FormationGeometry）→ 编队动态跟队（SquadFollowDirector）→ 相位跃进计划
## （SquadPhasePlan）→ 编制快照/权威值择班/信息上报，以及编制 UI
## （ui/formation_panel 编制窗口、ui/squad_card 班组卡、ui/squad_member_row 成员行）。
##
## 编制层级（现实军衔体系重排）：班 squad（8~12 人小班、硬顶 15，班长 rank 1，
## 阵亡组织侧补位免费轮转）→ 排 platoon（2~3 班 + 排长 1 名 rank 2，战斗域本地
## 聚合不入组织树；排长阵亡 = 指挥链缺口：该排失去集火号令与排长士气光环，
## 到战斗结束不补员）→ 连/战场（2~4 排 + 连长或指挥官 rank 3，挂载点 =
## platoon 的 company_id 字段，指挥官批次接入）。
##
## 排层契约（FormationSystem 实例方法，duck 调用）：
##   create_platoon(squad_ids, name="") -> platoon_id
##   assign_platoon_leader(platoon_id, unit) -> bool（排长须为排内班成员）
##   get_platoon_leader / get_platoon_squads / get_platoon_of_squad /
##   get_unit_platoon / get_platoon_units / get_all_platoons / get_platoon_count
##   disband_platoon(platoon_id)（班保留转独立）
##   has_squad_command_chain(squad_id) -> bool（排长缺口 → false）
##   信号：platoon_created(platoon_id, squad_ids) / platoon_leader_lost(platoon_id)
##
## 班内聚拢出口（Boids 式裁剪，常量见本文件 COHESION_/ALIGNMENT_ 段）：
##   get_unit_cohesion_steer(unit) -> Vector2（转向建议，加速度量纲；消费方
##   entity_motion 叠加到既有转向通道，不直改位置。ZERO = 死区内/避战中/无班）
##   get_squad_spread_radius(squad_id) -> float（聚拢死区半径，按班人数放宽）
##
## 边界（与 tactics / combat 模块的分工）：号令的语义与目标选择（TargetFinder /
## TacticalOrders）属 tactics，号令的下发链（CommandChain）属 combat——本模块只回答
## "人站在哪、阵列怎么排、何时算到位"，号令经 get_squad_dest(…, "formation") 取落点，
## 共享目标选型与推进类号令枚举直取 tactics/api.gd 契约出口。
##
## 外部模块通过本契约交互：
##   - FormationAPI.SEPARATION_RADIUS / SPREAD_SPACING_DEFAULT / ROW_GAP_DEFAULT /
##     UNITS_PER_COLUMN / FOLLOW_DEADZONE / ARRIVE_TOLERANCE
##       间距与物理分离的**单一真相源**（不变式见 scripts/formation_spacing.gd）。
##       units（实体分离）与 combat（批模拟）经本文件跨模块读取——禁止再抄副本常量。
##       UNITS_PER_COLUMN 为基准档（8~12 人小班取 4）；各班现役列高按班人数
##       4~6 自适应（formation_geometry.squad_units_per_column），槽位落点与
##       落定判定同源取数。
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

## 分离半径·横向轴（px；【提案/待定·待实测校准】椭圆口径——billboard 竖长卡
## 纵深视觉重叠，Y 轴另立；units 实体链与 combat 批模拟同源）
const SEPARATION_RADIUS_X: float = _Spacing.SEPARATION_RADIUS_X
## 分离半径·纵深轴（px；约横向 1.5 倍起步，改判定前消费方先读此值）
const SEPARATION_RADIUS_Y: float = _Spacing.SEPARATION_RADIUS_Y
## 分离半径兼容别名（= 横向轴 X）：消费方未改椭圆判定前自动跟随横向口径
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

## ── 班内聚拢（Boids 式裁剪）常量【提案/待定·待实测校准】──
## 消费出口：FormationSystem.get_unit_cohesion_steer(unit)（转向建议，加速度量纲，
## 消费方叠加到既有转向通道、不直改位置）；分离力不在此——分离是 units 侧
## 椭圆分离（SEPARATION_RADIUS_X/Y 口径）。
## 班散布半径基准（px，8 人班）：质心超出此距离才回拉（死区内零施力——
## 只拉掉队的，不吸站好的，防沙丁鱼的关键）
const COHESION_SPREAD_RADIUS_BASE: float = 140.0
## 每增 1 人的散布半径增量（px）：班越大越宽
const COHESION_SPREAD_RADIUS_PER_MEMBER: float = 6.0
## 回拉强度斜率（px/s² 每超出 1px，线性段）
const COHESION_PULL_PER_PX: float = 6.0
## 回拉强度上限（px/s²；防磁铁）
const COHESION_PULL_MAX: float = 220.0
## 接战衰减系数：接战中（behavior == "attack"）回拉 × 此值（战斗走位优先）
const COHESION_ENGAGED_SCALE: float = 0.5
## 班均速死区（px/s）：班均速低于此值不对齐（站桩不抖）
const COHESION_AVG_SPEED_DEADZONE: float = 20.0
## 对齐收敛权重（1/s）：行军速度向班均速收敛（转向建议 = Δv × 此值）
const ALIGNMENT_STEER_SCALE: float = 2.0
