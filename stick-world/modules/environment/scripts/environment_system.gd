class_name EnvironmentSystem
extends Node
## 环境系统 —— 跨场景保持的环境效果。
##
## P0 阶段实现：
##   - 时间推进（接 WorldState.game_time）
##   - 时间映射到 CanvasModulate.color（按关键帧插值）
##
## 后续阶段扩展：天空、天气、地面震动、生物群落。
## 详见 docs/技术/架构/场景与战斗架构.md §十一。

# EnvironmentAPI 是全局 class_name，无需 preload

# ─────────────────────────────── Inspector 参数 ────────────────────────────────
## 时间推进速度（现实秒 : 游戏小时）。默认 60 秒 = 24 小时。
@export var seconds_per_day: float = 60.0

## 跟随玩家的营火光开关（默认关：2026-09-06 用户指示去掉角色夜晚自发光，
## 泰拉瑞亚夜晚无随身光源，地表靠剪影+星光辨识；P2 逐光源布点时再启用）
@export var camp_light_enabled: bool = false

## 当前时间（0.0 ~ 24.0）
@export var time_of_day: float = 8.0:
	set(v):
		time_of_day = fposmod(v, 24.0)

# ─────────────────────────────── 内部状态 ────────────────────────────────
var _canvas_modulate: CanvasModulate = null

## 跟随玩家（附身实体）的暖光（PLACEHOLDER 素材 2026-08-22；替换项 P2）：
## 夜晚玩家自带的营火/灯笼光。位置跟踪玩家而非镜头——玩家不在场（主菜单/战斗空场）
## 时降为微光并在玩家出现前不移动。贴图为运行时生成的径向渐变，非手绘资产。
var _camp_light: PointLight2D = null


# ─────────────────────────────── 生命周期 ────────────────────────────────

func _ready() -> void:
	_ensure_canvas_modulate()
	_ensure_camp_light()
	if WorldState:
		# WorldState.game_time 单位为小时（0~24），存档加载后已有值则恢复，
		# 否则以本节点初始 time_of_day 为准
		if WorldState.game_time > 0.0:
			time_of_day = WorldState.game_time
		else:
			WorldState.game_time = time_of_day
	# 立即设置初始光照，避免首帧白屏
	_update_lighting()


func _process(delta: float) -> void:
	if TimeManager and not TimeManager.is_paused():
		# 推进时间
		var hours_per_second: float = 24.0 / seconds_per_day
		time_of_day += hours_per_second * delta
		if WorldState:
			WorldState.game_time = time_of_day
	# 更新光照
	_update_lighting()
	_update_camp_light()


# ─────────────────────────────── 夜间光源（PLACEHOLDER）────────────────────────────────

func _ensure_camp_light() -> void:
	_camp_light = PointLight2D.new()
	_camp_light.name = "CampLight"
	var tex := GradientTexture2D.new()
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 512
	tex.height = 512
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.82, 0.55, 0.9))
	grad.set_color(1, Color(1.0, 0.75, 0.45, 0.0))
	tex.gradient = grad
	_camp_light.texture = tex
	_camp_light.texture_scale = 3.0
	_camp_light.energy = 0.0
	add_child(_camp_light)


## 光强随环境亮度反相（越夜越亮），位置跟踪玩家（附身实体）脚下。
## 默认关闭（camp_light_enabled=false）：energy 归零，仅保留节点供调试面板读取。
func _update_camp_light() -> void:
	if _canvas_modulate == null or _camp_light == null:
		return
	if not camp_light_enabled:
		_camp_light.energy = 0.0
		return
	var brightness: float = _canvas_modulate.color.get_luminance()
	var t: float = clampf((0.72 - brightness) / 0.34, 0.0, 1.0)
	_camp_light.energy = lerpf(_camp_light.energy, t * 1.1, 0.08)
	var player: Node2D = _find_player_entity()
	if player == null:
		return
	# 玩家脚下 + 轻微上移（光心在人物重心而非脚底板）
	var target_pos: Vector2 = player.global_position + Vector2(0, -24.0)
	_camp_light.global_position = _camp_light.global_position.lerp(target_pos, 0.12)


## 找玩家（附身）实体：优先 GameRoot.get_entity 系的附身实体；无则先找当前附身单位
## （EnvironmentSystem 与 units 解耦经 GameRoot 路径，若多个都找不到返回 null → 光静止）
func _find_player_entity() -> Node2D:
	var gr := get_tree().root.get_node_or_null("GameRoot")
	if gr == null:
		return null
	# 1. 附身实体（最常用路径）：GameRoot → PossessionInterface.get_possessed_entity
	if gr.has_method("get_possession_interface"):
		var pi = gr.get_possession_interface()
		if pi != null and pi.has_method("get_possessed_entity"):
			var p = pi.get_possessed_entity()
			if p != null and is_instance_valid(p):
				return p as Node2D
	# 2. 兜底：玩家实体
	if gr.has_method("get_player_entity"):
		var pl = gr.get_player_entity()
		if pl != null and is_instance_valid(pl):
			return pl as Node2D
	return null


# ─────────────────────────────── 内部 ────────────────────────────────

func _ensure_canvas_modulate() -> void:
	_canvas_modulate = get_node_or_null("CanvasModulate") as CanvasModulate
	if _canvas_modulate == null:
		_canvas_modulate = CanvasModulate.new()
		_canvas_modulate.name = "CanvasModulate"
		add_child(_canvas_modulate)


func _update_lighting() -> void:
	if _canvas_modulate == null:
		return
	_canvas_modulate.color = EnvironmentAPI.sample_light_color(time_of_day)
	# 天空底色走清屏色（Terraria ColorOfTheSkies 同构）：不经过 CanvasModulate，
	# 星/月在黑天上保持亮度、云与背景贴图仍由 CanvasModulate 染色
	RenderingServer.set_default_clear_color(EnvironmentAPI.sample_sky_bg_color(time_of_day))


## 按关键帧插值采样光照颜色
static func _sample_light_color(hour: float) -> Color:
	return EnvironmentAPI.sample_light_color(hour)


# ─────────────────────────────── 公共 API ────────────────────────────────

## 设置一天的现实秒数
func set_seconds_per_day(seconds: float) -> void:
	seconds_per_day = maxf(1.0, seconds)


## 直接设置时间（0~24）
func set_time_of_day(hour: float) -> void:
	time_of_day = hour


## 获取当前时间
func get_time_of_day() -> float:
	return time_of_day


## 获取当前 CanvasModulate 颜色（供测试验证）
func get_current_light_color() -> Color:
	if _canvas_modulate == null:
		return Color.WHITE
	return _canvas_modulate.color
