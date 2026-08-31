extends Node
## 批量模式完成信号（TestRunner.finish_process 发射，batch_runner 消费）
signal test_done(code: int)
## 单元测试：武器/战斗翻译保真度（审计 docs/项目/归档/翻译保真度-武器战斗.md 补译项）。
##
## 覆盖"译走样/漏译"的补译结果，防止回退：
##   #1 命中帧读动画内嵌 Hit 事件真值（不再写死 0.45）
##   #2 爆头 = headShotBonusDamage **加值**（不是 ×1.5 倍率）
##   #3 暴击有自伤代价 critBonusDamageInflictedToSelf
##   #4 格挡需"举盾姿态 + 正面来袭"，并受 blockResetInterval 节流
##   #5 AOE 挥击：NumberOfUnitsThatCanHit 是一次挥击打中几人（扇形），不是围攻上限
##   #6 命中后动画可打断：AnimationCancelFractionOfAnimationAfterAttackHit 提前放行
##   漏3 反伤链：ApplyDamageReflect + CanReceiveReflectDamage
##   漏4 爆头死亡动画分家：Death-Headshot + died_from_headshot 标记

@warning_ignore("shadowed_global_identifier")
const TestRunner := preload("res://tests/core/test_runner.gd")
const Anims := preload("res://modules/units/scripts/rig/stickman_anims.gd")
const TargetFinder := preload("res://modules/combat/scripts/target_finder.gd")
const DamagePipeline := preload("res://modules/combat/scripts/battle/damage_pipeline.gd")
const WeaponMountScript := preload("res://modules/units/scripts/entity/weapon_mount.gd")
const HealthComponentScript := preload("res://modules/units/scripts/entity/health_component.gd")

const ANIM_DIR := "res://modules/units/animations/"

## 解包 Spine 数据里各攻击动画的 Hit 事件真值（秒），用于断言"读的是真值"
const EXPECTED_HIT_TIME: Dictionary = {
	"attack": 1.0,           # Swordwrath-Attack1（全长 1.3333s = 75%）
	"attack_spear": 0.8667,  # Spearton-Attack1（全长 1.6667s = 52%）
	"attack_bow": 0.5333,    # Archidon-Draw（全长 2.0s = 27%）
	"attack_pickaxe": 0.6667,# Miner-Attack1（全长 1.0s = 67%）
	"attack_staff": 1.0,     # Magikill-Spell1（全长 1.6667s = 60%）
}

var _runner: TestRunner


func _ready() -> void:
	_runner = TestRunner.new()
	_runner.add_test("命中帧: 攻击动画带 Hit 事件元数据（真值非拍脑袋比例）", _test_hit_event_meta)
	_runner.add_test("命中帧: 各武器命中点互不相同（写死比例必然全等）", _test_hit_points_differ)
	_runner.add_test("武器↔动画映射: 5 种武器各有专属攻击动画", _test_weapon_anim_map)
	_runner.add_test("爆头: 按加值结算（headShotBonusDamage 不是倍率）", _test_headshot_is_additive)
	_runner.add_test("暴击: 附带自伤代价 critBonusDamageInflictedToSelf", _test_crit_self_damage)
	_runner.add_test("格挡: 需要举盾姿态 + 正面来袭", _test_block_requires_stance)
	_runner.add_test("格挡: 成功后进入 blockResetInterval 冷却", _test_block_reset_interval)
	_runner.add_test("AOE 挥击: 身前扇形按人数上限取多个目标", _test_arc_targets)
	_runner.add_test("动画打断: 命中后尾段可打断提前出手（走样 #6）", _test_anim_cancel_fraction)
	_runner.add_test("反伤链: reflect_damage 反弹给攻击者（漏译 #3）", _test_reflect_chain)
	_runner.add_test("爆头死亡: died_from_headshot 标记 + Death-Headshot 动画（漏译 #4）", _test_headshot_death)
	_runner.add_test("武器持握: tscn 数值与解包附件数据一致（2026-08-30 审计）", _test_weapon_grip_data)
	_runner.run()
	print(_runner.summary())
	TestRunner.finish_process(self, 0 if _runner.all_passed() else 1)


# ─────────────────────────────── 命中帧（走样 #1）───────────────────────────────

