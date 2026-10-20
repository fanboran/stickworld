extends SceneTree
## 烘焙 walk_bow_hold.tres：拉弓保持姿态下行走（弓手持瞄窗内移动不丢拉满姿态）。
##
## 合并规则（诊断报告《症状三》确认的可行路径）：
##   - walk_bow 腿轨 + attack_bow_hold 上身轨轨道并集；
##   - head 冲突归 hold（真骨架 Archidon-Walk 带 head 通道=走步点头，持瞄窗内
##     头部应保持拉满瞄准姿态，走步点头让位）——head 之外的轨道重叠仍拒绝合并；
##   - 时长对齐取 walk 循环时长；hold 为定格姿态：按资产自带 "Drawn" 事件帧
##     （Archidon-Draw@0.5 拉满帧）采样上身各轨，定格值铺满整个 walk 时长
##     （不是时间轴重缩放——重缩放会让每个步态循环重演一次"拉弓过程"，
##     违背"上身姿态不变"的验收口径）；
##   - loop 标记按 walk_bow（LOOP_LINEAR）；轨的插值模式/过渡斜率/update 模式
##     保留各自源轨设置。
##
## 幂等：重复执行覆盖输出（同名文件重写，无累积副作用）。
##
## 运行：godot --headless --path <工程> --script res://tools/baking/bake_walk_bow_hold.gd

const SRC_WALK := "res://modules/stick_rig/animations/walk_bow.tres"
const SRC_HOLD := "res://modules/stick_rig/animations/attack_bow_hold.tres"
const OUT_PATH := "res://modules/stick_rig/animations/walk_bow_hold.tres"


func _initialize() -> void:
	var walk := load(SRC_WALK) as Animation
	var hold := load(SRC_HOLD) as Animation
	if walk == null or hold == null:
		push_error("[bake_walk_bow_hold] 源动画加载失败：%s / %s" % [SRC_WALK, SRC_HOLD])
		quit(1)
		return

	# ── 轨道冲突裁决（spine_import 全骨补垫后的定向规则）──
	#   腿轨归 walk（走步态；hold 的 Draw 开立步垫/真轨都让位——资产语义就是
	#   "腿走弓步态 + 上身拉满"）；非腿轨归 hold（持瞄上身姿态；hold 侧垫轨
	#   遇 walk 真轨则 walk 胜，如无此情形不触发）。
	var walk_paths := _track_paths(walk)
	var hold_paths := _track_paths(hold)
	var walk_cede := {}  # path -> true：walk 侧让位（hold 接管）
	var hold_cede := {}  # path -> true：hold 侧让位（walk 接管）
	for i in walk.get_track_count():
		var p := String(walk.track_get_path(i))
		if not hold_paths.has(p):
			continue
		var j := hold_paths.find(p)
		var leg_track := p.contains("thigh") or p.contains("shin") or p.contains("foot") or p.contains("toe")
		if leg_track:
			hold_cede[p] = true
		elif _is_padded(hold, j) and not _is_padded(walk, i):
			hold_cede[p] = true
		else:
			walk_cede[p] = true
	var ceded: int = walk_cede.size() + hold_cede.size()

	# ── 上身定格采样点：资产自带 "Drawn" 事件帧，缺失则回退各轨最后关键帧的最大时刻 ──
	var t_drawn := _drawn_time(hold)

	# ── 合并：让位轨跳过，walk 轨原样拷贝 + hold 轨定格值铺满 walk 时长 ──
	var merged := Animation.new()
	merged.length = walk.length
	merged.loop_mode = walk.loop_mode
	for i in walk.get_track_count():
		if walk_cede.has(String(walk.track_get_path(i))):
			continue
		walk.copy_track(i, merged)  # 引擎原样整轨拷贝（路径/插值/update/关键帧全保留）
	for i in hold.get_track_count():
		if hold_cede.has(String(hold.track_get_path(i))):
			continue
		_freeze_track(hold, i, merged, t_drawn, walk.length)
	for meta in walk.get_meta_list():
		merged.set_meta(meta, walk.get_meta(meta))

	# ── 保存前自查（代码先行，不靠渲染发现错误）──
	var errors := _self_check(merged, walk, hold_paths, ceded, hold_cede)
	if not errors.is_empty():
		for e in errors:
			push_error("[bake_walk_bow_hold] 自查失败：%s" % e)
		quit(1)
		return

	var err := ResourceSaver.save(merged, OUT_PATH)
	if err != OK:
		push_error("[bake_walk_bow_hold] 保存失败 %s (err=%d)" % [OUT_PATH, err])
		quit(1)
		return

	# ── 落盘回读复核：能作为 Animation 加载且结构一致 ──
	var reloaded := load(OUT_PATH) as Animation
	if reloaded == null or reloaded.get_track_count() != merged.get_track_count() \
			or not is_equal_approx(reloaded.length, merged.length) \
			or reloaded.loop_mode != merged.loop_mode:
		push_error("[bake_walk_bow_hold] 回读复核失败：%s" % OUT_PATH)
		quit(1)
		return

	print("[bake_walk_bow_hold] OK %s：%d 条轨（walk %d + hold %d），时长 %.4fs，loop_mode=%d，上身定格采样 t=%.3fs"
			% [OUT_PATH, merged.get_track_count(), walk.get_track_count(), hold.get_track_count(), merged.length, merged.loop_mode, t_drawn])
	quit(0)


## 收集动画全部轨道的 NodePath 字符串
static func _track_paths(anim: Animation) -> Array[String]:
	var paths: Array[String] = []
	for i in anim.get_track_count():
		paths.append(String(anim.track_get_path(i)))
	return paths


