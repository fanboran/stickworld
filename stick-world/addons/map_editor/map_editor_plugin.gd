@tool
extends EditorPlugin
## 地图编辑插件 -- 标尺 + 坐标输入放置建筑
##
## 使用方法：
## 1. 工具栏出现"建筑放置"按钮 + 下拉选择建筑 + X坐标输入框 + "放置"按钮
## 2. 下拉菜单选择建筑（支持子文件夹）
## 3. 在 X 坐标输入框输入格子坐标（如 16 表示 x=512）
## 4. 点"放置"按钮，建筑放在指定格子位置
## 5. 场景中标尺显示格子编号

const CELL_SIZE := 32
const BUILDINGS_DIR := "res://modules/building_gen/buildings/"

var _button: Button
var _menu_button: MenuButton
var _x_input: SpinBox
var _place_btn: Button
var _snap_btn: Button
var _separator: VSeparator
var _separator2: VSeparator
var _separator3: VSeparator
var _building_scenes: Array[String] = []
var _building_names: Array[String] = []
var _selected_index := 0
var _scene_check_timer: Timer


func _enter_tree() -> void:
	_button = Button.new()
	_button.text = "建筑放置"
	_button.toggle_mode = true
	_button.toggled.connect(_on_button_toggled)
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, _button)

	_separator = VSeparator.new()
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, _separator)

	_menu_button = MenuButton.new()
	_menu_button.text = "选择建筑"
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, _menu_button)

	_separator2 = VSeparator.new()
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, _separator2)

	var label := Label.new()
	label.text = "格子X:"
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, label)

	_x_input = SpinBox.new()
	_x_input.min_value = 0
	_x_input.max_value = 9999
	_x_input.value = 0
	_x_input.suffix = " (%dpx)"
	_x_input.custom_minimum_size = Vector2(120, 0)
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, _x_input)

	_place_btn = Button.new()
	_place_btn.text = "放置!"
	_place_btn.pressed.connect(_on_place_clicked)
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, _place_btn)

	_separator3 = VSeparator.new()
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, _separator3)

	_snap_btn = Button.new()
	_snap_btn.text = "吸附全部"
	_snap_btn.tooltip_text = "把所有建筑吸附到32px网格和草地中线"
	_snap_btn.pressed.connect(_on_snap_all_clicked)
	add_control_to_container(CONTAINER_CANVAS_EDITOR_MENU, _snap_btn)

	_rebuild_building_menu()

	_scene_check_timer = Timer.new()
	_scene_check_timer.wait_time = 0.3
	_scene_check_timer.timeout.connect(_on_scene_check)
	_scene_check_timer.autostart = true
	add_child(_scene_check_timer)

	# 按钮默认隐藏
	_set_controls_visible(false)


func _exit_tree() -> void:
	if _scene_check_timer:
		_scene_check_timer.queue_free()
	for ctrl in [_button, _separator, _menu_button, _separator2, _place_btn, _separator3, _snap_btn, _x_input]:
		if ctrl:
			remove_control_from_container(CONTAINER_CANVAS_EDITOR_MENU, ctrl)
			ctrl.queue_free()


func _handles(object: Object) -> bool:
	var is_map := object is Node2D and "ground_y" in object
	_set_controls_visible(is_map)
	return false  # 不接管场景，避免干扰编辑器选择


func _set_controls_visible(vis: bool) -> void:
	for ctrl in [_button, _separator, _menu_button, _separator2, _place_btn, _separator3, _snap_btn, _x_input]:
		if ctrl:
			ctrl.visible = vis


func _on_scene_check() -> void:
	var root := get_editor_interface().get_edited_scene_root()
	var is_map: bool = root != null and "ground_y" in root
	_set_controls_visible(is_map)


# ─────────────────────────────── 建筑菜单 ────────────────────────────────

func _rebuild_building_menu() -> void:
	_building_scenes.clear()
	_building_names.clear()
	var popup: PopupMenu = _menu_button.get_popup()
	popup.clear()
	for child in popup.get_children():
		child.queue_free()
	_scan_dir(BUILDINGS_DIR, popup)
	if not popup.id_pressed.is_connected(_on_building_selected):
		popup.id_pressed.connect(_on_building_selected)
	if _building_scenes.is_empty():
		_menu_button.text = "无建筑"
	else:
		_selected_index = 0
		_menu_button.text = _building_names[0]
	print("[MapEditor] 发现 %d 个建筑场景" % _building_scenes.size())


func _scan_dir(dir_path: String, menu: PopupMenu) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	var folders: Array[String] = []
	var files: Array[String] = []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if dir.current_is_dir() and not f.begins_with("."):
			folders.append(f)
		elif f.ends_with(".tscn"):
			files.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	for file in files:
		var name := file.get_basename()
		var full_path := dir_path + "/" + file
		var id: int = _building_scenes.size()
		_building_scenes.append(full_path)
		_building_names.append(name)
		menu.add_item(name, id)
	for folder in folders:
		var submenu := PopupMenu.new()
		submenu.name = folder
		menu.add_submenu_item(folder, folder)
		menu.add_child(submenu)
		_scan_dir(dir_path + "/" + folder, submenu)


func _on_building_selected(id: int) -> void:
	if id >= 0 and id < _building_scenes.size():
		_selected_index = id
		_menu_button.text = _building_names[id]


# ─────────────────────────────── 放置 ────────────────────────────────

func _on_button_toggled(pressed: bool) -> void:
	print("[MapEditor] %s" % ("工具已激活" if pressed else "工具已关闭"))


