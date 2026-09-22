extends RefCounted
## MapRenderer 贴图异步加载助手（R9 底图 + §R5 建成区三档；l3_map_renderer
## 三线程同款样板）——queue / pump / 解码线程体 / join / poll 机制体。
##
## 纪律：线程与队列状态（_tex_thread/_tex_result/_tex_slot/_load_queue）全部留宿主
## map_renderer.gd，本助手经 _h 动态回引读写，不另立状态、不写 class_name；
## PNG 解码体为 static 纯函数（FileAccess 直读，不触共享状态——完成 Image 经
## wait_to_finish 返回值交回主线程，归档语义与拆分前一致）。
## 后台线程 FileAccess 直读 + PNG 解码（纯 CPU、线程安全，主线程零阻塞）；
## 单线程串行消费队列（任务含 kind，完成时按它归档）。
## 完成前同层回退矢量管线，解码完成后 queue_redraw 自动切上。


var _h  ## 宿主 MapRenderer（Node2D）动态回引


## 按需触发异步加载（宿主 set_data / set_layer_on 调用）
func ensure() -> void:
	if _h._data == null:
		return
	queue_static()
	pump()


## 把「需要而未装载/未排队/未在途」的贴图任务入队：
## 底图恒需（不属于任何开关层）；建成区三档无条件装载（本省 + 已装邻省）——
## 装载是数据层事实，画不画由层开关定；若按城市层门控，先关后开会因装载
## 已过点而永远缺贴图（层开关与装载队列的时序耦合，已根除）
func queue_static() -> void:
	if _h._base_tex == null:
		_queue_file("base", -1, "%s/%s" % [_h._data.base_dir, _h.BASE_TEXTURE])
	if not _h._blob_ready:
		for ti in SettlementBlob.TIER_COUNT:
			if _h._blob_tex[ti] == null:
				_queue_file("blob", ti, "%s/%s" % [_h._data.base_dir, SettlementBlob.TIER_FILES[ti]])
	_queue_neighbor_blobs()


## 邻省建成区三档入队（城市层打开才消费；逐包按窗口内矩形裁贴图——
## 邻省只要本包窗口那一段，整张 context 贴图常驻是浪费）
func _queue_neighbor_blobs() -> void:
	for i in _h._nb_packs.size():
		var pack: Dictionary = _h._nb_packs[i]
		if bool(pack.get("blob_ready", false)):
			continue
		if _h._nb().blob_draw_rect(pack).size.x <= 1.0:
			continue   # 该邻省在本包窗口内无可见部分（或裁剪为空）
		for ti in SettlementBlob.TIER_COUNT:
			if pack["blob_tex"][ti] == null:
				_queue_neighbor_file(i, ti,
						"%s/%s" % [pack["data"].base_dir, SettlementBlob.TIER_FILES[ti]])


## 入队一个邻省贴图任务：除 kind/path 外带 nb（_nb_packs 下标）、slot（档）与
## crop（解码后在主线程裁出的窗口内矩形，见 _archive_neighbor_blob）
func _queue_neighbor_file(index: int, slot: int, path: String) -> void:
	if _pending(path):
		return
	var pack: Dictionary = _h._nb_packs[index]
	var vis: Rect2 = _h._nb().blob_draw_rect(pack)
	var src := Rect2(vis.position - (pack["offset"] as Vector2), vis.size)
	_h._load_queue.append({
		"kind": "neighbor_blob",
		"nb": index,
		"slot": slot,
		"path": path,
		"crop": Rect2i(int(floorf(src.position.x)), int(floorf(src.position.y)),
				int(ceilf(src.size.x)), int(ceilf(src.size.y))),
	})


## 入队一个贴图任务（同路径已在队列/在途则跳过——控制器每次 open 会逐层调 ensure，
## 去重后同一张图只解码一次）
func _queue_file(kind: String, slot: int, path: String) -> void:
	if _pending(path):
		return
	var job := {"kind": kind, "path": path}
	if slot >= 0:
		job["slot"] = slot
	_h._load_queue.append(job)