func _test_hit_event_meta() -> void:
	for anim_name in EXPECTED_HIT_TIME.keys():
		var anim: Animation = load(ANIM_DIR + anim_name + ".tres")
		_runner.assert_not_null(anim, "动画资源应存在: %s" % anim_name)
		if anim == null:
			continue
		_runner.assert_true(anim.has_meta("hit_time"), "%s 应带 hit_time 元数据" % anim_name)
		var t: float = float(anim.get_meta("hit_time"))
		_runner.assert_approx(t, EXPECTED_HIT_TIME[anim_name], 0.001,
			"%s 的 Hit 事件时间应为解包真值 %.4f，实际 %.4f" % [anim_name, EXPECTED_HIT_TIME[anim_name], t])
		# 命中帧必须落在动画时长内，否则永远等不到结算
		_runner.assert_true(t >= 0.0 and t <= anim.length,
			"%s 的 Hit 时间应落在 [0, %.4f] 内" % [anim_name, anim.length])


func _test_hit_points_differ() -> void:
	var ratios: Array = []
	for anim_name in EXPECTED_HIT_TIME.keys():
		var anim: Animation = load(ANIM_DIR + anim_name + ".tres")
		if anim == null or anim.length <= 0.0:
			continue
		ratios.append(float(anim.get_meta("hit_time")) / anim.length)
	_runner.assert_true(ratios.size() >= 4, "应收集到至少 4 个武器的命中帧比例")
	# 写死 STRIKE_FRAME_RATIO 时所有比例相同；真值各不相同（0.27~0.75）
	var min_r: float = ratios[0]
	var max_r: float = ratios[0]
	for r in ratios:
		min_r = minf(min_r, r)
		max_r = maxf(max_r, r)
	_runner.assert_gt(max_r - min_r, 0.15, "各武器命中帧比例应有明显差异（实际 %.3f~%.3f）" % [min_r, max_r])


func _test_weapon_anim_map() -> void:
	for w in range(5):
		var name: String = Anims.anim_for_weapon(w)
		_runner.assert_true(name.begins_with("attack"), "武器 %d 应有攻击动画，实际 %s" % [w, name])
		_runner.assert_true(name in Anims.ATTACK_ANIMS, "%s 应在攻击动画清单内" % name)
	# 5 种武器的动画名互不重复（否则"播矛刺、按剑的命中帧结算"）
	var seen: Dictionary = {}
	for w in range(5):
		seen[Anims.anim_for_weapon(w)] = true
	_runner.assert_equal(seen.size(), 5, "5 种武器应映射到 5 个不同攻击动画")


# ─────────────────────────────── 爆头 / 暴击（走样 #2 #3）───────────────────────────────

## 造一个只有 HealthComponent 的靶子
func _make_dummy(hp: float = 1000.0) -> Node2D:
	var d := Node2D.new()
	var h := HealthComponent.new()
	h.name = "HealthComponent"
	h.max_hp = hp
	d.add_child(h)
	add_child(d)
	h.hp = hp
	return d


func _test_headshot_is_additive() -> void:
	var target := _make_dummy()
	var p := DamagePipeline.Params.new(20.0, null)
	p.is_head_shot = true
	p.head_shot_bonus_damage = 7.0
	var dealt: float = DamagePipeline.apply(target, p)
	# 加值语义：20 + 7 = 27（若仍按 ×1.5 倍率则是 30）
	_runner.assert_approx(dealt, 27.0, 0.001, "爆头应为加值 20+7=27，实际 %.3f" % dealt)
	target.queue_free()


func _test_crit_self_damage() -> void:
	var target := _make_dummy()
	var attacker := _make_dummy()
	var p := DamagePipeline.Params.new(10.0, attacker)
	p.is_crit = true
	p.crit_damage_multiplier = 2.0
	p.crit_self_damage = 5.0
	var dealt: float = DamagePipeline.apply(target, p)
	_runner.assert_approx(dealt, 20.0, 0.001, "暴击应对目标造成 10×2=20，实际 %.3f" % dealt)
	var attacker_hp: Node = attacker.get_node("HealthComponent")
	_runner.assert_approx(attacker_hp.hp, attacker_hp.max_hp - 5.0, 0.001,
		"暴击者应自伤 5（critBonusDamageInflictedToSelf），剩余 %.1f" % attacker_hp.hp)
	target.queue_free()
	attacker.queue_free()


