extends RefCounted
## hd2d_shots_harness.gd —— HD-2D 诊断出图工装组件（hd2d_world 职责拆分）。
##
## 职责：一切开发工装——CLI 参数解析（_parse_args/_opts）、诊断分组隐藏
## （--hide= 对照实验）、--save-scene 地面几何落盘、截图 harness（_run_shots/
## _shot/_settle）、HUD 标签工厂（_make_label）、调试辅助线（--debug=1 的
## 整格网格/建筑边界紫线/1-3 线/末层基线）。shots 默认 "none" = 静默常驻
## 模式（游戏地图挂载用），工装路径只有显式 CLI 介入才激活。
##
## 固定跑法（可反复运行，产物落 stick-world/temp/proto_hd2d/）::
##
##   "F:/SteamLibrary/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe" \
##     --path stick-world res://modules/hd2d/scenes/hd2d_world.tscn -- --shots=all
##
##   # 只出某一张：--shots=a | b | c | d | e | s（s=主街巡览六机位）
##   # 性能档（关 vsync + 可选放大分辨率压过刷新率上限）：--perf=1 [--res=2560x1440]
##   # 角色 quad 通道对照：--char=blend|scissor
##
## 依赖（复用 proto_25d 已提交的 Blender 半场产物，本目录不改它）::
##   stick-world/temp/proto25d/cards.json + cards/*.png    建筑卡（albedo + glow）
##   stick-world/temp/ground_tiles/*.png                   地面分带贴图
##   若缺，先跑： blender -b --factory-startup -P stick-world/tests/dev/proto_25d/blender_proto.py
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

var w: Node3D = null   # 门面回引（_ready 注入；禁循环 preload 故不标门面类型）

## CLI 选项账（_parse_args 写；宿主 _ready 与光照域读 shots/flat/layout 等键）
var _opts := {
	"shots": "none", "res": "", "layout": "",
	"tag": "", "flat": false, "debug": false,
	"hide": "",
}  # shots 默认 "none" = 静默常驻模式（游戏地图挂载用；probe 出图须显式 --shots=…）


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s == "--save-scene":
			_opts["save_scene"] = true
			continue
		if s.begins_with("--shots="):
			_opts["shots"] = s.get_slice("=", 1)
		elif s.begins_with("--res="):
			_opts["res"] = s.get_slice("=", 1)
		elif s.begins_with("--tag="):
			_opts["tag"] = s.get_slice("=", 1)
		elif s.begins_with("--flat="):
			# --flat=1：关远焦 DOF（辅助线核对版出图用——DOF 满糊会把辅助线一起晕开）
			_opts["flat"] = s.get_slice("=", 1) != "0"
		elif s.begins_with("--layout="):
			# 布局驱动：读 city_layout 导出的布局 JSON 摆街（算法村，如村B）
			_opts["layout"] = s.get_slice("=", 1)
		elif s.begins_with("--battlefield="):
			# 战场模式：无墙无街的开阔野地（战场图宿主注入同款）
			w.battlefield = s.get_slice("=", 1) != "0"
		elif s.begins_with("--debug="):
			# --debug=1：辅助线（网格/紫线/1/3 线/末层基线）——调试模式才出现（创始人口径）
			_opts["debug"] = s.get_slice("=", 1) != "0"
		elif s.begins_with("--hide="):
			# --hide=shadow,plat,cards：诊断用分组隐藏（对照实验定位视觉缺陷来源）
			_opts["hide"] = s.get_slice("=", 1)
	# 工装跑法提示：只在显式出图/调试跑法（shots 激活）时提示，静默常驻（生产
	# 路径）零输出
	if str(_opts["shots"]) != "none":
		print("[hd2d] 跑法: godot --path stick-world res://modules/hd2d/scenes/hd2d_world.tscn -- --shots=all")


## 诊断对照实验：按 --hide= 组名隐藏节点组（shadow=接地影面片 / plat=台面系几何 /
## cards=建筑卡 / kerb=台肩镶边）。只影响显示，不改落位。
func _apply_hide_groups() -> void:
	var spec := str(_opts.get("hide", ""))
	if spec.is_empty():
		return
	for grp: String in spec.split(","):
		var roots: Array = []
		match grp:
			"shadow":
				roots = [w._shadow_root]
			"cards":
				roots = [w._card_root]
			"plat":
				for n: Node in w._ground_root.get_children():
					var nm := str(n.name)
					if nm.begins_with("Seg_") or nm.begins_with("Band_") \
							or nm.begins_with("PlatRim") or nm.begins_with("Decal_") \
							or nm.begins_with("DoorPath"):
						n.visible = false
				continue
			"kerb":
				for n: Node in w._ground_root.get_children():
					if str(n.name).begins_with("PlatRim"):
						n.visible = false
				continue
			_:
				continue
		for r: Node3D in roots:
			r.visible = false
	print("[hd2d] 已隐藏分组: ", spec)


func _set_owner_recursive(n: Node, root: Node) -> void:
	for c in n.get_children():
		c.owner = root
		_set_owner_recursive(c, root)


## --save-scene 落盘分支：只存**地面/台肩几何**（_ground_root 子树）——含运行时
## 光栅的角色/后期会把场景撑到几百 MB。存完即退出进程。
func _save_ground_scene_then_quit() -> void:
	var gr: Node = w._ground_root
	_set_owner_recursive(gr, gr)
	var packed := PackedScene.new()
	var err := packed.pack(gr)
	if err == OK:
		var p := "res://temp/hd2d/ground_scene_dump.tscn"
		var e2 := ResourceSaver.save(packed, p)
		print("[hd2d] 地面场景已存 -> ", p, " err=", e2)
	else:
		print("[hd2d] pack 失败 err=", err)
	w.get_tree().quit(0)


