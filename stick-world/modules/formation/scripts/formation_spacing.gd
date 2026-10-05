class_name FormationSpacing
extends RefCounted
## 编队阵列与物理分离的**间距单一真相源**（formation 模块内；units/combat 经 api.gd 读取）。
##
## 为什么集中：分离半径曾有三份副本（实体壳 / entity_motion 真身 / battle_sim 批模拟），
## 24px 换轨只改到壳——真身残留旧体型值 54，分离力持续对抗编队槽位，队列被推散抖动
## （"阵型混乱"的直接根因）。此后再不抄副本：数值与不变式只在本文件维护。
##
## 不变式（改任何数值前先读，顺序不可破坏）：
##   碰撞体宽 < 分离半径X ≤ 横向间距 < 分离半径Y ≤ 列间距，且
##   跟队死区 < 横向间距（否则站错一格的成员被判已落定、编队失修），
##   到位容差 ≥ 2×横向间距（槽位随小队质心每拍重算、锚向可翻转，容差过紧会出现
##   "站在线上却永远不到位"）。
## 碰撞体宽 = 83 × BASE_SCALE（24px 换轨后 BASE_SCALE 0.375 → ≈31）。
## 椭圆判等口径：横向间距 = 半径X（48）时同排邻位恰落在分离边界（判等不推），
## 槽位距即分离距——实测有抖动先把横向间距抬到 X+8。

## 运行时覆盖：横向/列间距走 BalanceConfig `balance.variables`（var_spread_spacing /
## var_row_gap，formation_system._apply_balance_tuning 装载）；到位容差走
## config/ai/squad_phase_plan.tres（arrive_tolerance）。分离半径与死区是物理/判定
## 不变式，不进调参表——调小叠身、调大挤散，必须与间距联动改。

## 分离半径·横向轴（px）：分离椭圆是**硬冲突区**判定，不是密度旋钮——调大它
## 必须联动出生几何/间距全链（椭圆判别压穿 = 分离力常驻 + 位置伺服极限环，
## 实测 vx 翻转 8.67 次/s 全员蛇形抽动）。密度观感用槽距（横向/列间距）调；
## 48 = 碰撞体宽 31 的安全倍率，实测档（2026-10-05 半径 60 试验回退：
## 出生阵列 MIN_ROW_GAP/STAGGER_X 未联动压穿椭圆，限位环复活）
const SEPARATION_RADIUS_X: float = 48.0
## 分离半径·纵深轴（px）：billboard 是竖长卡（视觉高度远超宽度），纵深前后
## 排视觉立面大量重叠——纵深轴放宽到 1.5 倍；同理不是密度旋钮。行内纵距
## 下限必须 ≥ 本值（压穿即极限环，battle_arena.MIN_ROW_GAP 与本值同源联动）
const SEPARATION_RADIUS_Y: float = 72.0
## 兼容别名（= 横向轴）：消费方（entity_motion/battle_sim）未改椭圆判定前
## 自动跟随横向口径（行为 = 圆半径 48）
const SEPARATION_RADIUS: float = SEPARATION_RADIUS_X
## 横向间距默认值（px，调参表 var_spread_spacing 覆盖）：密度主旋钮——队形
## 槽位横向拉开，单位不再人贴人；运行时真值 = BalanceConfig 覆盖值
##（改默认值必须同步 config/balance/variables.tres，默认值只是无配置兜底）
const SPREAD_SPACING_DEFAULT: float = 68.0
## 列间距默认值（px，调参表 var_row_gap 覆盖）：纵深主旋钮——≥ 纵深轴半径 72
## + 余量，编队列阵纵深不再压着分离线站；同步规则同上
const ROW_GAP_DEFAULT: float = 100.0
## 每列人数基准档（SWL Formation.UNITS_PER_COLUMN 直译；8~12 人小班口径取 4，
## 各班现役列高按班人数 4~6 自适应，见 formation_geometry.squad_units_per_column）
const UNITS_PER_COLUMN: int = 4
## 跟队重下发/落定死区（px）
const FOLLOW_DEADZONE: float = 40.0
## 小队相位计划到位容差默认值（px，config/ai/squad_phase_plan.tres 覆盖）
## （≥2×横向间距 68=136——96 档实测撞线，随横向间距联动抬）
const ARRIVE_TOLERANCE: float = 140.0


## 不变式自检（间距链改值后必跑；formation_system 启动时调用，违例打 error）：
## 返回违例清单（空 = 通过）。改任何数值前先读本文件头部不变式说明
static func check_invariants(spread_spacing: float, row_gap: float,
		arrive_tolerance: float) -> Array[String]:
	var bad: Array[String] = []
	const COLLIDER_W := 31.0
	if not (COLLIDER_W < SEPARATION_RADIUS_X):
		bad.append("碰撞体宽(%d)必须 < 分离半径X(%d)" % [COLLIDER_W, SEPARATION_RADIUS_X])
	if not (SEPARATION_RADIUS_X <= spread_spacing):
		bad.append("分离半径X(%d)必须 ≤ 横向间距(%d)——压穿=槽位互相推" % [
				SEPARATION_RADIUS_X, spread_spacing])
	if not (spread_spacing < SEPARATION_RADIUS_Y):
		bad.append("横向间距(%d)必须 < 分离半径Y(%d)——行内邻位落进椭圆" % [
				spread_spacing, SEPARATION_RADIUS_Y])
	if not (SEPARATION_RADIUS_Y <= row_gap):
		bad.append("分离半径Y(%d)必须 ≤ 列间距(%d)——纵深排压穿椭圆" % [
				SEPARATION_RADIUS_Y, row_gap])
	if not (arrive_tolerance >= spread_spacing * 2.0):
		bad.append("到位容差(%d)必须 ≥ 2×横向间距(%d)——站线上永不到位" % [
				arrive_tolerance, spread_spacing * 2.0])
	if not (FOLLOW_DEADZONE < spread_spacing):
		bad.append("跟队死区(%d)必须 < 横向间距(%d)——站错一格被判落定" % [
				FOLLOW_DEADZONE, spread_spacing])
	return bad