# ─────────────────────────────── 姿态格挡（走样 #4）───────────────────────────────

## 格挡桩：模拟 WeaponMount 的姿态格挡接口（持盾 + 举盾 + 正面 + 概率 + 重置冷却）
class BlockStub:
	extends Node

	var blocking: bool = false
	var block_succeeded_notified: bool = false
	var always_block: bool = true

	func is_shield_blocking(_incoming_dir: Vector2 = Vector2.ZERO) -> bool:
		return blocking and always_block

	func notify_block_succeeded() -> void:
		block_succeeded_notified = true


func _test_block_requires_stance() -> void:
	var target := _make_dummy()
	var stub := BlockStub.new()
	stub.name = "WeaponMount"
	target.add_child(stub)
	# 未举盾：不应格挡（原版 IsBlocking() 姿态条件）
	stub.blocking = false
	var p := DamagePipeline.Params.new(100.0, null)
	DamagePipeline.apply(target, p)
	_runner.assert_false(stub.block_succeeded_notified, "未举盾时不应触发格挡")
	_runner.assert_approx(target.get_node("HealthComponent").hp, 900.0, 0.001,
		"未格挡应吃满 100 伤害")
	# 举盾：应格挡（减伤 85%）
	stub.blocking = true
	DamagePipeline.apply(target, p)
	_runner.assert_true(stub.block_succeeded_notified, "举盾时应触发格挡")
	target.queue_free()


func _test_block_reset_interval() -> void:
	var target := _make_dummy()
	var stub := BlockStub.new()
	stub.name = "WeaponMount"
	target.add_child(stub)
	stub.blocking = true
	var p := DamagePipeline.Params.new(100.0, null)
	DamagePipeline.apply(target, p)
	_runner.assert_true(stub.block_succeeded_notified,
		"成功格挡后应通知 WeaponMount 启动 blockResetInterval（否则盾牌可无限吃伤害）")
	target.queue_free()


# ─────────────────────────────── AOE 挥击（走样 #5）───────────────────────────────

func _test_arc_targets() -> void:
	var self_node := Node2D.new()
	add_child(self_node)
	self_node.position = Vector2.ZERO
	# 身前 3 个（右），身后 1 个（左），远处 1 个
	var front_far := Node2D.new()
	var front_near := Node2D.new()
	var front_off := Node2D.new()
	var behind := Node2D.new()
	var too_far := Node2D.new()
	front_near.position = Vector2(50, 0)
	front_far.position = Vector2(90, 0)
	front_off.position = Vector2(70, -20)
	behind.position = Vector2(-60, 0)
	too_far.position = Vector2(400, 0)
	for n in [front_near, front_far, front_off, behind, too_far]:
		add_child(n)
	var enemies: Array = [front_far, front_near, front_off, behind, too_far]

	var found: Array = TargetFinder.find_targets_in_arc(self_node, {
		"enemies": enemies,
		"range": 120.0,
		"half_angle": 55.0,
		"max_count": 2,
		"facing": Vector2.RIGHT,
	})
	_runner.assert_equal(found.size(), 2, "扇形内应取到 2 个目标，实际 %d" % found.size())
	_runner.assert_true(front_near in found, "最近的身前目标应在名单内")
	_runner.assert_false(behind in found, "身后目标不应被扇形选中")
	_runner.assert_false(too_far in found, "超出射程的目标不应被选中")
	# max_count 不限制时应取到全部 3 个身前目标（含斜前方）
	var all_front: Array = TargetFinder.find_targets_in_arc(self_node, {
		"enemies": enemies, "range": 120.0, "half_angle": 55.0,
		"max_count": 0, "facing": Vector2.RIGHT,
	})
	_runner.assert_equal(all_front.size(), 3, "不限人数时应取到 3 个身前目标，实际 %d" % all_front.size())
	self_node.queue_free()
	for n in [front_near, front_far, front_off, behind, too_far]:
		n.queue_free()


# ──────────────────────── 命中后动画打断（走样 #6）────────────────────────

## 桩 rig：只暴露 WeaponMount 查询动画进度用的接口，时间由测试完全控制
class CancelStubRig:
	extends Node

	var hit_time: float = 1.0
	var anim_len: float = 1.3333
	var anim_time: float = -1.0

	func get_anim_event_time(_anim_name: String, event_name: String) -> float:
		return hit_time if event_name == "Hit" else -1.0

	func get_anim_time(_anim_name: String) -> float:
		return anim_time

	func get_anim_length(_anim_name: String) -> float:
		return anim_len