## HUD 标签工厂（只在遮挡对照图里显示，给两格加字）
func _make_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", 6)
	w._post_layer.add_child(l)
	return l


func _add_width_guides() -> void:
	if not bool(_opts["debug"]):
		return
	# **整格网格**（1 格 = 一条线，每 4 格加亮）+ 每栋建筑左右边界紫线（方便数几格宽）
	var thin := StandardMaterial3D.new()
	thin.albedo_color = Color(0.55, 0.95, 1.0, 0.55)
	thin.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	thin.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var bold := StandardMaterial3D.new()
	bold.albedo_color = Color(0.35, 0.85, 1.0, 0.95)
	bold.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bold.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var edge := StandardMaterial3D.new()
	edge.albedo_color = Color(1.0, 0.25, 0.85, 1.0)
	edge.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var x := -70.0
	while x <= 70.0:
		var pm := PlaneMesh.new()
		pm.size = Vector2(0.02 if int(x) % 4 != 0 else 0.035, 8.6)
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		mi.material_override = thin if int(x) % 4 != 0 else bold
		mi.position = Vector3(x, w.PLAT_H + 0.015, -2.6)
		mi.name = "GridX"
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		w._ground_root.add_child(mi)
		x += 1.0
	for occ in w._front_occ:
		var wg := float(occ[1]) - float(occ[0])
		var cx := (float(occ[0]) + float(occ[1])) * 0.5
		for s in [-1.0, 1.0]:
			var pm2 := PlaneMesh.new()
			pm2.size = Vector2(0.05, 8.6)
			var mi2 := MeshInstance3D.new()
			mi2.mesh = pm2
			mi2.material_override = edge
			mi2.position = Vector3(cx + s * wg * 0.5, w.PLAT_H + 0.018, -2.6)
			mi2.name = "BldEdge"
			mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			w._ground_root.add_child(mi2)


func _add_horizon_guides() -> void:
	if not bool(_opts["debug"]):
		return
	# 两条全屏水平辅助线（创始人 2026-09-14 要求；贴地 unshaded，无阴影）：
	#   橙 = 屏幕 1/3 线（33.3% 从底）：第二排基线 + 第一排（+地面）屏幕区的上边界
	#   绿 = 末排（bg2）基线 = 真实地平线（底衬远端收到同一点）
	# z 取实测卡基线（anchor 深度偏移各卡不同，见 _spawn_bg_card）。
	var specs := [
		{"z": float(w._bg_base_z.get(0, w.SKYLINE_Z)), "col": Color(1.0, 0.62, 0.10)},
		{"z": float(w._bg_base_z.get(w.BG_LAYERS - 1,
			w.SKYLINE_Z - w.BG_LAYER_GAP * float(w.BG_LAYERS - 1))),
			"col": Color(0.20, 1.0, 0.45)},
	]
	for i in specs.size():
		var pm := PlaneMesh.new()
		pm.size = Vector2(150.0, 0.12)
		var mi := MeshInstance3D.new()
		mi.mesh = pm
		var m := StandardMaterial3D.new()
		m.albedo_color = specs[i]["col"]
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mi.material_override = m
		mi.position = Vector3(0, 0.025, float(specs[i]["z"]))
		mi.name = "Guide%d" % i
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		w._ground_root.add_child(mi)


## 等待 sec 秒（出图节奏用）
func _settle(sec: float) -> void:
	await w.get_tree().create_timer(sec).timeout


func _shot(shot_name: String) -> String:
	await RenderingServer.frame_post_draw
	var img := w.get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(w._temp + "proto_hd2d")
	var tag := str(_opts.get("tag", ""))
	if not tag.is_empty():
		shot_name += tag
	var p: String = w._temp + "proto_hd2d/" + shot_name + ".png"
	var err := img.save_png(p)
	if err != OK:
		push_error("[hd2d] 截图失败 %s (err=%d)" % [p, err])
	else:
		print("[hd2d] shot -> %s  %dx%d  帧时=%.2f ms" % [
			p, img.get_width(), img.get_height(), _last_frame_ms()])
	return p


func _last_frame_ms() -> float:
	return 1000.0 / max(1.0, Performance.get_monitor(Performance.TIME_FPS))


func _run_shots(which: String) -> void:
	var t0 := Time.get_ticks_usec()
	var do: Array = []
	if which == "all" or which == "":
		do = ["a", "c", "e"]
	else:
		do = [which]

	for st in do:
		match st:
			"a":
				w.light._apply_light("day")
				w.light._apply_stage("a")
				await _settle(1.4)
				await _shot("hd2d_a_base")
			"c":
				w.light._apply_light("day")
				w.light._apply_stage("c")
				await _settle(1.4)
				await _shot("hd2d_c_final")
			"e":
				w.light._apply_light("night")
				w.light._apply_stage("e")
				await _settle(1.6)
				await _shot("hd2d_e_night")
			"s":
				# 主街巡览（2026-09-14 手工摆+街长扩到村A全域的验收档）：
				# 沿街机位横移（set_cam_x），含两端城墙/门洞与墙外野外带，
				# 各出一张白天最终观感图
				w.light._apply_light("day")
				w.light._apply_stage("c")
				for cam_x: float in [-115.0, -55.0, 0.0, 55.0, 100.0, 122.0]:
					w.set_cam_x(cam_x)
					await _settle(1.2)
					await _shot("hd2d_s_street_x%d" % int(cam_x))
				w.set_cam_x(0.0)
	print("[hd2d] 出图用时 %.1f s" % (float(Time.get_ticks_usec() - t0) / 1000000.0))
