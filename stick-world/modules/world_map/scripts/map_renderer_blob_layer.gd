extends RefCounted
## MapRenderer 建成区 blob V2 层助手（§R5）——每城三档嵌套形状的档位对账、单城补丁
## 生成（分帧防卡顿）与 TERRAIN 模式的两套档位绘制件。
##
## 纪律：状态全部留在宿主 map_renderer.gd（_geo/_city_tier/_blob_tex/_blob_ready/
## _city_overlays/_city_erases/_overlay_queue 等），本助手经 _h 动态回引读写，
## 不另立状态、不写 class_name（防全局类循环引用）；
## load_pack / current_city_outline 为 static 纯函数（输入数据 → 输出，不触宿主）。
## 拆分前后行为逐行等价（数值/分支顺序/绘制顺序零变化）。

## 同模块几何库（点列闭合工具；宿主同款 preload）
const _GeoLib := preload("res://modules/world_map/scripts/map_renderer_geo.gd")


var _h  ## 宿主 MapRenderer（Node2D）动态回引


## 装载包几何（blob_v2_geo.bin：每城三档环顶点 + 烘焙档）+ 各城生效档初值。
## 初值 = 烘焙档（贴图画的就是它，reconcile 后修正为运行时判档）。
## 返回 {"geo": Dictionary, "tiers": Dictionary(sid → 烘焙档)}。
static func load_pack(data: L1WorldData) -> Dictionary:
	var geo := SettlementBlob.load_pack_geometry(data.base_dir)
	var tiers := {}
	for tile in data.tiles:
		if tile.settlement == null:
			continue
		tiers[tile.settlement.settlement_id] = \
			SettlementBlob.bake_tier_of(geo, tile.settlement.settlement_id)
	return {"geo": geo, "tiers": tiers}


## 当前城建成区轮廓（mid 档最大外环平移到城市锚点 + 弧长重采样闭合；
## 与建成区图形重合的 R2 语义，旧径向 blob 轮廓已随 §R5 退役）。
## 固定 mid 档——分数变化不再引起描边几何跳变。
## 语义与拆分前宿主内联体一致：命中块即止（块无聚落返回空）。
static func current_city_outline(geo: Dictionary, data: L1WorldData,
		tile_id: String) -> PackedVector2Array:
	for tile in data.tiles:
		if tile.tile_id == tile_id:
			if tile.settlement != null:
				var ring := SettlementBlob.glow_outline(geo, tile.settlement.settlement_id)
				if ring.size() >= 3:
					var pts := PackedVector2Array()
					pts.resize(ring.size())
					for i in ring.size():
						pts[i] = ring[i] + tile.settlement.position
					return FlowOutline.resample_closed(pts)
			return PackedVector2Array()
	return PackedVector2Array()


## 档位对账（三档贴图就绪后一次）：运行时扰动分 vs 烘焙档不同的城 → 补丁队列
## （分帧生成，生成前保持烘焙档画面——±15% jitter 边界城的短暂小偏差，可接受）
func reconcile_tiers() -> void:
	if not _h._blob_ready or _h._data == null:
		return
	for tile in _h._data.tiles:
		if tile.settlement == null:
			continue
		var sid = tile.settlement.settlement_id
		var t := SettlementBlob.tier_of(tile.settlement.population_score)
		if t != int(_h._city_tier.get(sid, -1)):
			_h._city_tier[sid] = t
			if not _h._overlay_queue.has(sid):
				_h._overlay_queue.append(sid)
	_h.queue_redraw()