## 桩宿主：CharacterBody2D 外壳 + rig 属性 + play_attack 钩子
class CancelStubOwner:
	extends CharacterBody2D

	var rig: Node = null

	func play_attack() -> void:
		pass


## 组装"宿主 + 桩 rig + WeaponMount + 射程内靶子"
func _make_cancel_pair() -> Dictionary:
	var owner_node := CancelStubOwner.new()
	add_child(owner_node)
	var rig := CancelStubRig.new()
	rig.name = "Rig"
	owner_node.add_child(rig)
	owner_node.rig = rig
	var wm: Node = WeaponMountScript.new()
	wm.name = "WeaponMount"
	owner_node.add_child(wm)
	wm.set_physics_process(false)
	wm.damage = 20.0
	wm.base_hit_chance = 1.0
	var target := Node2D.new()
	add_child(target)
	target.position = Vector2(50, 0)
	var hc := HealthComponentScript.new()
	hc.name = "HealthComponent"
	hc.max_hp = 1000.0
	target.add_child(hc)
	hc.hp = 1000.0
	return {"owner": owner_node, "rig": rig, "wm": wm, "target": target, "health": hc}


func _test_anim_cancel_fraction() -> void:
	# attack 动画 1.3333s，Hit@1.0s，cancel=0.5 → 可打断点 = 1.0 + 0.5×0.3333 ≈ 1.1667s
	var kit: Dictionary = _make_cancel_pair()
	var wm: Node = kit["wm"]
	var rig: CancelStubRig = kit["rig"]
	rig.anim_time = 0.0
	wm.perform_attack(kit["target"])
	_runner.assert_false(wm.can_attack(), "刚出手应在冷却中")
	# 挥过命中帧（1.1s > 1.0s）结算伤害，但还没到可打断点（1.1667s）
	rig.anim_time = 1.1
	wm._physics_process(0.05)
	_runner.assert_approx(kit["health"].hp, 980.0, 0.001, "越过 Hit 事件应结算伤害")
	_runner.assert_false(wm.can_attack(), "未到可打断点（1.1s < 1.167s）不应提前出手")
	rig.anim_time = 1.2
	_runner.assert_true(wm.can_attack(), "进入可打断尾段（1.2s ≥ 1.167s）应提前放行")
	# 提前放行后真的能再次出手：命中帧重新武装，新挥砍不立即结算
	kit["health"].hp = 1000.0
	rig.anim_time = 0.0
	var result: Dictionary = wm.perform_attack(kit["target"])
	_runner.assert_equal(result.get("reason", ""), "striking", "可打断尾段应允许再次出手")
	_runner.assert_approx(kit["health"].hp, 1000.0, 0.001, "新挥砍不应立即结算（命中帧从头计）")
	# cancel=0：关闭打断——命中后也不放行，等完整冷却
	wm.animation_cancel_fraction = 0.0
	rig.anim_time = 1.1
	wm._physics_process(0.05)
	_runner.assert_false(wm.can_attack(), "cancel=0 时命中后也不应打断")
	kit["owner"].free()
	kit["target"].free()


# ──────────────────────── 反伤链（漏译 #3）────────────────────────

## 反伤桩：模拟 WeaponMount 的 reflect_damage 配置与免疫虚方法
class ReflectStub:
	extends Node

	var reflect_damage: float = 0.0
	var immune: bool = false

	func can_receive_reflect_damage() -> bool:
		return not immune


