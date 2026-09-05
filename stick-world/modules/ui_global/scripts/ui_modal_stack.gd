class_name UIModalStack
extends Node
## 统一模态栈 —— 层键字典 + 逐层 pop，替代 GameRoot._handle_escape 的特判 if。
##
## 设计参照《药剂工艺》DarkScreen（docs/设计/UI/10-UI系统重构参考.md §2.2）：
##   - 按层索引字典：`layers[layer]`，每层同时只挂一个激活对象（同类单例）
##   - 压栈而非互斥：设置上可再开确认框；ESC 逐层退栈（pop 栈顶）
##   - 输入屏蔽随栈统一：首层入栈自动暂停、栈空恢复原速度；压上层自动盖住下层
##     （防双重遮罩，揭示时恢复可见）
##
## 由 UIRoot 装配（UIModalStack 子节点）；GameRoot._handle_escape 只保留
## POSSESS 特判与"空栈 → 开暂停菜单"，其余全部委托给本栈。
## 非模态窗口（StickWindow FLOATING/DOCK/POPOVER）不入栈，ESC 自关。

# ─────────────────────────────── 层键 ────────────────────────────────
## 层键从低到高 = ESC 退栈顺序（键值越大越靠上）
enum Layer {
	PAUSE_MENU,    ## 0 最底：暂停菜单（ESC 空栈时的默认目标）
	SETTINGS,      ## 1 设置
	SAVE_PANEL,    ## 2 存档管理
	EMPIRE_PANEL,  ## 3 帝国功能空面板（K/O/J/L，同类单例，替换不叠加）
	INVENTORY,     ## 4 背包（E 键；确认框需盖在其上）
	STATS,         ## 5 角色属性面板（C 键）
	CONFIRM,       ## 6 最顶：确认框（SystemOverlay，ESC = 取消）
}
## 无层
const NONE := -1

# ─────────────────────────────── 状态 ────────────────────────────────
## 层键 → 激活对象（每层同时只挂一个 ActiveObject）
var layers: Dictionary = {}
## 被本栈盖住的层（visible=false 但仍在栈中）——覆盖时置 true，揭示时清除
var _covered: Dictionary = {}
## 可见性同步回调（screen -> Callable，disconnect 用）
var _visibility_cbs: Dictionary = {}
## 打开前的时间速度（栈空恢复；-1 = 本栈未暂停）
var _prev_speed: int = -1

# ─────────────────────────────── 压栈 ────────────────────────────────

## 把模态压入指定层。同一实例重复 push = 提到栈顶；同层被不同实例占用 = 替换（同类单例）。
func push(screen: Control, layer: int) -> void:
	if screen == null:
		return
	if layers.has(layer) and is_instance_valid(layers[layer]):
		var existing: Control = layers[layer]
		if existing == screen:
			raise_to_top(layer)
		else:
			_replace_existing(layer, existing, screen)
		return
	_push_new(screen, layer)


## 同层不同实例：先退旧再压新（不 reveal/restore，避免同帧闪烁）
func _replace_existing(layer: int, existing: Control, screen: Control) -> void:
	_untrack(existing)
	_covered.erase(existing)
	layers.erase(layer)
	if existing.has_method("close"):
		existing.close()
	else:
		existing.hide()
	_push_new(screen, layer)


func _push_new(screen: Control, layer: int) -> void:
	_cover_layers_below(layer)
	layers[layer] = screen
	_track(screen)
	_raise_in_parent(screen)
	_pause_if_needed()
	if screen.has_method("open"):
		screen.open()
	else:
		screen.show()


## 盖住比 layer 低的全部已开层（防双重遮罩；仍在栈中，pop 上层后揭示）
func _cover_layers_below(layer: int) -> void:
	for key in layers.keys():
		if int(key) < layer:
			var s: Control = layers[key]
			_covered[s] = true
			s.hide()


## 把屏幕提到父容器末尾（同槽内绘制在最上）
func _raise_in_parent(screen: Control) -> void:
	var parent := screen.get_parent()
	if parent != null and screen.get_index() != parent.get_child_count() - 1:
		parent.move_child(screen, parent.get_child_count() - 1)


## 同类单例：把 layer 提到栈顶（清掉叠在上面的层；若被盖住则揭示）
func raise_to_top(layer: int) -> void:
	if not layers.has(layer):
		return
	var t := top_layer()
	while t > layer:
		pop(t)
		t = top_layer()
	var s: Control = layers.get(layer) as Control
	if s != null and _covered.has(s):
		_covered.erase(s)
		s.show()
	_raise_in_parent(s)


# ─────────────────────────────── 退栈 ────────────────────────────────

