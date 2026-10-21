extends RefCounted
## 火柴人死亡与受击助手 —— 从 stickman_entity 拆出的战斗结算反馈子域。
##
## 职责：
## - 死亡收口（2026-08-31 审计 P0-1）：一次性权威清理（清速度/奔跑态/动作锁、
##   延迟禁 Collider、通知战斗实例、生成遗物）
## - 尸体物理帧（tick_corpse，宿主 _physics_tick 死亡分支委托）：Collider 禁用
##   计时 + 尸体停留/淡出（SWL fadeOutOver 语义）
## - 死亡遗物生成（翻包式掉落，items 域容器）
## - 受击处理（反编译参考实装 B：SelectHitAnimation 部位×方向×强度直译）+
##   受击硬直/受击音
## - 受击反馈（§7.5 近战打击感）：物理击退冲量 + 受击红闪
##
## 纪律：_knockback_velocity/_hit_stun_timer/_last_hit_ms/_corpse_fade_timer/
## _dead_disable_timer 留宿主（宿主物理帧衰减/回血脱战判定直接消费，tests/dev
## 基准也经 Node.set 直写），本类经 _entity 回引读写；_hurt_tween 为红闪私有随迁。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null
## 受击红闪 Tween（中断旧闪烁）
var _hurt_tween: Tween = null

## 动画名/变体池（死亡与受击变体选择用；显式 preload 防 headless class_name 未注册）
const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT


func _init(entity: Node) -> void:
	_entity = entity


# ─────────────────────────────── 结算常量 ────────────────────────────────
## 击退衰减（px/s²）。与 battle_sim.KNOCKBACK_DECAY 成对（同值纪律：观察场
## sim 链 2026-10 标定 700，实体链随统一；批1 建双链契约测试后退役成对常量）
const KNOCKBACK_DECAY: float = 700.0
## 受击硬直时长（秒）
const HIT_STUN_DURATION: float = 0.2
## 尸体停留时长（s；碰撞禁用后计时，之后淡出）——SWL 尸体 fadeOutOver 前的停留
const CORPSE_LIFETIME: float = 4.0
## 尸体淡出时长（s，透明度线性降到 0 后移除节点）
const CORPSE_FADE: float = 1.2


# ─────────────────────────────── 死亡收口 ────────────────────────────────

## 死亡处理：停止移动、播放死亡动画、禁用受击、通知战斗实例。
## 爆头致死播 Death-Headshot 专属动画（原版 Kill(isHeadShot) 分家语义）。
## 2026-08-31 审计 P0-1 死亡收口：这里是一次性权威清理——
## 清空速度/奔跑态/动作锁（防减速回切覆盖死亡动画）、延迟禁用 Collider
## （尸体不当墙，消灭卡位源头；宿主 _physics_tick 的死亡早退管住其余帧级行为）。
func on_died() -> void:
	_entity.ai_stop()
	_entity.velocity = Vector2.ZERO
	_entity._knockback_velocity = Vector2.ZERO
	_entity._current_speed = 0.0
	_entity._is_running = false
	# sim 侧意图/击退清零（死亡刻起 sim 不再积分本实体，防御残留）
	if _entity._sim != null and _entity._sim_sid >= 0:
		_entity._sim.set_intent(_entity._sim_sid, Vector2.ZERO)
		_entity._sim.add_knockback(_entity._sim_sid, Vector2.ZERO)
	# 建造动作锁会拦截 play("dead")——死亡优先级最高，强制解锁
	_entity._action_locked = false
	# 死亡变体池（SWL 死亡变体随机）：普通死 Death1/2，爆头死 Headshot 系 8 变体
	var health: Node = _entity.health_component
	var dead_anim: String = Anims.pick_dead_anim(
			health != null and health.died_from_headshot)
	_entity._visual.play(dead_anim)
	# 禁用 hitbox 避免继续被攻击
	if _entity.hitbox != null:
		_entity.hitbox.set_deferred("monitorable", false)
	# 死亡动画（0.8s）播完后由 _physics_process 死亡分支禁用 Collider：
	# 尸体不当墙（卡位主因）。计时起点在此置位。
	_entity._dead_disable_timer = 0.9
	# 通知战斗实例（由 BattleInstance 统计伤亡）
	var bi: Node = _entity._battle_instance
	if bi != null and is_instance_valid(bi):
		if bi.has_method("on_unit_died"):
			bi.on_unit_died(_entity)
	# 尸体遗物（翻包式掉落，items 域容器）：玩家接管实体不掉（装备属于玩家
	# 背包）；NPC 按武器/盾生成遗物容器挂 meta("loot")。
	# 滞留/淡出由 _physics_process 死亡分支的物理帧计时**唯一驱动**
	#（A1b：旧 tween 与物理计时双驱动打架——有遗物尸体在 alpha≈0.36 被物理
	# 路径瞬删跳变；时长真相源归一 4/12s + 1.2s 淡出）
	if not _entity.user_controlled:
		generate_loot_container()


