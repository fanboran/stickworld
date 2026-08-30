extends Node
## 武器动作预览：五种武器站姿 + 攻击动作中帧，拼成对照网格图。
## 这也是"怎么测试武器使用动作"的工具：每武器截两帧（持械站姿/攻击中段）。
## 运行（弹窗 ~15s 自动退出，输出拼图）：
##   godot --path stick-world res://tests/dev/diag_weapon_panel.tscn
## 产物：stick-world/tools/baking/diag_weapon_poses.png（5 行×2 列）

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _SHOT_DIR := "res://tools/baking/_poses"

var _game_root: Node = null
var _frames: int = 0
var _started := false
## 已截帧存档（键 = "stand_sword" 等），拼图直接用内存图，不重读文件
var _shots: Dictionary = {}
## 每帧截图时单位在屏幕上的坐标（以单位为中心裁剪）
var _shot_anchors: Dictionary = {}


func _ready() -> void:
	get_window().grab_focus()
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == 100 and not _started:
		_started = true
		_run_preview()


func _run_preview() -> void:
	var player: Node2D = _game_root.get_player_entity()
	if player == null:
		print("[preview] 无玩家实体")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(_SHOT_DIR)
	var cam: Camera2D = get_viewport().get_camera_2d()
	var wm: Node = player.get_node_or_null("WeaponMount")
	var names: Array[String] = ["sword", "spear", "bow", "pickaxe", "staff"]
	for i in 5:
		if wm != null:
			wm.weapon_type = i
		if player.has_method("refresh_stance"):
			player.refresh_stance()
		if cam != null:
			cam.global_position = player.global_position
		# 等站姿稳定（武器重挂 + 站姿动画进入）
		for _f in 30:
			await get_tree().process_frame
		await _snap("stand_%s" % names[i], player)
		# 攻击动作中帧（挥砍中段；attack_* 时长约 1~2s，0.55×时长在动作高点附近）
		player.play_attack()
		await get_tree().create_timer(0.55).timeout
		await _snap("attack_%s" % names[i], player)
		# 等攻击动画播完回站姿
		await get_tree().create_timer(1.6).timeout
	# 拼图
	await get_tree().process_frame
	_stitch(names)
	get_tree().quit(0)


func _snap(pname: String, player: Node2D) -> void:
	await get_tree().process_frame
	var img: Image = get_viewport().get_texture().get_image()
	# viewport 取出的图可能是 RGBAH 浮点格式，blit_rect 到 RGBA8 画布会静默失败——统一转 8bit
	img.convert(Image.FORMAT_RGBA8)
	_shots[pname] = img
	_shot_anchors[pname] = player.get_global_transform_with_canvas().origin
	var err := img.save_png("%s/%s.png" % [_SHOT_DIR, pname])
	print("[preview] %s (err=%d)" % [pname, err])


## 拼图：5 行（武器）×2 列（站姿/攻击中帧），每格裁 360x420
func _stitch(names: Array[String]) -> void:
	var cell := Vector2i(360, 420)
	var cols := ["stand", "attack"]
	var out := Image.create(cell.x * 2, cell.y * names.size(), false, Image.FORMAT_RGBA8)
	out.fill(Color(0.1, 0.1, 0.12))
	for r in names.size():
		for c in 2:
			var key := "%s_%s" % [cols[c], names[r]]
			var img: Image = _shots.get(key)
			if img == null:
				continue
			# 以单位屏幕坐标为中心裁剪（脚原点在下 1/4 处，头顶留白）
			var vp := Vector2i(img.get_width(), img.get_height())
			var anchor: Vector2 = _shot_anchors.get(key, Vector2(vp.x * 0.5, vp.y * 0.5))
			var origin := Vector2i(int(anchor.x) - cell.x / 2, int(anchor.y) - cell.y * 3 / 4)
			origin.x = clampi(origin.x, 0, vp.x - cell.x)
			origin.y = clampi(origin.y, 0, vp.y - cell.y)
			var region := img.get_region(Rect2i(origin, cell))
			out.blit_rect(region, Rect2i(Vector2i.ZERO, cell), Vector2i(c * cell.x, r * cell.y))
	var out_path := "res://tools/baking/diag_weapon_poses.png"
	var err := out.save_png(ProjectSettings.globalize_path(out_path))
	print("[preview] 拼图 %s (err=%d)" % [out_path, err])
