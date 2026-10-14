class_name FormationSpacing
extends RefCounted
## 编队阵列与物理分离的**间距单一真相源**（formation 模块内；units/combat 经 api.gd 读取）。
##
## 为什么集中：分离半径曾有三份副本（实体壳 / entity_motion 真身 / battle_sim 批模拟），
## 24px 换轨只改到壳——真身残留旧体型值 54，分离力持续对抗编队槽位，队列被推散抖动
## （"阵型混乱"的直接根因）。此后再不抄副本：数值与不变式只在本文件维护。
##
## 不变式（改任何数值前先读，顺序不可破坏）：
##   碰撞体宽 < 分离半径X < 列间距 ≤ 横向间距，且
##   分离半径X < 分离半径Y ≤ 横向间距（同排邻位贴椭圆边界外——邻位相向漂移
##   的最坏压近由 battle_line 漂移幅值钳 (横向间距−半径Y)/2 保证不出椭圆），
##   跟队死区 < 横向间距（否则站错一格的成员被判已落定、编队失修），
##   横向间距 ≤ 到位容差 < 2×横向间距（波次完成门槛：落点是跃进线锚定的
##   静态槽位（前列贴 base_pos），容差只需吸收锚向抖动——不是随质心每拍
##   重算的动态锚；过大（≥2×间距）会把「离落点一格内」的成员误判已到位，
##   波次号令不发、成员永不到位）。
## 口径注：横向间距 > 半径Y = 出场/行军排面比碰撞平衡距稀疏一档（创始人
##   2026-10-11：纵碰撞=前排间距量级、出场摆稀疏点）；列间距在 x 轴独立出
##   椭圆（Δx ≥ 列间距 > 半径X 时任意纵距判别恒 >1，前后排混合偏移不进椭圆），
##   26° 投影把横向（纵深轴）压缩 ~0.44 倍，间距须大过立绘视觉高度才读得出「排」。
##   碰撞体宽 = 83 × BASE_SCALE（24px 换轨后 BASE_SCALE 0.375 → ≈31）。

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
## 分离半径·纵深轴（px）：= 前排间距量级（创始人 2026-10-11 裁决：把垂直碰撞
## 箱设成前排那么大——接战战团靠碰撞自然展开到排面密度，不需要阵型算法管
## 接战期间距；billboard 竖长卡纵深立面大量重叠的旧观感同源治理）。行军/
## 出生槽距（横向间距）须高于本值留漂移余量，密度观感用槽距调；
## 改本值必须联动出生几何/间距全链（椭圆判别压穿 = 分离力常驻 + 位置伺服
## 极限环，实测 vx 翻转 8.67 次/s 全员蛇形抽动）
const SEPARATION_RADIUS_Y: float = 110.0
## ── 战斗域分离半径（战场单位专用，2026-10-14 创始人裁决三连：
## 「碰撞体积再大一圈，尤其垂直开到超级大」→「横纵都翻一倍」→「碰撞箱加大，
## 也没让你摆放变化」）──
## 城镇维持上方基础值（劳作工位间距 96 < 超级大纵轴，全镇互推乱套）；
## 战斗域（battle_sim / entity_motion 战斗活跃期 / battle_line 漂移钳）取本组。
## X 112 / Y 440 = 碰撞箱口径（近战接敌不受影响：sim 链分离只推同阵营，
## Node 链推力只弯折意图，碰撞体 62 先于推力失速点 42 挡住，攻击射程 100 够得着）。
## **摆放与碰撞解耦**（裁决#40b 澄清）：横向间距/列距等摆放口径**不随椭球联动**
## ——单位站原位，超椭球的接近对由分离力自然推开（10-11「碰撞自然展开战团、
## 阵型算法不管接战期间距」同源）；battle_line 漂移幅值钳对椭球超出的部分取 0。
const SEPARATION_RADIUS_X_BATTLE: float = 112.0
const SEPARATION_RADIUS_Y_BATTLE: float = 440.0
## 兼容别名（= 横向轴）：消费方（entity_motion/battle_sim）未改椭圆判定前
## 自动跟随横向口径（行为 = 圆半径 48）
const SEPARATION_RADIUS: float = SEPARATION_RADIUS_X
## 横向间距默认值（px，调参表 var_spread_spacing 覆盖）：摆放密度主旋钮——
## 同排邻位出生距（紧凑口径，创始人 2026-10-14：摆放不随碰撞椭球联动且
## 230 太稀疏；战斗期同排压近由分离椭球自然展开，槽距不追）。运行时真值 =
## BalanceConfig 覆盖值（改默认值必须同步 config/balance/variables.tres）
const SPREAD_SPACING_DEFAULT: float = 150.0
## 列间距默认值（px，调参表 var_row_gap 覆盖）：纵深主旋钮——前列到后列退距。
## SWL 方阵纵深观感 = 紧凑（列距远小于射程）；> 半径X 使前后排在 x 轴独立
## 出椭圆（任意纵距不触发分离），同时 ≤ 射程预算的 1/3（战斗锚按「最前列 −
## 方阵纵深」落位，末列才贴射程线）；同步规则同上
const ROW_GAP_DEFAULT: float = 80.0
## 每列人数基准档（SWL Formation.UNITS_PER_COLUMN 直译；8~12 人小班口径取 4，
## 各班现役列高按班人数 4~6 自适应，见 formation_geometry.squad_units_per_column）
const UNITS_PER_COLUMN: int = 4
## 跟队重下发/落定死区（px）
const FOLLOW_DEADZONE: float = 40.0
## 小队相位计划到位容差默认值（px，config/ai/squad_phase_plan.tres 覆盖）
##（夹在横向间距与 2×横向间距之间：波次完成门槛吸收锚向抖动，见头部不变式）
const ARRIVE_TOLERANCE: float = 240.0


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
	if not (SEPARATION_RADIUS_X < row_gap):
		bad.append("分离半径X(%d)必须 < 列间距(%d)——前后排压进椭圆（x 轴独立出界的保底）" % [
				SEPARATION_RADIUS_X, row_gap])
	if not (row_gap <= spread_spacing):
		bad.append("列间距(%d)必须 ≤ 横向间距(%d)——方阵横纵比倒挂" % [
				row_gap, spread_spacing])
	if not (SEPARATION_RADIUS_Y <= spread_spacing):
		bad.append("分离半径Y(%d)必须 ≤ 横向间距(%d)——同排邻位压进椭圆，排面被推散（漂移幅值由 battle_line 钳 (间距−半径Y)/2）" % [
				SEPARATION_RADIUS_Y, spread_spacing])
	if not (spread_spacing <= arrive_tolerance and arrive_tolerance < spread_spacing * 2.0):
		bad.append("到位容差(%d)必须夹在 [横向间距(%d), 2×横向间距(%d))——波次完成门槛" % [
				arrive_tolerance, spread_spacing, spread_spacing * 2.0])
	if not (FOLLOW_DEADZONE < spread_spacing):
		bad.append("跟队死区(%d)必须 < 横向间距(%d)——站错一格被判落定" % [
				FOLLOW_DEADZONE, spread_spacing])
	# 战斗域超级大椭球（112/440）与摆放间距**解耦**（2026-10-14 裁决#40b：
	# 「碰撞箱加大，也没让你摆放变化」）——摆放按紧凑口径，椭球超出间距的
	# 部分由分离力自然展开（10-11「碰撞自然展开战团」同源），不作不变式约束。
	return bad
