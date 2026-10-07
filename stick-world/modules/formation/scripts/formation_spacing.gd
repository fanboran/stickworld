class_name FormationSpacing
extends RefCounted
## 编队阵列与物理分离的**间距单一真相源**（formation 模块内；units/combat 经 api.gd 读取）。
##
## 为什么集中：分离半径曾有三份副本（实体壳 / entity_motion 真身 / battle_sim 批模拟），
## 24px 换轨只改到壳——真身残留旧体型值 54，分离力持续对抗编队槽位，队列被推散抖动
## （"阵型混乱"的直接根因）。此后再不抄副本：数值与不变式只在本文件维护。
##
## 不变式（改任何数值前先读，顺序不可破坏）：
##   碰撞体宽 < 分离半径X < 分离半径Y ≤ 列间距 ≤ 横向间距，且
##   跟队死区 < 横向间距（否则站错一格的成员被判已落定、编队失修），
##   横向间距 ≤ 到位容差 < 2×横向间距（波次完成门槛：落点是跃进线锚定的
##   静态槽位（前列贴 base_pos），容差只需吸收锚向抖动——不是随质心每拍
##   重算的动态锚；过大（≥2×间距）会把「离落点一格内」的成员误判已到位，
##   波次号令不发、成员永不到位）。
## 口径注：横向间距 ≥ 半径Y = 同排邻位脱离分离椭圆（干净排面——横向轴经 26° 投影
## 压缩 ~0.44，间距必须大过立绘视觉高度才读得出「排」；旧值 68 投影后仅 ~30px 屏距，
## 前后排糊成一条竖线）；列间距 ≥ 半径Y = 前后排混合偏移也不进椭圆。
## 碰撞体宽 = 83 × BASE_SCALE（24px 换轨后 BASE_SCALE 0.375 → ≈31）。

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
## 横向间距默认值（px，调参表 var_spread_spacing 覆盖）：排面密度主旋钮——
## 同排邻位间距。26° 投影把横向（纵深轴）压缩 ~0.44 倍，立绘视觉高 ~90px：
## 间距须 ≥ 半径Y 脱离分离椭圆且投影后 ~48px 屏距才读得出「排」（旧值 68 投影
## 后 ~30px，前后排糊成竖线——「射手挤一排」观感的几何根因）；运行时真值 =
## BalanceConfig 覆盖值（改默认值必须同步 config/balance/variables.tres）
const SPREAD_SPACING_DEFAULT: float = 110.0
## 列间距默认值（px，调参表 var_row_gap 覆盖）：纵深主旋钮——前列到后列退距。
## SWL 方阵纵深观感 = 紧凑（列距远小于射程）；≥ 半径Y 保前后排不进分离椭圆，
## 同时 ≤ 射程预算的 1/3（战斗锚按「最前列 − 方阵纵深」落位，末列才贴射程线）；
## 同步规则同上
const ROW_GAP_DEFAULT: float = 80.0
## 每列人数基准档（SWL Formation.UNITS_PER_COLUMN 直译；8~12 人小班口径取 4，
## 各班现役列高按班人数 4~6 自适应，见 formation_geometry.squad_units_per_column）
const UNITS_PER_COLUMN: int = 4
## 跟队重下发/落定死区（px）
const FOLLOW_DEADZONE: float = 40.0
## 小队相位计划到位容差默认值（px，config/ai/squad_phase_plan.tres 覆盖）
##（夹在横向间距与 2×横向间距之间：波次完成门槛吸收锚向抖动，见头部不变式）
const ARRIVE_TOLERANCE: float = 150.0


## 不变式自检（间距链改值后必跑；formation_system 启动时调用，违例打 error）：
## 返回违例清单（空 = 通过）。改任何数值前先读本文件头部不变式说明
static func check_invariants(spread_spacing: float, row_gap: float,
		arrive_tolerance: float) -> Array[String]:
	var bad: Array[String] = []
	const COLLIDER_W := 31.0
	if not (COLLIDER_W < SEPARATION_RADIUS_X):
		bad.append("碰撞体宽(%d)必须 < 分离半径X(%d)" % [COLLIDER_W, SEPARATION_RADIUS_X])
	if not (SEPARATION_RADIUS_X < SEPARATION_RADIUS_Y):
		bad.append("分离半径X(%d)必须 < 分离半径Y(%d)" % [SEPARATION_RADIUS_X, SEPARATION_RADIUS_Y])
	if not (SEPARATION_RADIUS_Y <= row_gap):
		bad.append("分离半径Y(%d)必须 ≤ 列间距(%d)——前后排压进椭圆" % [
				SEPARATION_RADIUS_Y, row_gap])
	if not (row_gap <= spread_spacing):
		bad.append("列间距(%d)必须 ≤ 横向间距(%d)——方阵横纵比倒挂" % [
				row_gap, spread_spacing])
	if not (SEPARATION_RADIUS_Y <= spread_spacing):
		bad.append("分离半径Y(%d)必须 ≤ 横向间距(%d)——同排邻位压进椭圆，排面被推散" % [
				SEPARATION_RADIUS_Y, spread_spacing])
	if not (spread_spacing <= arrive_tolerance and arrive_tolerance < spread_spacing * 2.0):
		bad.append("到位容差(%d)必须夹在 [横向间距(%d), 2×横向间距(%d))——波次完成门槛" % [
				arrive_tolerance, spread_spacing, spread_spacing * 2.0])
	if not (FOLLOW_DEADZONE < spread_spacing):
		bad.append("跟队死区(%d)必须 < 横向间距(%d)——站错一格被判落定" % [
				FOLLOW_DEADZONE, spread_spacing])
	return bad
