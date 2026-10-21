extends RefCounted
## hd2d_walls.gd —— HD-2D 城墙域组件（hd2d_world 职责拆分）。
##
## 职责：城墙**几何**——转角收边墙板（沿纵深方向，正交视角下呈"窄竖条 +
## 墙顶垛口"）、门洞带（两段墙板夹洞 + 门柱加厚/叠涩内挑/横梁组成门楼）、
## 墙体石材材质。墙线取值/碰撞带/城门表（_wall_x/get_gates/get_solid_rects）
## 归门面 solids 域——几何归本组件、数据归门面。
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

var w: Node3D = null   # 门面回引（_ready 注入；禁循环 preload 故不标门面类型）


## 城墙转角收边（§4.5）：±墙线立石墙板（沿纵深方向，正交视角下呈窄竖条
## + 墙顶垛口），门洞开在路面纵深带 GATE_Z0~Z1——门柱加厚、叠涩内挑、横梁
## 过顶组成"门楼"读法（深一档石材与墙面拉开），出城从门洞直穿。
func _build_walls() -> void:
	var wx: float = w._wall_x()
	# 墙纵深贯通到后景地平线（背景地面带远端，创始人：包括城墙也是一直
	# 延伸到后景地平线）
	var wall_far_z: float = float(w._bg_base_z.get(w.BG_LAYERS - 1,
			w.SKYLINE_Z - w.BG_LAYER_GAP * float(w.BG_LAYERS - 1)))
	var mat := _wall_material(Color(0.85, 0.83, 0.79))
	var pmat := _wall_material(Color(0.62, 0.60, 0.57))
	var root := Node3D.new()
	root.name = "CityWalls"
	w.add_child(root)
	for sx: float in [-1.0, 1.0]:
		# 两段墙板夹出门洞：**后段从天际线（z=-7，背景楼群根部）起**——
		# 城墙纵深贯通全场景（创始人：垂直向城墙不能只有道路带那么短），
		# 前段铺到行走带前缘外
		for seg: Variant in [[wall_far_z, w.GATE_Z0], [w.GATE_Z1, 19.5]]:
			var z0: float = float(seg[0])
			var z1: float = float(seg[1])
			_box(root, mat, Vector3(w.WALL_T, w.WALL_H, z1 - z0),
					Vector3(sx * wx, w.WALL_H * 0.5, (z0 + z1) * 0.5))
			var z: float = z0 + 0.7
			while z < z1 - 0.4:
				_box(root, mat, Vector3(w.WALL_T, 0.55, 0.85),
						Vector3(sx * wx, w.WALL_H + 0.275, z))
				z += 1.7
		for pz: float in [w.GATE_Z0 - 0.35, w.GATE_Z1 + 0.35]:
			_box(root, pmat, Vector3(w.WALL_T + 0.55, w.WALL_H + 0.7, 0.7),
					Vector3(sx * wx, (w.WALL_H + 0.7) * 0.5, pz))
		for cz: float in [w.GATE_Z0 + 0.45, w.GATE_Z1 - 0.45]:
			_box(root, pmat, Vector3(w.WALL_T + 0.35, 1.2, 0.55),
					Vector3(sx * wx, 4.4, cz))
		_box(root, pmat, Vector3(w.WALL_T + 0.3, w.WALL_H - 5.0, w.GATE_Z1 - w.GATE_Z0),
				Vector3(sx * wx, 5.0 + (w.WALL_H - 5.0) * 0.5, (w.GATE_Z0 + w.GATE_Z1) * 0.5))
		for mz: float in [w.GATE_Z0 + 0.9, (w.GATE_Z0 + w.GATE_Z1) * 0.5, w.GATE_Z1 - 0.9]:
			_box(root, pmat, Vector3(w.WALL_T + 0.3, 0.5, 0.8),
					Vector3(sx * wx, w.WALL_H + 0.25, mz))


## 墙体石材（路肩石贴图三平面投射，免逐面 UV；tint 分档）
func _wall_material(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	var tex: Texture2D = w._tex_abs(w._temp + w.GROUND_DIR + "band_shoulder_stone_128.png")
	if tex != null:
		m.albedo_texture = tex
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3(0.4, 0.4, 0.4)
	m.albedo_color = tint
	m.roughness = 0.92
	return m


func _box(root: Node3D, mat: Material, size: Vector3, pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	root.add_child(mi)
