class_name IncomingThreatLedger
extends RefCounted
## 在飞箭矢账本 —— 从 stickman_entity 拆出的箭矢威胁状态（11d MissingArrowsTolerance
## + SpeartonAi.IsAnyArrowThreat 消费口径）。
##
## stickman_entity 经 property 委托（incoming_arrow_damage / arrow_threat_time）保持
## 既有 duck-typing 协议（WeaponMount 出弓登记、arrow_projectile 终态结算、
## behavior_attack/team_ai 感知读取均零改动）；新代码建议直接用本类语义方法。

## 在飞箭矢的满伤害估计总额（箭矢终态结算时扣减；估计口径允许偏差）
var incoming_arrow_damage: float = 0.0

## 最后一次被敌方箭矢瞄准的时刻（s，Time.get_ticks_msec 换算；-999=无威胁）
var arrow_threat_time: float = -999.0


## 出弓登记：按满伤害累加（WeaponMount._fire_arrow 消费口径）
func register_incoming(damage: float) -> void:
	incoming_arrow_damage += damage


## 箭矢终态结算：命中（伤害已真实入账）或插地（估计落空），从估计总额扣减
func settle_incoming(damage: float) -> void:
	incoming_arrow_damage = maxf(0.0, incoming_arrow_damage - damage)


## 标记箭矢威胁时刻（出弓瞬间写入目标）
func mark_threat(now_s: float) -> void:
	arrow_threat_time = now_s


## 威胁窗口查询：now_s - mark 时刻是否落在 window 内
func is_threatened(now_s: float, window: float) -> bool:
	return now_s - arrow_threat_time < window
