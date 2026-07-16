@tool
extends Node3D
## 3D 地形查看器 — 加载高度图 PNG，生成带顶点位移和海拔着色的地形网格。
##
## 运行方式（编辑器内）：
##   1. 打开 res://tools/terrain_viewer/terrain_viewer.tscn
##   2. 在场景 dock 选中 TerrainViewer 节点
##   3. 脚本会自动加载高度图并重建网格
##
## 相机操作：
##   左键拖拽 → 旋转（orbit）
##   滚轮 → 缩放
##   中键拖拽 → 平移

const HEIGHTMAP_PATH := "res://tools/terrain_viewer/output/heightmap_8192.png"
const LANDMASK_PATH := "res://tools/terrain_viewer/output/landmask_8192.png"
const RIVER_MASK_PATH := "res://tools/terrain_viewer/output/rivers_8192.png"
const LAKE_MASK_PATH := "res://tools/terrain_viewer/output/lakes_8192.png"
const SHADER_PATH := "res://tools/terrain_viewer/terrain.gdshader"
const TERRAIN_SIZE := 100.0
const MESH_SUBDIVISIONS := 2048

@export var height_scale: float = 7.5:
	set(v):
		height_scale = v
		_update_shader_param("height_scale", v)

@export var water_width: float = 0.0008:
	set(v):
		water_width = v
		_update_shader_param("water_width", v)

@export var auto_rebuild: bool = true:
	set(v):
		auto_rebuild = v
		if auto_rebuild:
			_rebuild()

var _camera: Camera3D
var _mesh_instance: MeshInstance3D
var _orbit_angle_h := 0.0   # 水平旋转角（弧度）
var _orbit_angle_v := 0.5   # 垂直旋转角（弧度）
var _orbit_distance := 120.0
var _orbit_center := Vector3(TERRAIN_SIZE * 0.5, 0.0, TERRAIN_SIZE * 0.5)
var _mouse_pressed := false
var _mouse_button := MOUSE_BUTTON_NONE
var _last_mouse_pos := Vector2.ZERO
var _is_dragging := false


func _ready() -> void:
	if Engine.is_editor_hint():
		_rebuild()
		return

	# 运行时：确保有相机和灯光
	_setup_camera()
	_setup_light()
	_rebuild()


func _setup_camera() -> void:
	_camera = get_node_or_null("Camera3D") as Camera3D
	if not _camera:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera, false, INTERNAL_MODE_BACK)
		if not _camera.owner:
			_camera.owner = self if not Engine.is_editor_hint() else get_tree().edited_scene_root

	_camera.position = _orbit_center + Vector3(0, _orbit_distance * 0.6, _orbit_distance)
	_camera.look_at(_orbit_center)


func _setup_light() -> void:
	var light := get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if not light:
		light = DirectionalLight3D.new()
		light.name = "DirectionalLight3D"
		add_child(light, false, INTERNAL_MODE_BACK)
		if not light.owner:
			light.owner = self if not Engine.is_editor_hint() else get_tree().edited_scene_root

	light.rotation_degrees = Vector3(-45, 45, 0)
	light.shadow_enabled = false


func _rebuild() -> void:
	_ensure_mesh_instance()
	_apply_material()


func _ensure_mesh_instance() -> void:
	_mesh_instance = get_node_or_null("TerrainMesh") as MeshInstance3D
	if _mesh_instance:
		return

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "TerrainMesh"
	add_child(_mesh_instance, false, INTERNAL_MODE_BACK)
	if not _mesh_instance.owner:
		_mesh_instance.owner = self if not Engine.is_editor_hint() else get_tree().edited_scene_root

	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(TERRAIN_SIZE, TERRAIN_SIZE)
	plane_mesh.subdivide_width = MESH_SUBDIVISIONS
	plane_mesh.subdivide_depth = MESH_SUBDIVISIONS
	plane_mesh.center_offset = Vector3(TERRAIN_SIZE * 0.5, 0.0, TERRAIN_SIZE * 0.5)
	plane_mesh.orientation = PlaneMesh.FACE_Y  # 水平面（XZ 平面），Y 轴为高度
	_mesh_instance.mesh = plane_mesh