func _test_reflect_chain() -> void:
	# 受击方带 reflect_damage=6 的桩，攻击者也带 reflect_damage=5（测递归防护）
	var target := _make_dummy()
	var t_stub := ReflectStub.new()
	t_stub.name = "WeaponMount"
	t_stub.reflect_damage = 6.0
	target.add_child(t_stub)
	var attacker := _make_dummy()
	var a_stub := ReflectStub.new()
	a_stub.name = "WeaponMount"
	a_stub.reflect_damage = 5.0
	attacker.add_child(a_stub)
	var t_hp: Node = target.get_node("HealthComponent")
	var a_hp: Node = attacker.get_node("HealthComponent")
	var dealt: float = DamagePipeline.apply(target, DamagePipeline.Params.new(20.0, attacker))
	_runner.assert_approx(dealt, 20.0, 0.001, "受击方应吃满 20 伤害")
	_runner.assert_approx(a_hp.hp, a_hp.max_hp - 6.0, 0.001,
		"攻击者应被反伤 6（ApplyDamageReflect），实际 %.1f" % (a_hp.max_hp - a_hp.hp))
	_runner.assert_approx(t_hp.hp, t_hp.max_hp - 20.0, 0.001,
		"反伤不得递归（攻击者的 reflect_damage 不反弹回受击方）")
	# 攻击者免疫反伤（CanReceiveReflectDamage=false）→ 不掉血
	var attacker2 := _make_dummy()
	var a2_stub := ReflectStub.new()
	a2_stub.name = "WeaponMount"
	a2_stub.immune = true
	attacker2.add_child(a2_stub)
	DamagePipeline.apply(target, DamagePipeline.Params.new(20.0, attacker2))
	var a2_hp: Node = attacker2.get_node("HealthComponent")
	_runner.assert_approx(a2_hp.hp, a2_hp.max_hp, 0.001, "免疫反伤的攻击者不应掉血")
	target.queue_free()
	attacker.queue_free()
	attacker2.queue_free()


# ──────────────────────── 爆头死亡动画分家（漏译 #4）────────────────────────

func _test_headshot_death() -> void:
	# 资源：dead_headshot.tres 存在、一次性、与普通 dead 是两条动画
	var anim: Animation = load(ANIM_DIR + "dead_headshot.tres")
	_runner.assert_not_null(anim, "dead_headshot.tres 应存在（tools/baking 产线生成）")
	if anim != null:
		_runner.assert_true(anim.loop_mode == Animation.LOOP_NONE, "死亡动画应为一次性")
		var dead: Animation = load(ANIM_DIR + "dead.tres")
		_runner.assert_true(anim != dead and not is_equal_approx(anim.length, dead.length),
			"爆头死亡与普通死亡应是不同动画（%.3f vs %.3f）" % [anim.length, dead.length])
	# 标记：爆头致死 → died_from_headshot=true；普通致死 → false
	var target := _make_dummy(25.0)
	var p := DamagePipeline.Params.new(20.0, null)
	p.is_head_shot = true
	p.head_shot_bonus_damage = 10.0
	DamagePipeline.apply(target, p)
	var hc: Node = target.get_node("HealthComponent")
	_runner.assert_true(hc.is_dead(), "爆头 30 伤应击杀 25 血目标")
	_runner.assert_true(hc.died_from_headshot, "爆头致死应打 died_from_headshot 标记")
	var target2 := _make_dummy(25.0)
	DamagePipeline.apply(target2, DamagePipeline.Params.new(30.0, null))
	var hc2: Node = target2.get_node("HealthComponent")
	_runner.assert_true(hc2.is_dead(), "普通 30 伤应击杀 25 血目标")
	_runner.assert_false(hc2.died_from_headshot, "非爆头致死不应打标记")
	target.queue_free()
	target2.queue_free()


# ──────────────────── 武器持握数据（2026-08-30 挂载骨重直译，防回退）────────────────────