func _on_place_clicked() -> void:
	var cell_x: int = int(_x_input.value)
	var root := get_editor_interface().get_edited_scene_root() as Node2D
	if root == null:
		print("[MapEditor] 没有打开的场景")
		return
	var tb := _get_terrain_buildings(root)
	if tb == null:
		print("[MapEditor] 未找到 TerrainBuildings 节点")
		return
	if _building_scenes.is_empty():
		print("[MapEditor] 没有可用的建筑场景")
		return

	var ground_y: float = root.ground_y if "ground_y" in root else 810.0
	var ground_bottom: float = root.ground_bottom if "ground_bottom" in root else 1080.0
	var midline: float = (ground_y + ground_bottom) / 2.0
	var width_cells := _get_building_width_cells(_building_scenes[_selected_index])
	var width_px: float = width_cells * CELL_SIZE
	# Y = midline - 碰撞体下边界相对建筑原点的偏移
	var collision_bottom_local := _get_scene_collision_bottom_local(_building_scenes[_selected_index])
	var pos := Vector2(cell_x * CELL_SIZE + width_px / 2.0, midline - collision_bottom_local)

	# 重叠检查
	var new_left: float = pos.x - width_px / 2.0
	var new_right: float = pos.x + width_px / 2.0
	for child in tb.get_children():
		if child is Node2D:
			var child_w: float = _get_node_width_cells(child) * CELL_SIZE
			var child_left: float = child.position.x - child_w / 2.0
			var child_right: float = child.position.x + child_w / 2.0
			if new_left < child_right and new_right > child_left:
				print("[MapEditor] 位置已被占用: cell %d" % cell_x)
				return

	var scene := load(_building_scenes[_selected_index]) as PackedScene
	if scene == null:
		return
	var building := scene.instantiate() as Node2D
	if building == null:
		return
	building.position = pos

	var ur := get_undo_redo()
	ur.create_action("放置 %s @ cell %d" % [_building_names[_selected_index], cell_x])
	ur.add_do_method(tb, "add_child", building)
	ur.add_do_method(building, "set_owner", root)
	ur.add_undo_method(tb, "remove_child", building)
	ur.add_undo_reference(building)
	ur.commit_action()

	print("[MapEditor] 放置 %s 于 cell %d (x=%.0f, y=%.0f)" % [_building_names[_selected_index], cell_x, pos.x, pos.y])

	# 自动递增 X，方便连续放置
	_x_input.value = cell_x + width_cells


func _on_snap_all_clicked() -> void:
	var root := get_editor_interface().get_edited_scene_root() as Node2D
	if root == null:
		return
	var tb := _get_terrain_buildings(root)
	if tb == null:
		print("[MapEditor] 未找到 TerrainBuildings")
		return
	var ground_y: float = root.get("ground_y") if "ground_y" in root else 810.0
	var ground_bottom: float = root.get("ground_bottom") if "ground_bottom" in root else 1080.0
	var midline: float = (ground_y + ground_bottom) / 2.0
	var count := 0
	var ur := get_undo_redo()
	ur.create_action("吸附全部建筑")
	for child in tb.get_children():
		if child is Node2D:
			var old_pos: Vector2 = child.position
			var new_x: float = roundf(old_pos.x / CELL_SIZE) * CELL_SIZE
			# Y = midline - 碰撞体下边界相对建筑原点的偏移
			var col_bottom_local := _get_node_collision_bottom_local(child)
			var new_y: float = midline - col_bottom_local
			var new_pos := Vector2(new_x, new_y)
			if old_pos.distance_to(new_pos) > 0.5:
				ur.add_do_property(child, "position", new_pos)
				ur.add_undo_property(child, "position", old_pos)
				count += 1
	ur.commit_action()
	print("[MapEditor] 吸附了 %d 个建筑" % count)


# ─────────────────────────────── 辅助 ────────────────────────────────

func _get_terrain_buildings(root: Node) -> Node2D:
	return _find_node(root, "TerrainBuildings")


func _find_node(node: Node, node_name: String) -> Node2D:
	if node.name == node_name and node is Node2D:
		return node as Node2D
	for child in node.get_children():
		var found := _find_node(child, node_name)
		if found:
			return found
	return null


func _get_building_width_cells(scene_path: String) -> int:
	var scene := load(scene_path) as PackedScene
	if scene == null:
		return 1
	var temp := scene.instantiate() as Node2D
	if temp == null:
		return 1
	var width := 1
	var pb := temp.get_node_or_null("PassageBarrier")
	if pb:
		for child in pb.get_children():
			if child is CollisionShape2D and child.shape is RectangleShape2D:
				width = maxi(1, int(round(child.shape.size.x / CELL_SIZE)))
				break
	temp.free()
	return width


func _get_node_width_cells(node: Node2D) -> int:
	var pb := node.get_node_or_null("PassageBarrier")
	if pb:
		for child in pb.get_children():
			if child is CollisionShape2D and child.shape is RectangleShape2D:
				return maxi(1, int(round(child.shape.size.x / CELL_SIZE)))
	return 1


## 从场景文件读取碰撞体下边界相对建筑原点的 Y 偏移
func _get_scene_collision_bottom_local(scene_path: String) -> float:
	var scene := load(scene_path) as PackedScene
	if scene == null:
		return 0.0
	var temp := scene.instantiate() as Node2D
	if temp == null:
		return 0.0
	var bottom := _get_node_collision_bottom_local(temp)
	temp.free()
	return bottom


## 从已实例化的节点读取碰撞体下边界相对建筑原点的 Y 偏移
func _get_node_collision_bottom_local(node: Node2D) -> float:
	var pb := node.get_node_or_null("PassageBarrier")
	if pb:
		for child in pb.get_children():
			if child is CollisionShape2D and child.shape is RectangleShape2D:
				return child.position.y + child.shape.size.y / 2.0
	return 0.0