func _apply_material() -> void:
	if not _mesh_instance:
		return

	var shader := load(SHADER_PATH) as Shader
	if not shader:
		push_error("地形查看器: 找不到着色器 %s" % SHADER_PATH)
		return

	var mat := ShaderMaterial.new()
	mat.shader = shader

	var heightmap_tex := load(HEIGHTMAP_PATH) as Texture2D
	if heightmap_tex:
		mat.set_shader_parameter("heightmap", heightmap_tex)
	else:
		push_warning("地形查看器: 找不到高度图 %s，请先运行 convert_heightmap.py" % HEIGHTMAP_PATH)

	var landmask_tex := load(LANDMASK_PATH) as Texture2D
	if landmask_tex:
		mat.set_shader_parameter("landmask", landmask_tex)
	else:
		push_warning("地形查看器: 找不到陆地蒙版 %s，请先运行 convert_heightmap.py" % LANDMASK_PATH)

	var river_tex := load(RIVER_MASK_PATH) as Texture2D
	if river_tex:
		mat.set_shader_parameter("river_mask", river_tex)
	else:
		push_warning("地形查看器: 找不到河流蒙版 %s，请先运行 convert_heightmap.py" % RIVER_MASK_PATH)

	var lake_tex := load(LAKE_MASK_PATH) as Texture2D
	if lake_tex:
		mat.set_shader_parameter("lake_mask", lake_tex)
	else:
		push_warning("地形查看器: 找不到湖泊蒙版 %s，请先运行 convert_heightmap.py" % LAKE_MASK_PATH)

	mat.set_shader_parameter("height_scale", height_scale)
	mat.set_shader_parameter("water_width", water_width)

	_mesh_instance.material_override = mat


func _update_shader_param(name: String, value: float) -> void:
	if not _mesh_instance:
		return
	var mat := _mesh_instance.material_override as ShaderMaterial
	if mat:
		mat.set_shader_parameter(name, value)


# ── 编辑器内检查 ──────────────────────────────────────────────

func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = []
	if not ResourceLoader.exists(HEIGHTMAP_PATH):
		warnings.append("高度图缺失: %s\n请运行 convert_heightmap.py 生成" % HEIGHTMAP_PATH)
	return warnings


# ── 运行时相机控制 ──────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if Engine.is_editor_hint():
		return
	if not _camera:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_mouse_pressed = true
			_mouse_button = MOUSE_BUTTON_LEFT
			_last_mouse_pos = event.position
			_is_dragging = false
		else:
			_mouse_pressed = false
			_mouse_button = MOUSE_BUTTON_NONE
	elif event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			_mouse_pressed = true
			_mouse_button = MOUSE_BUTTON_MIDDLE
			_last_mouse_pos = event.position
			_is_dragging = false
		else:
			_mouse_pressed = false
			_mouse_button = MOUSE_BUTTON_NONE
	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_orbit_distance = max(_orbit_distance * 0.9, 10.0)
		_update_camera_position()
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_orbit_distance = min(_orbit_distance * 1.1, 500.0)
		_update_camera_position()


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	if not _mouse_pressed:
		return

	var delta := event.position - _last_mouse_pos
	_last_mouse_pos = event.position

	if delta.length() > 0.5:
		_is_dragging = true

	if not _is_dragging:
		return

	if _mouse_button == MOUSE_BUTTON_LEFT:
		# Orbit 旋转
		_orbit_angle_h -= delta.x * 0.005
		_orbit_angle_v = clamp(_orbit_angle_v - delta.y * 0.005, 0.05, PI * 0.45)
		_update_camera_position()
	elif _mouse_button == MOUSE_BUTTON_MIDDLE:
		# 平移
		var right := Vector3(cos(_orbit_angle_h), 0, -sin(_orbit_angle_h))
		var forward := Vector3(-sin(_orbit_angle_h), 0, -cos(_orbit_angle_h))
		var pan := right * (-delta.x * 0.3) + forward * (delta.y * 0.3)
		_orbit_center += pan
		_update_camera_position()


func _update_camera_position() -> void:
	if not _camera:
		return
	var cam_pos := _orbit_center + Vector3(
		sin(_orbit_angle_h) * cos(_orbit_angle_v) * _orbit_distance,
		sin(_orbit_angle_v) * _orbit_distance,
		cos(_orbit_angle_h) * cos(_orbit_angle_v) * _orbit_distance
	)
	_camera.position = cam_pos
	_camera.look_at(_orbit_center)
