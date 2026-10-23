extends RefCounted
## hd2d_light_rig.gd —— HD-2D 光照后处理域组件（hd2d_world 职责拆分）。
##
## 职责：昼夜光照档（_apply_light：天幕/清屏色、环境光、主光/补光、卡着色器
## 昼夜参数、街灯能量）与屏幕后处理（_set_post 移轴/暗角/分级、_update_px_size
## 像素尺寸、_apply_stage 的 glow/DOF 档开关）。光照档常量（SKY_BLUE/SKY_NIGHT）
## 留在门面（门面 _build_world 与本组件共用），经 w 读取。
##
## 约定：w = 宿主门面（hd2d_world）回引，_ready 时注入；组件间经 w 互访成员属
## 模块内部自由域，模块对外契约仍只有 modules/hd2d/api.gd 的 duck 面。

var w: Node3D = null   # 门面回引（_ready 注入；禁循环 preload 故不标门面类型）


## 光照档公开逻辑（宿主 set_light_mode 调；本函数幂等可反复调用）。
## 每档先复位再覆盖（幂等，可反复调用）
## 白天 = "阳光明媚 + 高调照明"（创始人最终口径）：
##   · 去雾（fog 关）—— 大气不再把画面洗灰；
##   · 冷天空环境 0.58 抬暗部，冷补光 0.12 压明暗比（卡是已带白天光照的
##     烘焙图）；
##   · 白平衡略偏暖（主光暖 + gain 微暖 + lift 微抬）。
func _apply_light(mode: String) -> void:
	w.sky._set_sky_look(w.SKY_BLUE)
	w._env.ambient_light_color = Color(0.64, 0.71, 0.86)
	w._env.ambient_light_energy = 0.58
	# 去雾：阳光明媚口径下大气密度 ≈0（保留开关，量级调到看不出）
	w._env.fog_enabled = false
	w._env.fog_density = 0.06
	w._env.fog_light_color = Color(0.84, 0.89, 0.96)
	w._env.fog_depth_begin = 55.0
	w._env.fog_depth_end = 160.0
	w._sun.light_color = Color(1.0, 0.95, 0.83)
	# 太阳 1.10（创始人 2026-09-16：恢复提亮档原值——0.48 是场景回退时被连带
	# 滚回去的；主光方向仍按档位固定，与天幕弧线日盘解耦）
	w._sun.light_energy = 1.10
	w._sun.rotation = Vector3(deg_to_rad(-46.0), deg_to_rad(-62.0), 0)
	w._fill.light_color = Color(0.70, 0.80, 1.0)
	w._fill.light_energy = 0.12
	w._fill.rotation = Vector3(deg_to_rad(-16.0), deg_to_rad(118.0), 0)
	var glow := 0.0
	var lamp := 0.0
	var night_mix := 0.0   # 夜档=1：整卡换用 Blender 月夜灯位烘的 <卡>_night.png
	var night_comp := 0.0  # 夜档卡亮度补偿（烘卡亮度不被场景光二次压暗，见 card.gdshader）
	var post := {
		# 主场景零模糊（创始人拍板）：移轴归零，模糊只由 DOF 的远焦层承担
		"tilt_level": 0.0, "tilt_radius": 7.0, "tilt_center": 0.72,
		"tilt_band": 0.17, "tilt_feather": 0.24,
		"vig_strength": 0.28, "vig_inner": 0.55, "vig_outer": 1.10,
		"exposure": 1.14, "contrast": 1.02, "saturation": 1.18,
		"lift": Color(0.024, 0.022, 0.024), "gain": Color(1.0, 0.996, 0.986),
		"split": 1.0,
	}
	match mode:
		"night":
			# 月夜档（创始人 2026-09-15 三条口径）：
			#   ① **夜雾删掉**——后景/远处地面"纯黑"的元凶就是这层雾（雾色近黑
			#     (0.05,0.07,0.14)、后景正好吃满雾程）；距离层次交给后景分层染色
			#     + 远焦 DOF，与白天同口径；
			#   ② 月光主要**烘在卡里**（Blender 夜版贴图），场景光按"卡已带光、
			#     合成 ≈1.0"纪律给中性冷色保底——旧档有效亮度只有 ≈5%，是
			#     "建筑卡夜里全黑"的主因；街边小物件夜里的月光同样来自夜版贴图；
			#   ③ 窗光去黄——glow 染色收暖白（CARD_GLOW_TINT）、能量降档，街灯
			#     降能减饱和，画面不再整片泛橙。
			w.sky._set_sky_look(w.SKY_NIGHT)
			w._env.ambient_light_color = Color(0.60, 0.68, 0.90)
			w._env.ambient_light_energy = 0.42
			w._env.fog_enabled = false
			w._env.glow_intensity = 0.9
			w._env.glow_bloom = 0.08
			# 月光方向光只给 0.15：月光主要烘在卡里（夜版贴图），能量一高会把
			# 画面整体推蓝。夜空月盘 = 天幕弧线月盘（_update_celestial），能量
			# 低不撑亮场景，只作天体读法
			w._sun.light_color = Color(0.62, 0.72, 1.0)
			w._sun.light_energy = 0.15
			w._sun.rotation = Vector3(deg_to_rad(-62.0), deg_to_rad(140.0), 0)
			w._fill.light_energy = 0.03
			glow = 0.7
			lamp = 1.3
			night_mix = 1.0
			night_comp = 0.6
			# 夜景同样不做屏幕空间移轴：主场景零模糊是全局口径，夜幕的层次交给远焦 DOF
			post["tilt_level"] = 0.0
			post["vig_strength"] = 0.50
			post["exposure"] = 1.08
			post["saturation"] = 1.02
			post["lift"] = Color(0.008, 0.010, 0.022)
		_:
			pass  # day
	for m in w.cards._card_mats:
		m.set_shader_parameter("glow_energy", glow)
		m.set_shader_parameter("night_mix", night_mix)
		m.set_shader_parameter("night_comp", night_comp)
		m.set_shader_parameter("glow_tint", w.CARD_GLOW_TINT)
	for m in w.cards._bg_card_mats:
		m.set_shader_parameter("glow_energy", glow * w.BG_GLOW_RATIO)   # 后景窗火只做点缀
		m.set_shader_parameter("night_mix", night_mix)
		m.set_shader_parameter("night_comp", night_comp)
		m.set_shader_parameter("glow_tint", w.CARD_GLOW_TINT)
	for l in w._lamps:
		l.visible = lamp > 0.0
		l.light_energy = lamp
	w._last_light_mode = mode
	if w._cloud_root != null:
		w._cloud_root._apply_cloud_light(mode)
	_set_post(post)
	# 光照档是生产路径运行期状态（昼夜换档即打）——收进 STICK_HD2D_VERBOSE 门控
	if OS.get_environment("STICK_HD2D_VERBOSE") != "":
		print("[hd2d] 光照档=%s glow=%.2f lamp=%.2f night_mix=%.1f comp=%.2f" % [mode, glow, lamp, night_mix, night_comp])


