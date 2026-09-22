extends RefCounted
## MapRenderer 贴图异步加载助手（R9/R4 底图 + §R5 建成区三档；l3_map_renderer
## 三线程同款样板）——queue / pump / 解码线程体 / join / poll 机制体。
##
## 纪律：线程与队列状态（_tex_thread/_tex_result/_tex_slot/_load_queue）全部留宿主
## map_renderer.gd，本助手经 _h 动态回引读写，不另立状态、不写 class_name；
## PNG 解码体为 static 纯函数（FileAccess 直读，不触共享状态——完成 Image 经
## wait_to_finish 返回值交回主线程，归档语义与拆分前一致）。
## 后台线程 FileAccess 直读 + PNG 解码（纯 CPU、线程安全，主线程零阻塞）；
## 单线程串行消费队列（任务含 kind/slot，完成时按它归档）。
## 完成前当前模式回退矢量管线，解码完成后 queue_redraw 自动切上。


var _h  ## 宿主 MapRenderer（Node2D）动态回引


## 按需触发异步加载（宿主 set_data / set_map_mode 调用）
func ensure() -> void:
	if _h._data == null:
		return
	queue_static()
	pump()


## 按当前模式把「需要而未装载/未排队/未在途」的贴图任务入队
func queue_static() -> void:
	if _h.MODE_TEXTURES.has(_h.map_mode) and not _h._mode_textures.has(_h.map_mode):
		_h._load_queue.append({
			"kind": "mode", "slot": _h.map_mode,
			"path": "%s/%s" % [_h._data.base_dir, _h.MODE_TEXTURES[_h.map_mode]],
		})
	# 建成区三档只在 TERRAIN 模式消费（POLITICAL/TRAFFIC 不显示建成区，§R4）
	if _h.map_mode == MapModeManager.Mode.TERRAIN and not _h._blob_ready:
		for ti in SettlementBlob.TIER_COUNT:
			if _h._blob_tex[ti] == null:
				_h._load_queue.append({
					"kind": "blob", "slot": ti,
					"path": "%s/%s" % [_h._data.base_dir, SettlementBlob.TIER_FILES[ti]],
				})


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
## ImageTexture 按 slot 归档；blob 三档齐 → 档位对账；随后按当前模式补启动下一个任务
func poll() -> void:
	if _h._tex_thread != null and not _h._tex_thread.is_alive():
		_h._tex_result = _h._tex_thread.wait_to_finish()
		_h._tex_thread = null
		if _h._tex_result != null and not _h._tex_slot.is_empty():
			var tex := ImageTexture.create_from_image(_h._tex_result)
			if str(_h._tex_slot.get("kind")) == "mode":
				_h._mode_textures[_h._tex_slot.slot] = tex
				if int(_h._tex_slot.get("slot", -1)) == MapModeManager.Mode.TERRAIN:
					_h._terrain_img = _h._tex_result   # 降档擦除贴图的取样源
			elif str(_h._tex_slot.get("kind")) == "blob":
				var slot := int(_h._tex_slot.get("slot", -1))
				if slot >= 0 and slot < _h._blob_tex.size():
					_h._blob_tex[slot] = tex
					_h._check_blob_ready()
			_h._tex_result = null
			_h._tex_slot = {}
			_h.queue_redraw()
		queue_static()
		pump()
