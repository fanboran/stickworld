class_name SketchTextures
extends RefCounted
## 手绘贴图集 —— assets/ui/sketch 的沸腾帧贴图（tools 生成：见 temp/gen_sketch_ui_a10.py）。
##
## AnimatedTexture 在 StyleBoxTexture 渲染路径不推进帧 → 全局 _FrameDriver
## 定时把注册的九宫格 stylebox 换到下一帧贴图（真沸腾）。
##
## 帧驱动语义（节流 / 分批 / 降级）：
## - 节流：_FrameDriver 用 Time.get_ticks_msec() 墙钟判真实间隔（≥ 1000/FPS ms
##   才开新轮），不累积 delta——低帧率下引擎把单帧 delta 钳到上限（约 0.267s）
##   ≥ 间隔阈值，累积法会退化成「每帧换一轮」，把掉帧放大成全 UI 主题失效级联。
## - 分批：单轮换帧限时 BUDGET_USEC（2ms）；目标帧在轮次开始时一次性确定，
##   超预算保留游标、下一帧立即续传（不等节流间隔）直到写完同一目标帧。
##   正常负载整轮在预算内完成 → 所有盒同一帧同步换帧，视觉与逐帧轮换无差别。
## - 压缩：遍历时对已释放的死条目就地剔除（写索引压缩），数组与映射不随
##   场景反复进出无限增长。
## - 可见性：register_box 可选传 owner（CanvasItem），owner 在树中不可见的盒
##   本轮跳过换帧（游标照常推进，重新可见后自然追平目标帧）。
## - 门控：animation_enabled 为 false 时驱动空转，画面停留在当前帧；
##   由玩法宿主（GameRoot）置 false、主菜单置 true。

const DIR := "res://assets/ui/sketch/"
const FRAMES := 3
const FPS := 7.5
## 九宫格边距（与生成脚本 MARGIN 同值）
const MARGIN := 10
## 单轮换帧的时间预算（微秒）：超时即停，靠游标分帧续传同一目标帧
const BUDGET_USEC := 2000
## 每处理多少个盒查一次预算（均摊时钟查询开销）
const BUDGET_CHECK_EVERY := 16

static var _frame_sets: Dictionary = {}
## 玩法场景置 false 冻结换帧，菜单等纯 UI 场景保持 true
static var animation_enabled := true
static var _boxes: Array[StyleBoxTexture] = []
static var _slot_map: Dictionary = {}
static var _owners: Dictionary = {}  # sb -> CanvasItem（可选，register_box 传了才入表）
static var _step: int = 0
static var _driver: Node
## 分批游标：_cursor = 本轮已读到的下标（0 = 无未完成轮次）；
## _write_idx = 已压实前缀长度（≤ _cursor，写索引压缩的落点）
static var _cursor: int = 0
static var _write_idx: int = 0


static func ensure_driver(tree: SceneTree) -> void:
	if _driver != null and is_instance_valid(_driver):
		return
	_driver = _FrameDriver.new()
	# deferred：首次调用常发生在 UIRoot._ready（root 正忙于子树 ready 传播），
	# 同步 add 到 root 会报 "Parent node is busy setting up children" 并丢帧驱动；
	# 延到空闲帧挂载（沸腾晚一帧启动，无感）
	tree.root.add_child.call_deferred(_driver)


## 注册九宫格 stylebox 到帧轮换（SketchStyle._box 内部调用）。
## owner 可选：换帧时 owner 不在树中可见则跳过该盒，省无谓的主题失效。
static func register_box(sb: StyleBoxTexture, slot: StringName, owner: CanvasItem = null) -> void:
	if _frame_sets.is_empty():
		_load_all()
	_boxes.append(sb)
	_slot_map[sb] = slot
	if owner != null:
		_owners[sb] = owner
	if _frame_sets.has(slot):
		sb.texture = (_frame_sets[slot] as Array)[_step]