## 期望值直译自各兵种皮肤 weapon/Arrow1 附件数据（推导链见各 weapon_*.tscn 头注释）：
## rot = C − (挂载骨Spine世界角@该兵种Stand动画 + 附件rot) − 挂载骨Godot世界角(idle=0)，
##       C=0（剑四候选 {0,±90,180} 截图对照忠实参考帧标定，C=0 与原版同向）；
##       boneSpine 取各武器兵种自己的 Stand 动画（Swordwrath-Stand1=42.68 /
##       Spearton-Stand1: pickaxe1=90.92、Arrow1=388.41 / Miner-Stand1=123.96 /
##       Magikill-Stand=92.95 / Archidon-Stand1=38.01，数据源 _faithful/spine_pose.json 口径）
## scale = K(0.475)×附件 s×(附件逻辑 wh/region 像素)；bow 为 mesh 仿射拟合值
## grip = 手（挂载骨原点）握在纹理哪个点（px、中心原点 y-down）：
##        q=R(−附件rot)·(−xy)（Spine y-up），grip=(q.x/(whW·s)·regW, −q.y/(whH·s)·regH)；
##        bow 为 mesh 精确仿射逆映射。旧链的 grip y 符号反（剑握到刃尖/杖握到尾端），
##        旧链 rot 用局部角 84.97 当世界角（剑竖直的假象），2026-08-30 修正钉死。
const EXPECTED_GRIP: Dictionary = {
	"res://modules/units/scenes/components/weapon_sword.tscn":
		{"rot": 46.85, "scale": Vector2(0.483, 0.483), "grip": Vector2(4.4, 64.6)},
	"res://modules/units/scenes/components/weapon_spear.tscn":
		{"rot": 0.71, "scale": Vector2(0.616, 0.631), "grip": Vector2(0.8, 5.5)},
	"res://modules/units/scenes/components/weapon_pickaxe.tscn":
		{"rot": -33.47, "scale": Vector2(0.511, 0.512), "grip": Vector2(0.3, 63.3)},
	"res://modules/units/scenes/components/weapon_magicstaff.tscn":
		{"rot": -1.49, "scale": Vector2(0.480, 0.482), "grip": Vector2(1.9, -26.9)},
	"res://modules/units/scenes/components/weapon_bow.tscn":
		{"rot": 55.61, "scale": Vector2(0.955, 0.965), "grip": Vector2(13.0, -0.8)},
	"res://modules/units/scenes/components/weapon_shield.tscn":
		{"rot": 3.91, "scale": Vector2(0.631, 0.632), "grip": Vector2(-3.5, 24.2)},
}


func _test_weapon_grip_data() -> void:
	for path in EXPECTED_GRIP.keys():
		var scene: PackedScene = load(path)
		_runner.assert_not_null(scene, "武器场景应存在: %s" % path)
		if scene == null:
			continue
		var inst: Node2D = scene.instantiate()
		var spr := inst.get_node_or_null("Sprite") as Sprite2D
		var grip := inst.get_node_or_null("GripPoint") as Marker2D
		_runner.assert_not_null(spr, "%s 应有 Sprite" % path)
		_runner.assert_not_null(grip, "%s 应有 GripPoint" % path)
		if spr == null or grip == null:
			inst.free()
			continue
		var exp: Dictionary = EXPECTED_GRIP[path]
		var rot_deg: float = rad_to_deg(spr.rotation)
		_runner.assert_approx(rot_deg, exp["rot"], 0.15,
			"%s Sprite.rotation 应为 %.2f°（附件世界角），实际 %.2f°" % [path, exp["rot"], rot_deg])
		var want_sc: Vector2 = exp["scale"]
		_runner.assert_approx(spr.scale.x, want_sc.x, 0.005, "%s scale.x 应 %.3f" % [path, want_sc.x])
		_runner.assert_approx(spr.scale.y, want_sc.y, 0.005, "%s scale.y 应 %.3f" % [path, want_sc.y])
		var want_g: Vector2 = exp["grip"]
		_runner.assert_approx(grip.position.x, want_g.x, 0.5, "%s GripPoint.x 应 %.1f" % [path, want_g.x])
		_runner.assert_approx(grip.position.y, want_g.y, 0.5, "%s GripPoint.y 应 %.1f" % [path, want_g.y])
		# 握点须落在贴图范围内（region 裁错时会越界/语义反转）
		var tex: Texture2D = spr.texture
		if tex != null:
			var half := Vector2(tex.get_width(), tex.get_height()) / 2.0
			_runner.assert_true(absf(grip.position.x) <= half.x + 0.5 and absf(grip.position.y) <= half.y + 0.5,
				"%s GripPoint %s 应落在贴图 %dx%d 内" % [path, grip.position, tex.get_width(), tex.get_height()])
		inst.free()
	# 镐贴图 region 防回退：应为 "pickaxe1 (2)"（113x190），不是 "pickaxe"（55x198 狼牙棒）
	var pick: Texture2D = load("res://modules/units/assets/textures/weapons/pickaxe.png")
	_runner.assert_not_null(pick, "pickaxe.png 应存在")
	if pick != null:
		_runner.assert_true(pick.get_width() == 113 and pick.get_height() == 190,
			"pickaxe.png 应为 region pickaxe1 (2) 的 113x190，实际 %dx%d" % [pick.get_width(), pick.get_height()])