## 该路径是否已排队或在途
func _pending(path: String) -> bool:
	if str(_h._tex_slot.get("path", "")) == path:
		return true
	for job in _h._load_queue:
		if str((job as Dictionary).get("path", "")) == path:
			return true
	return false


## 线程空闲时从队列取一个任务启动（缺失文件直接跳过继续取下一个）
func pump() -> void:
	while _h._tex_thread == null and not _h._load_queue.is_empty():
		var job: Dictionary = _h._load_queue.pop_front()
		if not FileAccess.file_exists(job.path):
			continue
		_h._tex_slot = job
		_h._tex_thread = Thread.new()
		_h._tex_thread.start(decode_png.bind(job.path))


## 后台线程体：PNG 文件直读解码（成功返回 Image，失败返回 null）
static func decode_png(path: String) -> Image:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var img := Image.new()
	if img.load_png_from_buffer(f.get_buffer(f.get_length())) == OK:
		return img
	return null


## join 后台线程并丢弃未消费结果（宿主 set_data 换包 / _exit_tree 销毁前必须调用——
## 未完成的 Thread 直接销毁在 Windows 上会段错误）
func join() -> void:
	_h._load_queue.clear()
	_h._tex_slot = {}
	if _h._tex_thread != null:
		_h._tex_thread.wait_to_finish()
		_h._tex_thread = null
	_h._tex_result = null


## 每帧检查后台线程（宿主 _process 调用）：解码完成 → wait_to_finish + 主线程建
## ImageTexture 按 slot 归档；blob 三档齐 → 档位对账；随后补启动下一个任务
func poll() -> void:
	if _h._tex_thread != null and not _h._tex_thread.is_alive():
		_h._tex_result = _h._tex_thread.wait_to_finish()
		_h._tex_thread = null
		if _h._tex_result != null and not _h._tex_slot.is_empty():
			var tex := ImageTexture.create_from_image(_h._tex_result)
			if str(_h._tex_slot.get("kind")) == "base":
				_h._base_tex = tex
				_h._terrain_img = _h._tex_result   # 降档擦除贴图的取样源
			elif str(_h._tex_slot.get("kind")) == "blob":
				var slot := int(_h._tex_slot.get("slot", -1))
				if slot >= 0 and slot < _h._blob_tex.size():
					_h._blob_tex[slot] = tex
					_h._check_blob_ready()
			elif str(_h._tex_slot.get("kind")) == "neighbor_blob":
				_archive_neighbor_blob()
			_h._tex_result = null
			_h._tex_slot = {}
			_h.queue_redraw()
		queue_static()
		pump()


## 邻省建成区贴图归档：按任务里的窗口 rect 裁剪后建纹理常驻（整张 context 贴图不保留），
## 三档齐 → blob_ready（绘制件据此整包一次画完）。解码结果由 poll() 放在 _h._tex_result，
## 本函数只读不置空（poll 在归档后统一清）。
func _archive_neighbor_blob() -> void:
	var idx := int(_h._tex_slot.get("nb", -1))
	var ti := int(_h._tex_slot.get("slot", -1))
	if idx < 0 or idx >= _h._nb_packs.size():
		return
	var pack: Dictionary = _h._nb_packs[idx]
	if ti < 0 or ti >= pack["blob_tex"].size():
		return
	var img: Image = _h._tex_result
	if img == null:
		return
	var crop: Rect2i = _h._tex_slot.get("crop", Rect2i())
	var bounds := Rect2i(0, 0, img.get_width(), img.get_height())
	var region := crop.intersection(bounds)
	if region.size.x <= 0 or region.size.y <= 0:
		return
	if region.size != bounds.size:
		var cut := img.get_region(region)
		if cut == null or cut.is_empty():
			return
		img = cut
	pack["blob_tex"][ti] = ImageTexture.create_from_image(img)
	pack["blob_rect"] = _h._nb().blob_draw_rect(pack)
	var ready := true
	for t: Variant in pack["blob_tex"]:
		if t == null:
			ready = false
			break
	pack["blob_ready"] = ready