## 单城档位刷新（宿主公共入口 invalidate_blob 转发至此）：SettlementRef.population_score
## 已由 api 更新，这里重判档位并把该城排进补丁队列优先生成。不在当前数据中的 id 忽略
func invalidate(settlement_id: String) -> void:
	if _h._data == null:
		return
	var sref = _h._data.get_settlement(settlement_id)
	if sref == null:
		return
	var new_tier := SettlementBlob.tier_of(sref.population_score)
	if new_tier != int(_h._city_tier.get(settlement_id, new_tier)):
		_h._city_tier[settlement_id] = new_tier
		_h._overlay_queue.erase(settlement_id)     # 去重：同一城只保留一个待补丁条目
		_h._overlay_queue.insert(0, settlement_id)
		process_overlay_queue()
	_h.queue_redraw()


## 每帧消费补丁队列（宿主 _process 调用；settlement_updated 走同步直通不走此队列等待）
func process_overlay_queue() -> void:
	var n := 0
	while not _h._overlay_queue.is_empty() and n < _h.OVERLAY_BUDGET_PER_FRAME:
		build_city_patch(_h._overlay_queue.pop_front())
		n += 1
	if n > 0:
		_h.queue_redraw()


## 单城补丁：按「生效档 vs 烘焙档」的差异方向生成 overlay/erase。
## 升档：嵌套覆盖（新形状 ⊇ 旧形状）→ 只需该城新档小贴图；
## 降档：旧档像素超出新形状 → 先以 l1_terrain.png 原样回贴擦除旧档区域，
##       再重画影响域内各城（含被波及的邻城）的生效档形状。
func build_city_patch(sid: String) -> void:
	if not _h._blob_ready or _h._data == null:
		return
	var sref = _h._data.get_settlement(sid)
	if sref == null or not _h._geo.has(sid):
		return
	var tier := int(_h._city_tier.get(sid, -1))
	if tier < 0:
		return
	var bake := SettlementBlob.bake_tier_of(_h._geo, sid)
	if tier > bake:
		_h._city_erases.erase(sid)
		var ov := make_city_overlay(sid, tier)
		if ov.is_empty():
			_h._city_overlays.erase(sid)
		else:
			_h._city_overlays[sid] = ov
	elif tier < bake:
		var bb := city_context_bbox(sid, bake, sref)
		if bb.size.x <= 0.0:
			return
		var ep := make_erase_patch(bb)
		if not ep.is_empty():
			_h._city_erases[sid] = ep
		for other_sid in cities_touching(bb):
			var ot := int(_h._city_tier.get(other_sid, SettlementBlob.bake_tier_of(_h._geo, other_sid)))
			var ov2 := make_city_overlay(other_sid, ot)
			if ov2.is_empty():
				_h._city_overlays.erase(other_sid)
			else:
				_h._city_overlays[other_sid] = ov2


## 单城生效档形状 → 小贴图（相对锚点局部栅格化 + 锚点平移定位）。该档无建成区返回 {}。
func make_city_overlay(sid: String, tier: int) -> Dictionary:
	var sref = _h._data.get_settlement(sid)
	if sref == null:
		return {}
	var res := SettlementBlob.rasterize_evenodd(
		SettlementBlob.city_rings(_h._geo, sid, tier), _h.BLOB_FILL)
	if res.is_empty():
		return {}
	var origin: Vector2 = res["origin"]
	var img: Image = res["img"]
	return {
		"tex": ImageTexture.create_from_image(img),
		"rect": Rect2(origin + sref.position, Vector2(img.get_width(), img.get_height())),
	}


## 擦除补丁：l1_terrain.png 原样回贴（区域 = 旧档形状 bbox 外扩 2px，裁进 context）。
## 底图 Image 未就绪（贴图加载失败等）返回 {}——降档城保持烘焙画面（报告遗留项）。
func make_erase_patch(bb: Rect2) -> Dictionary:
	if _h._terrain_img == null:
		return {}
	var ctx = _h._data.context_size
	var bounds := Rect2(Vector2.ZERO, Vector2(ctx.x, ctx.y))
	var rect := bb.grow(2.0).intersection(bounds)
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return {}
	var img = _h._terrain_img.get_region(Rect2i(int(rect.position.x), int(rect.position.y),
		int(rect.size.x), int(rect.size.y)))
	return {"tex": ImageTexture.create_from_image(img), "rect": rect}


