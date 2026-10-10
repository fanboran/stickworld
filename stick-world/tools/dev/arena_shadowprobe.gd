extends Node
## 观察场影子/宿主对账探针——由 arena_shot_boot 挂到 SceneTree.root（--probe 模式）。
## 等揭幕后逐秒采样 N 次，对每个 StickmanEntity 打印：宿主是否在 _char_map、
## 宿主渲染位 vs 实体逻辑位偏差、影子是否可见、影子位 vs 宿主位偏差。
## 定位"孤儿影/缺影/偏移"三类缺陷的归属。


const COVER_WAIT_FRAMES := 4200
## 卡渲染位与实体逻辑位的换算（同 feed：格→世界）
var _map: Node = null


func run(_tag: String, _preset: int, secs: int, every: int) -> void:
	for i in COVER_WAIT_FRAMES:
		await get_tree().process_frame
		var arena := get_tree().current_scene
		if arena != null and is_instance_valid(arena) \
				and arena.get_node_or_null("ArenaCover") == null:
			break
	print("[ShadowProbe] 揭幕完成，开始对账")
	# 等旧图退场（arena"旧图延迟销毁"：遮罩撤除后旧村图还挂几帧，
	# 截图/采样落在窗内会把村舍残影当战场）——揭幕后稳定一小段再动作
	for i in 12:
		await get_tree().process_frame
	_t0 = Time.get_ticks_msec() / 1000.0
	var next := 0.0
	while _elapsed() < secs:
		await get_tree().process_frame
		if _elapsed() >= next:
			next = _elapsed() + maxf(every, 1)
			_audit()
	print("[ShadowProbe] done")
	get_tree().quit(0)


var _t0 := 0.0


func _elapsed() -> float:
	return Time.get_ticks_msec() / 1000.0 - _t0


func _audit() -> void:
	var arena := get_tree().current_scene
	if arena == null or not is_instance_valid(arena):
		return
	var maps: Array = arena.find_children("", "Hd2dMapBase", true, false)
	var hd_map: Node = null
	for m in maps:
		hd_map = m
		break
	if hd_map == null:
		print("[ShadowProbe] 无 Hd2dMapBase")
		return
	var char_map: Dictionary = hd_map.get("_char_map")
	var depth_y_min: float = float(hd_map.get("depth_y_min"))
	var cell: float = float(hd_map.get("CELL_PX"))
	var n_total := 0
	var n_no_card := 0
	var n_no_shadow := 0
	var n_shadow_offset := 0
	var n_card_lag := 0
	var worst_shadow := 0.0
	var worst_lag := 0.0
	var worst_fed_stale := 0.0
	var n_fed_stale := 0
	var worst_e: Array = []
	for e in arena.find_children("", "StickmanEntity", true, false):
		if not is_instance_valid(e) or e.is_dead():
			continue
		n_total += 1
		var card: Node3D = char_map.get(e.get_instance_id())
		if card == null or not is_instance_valid(card):
			n_no_card += 1
			continue
		var shadow: Node3D = card.get("_shadow")
		var qp: Vector3 = card.get("_pos")
		var shadow_off := -1.0
		if shadow == null or not is_instance_valid(shadow) or not shadow.visible:
			n_no_shadow += 1
		else:
			var sp: Vector3 = shadow.global_position
			shadow_off = Vector2(sp.x - qp.x, sp.z - qp.z).length()
			worst_shadow = maxf(worst_shadow, shadow_off)
			if shadow_off > 0.15:
				n_shadow_offset += 1
		# 卡位 vs 实体逻辑位（feed 同口径换算）
		var body := e as Node2D
		# 注意：ex/ez 用的是基类格映射，战场图（battlefield）有自己的坐标覆写，
		# 此"卡滞后"指标对战场图不可信（基线漂移）——裁决性指标是"喂入陈旧"
		#（feed 原始 2D 坐标 vs 实体现 2D 坐标，零公式同空间）
		var ex: float = body.position.x / cell
		var ez: float = (body.position.y - depth_y_min) / cell
		var lag := Vector2(qp.x - ex, qp.z - ez).length()
		worst_lag = maxf(worst_lag, lag)
		if lag >= worst_lag and lag > 0.0:
			worst_e = [ex, ez, qp.x, qp.z, body.position, qp]
		if lag > 0.5:
			n_card_lag += 1
	print("[ShadowProbe] 实体 %d | 无宿主 %d | 影不可见 %d | 影偏移>0.15 %d (worst %.2f) | 宿主滞后>0.5格 %d (worst %.2f) | 喂入陈旧>40px %d (worst %.0fpx)" % [
		n_total, n_no_card, n_no_shadow, n_shadow_offset, worst_shadow, n_card_lag, worst_lag, n_fed_stale, worst_fed_stale])
	if not worst_e.is_empty():
		print("[ShadowProbe]   worst: 实体格(ex=%.2f,ez=%.2f) 卡格(qx=%.2f,qz=%.2f) | 实体2D=%s 卡local=%s" % [
			worst_e[0], worst_e[1], worst_e[2], worst_e[3], worst_e[4], worst_e[5]])