## 把全部注册盒换到下一帧（带 BUDGET_USEC 预算，超时保留游标分帧续传；
## 语义详见类头「帧驱动语义」）
static func _advance() -> void:
	var deadline := Time.get_ticks_usec() + BUDGET_USEC
	var target := (_step + 1) % FRAMES  # 目标帧轮次开始时一次性定死；续传期间 _step 不变，重算同值
	var n := _boxes.size()
	var w := _write_idx  # 写索引：存活前缀长度
	var i := _cursor
	while i < n:
		var sb := _boxes[i]
		if sb == null or not is_instance_valid(sb):
			_slot_map.erase(sb)  # 死条目就地剔除（数组尾部稍后由 resize 裁掉）
			_owners.erase(sb)
		else:
			if i != w:
				_boxes[w] = sb  # 前移压实；映射以 sb 对象为键，不随数组重排失效
			w += 1
			var ow := _owners.get(sb) as CanvasItem
			if ow != null and not is_instance_valid(ow):
				_owners.erase(sb)  # owner 已释放：清映射，视同无 owner
				ow = null
			# 可见性跳过：不可见盒本轮不换帧（游标照常推进，可见后自然追平）
			if ow == null or ow.is_visible_in_tree():
				var frames: Array = _frame_sets.get(_slot_map.get(sb, &"panel"), [])
				if not frames.is_empty():
					sb.texture = frames[target]
		i += 1
		if i < n and (i % BUDGET_CHECK_EVERY) == 0 and Time.get_ticks_usec() >= deadline:
			_cursor = i  # 超预算：保留游标（含压实落点），下帧立即续传
			_write_idx = w
			return
	# 整轮完成：提交目标帧、清游标、把尾部死条目裁掉
	if w < n:
		_boxes.resize(w)
	_cursor = 0
	_write_idx = 0
	_step = target


static func _load_all() -> void:
	for slot in ["panel", "panel_light", "groove", "groove_focus",
			"btn_normal", "btn_hover", "btn_pressed", "btn_disabled",
			"accent_normal", "accent_hover", "accent_pressed",
			"btn_primary_normal", "btn_primary_hover", "btn_primary_pressed", "btn_primary_disabled",
			"btn_ink_normal", "btn_ink_hover", "btn_ink_pressed", "btn_ink_disabled",
			"danger_normal", "danger_hover",
			"tab_selected", "tab_hover",
			"progress_bg", "progress_fill", "sep_h", "sep_v"]:
		var frames: Array[Texture2D] = []
		for i in FRAMES:
			var tex := load("%s%s_f%d.png" % [DIR, slot, i]) as Texture2D
			if tex == null:
				push_warning("[SketchTextures] 贴图缺失：%s_f%d" % [slot, i])
				continue  # 单 slot 缺图只弃该 slot，不中断其余 slot 加载
			frames.append(tex)
		_frame_sets[StringName(slot)] = frames


class _FrameDriver extends Node:
	## 上一轮换帧的开始时刻（msec 墙钟）
	var _last_round_ms: int = 0

	func _process(_delta: float) -> void:
		# 门控：关闭时立即停止换帧调度（若有未完成轮次，游标保留，重新启用后续传）
		if not SketchTextures.animation_enabled:
			return
		# 上轮超预算未完成（游标 > 0）：立即续传（不等节流间隔），尽快收敛同一目标帧
		if SketchTextures._cursor > 0:
			SketchTextures._advance()
			return
		# 真墙钟节流：不用累积 delta——低帧率下引擎钳制单帧 delta（可达 ~0.267s）
		# ≥ 间隔阈值，累积法会退化成每帧换一轮；ticks_msec 判的是真实时间间隔
		var now := Time.get_ticks_msec()
		if now - _last_round_ms < 1000.0 / SketchTextures.FPS:
			return
		_last_round_ms = now
		SketchTextures._advance()