func _set_post(d: Dictionary) -> void:
	for k in d.keys():
		w._post_mat.set_shader_parameter(k, d[k])


## 屏幕像素尺寸（移轴模糊半径以 px 计）。canvas_item shader 在 4.7 没有
## SCREEN_PIXEL_SIZE 内建，只能由脚本灌；窗口 resize / 性能档改分辨率后必须重灌。
func _update_px_size() -> void:
	var sz := w.get_viewport().get_visible_rect().size
	if sz.x > 0.0 and sz.y > 0.0:
		w._post_mat.set_shader_parameter("px_size", Vector2(1.0 / sz.x, 1.0 / sz.y))


## A/B/C 三张递进图的开关
##   a: 无角色 + 无后处理（glow/DOF/后处理层全关 → 只有 3D 场景 + 建筑卡）
##   b: 加角色（SubViewport -> billboard），仍无任何后处理
##   c: 再加 HD-2D 后处理（glow + DOF + 移轴 + 暗角 + 分级）
func _apply_stage(stage: String) -> void:
	w._post_rect.visible = stage == "c" or stage == "d" or stage == "e"
	_update_px_size()
	var hd := stage == "c" or stage == "d" or stage == "e"
	w._env.glow_enabled = hd
	# 景深（CameraAttributesPractical；Godot 4 的 DOF 挂在相机属性上，不在 Environment）
	# **业界口径**：八方旅人初代的强移轴被广泛批评（"让玩家想关掉"），三角战略已把它
	# 改成可关设置。故本档口径 = 近焦**关**、主场景（临街一排 + 火柴人）**零模糊**，
	# 只让远背景层吃远焦模糊。
	# 深度坐标（相机视图空间，实测本机位）：角色 29~35 | 临街建筑卡 41~45.5 |
	# 中景地面 44~62 | 远景剪影层(z=-24) ≈ 66。
	# far 46.5 + 过渡 9：临街卡(41~45.5) 完全在 46.5 以内 → 100% 锐利；
	# 第二排 bg1（≈51）→ (51-46.5)/9 = 50% 半档模糊（创始人：第二排景深要明显）；
	# 末排 bg2（≈56）→ 满档。运行时经 set_cam_zoom 重算为同一世界线
	# （天际线前移 DOF_FAR_START_AHEAD 格），两处口径一致。
	w._cam_attrs.dof_blur_near_enabled = false
	w._cam_attrs.dof_blur_far_enabled = hd and not bool(w.shots._opts["flat"]) and not w.battlefield
	# 战场广角视关远焦（深带中景全落模糊带，绿草地糊成白幕、单位熔进背景——
	# DOF 电影感是主街近景语言，RTS 观战视不适用）
	w._cam_attrs.dof_blur_near_distance = 24.0
	w._cam_attrs.dof_blur_near_transition = 10.0
	# far 走 set_cam_zoom 同一条"天际线世界线"公式，不写死：正式链路有逐帧
	# set_cam_zoom 兜底重算，静默/shots 路径 stage 覆盖后没人再算——写死 48
	# 会停在 0.75 档两排背景楼的深度（≈42/45）以内，后排零模糊（与正式观感
	# 脱节，创始人 2026-09-16 指出测试图没有正式场景一直有的模糊）
	w._cam_attrs.dof_blur_far_distance = (
			w._cam.position.z - w.SKYLINE_Z - w.DOF_FAR_START_AHEAD) / cos(deg_to_rad(w.TILT_DEG))
	w._cam_attrs.dof_blur_far_transition = 20.0
	# amount 0.20：回到初始渐变（第二排半档、远景满档）——0.26+9 过渡把两层
	# 糊成一档，渐变读不出来（创始人 2026-09-15）。
	w._cam_attrs.dof_blur_amount = 0.20