## 城 tier 档形状的 context 坐标包围盒（锚点 = settlement.position）
func city_context_bbox(sid: String, tier: int, sref: SettlementRef) -> Rect2:
	var bb := Rect2()
	var polys := SettlementBlob.city_rings(_h._geo, sid, tier)
	var first := true
	for poly: Variant in polys:
		var outer: PackedVector2Array = (poly as Dictionary).get("outer", PackedVector2Array())
		for p in outer:
			var pt := p + sref.position
			if first:
				bb = Rect2(pt, Vector2.ZERO)
				first = false
			else:
				bb = bb.expand(pt)
	return bb


## 包围盒触及的城 sid 集合（各城烘焙档形状 bbox 相交判定——擦除区内所有
## 可能被波及的城都要重画）
func cities_touching(bb: Rect2) -> Array[String]:
	var out: Array[String] = []
	if bb.size.x <= 0.0:
		return out
	for tile in _h._data.tiles:
		if tile.settlement == null:
			continue
		var sid = tile.settlement.settlement_id
		var ot := int(_h._city_tier.get(sid, SettlementBlob.bake_tier_of(_h._geo, sid)))
		var obb := city_context_bbox(sid, maxi(ot, SettlementBlob.bake_tier_of(_h._geo, sid)),
			tile.settlement)
		if obb.size.x > 0.0 and obb.intersects(bb):
			out.append(sid)
	return out


## 档位绘制件之一（贴图就绪态）：三档嵌套贴图逐层叠加（每城显示烘焙档形状）
## + 单城档位补丁（先 erase 回贴底图，再 overlay 生效档形状）。
func draw_tier_textures(ctx_size: Vector2) -> void:
	for tex in _h._blob_tex:
		if tex != null:
			_h.draw_texture_rect(tex, Rect2(Vector2.ZERO, ctx_size), false)
	# 降档擦除（底图原样回贴）→ 单城生效档 overlay（顺序不可换：
	# 全部 erase 完成后再统一 overlay，多城 patch 相互覆盖才正确）
	for patch: Dictionary in _h._city_erases.values():
		_h.draw_texture_rect(patch.tex, patch.rect, false)
	for patch: Dictionary in _h._city_overlays.values():
		_h.draw_texture_rect(patch.tex, patch.rect, false)


## 档位绘制件之二（贴图未就绪矢量回退）：包几何按生效档平涂（洞不挖——过渡
## 画面数帧）；描边沿用级别色（T4+ 白描边 / T5 金描边）。
func draw_vector_fallback(zz: float) -> void:
	var bew: float = _h.BLOB_EDGE_WIDTH
	if zz > 0.0001:
		bew = _h.BLOB_EDGE_WIDTH / zz
	for tile in _h._data.tiles:
		var sref = tile.settlement
		if sref == null:
			continue
		var tier := int(_h._city_tier.get(sref.settlement_id, SettlementBlob.TIER_LOW))
		var polys := SettlementBlob.city_rings(_h._geo, sref.settlement_id, tier)
		if polys.is_empty():
			continue
		var edge = _h.BLOB_EDGE
		if sref.level >= 5:
			edge = _h.BLOB_EDGE_T5
		elif sref.level >= 4:
			edge = _h.BLOB_EDGE_T4
		for poly: Variant in polys:
			var outer: PackedVector2Array = (poly as Dictionary).get("outer",
				PackedVector2Array())
			if outer.size() < 3:
				continue
			var pts := PackedVector2Array()
			pts.resize(outer.size())
			for i in outer.size():
				pts[i] = outer[i] + sref.position
			_h.draw_colored_polygon(pts, _h.BLOB_FILL)
			_h.draw_polyline(_GeoLib.closed(pts), edge, bew, true)