## 是否 spine_import 的全骨补垫轨：t=0 单键且值为 0（rotation 0.0 / position (0,0)）
## ——静止断言，无动作信息，冲突时让位无损失。
static func _is_padded(anim: Animation, track_idx: int) -> bool:
	if anim.track_get_key_count(track_idx) != 1:
		return false
	if not is_zero_approx(anim.track_get_key_time(track_idx, 0)):
		return false
	var v: Variant = anim.track_get_key_value(track_idx, 0)
	if v is float or v is int:
		return is_zero_approx(float(v))
	if v is Vector2:
		return v.is_zero_approx()
	return false


## 取 "Drawn" 事件帧时刻（attack_bow_hold 的 metadata/anim_events）；
## 找不到时回退各轨最后关键帧的最大时刻。
static func _drawn_time(hold: Animation) -> float:
	var fallback := 0.0
	for i in hold.get_track_count():
		var last := hold.track_get_key_time(i, hold.track_get_key_count(i) - 1)
		fallback = maxf(fallback, last)
	if hold.has_meta("anim_events"):
		for ev: Dictionary in hold.get_meta("anim_events"):
			if ev.get("name", "") == "Drawn":
				var t := float(ev.get("time", -1.0))
				if t >= 0.0 and t < hold.length:
					return t
	return fallback


## 拷贝一条源轨并定格：在 t_sample 采样值，铺满 [0, dst_length]（首尾同值双关键帧，
## 线性循环无缝）。采样/写键按轨道类型分发——S1 直译管线起旋转轨是 BEZIER
##（Spine 段曲线），hip 位移等仍是 VALUE。
static func _freeze_track(src: Animation, src_idx: int, dst: Animation, t_sample: float, dst_length: float) -> void:
	var t := _add_track_with_settings(src, src_idx, dst)
	var frozen: Variant = _sample_track(src, src_idx, t_sample)
	if src.track_get_type(src_idx) == Animation.TYPE_BEZIER:
		# 同值双键 + 零值柄 = 常量轨（柄不影响同值段）
		dst.bezier_track_insert_key(t, 0.0, frozen, Vector2(-1.0, 0.0), Vector2(1.0, 0.0))
		dst.bezier_track_insert_key(t, dst_length, frozen, Vector2(-1.0, 0.0), Vector2(1.0, 0.0))
	else:
		dst.track_insert_key(t, 0.0, frozen, 1.0)
		dst.track_insert_key(t, dst_length, frozen, 1.0)
		dst.value_track_set_update_mode(t, src.value_track_get_update_mode(src_idx))


## 轨道类型感知采样：BEZIER 走 bezier_track_interpolate，其余 VALUE 老路径
static func _sample_track(src: Animation, src_idx: int, t: float) -> Variant:
	if src.track_get_type(src_idx) == Animation.TYPE_BEZIER:
		return src.bezier_track_interpolate(src_idx, t)
	return src.value_track_interpolate(src_idx, t)


## 按源轨设置（类型/路径/插值/循环包裹/导入标记/启用）向 dst 加轨，返回新轨号
static func _add_track_with_settings(src: Animation, src_idx: int, dst: Animation) -> int:
	var t := dst.add_track(src.track_get_type(src_idx))
	dst.track_set_path(t, src.track_get_path(src_idx))
	dst.track_set_interpolation_type(t, src.track_get_interpolation_type(src_idx))
	dst.track_set_interpolation_loop_wrap(t, src.track_get_interpolation_loop_wrap(src_idx))
	dst.track_set_imported(t, src.track_is_imported(src_idx))
	dst.track_set_enabled(t, src.track_is_enabled(src_idx))
	return t


## 结构自查：轨道数=两源之和、无同名轨、时长/循环正确、腿轨未被动过
static func _self_check(merged: Animation, walk: Animation, hold_paths: Array[String], ceded: int = 0, hold_ceded: Dictionary = {}) -> Array[String]:
	var errors: Array[String] = []
	var expect := walk.get_track_count() + hold_paths.size() - ceded
	if merged.get_track_count() != expect:
		errors.append("轨道数 %d != 两源之和扣除让位轨 %d" % [merged.get_track_count(), expect])
	var paths := _track_paths(merged)
	if paths.size() != _dedup(paths).size():
		errors.append("存在同名轨道冲突")
	if not is_equal_approx(merged.length, walk.length):
		errors.append("时长 %.4f != walk 时长 %.4f" % [merged.length, walk.length])
	if merged.loop_mode != walk.loop_mode:
		errors.append("loop_mode %d != walk 的 %d" % [merged.loop_mode, walk.loop_mode])
	# 上身轨应全部来自 hold（让位轨除外），且铺满 [0, length]
	for p in hold_paths:
		if not paths.has(p) and not hold_ceded.has(p):
			errors.append("缺少上身轨 %s" % p)
	for i in merged.get_track_count():
		var mp := String(merged.track_get_path(i))
		if hold_paths.has(mp) and not hold_ceded.has(mp):
			if merged.track_get_key_count(i) != 2:
				errors.append("上身轨 %s 关键帧数 %d != 2（应为定格双帧）"
						% [merged.track_get_path(i), merged.track_get_key_count(i)])
				continue
			var v0: Variant = merged.track_get_key_value(i, 0)
			var v1: Variant = merged.track_get_key_value(i, 1)
			if not is_equal_approx(merged.track_get_key_time(i, 0), 0.0) \
					or not is_equal_approx(merged.track_get_key_time(i, 1), merged.length) \
					or typeof(v0) == TYPE_FLOAT and not is_equal_approx(v0, v1):
				errors.append("上身轨 %s 定格铺满不符（首尾时刻/值）" % mp)
	return errors


static func _dedup(paths: Array[String]) -> Dictionary:
	var seen := {}
	for p in paths:
		seen[p] = true
	return seen