## 关闭并移除指定层（close 由层自身负责；未实现 close 的用 hide）
func pop(layer: int) -> void:
	if not layers.has(layer):
		return
	var screen: Control = layers[layer]
	_untrack(screen)
	_covered.erase(screen)
	layers.erase(layer)
	if screen.has_method("close"):
		screen.close()
	else:
		screen.hide()
	_reveal_top()
	_restore_if_empty()


## 从栈顶逐层 pop 到指定层（inclusive=true 时连该层一起退）
func pop_until(layer: int, inclusive: bool = false) -> void:
	var t := top_layer()
	while t != NONE:
		if t < layer or (t == layer and not inclusive):
			break
		pop(t)
		t = top_layer()


## 清空整个栈
func clear() -> void:
	pop_until(NONE, true)


## 揭示当前栈顶（若被盖住）
func _reveal_top() -> void:
	var t := top_layer()
	if t == NONE:
		return
	var s: Control = layers.get(t) as Control
	if s != null and _covered.has(s):
		_covered.erase(s)
		s.show()


## ESC 统一退栈：有模态 → pop 栈顶并消费；无模态 → 返回 false（调用方决定开暂停菜单）
func handle_escape() -> bool:
	if not is_any_open():
		return false
	pop(top_layer())
	return true


# ─────────────────────────────── 查询 ────────────────────────────────

## 当前栈顶层键（无则 NONE）。顺带清理失效引用（场景切换后旧实例已 freed）
func top_layer() -> int:
	var top := NONE
	for key in layers.keys():
		var s: Control = layers[key]
		if not is_instance_valid(s):
			_untrack(s)
			layers.erase(key)
			_covered.erase(s)
			continue
		var k: int = int(key)
		if k > top:
			top = k
	return top


## 当前栈顶对象（无则 null）
func top() -> Control:
	var t := top_layer()
	if t == NONE:
		return null
	return layers.get(t) as Control


func is_any_open() -> bool:
	return not layers.is_empty()


func is_open(layer: int) -> bool:
	return layers.has(layer)


func get_entry(layer: int) -> Control:
	var s: Control = layers.get(layer, null)
	if s != null and not is_instance_valid(s):
		return null
	return s


# ─────────────────────────────── 输入屏蔽：暂停随栈 ────────────────────────────────

## 首个模态入栈时暂停（记原速度）；栈空时恢复原速度。与 StickScreen 自身暂停
## 兼容：面板 open() 时发现已暂停则不再记录，恢复只由最外层负责。
func _pause_if_needed() -> void:
	if TimeManager == null or _prev_speed >= 0:
		return
	if TimeManager.is_paused():
		_prev_speed = -1
	else:
		_prev_speed = int(TimeManager.current_speed)
		TimeManager.set_speed(TimeManager.Speed.PAUSED)


func _restore_if_empty() -> void:
	if not layers.is_empty() or _prev_speed < 0:
		return
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(_prev_speed)
	_prev_speed = -1


# ─────────────────────────────── 可见性同步 ────────────────────────────────

## 面板自身按钮 close（如设置"关闭"）→ visible=false → 本栈同步退栈，
## 保证栈状态与真实可见性一致（被栈盖住的层除外）。
func _track(screen: Control) -> void:
	var cb := _on_screen_visibility_changed.bind(screen)
	_visibility_cbs[screen] = cb
	screen.visibility_changed.connect(cb)


func _untrack(screen: Control) -> void:
	if _visibility_cbs.has(screen):
		var cb: Callable = _visibility_cbs[screen]
		if screen.visibility_changed.is_connected(cb):
			screen.visibility_changed.disconnect(cb)
		_visibility_cbs.erase(screen)


func _on_screen_visibility_changed(screen: Control) -> void:
	if _covered.has(screen):
		return  # 栈主动盖住（仍在栈中）
	if not screen.visible:
		_unregister(screen)


func _unregister(screen: Control) -> void:
	var layer := _find_layer(screen)
	if layer == NONE:
		return
	_untrack(screen)
	layers.erase(layer)
	_covered.erase(screen)
	_reveal_top()
	_restore_if_empty()


func _find_layer(screen: Control) -> int:
	for key in layers.keys():
		if layers[key] == screen:
			return int(key)
	return NONE


# ─────────────────────────────── 定位 ────────────────────────────────

## 从任意节点向上找 UIRoot 的模态栈（无 UIRoot 环境如主菜单返回 null）。
static func find(from: Node) -> UIModalStack:
	if from == null:
		return null
	var tree := from.get_tree()
	if tree == null:
		return null
	var root := tree.get_first_node_in_group("ui_root")
	if root == null:
		return null
	return root.get_node_or_null("UIModalStack") as UIModalStack