## 尸体物理帧（宿主 _physics_tick 死亡分支委托）：清零速度、Collider 禁用计时、
## 尸体停留/淡出。死亡 0.9s 后禁用 Collider——在实体内计时，不用
## SceneTreeTimer lambda（清场 queue_free 后 lambda 捕获失效报错）。
func tick_corpse(delta: float) -> void:
	# 尸体没有物理帧——不跑 AI、不减速回切（正是这套回切把 0.8s 死亡动画在
	# 0.25s 内覆盖成 walk/idle，尸体"站起来"）、不做分离推挤（尸体不当墙、
	# 不滑行）、不受击退。
	_entity.velocity = Vector2.ZERO
	_entity._knockback_velocity = Vector2.ZERO
	if _entity._dead_disable_timer >= 0.0:
		_entity._dead_disable_timer -= delta
		if _entity._dead_disable_timer < 0.0:
			var col := _entity.get_node_or_null("Collider") as CollisionShape2D
			if col != null:
				col.set_deferred("disabled", true)
	# 尸体淡出（SWL fadeOutOver 语义，2026-09-01 观察场反馈：尸体永存
	# 堆满战场）——碰撞禁用后停留 CORPSE_LIFETIME，再 CORPSE_FADE 淡入地里移除；
	# 有遗物的尸体停留 ×3（12s 翻检窗口，与 on_died tween 同拍）；翻空的
	# 尸体快进淡出（遗物被搬走，不再占战场）
	elif not _entity.user_controlled and _entity._corpse_fade_timer < 0.0:
		_entity._corpse_fade_timer = CORPSE_LIFETIME * (3.0 if _entity.has_meta("loot") else 1.0)
	if not _entity.user_controlled and _entity._corpse_fade_timer >= 0.0:
		if _entity._corpse_fade_timer > CORPSE_FADE:
			var loot: ItemContainer = get_loot_container()
			if loot != null and loot.is_empty():
				_entity._corpse_fade_timer = CORPSE_FADE  # 翻空快进淡出
		_entity._corpse_fade_timer -= delta
		if _entity._corpse_fade_timer <= 0.0:
			_entity.queue_free()
		elif _entity._corpse_fade_timer < CORPSE_FADE:
			_entity.modulate.a = clampf(_entity._corpse_fade_timer / CORPSE_FADE, 0.0, 1.0)


## 死亡遗物生成（weapon_type→def 映射 + 盾 + 随机小额消耗品）。
## 返回是否生成了非空容器（决定尸体保留时长）。
func generate_loot_container() -> bool:
	var loot := ItemContainer.new()
	var wm: Node2D = _entity.weapon_mount
	if wm != null and is_instance_valid(wm):
		var wt: int = int(wm.weapon_type)
		var wid: StringName = ItemsAPI.WEAPON_ITEM_BY_TYPE.get(wt, &"")
		if wid != &"":
			loot.add(wid, 1)
		# 盾：显式装备盾或矛士兵种默认盾
		if bool(wm.equipped_shield) \
				or (bool(wm.shield_enabled) and wt == 1):
			loot.add(&"shd_wood_001", 1)
	if randf() < 0.3:
		loot.add(&"con_bandage", 1)
	if loot.is_empty():
		return false
	_entity.set_meta("loot", loot)
	return true


## 遗物容器查询（翻包交互/物理帧翻空检测消费）
func get_loot_container() -> ItemContainer:
	return _entity.get_meta("loot") if _entity.has_meta("loot") else null


# ─────────────────────────────── 受击处理 ────────────────────────────────

## 受击处理（反编译参考实装 B）：按攻击者方位 vs 自身朝向判定正面/背面，
## 触发受击插播。SelectHitAnimation 全量直译：部位(Head/Mid)×方向×强度(Big/Small)。
func on_damaged(amount: float, source: Node) -> void:
	# 死亡保护：died 与 damaged 可能同帧连发（AOE 多段/集火补刀），
	# 尸体不吃受击硬直、不播受击插播（否则覆盖死亡动画 → "尸体站起来"）
	if _entity.is_dead():
		return
	# 最近受击时刻（战斗中脱火恢复判定用：≥3s 未受击才算"脱离火线"）
	_entity._last_hit_ms = Time.get_ticks_msec()
	if source == null or not is_instance_valid(source):
		return
	# 受击硬直：被打瞬间 AI 短暂停滞（行业最佳实践 hit stun）
	_entity._hit_stun_timer = HIT_STUN_DURATION
	# 受击音（痛叫三变体）。世界坐标交给 AudioManager：人群战斗时同帧请求并成
	# 1~2 路声部（而不是叠成音墙，也不是"停旧实例"的机关枪顿挫）；屏外单位自然变轻
	if AudioManager != null:
		AudioManager.play_event("unit_hurt", _entity.global_position)
	# 攻击者在自身朝向侧 = 正面受击（后仰）；否则背面受击（前扑）
	var from_left: bool = source.global_position.x < _entity.global_position.x
	var facing_right: bool = _entity._facing > 0
	var from_front: bool = from_left != facing_right
	# 强度分级（SWL Big/Small 按伤害量级）；部位近似（头部命中概率 30%——
	# 近战挥击/箭雨的头部命中，爆头致死走独立死亡链路不受此影响）
	var big: bool = amount >= Anims.HIT_BIG_DAMAGE_THRESHOLD
	var head: bool = randf() < 0.3
	# 举盾中被击（招架系统配套反馈：Hit-Spearton-Block 池）
	var wm: Node2D = _entity.weapon_mount
	var blocking: bool = wm != null and is_instance_valid(wm) \
			and wm.has_method("is_blocking") and wm.is_blocking()
	var visual: Node = _entity._visual
	if visual != null and visual.has_method("play_hit"):
		visual.play_hit(from_front, big, head, blocking)


## 是否处于受击硬直（>0 表示被打停中；AI 行为据此暂停行动）。
func is_in_hit_stun() -> bool:
	return _entity._hit_stun_timer > 0.0


# ─────────────────────────────── 受击反馈（§7.5 近战打击感）────────────────────────────────

## 受击反馈：物理击退冲量 + 受击红闪。
## 由 WeaponMount.perform_attack 命中时调用（dir 为指向目标的方向）。
## sim 模式冲量写入 sim 击退数组（批循环积分+衰减），不再写本地冲量字段。
func apply_hit_reaction(dir: Vector2, force: float) -> void:
	if dir != Vector2.ZERO:
		if _entity._sim_active():
			_entity._sim.add_knockback(_entity._sim_sid, dir.normalized() * force)
		else:
			_entity._knockback_velocity = dir.normalized() * force
	_flash_hurt()


## 受击红闪：身体短暂变红后恢复（Stickman Burst 受击闪光方案）。
func _flash_hurt() -> void:
	var rig: Node2D = _entity.rig
	if rig == null:
		return
	if _hurt_tween != null and _hurt_tween.is_valid():
		_hurt_tween.kill()
	_hurt_tween = _entity.create_tween()
	_hurt_tween.tween_property(rig, "modulate", Color(1.0, 0.25, 0.25), 0.06)
	_hurt_tween.tween_property(rig, "modulate", Color.WHITE, 0.18)
