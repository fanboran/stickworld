extends Node
## 战斗演练场（观察用，非 CI 测试）：按预设双方各 16~96 人、多班多排按武器分排编队推进互殴。
##
## 用途：肉眼观察战斗画面自然度——编队推进/站姿/走姿/挥砍/受击/死亡/血条/阵营对抗。
## 入口：项目主场景（F5 直进）或主菜单「战斗演练」→「大乱斗观察场」。
## 控制面板（底部居中）：预设按钮（遭遇战·16 / 标准战役·48 / 大军压境·96，点按或
## 1/2/3 切换并立即重开，static _preset_idx 跨重开保持）+「重开 (R)」按钮。
##
## 编制（现实军衔体系重排，融合 FormationSystem 排聚合层 + 火力组指挥分组）：
##   班 squad = 8~12 人小班（硬顶 15），班长 1 名（rank 1，阵亡经组织侧补位免费无缝轮转）；
##   火力组 fireteam = 班内成员子集的指挥分组（创始人编制口径：一个班除班长外劈两个
##   火力组，班长可以火力组为单位下发细分命令）——每班劈一号/二号两组，组长 = 组内
##   首员（无标记不占军衔）；只作号令寻址粒度（TacticalOrders.issue 对 ft_id 下令），
##   不拆散班聚结（归队锚点仍是班长）。军师意图规划器仍按班下令不动——火力组细分
##   是后续班长级 AI 的地基；
##   排 platoon = 2~3 个班 + 排长 1 名（rank 2）——排长阵亡 = 该排指挥链缺口：
##   失去集火号令与排长士气光环，到战斗结束无法补员（班长轮转不受影响）。
##   兵种结构落到班级：矛兵班（先锋，射程 120 卡线）→ 剑士班（中坚）→
##   火力班（杖+弓，射程 300 压制）。三档编成（"platoons" = 班下标分组建排）：
##     遭遇战·16 = 1 排（矛兵班 8 + 中坚火力班 8，2 班 ×8 人）
##     标准战役·48 = 2 排 ×2 班（矛 12 + 矛剑混编 12 ｜ 剑 12 + 火 12，4 班 ×12 人）
##     大军压境·96 = 4 排 ×2 班（矛×2 ｜ 混编+剑 ｜ 剑×2 ｜ 火×2，8 班 ×12 人）
##   一屏战场（创始人：战场范围限定在屏幕一样大）：出生中心 ±700、全部武器行按
##   纵深行距 ROW_GAP=50 均匀收排（相邻行任意两员 Δx≥50 > 分离椭圆横半径 48，
##   任意纵距都不违反分离不变式；行内纵向间距仍由 MIN_ROW_GAP≥72 分离下限把关），
##   指挥官阵列再后退 120——三档全场横向跨度最大 ≈ ±1170（96 档含指挥官），
##   观战缩放 0.75（缩放条 100% 档）可见半宽 1280px，整场一屏内可见。
##   开战先锋班下 ADVANCE_ALL（formation row/col 列阵）压至中线交战；后队班由编队动态
##   跟队（set_squad_follow_squad）锚定前队质心后方 gap 处，保持纵深推进、接战即还战斗；
##   前队全灭自动解除锚定转自主决策。接战后 FormationSystem 排长集火 +
##   兵种行为档案（冲脸/持阵/风筝）接管；排长阵亡该排失去集火但班仍执行规划器号令。
##
## 夺点模式（CAPTURE_ENABLED 默认开）：中线布 3 个夺点（左/中/右，y 错开），双方各一台
##   班级意图规划器（tactics SquadIntentPlanner，0.5s 节拍）按打分给每班选意图
##   （攻点/驻防/接火 + 惯性防抖）并翻译成 TacticalOrders 下发；到旗边先停驻观察
##   约 0.8s 再入场（Ravenfield"先看再进"）。夺点接手后开战推进/跟队锚定与 TeamAi
##   姿态号令全部让位（规划器独占号令权，防双脑互覆）。控制面板战况板加旗点状态行
##   （"旗：左我/中敌/右争夺"）。开关关闭 = 完整回退上面一段的旧开战逻辑。
##   规划器打分权重/风格表 = RL 搜索变量集（待实测校准），见 squad_intent_planner.gd。
##
## 相机（审计 P0-6）：camera_rig 保持启用（滚轮缩放/边界钳制/平滑全可用），
##   居中模式跟随"质心代理"（每帧 lerp）+ 开纵向跟随（rig 侧钳在行走带内）；
##   缩放 0.75（缩放条 100% 档）——3D 侧战场契约把地平线钉屏幕上 1/3 线，
##   地面恒占 2/3（HD-2D街景系统.md §4.1）。
##
## 热键：ESC 确认后回主菜单（DevSceneEscape 统一弹窗拦截）· R 重新开局 · 空格 暂停/继续（TimeManager 全局暂停）。

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _MainMenuScene := "res://modules/ui_global/scenes/menus/main_menu.tscn"
const _TacticalOrders := preload("res://modules/tactics/scripts/tactical_orders.gd")
## tactics 模块契约出口（夺点/意图规划器；跨模块 preload 走 api.gd 惯例）
const _TacticsAPI: GDScript = preload("res://modules/tactics/api.gd")

## 武器类型（对齐 WeaponMount.WeaponType：0 剑 1 矛 2 弓 3 镐 4 杖）
const W_SWORD: int = 0
const W_SPEAR: int = 1
const W_BOW: int = 2
const W_PICKAXE: int = 3
const W_STAFF: int = 4
const W_MERIC: int = 5

## 每方编制 rows 自前向后；front_x = 班最前排相对团队中心的 x，攻方朝 +x，
## advance_x = 该班推进目标相对中线的 x，**正值=越过中线（敌方向），负值=停在己方侧**；
## follow_gap > 0 = 锚定跟随前一班（编队动态跟队），不下推进号令）：
## 兵种射程 矛120 / 剑80 / 杖280（施法）/ 弓300 → 矛先锋卡线、火力压后。
## platoons = 班下标分组建排（排聚合层，2~3 班/排），每排任命排长（rank 2）。
## 纵深布阵（一屏收拢口径）：全部武器行按纵深行距 ROW_GAP=50 均匀收排——
## front_x 沿行序每行递减 50（跨班同口径），班结构只体现在编制层不体现在间距上。
##
## 对战预设（控制面板 1/2/3 切换，重开保持所选档位）：
const PRESETS: Array = [
	{
		"name": "遭遇战·16",
		"squads": [
			{
				"name": "矛兵班", "front_x": 150.0, "advance_x": 60.0, "follow_gap": 0.0,
				"rows": [{ "weapon": W_SPEAR, "count": 8 }],
			},
			{
				"name": "中坚火力班", "front_x": 100.0, "follow_gap": 150.0,
				"rows": [
					{ "weapon": W_SWORD, "count": 4 }, { "weapon": W_STAFF, "count": 1 },
					{ "weapon": W_BOW, "count": 2 }, { "weapon": W_MERIC, "count": 1 },
				],
			},
		],
		# 1 排 ×2 班（每班 8 人 = 16）
		"platoons": [[0, 1]],
	},
	{
		"name": "标准战役·48",
		"squads": [
			{
				"name": "矛兵班", "front_x": 150.0, "advance_x": 60.0, "follow_gap": 0.0,
				"rows": [{ "weapon": W_SPEAR, "count": 12 }],
			},
			{
				"name": "矛剑混编班", "front_x": 100.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SPEAR, "count": 4 }, { "weapon": W_SWORD, "count": 8 }],
			},
			{
				"name": "剑士班", "front_x": 0.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SWORD, "count": 12 }],
			},
			{
				"name": "火力班", "front_x": -50.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_STAFF, "count": 4 }, { "weapon": W_BOW, "count": 8 }],
			},
		],
		# 2 排 ×2 班（每班 12 人 = 48）
		"platoons": [[0, 1], [2, 3]],
	},
	{
		"name": "大军压境·96",
		"squads": [
			{
				"name": "矛兵一班", "front_x": 150.0, "advance_x": 60.0, "follow_gap": 0.0,
				"rows": [{ "weapon": W_SPEAR, "count": 12 }],
			},
			{
				"name": "矛兵二班", "front_x": 100.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SPEAR, "count": 12 }],
			},
			{
				"name": "矛剑混编班", "front_x": 50.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SPEAR, "count": 4 }, { "weapon": W_SWORD, "count": 8 }],
			},
			{
				"name": "剑士一班", "front_x": -50.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SWORD, "count": 12 }],
			},
			{
				"name": "剑士二班", "front_x": -100.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SWORD, "count": 12 }],
			},
			{
				"name": "剑士三班", "front_x": -150.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_SWORD, "count": 12 }],
			},
			{
				"name": "火力一班", "front_x": -200.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_STAFF, "count": 4 }, { "weapon": W_BOW, "count": 8 }],
			},
			{
				"name": "火力二班", "front_x": -300.0, "follow_gap": 150.0,
				"rows": [{ "weapon": W_STAFF, "count": 4 }, { "weapon": W_BOW, "count": 8 }],
			},
		],
		# 4 排 ×2 班（每班 12 人 = 96）：矛排 ｜ 混编+剑排 ｜ 剑排 ｜ 火排
		"platoons": [[0, 1], [2, 3], [4, 5], [6, 7]],
	},
]
## 当前预设下标（static：场景 reload 重开/切预设后保持所选档位）
static var _preset_idx: int = 1
## 纵深行距（px）：相邻武器行/班的 x 间距（一屏收拢口径，全预设统一 50 收排）。
## 取 STAGGER_X 同值——相邻行任意两员 Δx≥50 > 分离椭圆横半径 48
##（formation_spacing.SEPARARATION_RADIUS_X），纵距再近椭圆判别恒 >1、分离力
## 不激活；行内纵向间距由 MIN_ROW_GAP（≥纵深半径 72）把关。
##【提案/待定·待实测校准】
const ROW_GAP: float = 50.0
## 排内左右间距（px）
const LINE_GAP: float = 90.0
## 行内最小纵距（px，诊断 A1/B）：分离椭圆纵深半径（formation_spacing 72）——
## 行内自适应压缩的钳制下限。压穿它 = 分离力常驻 + 位置伺服极限环（移动单位
## 水平翻转 4.3~5.1 次/s、友邻纵距 43~57px 的根因）。【待实测校准】
const MIN_ROW_GAP: float = 72.0
## 奇偶错排横向错位（px，诊断 B）：一行按 MIN_ROW_GAP 放不下时改错排——相邻
## 单位 x 错开 ≥ 分离椭圆横向半径 48，Δx≥50 时任意纵距都不违反分离不变式
##（椭圆判别恒 >1），只须保同列纵距 ≥ MIN_ROW_GAP。【待实测校准】
const STAGGER_X: float = 50.0
## 左右两团出生中心 x 相对地图中线的偏移。一屏战场（创始人：战场范围限定在屏幕
## 一样大）：观战缩放 0.75（缩放条 100% 档）下可见半宽 = 1920/(2×0.75) = 1280px——
## ±700 出生 + 阵列纵深朝中线内收（96 档最末行 -350）+ 指挥官再后退 120，
## 全场横向跨度最大 ≈ ±1170（96 档含指挥官），整场一屏内可见。
##【提案/待定·待实测校准】
const TEAM_OFFSET_X: float = 700.0
## 编制预设 id（FormationSystem 加载自 config/formations/formation_presets.tres）
const SQUAD_PRESET := "fp_combat_squad"

## ── 夺点模式（开 = 意图规划器接管开战；关 = 完整回退旧 ADVANCE_ALL + 跟队逻辑）──
const CAPTURE_ENABLED: bool = true
## 夺点占领半径（px）【提案/待定·待实测校准】（RL v3 一屏口径 120；v2 战场是 180）
const CAPTURE_RADIUS: float = 120.0
## 相邻夺点横向间距（px，相对中线左右展开）【提案/待定·待实测校准】
##（一屏收拢 ±260；120 半径下相邻旗圈不重叠，v2 战场是 ±500）
const CAPTURE_X_SPREAD: float = 260.0
## 夺点纵向错开偏移（px，相对行走带中心）
const CAPTURE_Y_OFFSET: float = 200.0
## 纵向夹紧安全边距（px：点心离行走带上下沿至少此值，再取整十）
const CAPTURE_Y_MARGIN: float = 100.0
## 旗点状态行用方位标签（与布点顺序一一对应：左/中/右）
const CAPTURE_POINT_LABELS: Array = ["左", "中", "右"]

## ── 指挥官（斩首规则）：双方后方各 1 名，阵亡 = 该方立即战败 ──
const COMMANDER_ENABLED: bool = true
## 指挥官出生在本方阵列最末行再后退的纵深（px；一屏口径收紧——v2 战场 200，
## 阵列收拢后 120 即可脱离接战第一排；越界由实体地面约束钳到图缘）
##【提案/待定·待实测校准】
const COMMANDER_REAR_OFFSET: float = 120.0
## 指挥官出生 y 相对带中心的错开（px；避开编队出生带中位，防出生重叠遭分离推挤
## 把指挥官挤离留守位）
const COMMANDER_Y_OFFSET: float = 300.0
## 指挥官武器（佩剑；持旗视觉后议，机制先行）
const COMMANDER_WEAPON: int = W_SWORD

var _game_root: Node = null
var _left_alive_label: Label = null
var _right_alive_label: Label = null
const _TARGET_MAP := "battlefield"   # HD-2D 战场：观察场=真实生产观感（血条随骨架进 billboard）
	## （battlefield_2d 是自动化套件的 2D 空旷开机图，不承担观感）
var _hint_label: Label = null
## 旗点状态行（夺点模式；"旗：左我/中敌/右争夺"）
var _flag_label: Label = null
## 火力组计数行（"火：蓝 N / 红 M"——仍有存活成员的火力组数）
var _ft_label: Label = null
## 控制面板预设按钮组（下标对齐 PRESETS）
var _preset_buttons: Array = []
var _attacker: Array = []
var _defender: Array = []
## 夺点实例列表（tactics CapturePoint；布点顺序 = 左/中/右）
var _capture_points: Array = []
## 意图规划器（faction -> SquadIntentPlanner；夺点模式每方一台）
var _planners: Dictionary = {}
## 编队系统引用（单位快照 provider 取班号用）
var _arena_formation: Node = null
## 火力组 id 登记（faction -> ft_id 数组；HUD 火力组计数用）
var _arena_fireteams: Dictionary = {}
## 双方指挥官（faction -> 单位；斩首规则 HUD 消费）
var _arena_commanders: Dictionary = {}
## 相机跟随代理（camera_rig 居中模式目标；每帧 lerp 到存活质心）
var _cam_proxy: Marker2D = null
## 战斗开始后开启质心跟随
var _camera_following: bool = false
## 开场遮罩（防闪现主场景：GameRoot 先装配默认村图数帧才切 battlefield）
var _cover: ColorRect = null


func _ready() -> void:
	_build_cover()
	_game_root = _GameRootScene.instantiate()
	add_child(_game_root)
	_build_hud()
	_spawn_and_start.call_deferred()


func _spawn_and_start() -> void:
	# 战场图已退役自动刷敌（出征与领地架构 §4.3），本工具自行组织战斗，无幽灵战斗问题
	# 等启动序列走完（boot 阶段列表异步推进——死等帧数会撞在地图注册/首图
	# 装配完成前：轻则 load_map 静默失败遮罩不撤=黑屏，重则启动收尾把刚切的
	# 战场图顶掉）。_boot_world_phase 落 false = 世界就绪（覆盖层淡出点）。
	for i in 1800:   # ~30s 上限
		if _game_root.get("_boot_world_phase") == false and _game_root.get_current_map() != null:
			break
		await get_tree().process_frame
	var loader: Node = _game_root.get("scene_loader")
	# 切到空旷演练场（village 是玩家村，建筑/资源点干扰观察）
	if loader != null and loader.has_method("load_map"):
		loader.load_map(_TARGET_MAP)
		# 等新图装配（旧图延迟销毁，get_current_map 稳定到 battlefield 再继续）
		for i in 300:
			await get_tree().process_frame
			var m: Node2D = _game_root.get_current_map()
			if m != null and "battlefield" in str(m.scene_file_path):
				break
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		push_error("[Arena] 地图未加载")
		return
	# 清空地图自带单位（_on_map_loaded 刚 spawn 的玩家实体等）——
	# 演练场只保留自己刷的 96 个演练单位，保证观察画面纯净
	for e in map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 3:
		await get_tree().process_frame
	var mid_x: float = (map.map_left + map.map_right) * 0.5
	var spawn_y: float = map.ground_y + (map.ground_bottom - map.ground_y) * 0.5
	# 接管相机（审计 P0-6）：不停用 rig——滚轮缩放/边界钳制/平滑全保留；
	# 居中模式跟随"质心代理"；缩放让整场一屏内可见：一屏战场全宽最大 ≈2340px
	#（96 档 ±1170 含指挥官）< 0.75 缩放可见宽 2560px（1920/0.75），全宽入画
	var rig: Node = _game_root.get("camera_rig")
	if rig != null and rig.has_method("set_centered_mode"):
		rig.set_centered_mode(true)
		# 纵向贴住战场质心（rig 默认把视野下边界锚死 ground_bottom，混战线
		# 南漂时大军沉出屏幕下沿；RTS 观战开 Y 跟随，rig 侧带内钳制）
		if rig.has_method("set_follow_target_y"):
			rig.set_follow_target_y(true)
		# 缩放取 HD-2D 构图契约基准档 0.75（缩放条读 100%；设 1.0 会显示 133%
		# ——创始人 2026-09-16：观察场缩放条该是 100%；0.75 下可见半宽 1280
		# 覆盖一屏战场 ±1170，全宽可见无需再缩）
		if rig.has_method("set_user_zoom"):
			rig.set_user_zoom(0.75)
		_cam_proxy = Marker2D.new()
		_cam_proxy.name = "ArenaCamProxy"
		add_child(_cam_proxy)
		_cam_proxy.global_position = Vector2(mid_x, spawn_y)
		if rig.has_method("set_follow_target"):
			rig.set_follow_target(_cam_proxy)
		if rig.has_method("snap_to_follow_target"):
			rig.snap_to_follow_target()
	# 按编制分排出生（左攻右守，镜像）
	var squad_defs: Array = PRESETS[_preset_idx]["squads"]
	var squads_left: Array = []
	var squads_right: Array = []
	var fs: Node = _game_root.get_formation_system()
	for si in squad_defs.size():
		var def: Dictionary = squad_defs[si]
		var l_units: Array = []
		var r_units: Array = []
		var rows: Array = def["rows"]
		for ri in rows.size():
			var row: Dictionary = rows[ri]
			var x_off: float = float(def["front_x"]) - ri * ROW_GAP
			var count: int = int(row["count"])
			# 行内间距按行宽自适应压缩，但下限 = 分离椭圆纵深半径（MIN_ROW_GAP）：
			# 压缩穿底会把友邻纵距压到 43~57px < 72px → 分离力常驻 + 位置伺服极限环
			# （诊断 A1）。单排放不下改奇偶错排（相邻 x 错开 ≥ 椭圆横半径 48，纵距
			# 再近也不违反分离不变式），不再压间距。
			var half_span: float = (count - 1) * 0.5 * LINE_GAP
			var max_half: float = (map.ground_bottom - map.ground_y) * 0.5 - 40.0
			var staggered: bool = false
			var gap: float = LINE_GAP
			if half_span > max_half:
				var gap_single: float = (max_half * 2.0) / float(maxi(count - 1, 1))
				if gap_single >= MIN_ROW_GAP:
					gap = gap_single
				else:
					# 奇偶错排：纵距减半（同列间距 = 2×gap ≥ MIN_ROW_GAP），
					# 相邻同学横向错开 STAGGER_X
					staggered = true
					gap = clampf(gap_single, MIN_ROW_GAP * 0.5, LINE_GAP * 0.5)
			for k in count:
				var y: float = spawn_y + (float(k) - (count - 1) * 0.5) * gap
				# 错排横向偏移：偶数位 −STAGGER_X/2、奇数位 +STAGGER_X/2（相邻 Δx=50，
				# 阵列中线不动）；右军镜像取反保持两军点对称
				var stag_x: float = 0.0
				if staggered:
					stag_x = -STAGGER_X * 0.5 if k % 2 == 0 else STAGGER_X * 0.5
				var lt := _spawn_unit(map, Vector2(mid_x - TEAM_OFFSET_X + x_off + stag_x, y), int(row["weapon"]), fs)
				if lt != null:
					l_units.append(lt)
					_attacker.append(lt)
				var rt := _spawn_unit(map, Vector2(mid_x + TEAM_OFFSET_X - x_off - stag_x, y), int(row["weapon"]), fs)
				if rt != null:
					r_units.append(rt)
					_defender.append(rt)
		squads_left.append(l_units)
		squads_right.append(r_units)
		await get_tree().process_frame
	# 指挥官（斩首规则）：双方后方各 1 名——留守后方，不编班不下推进令，
	# 被近身自卫反击（行为层 LEASH 内迎击 + 避战豁免）；阵亡 = 斩首 =
	# 该方立即战败（BattleInstance.add_unit 自动扫描 rank 登记，进战斗前先 set_rank）。
	# 纵深随预设编成推导（多班纵深分排收拢后 96 档阵列深 ~500px，固定 rear 会把
	# 指挥官埋进队列中部挨打）——取最深一排再后退 COMMANDER_REAR_OFFSET。
	if COMMANDER_ENABLED:
		var rear_x: float = 0.0
		for si in squad_defs.size():
			var sdef: Dictionary = squad_defs[si]
			rear_x = minf(rear_x, float(sdef["front_x"]) - (float(sdef["rows"].size()) - 1.0) * ROW_GAP)
		rear_x -= COMMANDER_REAR_OFFSET
		# 图内钳制：站位 = |TEAM_OFFSET_X + rear_x|（rear_x 为负，两段相加），
		# 不得越过图缘贴边站——离图缘至少 500px。超深阵列推导触此限时，指挥官会
		# 落到阵列纵深中部（图幅不够的无解退化），属预设几何与图幅的匹配问题，
		# 归编制侧调预设纵深，不在此放大 offset 硬顶。
		var half_width: float = (map.map_right - map.map_left) * 0.5
		rear_x = maxf(rear_x, -(half_width - TEAM_OFFSET_X - 500.0))
		# y 相对带中心错开：编队出生带沿 y 展开占满中位区，同 y 出生会遭分离推挤
		var cmd_y: float = spawn_y + COMMANDER_Y_OFFSET
		var l_cmd := _spawn_unit(map, Vector2(mid_x - TEAM_OFFSET_X + rear_x, cmd_y), COMMANDER_WEAPON, fs)
		var r_cmd := _spawn_unit(map, Vector2(mid_x + TEAM_OFFSET_X - rear_x, cmd_y), COMMANDER_WEAPON, fs)
		if l_cmd != null:
			l_cmd.set_rank(3)
			_attacker.append(l_cmd)
			_arena_commanders[1] = l_cmd
		if r_cmd != null:
			r_cmd.set_rank(3)
			_defender.append(r_cmd)
			_arena_commanders[2] = r_cmd
	var battle: Node = _game_root.start_test_battle(_attacker, _defender)
	print("[Arena] 预设[%s] 战斗开始: battle=%s 左 %d 人 vs 右 %d 人" % [PRESETS[_preset_idx]["name"], battle, _attacker.size(), _defender.size()])
	# 开战自动暂停豁免（TimeManager._on_battle_started，game/auto_pause_battle 默认
	# true 会把全局时间置 PAUSED）：观察场要直接开演，自动恢复 X1；空格仍可手动暂停
	if TimeManager != null and TimeManager.is_paused():
		TimeManager.set_speed(TimeManager.Speed.X1)
	# 编队注入（审计 P1-1）：每方按预设建班（fp_combat_squad 预设）+ 任命班长——
	# 班长 rank 1，阵亡经组织侧补位免费无缝轮转
	var left_squad_ids: Array = []
	var right_squad_ids: Array = []
	for si in squad_defs.size():
		left_squad_ids.append(_make_squad(fs, squads_left[si], "%s·蓝" % squad_defs[si]["name"]))
		right_squad_ids.append(_make_squad(fs, squads_right[si], "%s·红" % squad_defs[si]["name"]))
	# 排聚合层编成（现实军衔体系重排）：按预设 platoons 分组建排 + 任命排长
	#（rank 2；排长 = 排内第一班的队首成员，班长取队列中位，两者不重合互不挤占）。
	# 排长阵亡 = 该排指挥链缺口（失去集火/光环），班照常执行规划器号令。
	for platoon_def_v in PRESETS[_preset_idx].get("platoons", []):
		var members: Array = platoon_def_v
		var l_ids: Array = []
		var r_ids: Array = []
		for mi in members.size():
			l_ids.append(left_squad_ids[int(members[mi])])
			r_ids.append(right_squad_ids[int(members[mi])])
		var _l_pid: String = _make_platoon(fs, l_ids, squads_left, members)
		var _r_pid: String = _make_platoon(fs, r_ids, squads_right, members)
	# 火力组编成（班内指挥分组，创始人编制口径）：每班劈一号/二号两组——组长 =
	# 组内首员无标记，火力组不拆散班聚结、不占军衔；号令通道已通（TacticalOrders
	# issue 对 ft_id 寻址）。军师规划器仍按班下令不动——细分是后续班长级 AI 的地基。
	_arena_fireteams = { 1: [], 2: [] }
	for si in squad_defs.size():
		_arena_fireteams[1].append_array(_make_fireteams(fs, left_squad_ids[si]))
		_arena_fireteams[2].append_array(_make_fireteams(fs, right_squad_ids[si]))
	# 开战推进接管权分流：夺点模式 = 意图规划器（布点 + 双方各一台，0.5s 节拍
	# 自主攻点/驻防/接火）；关闭 = 完整回退旧开战逻辑（下 else 分支，逐行原样）
	var to: Node = _game_root.get_tactical_orders()
	if CAPTURE_ENABLED:
		_setup_capture_mode(mid_x, spawn_y, map, fs, to, left_squad_ids, right_squad_ids)
		# 双脑仲裁：夺点模式号令权归规划器，TeamAi 姿态机让位（延迟到帧末——
		# BattleDirector 也是帧末才注册生产 TeamAi，本方排其后才能拿到实例）
		if battle != null:
			_suppress_team_ai.call_deferred(battle)
	else:
		# 回退路径（夺点关闭）：旧行为原样——先锋班单线 ADVANCE_ALL + 锚定班动态跟队
		if to != null and to.has_method("issue"):
			for si in squad_defs.size():
				var def: Dictionary = squad_defs[si]
				if float(def.get("follow_gap", 0.0)) > 0.0:
					continue  # 锚定班：剑班/火力班由动态跟队接管
				var adv_x: float = float(def["advance_x"])
				var lid: String = left_squad_ids[si]
				var rid: String = right_squad_ids[si]
				if not lid.is_empty():
					to.issue(_TacticalOrders.OrderType.ADVANCE_ALL, lid, Vector2(mid_x + adv_x, spawn_y), 0)
				if not rid.is_empty():
					to.issue(_TacticalOrders.OrderType.ADVANCE_ALL, rid, Vector2(mid_x - adv_x, spawn_y), 0)
		else:
			push_warning("[Arena] TacticalOrders 未就绪，编队前进跳过")
		# 编队动态跟队（SWL MoveInFormationBehindAnotherFormation + GapBetweenFormationGroups
		# 直译）：剑班锚矛班、火力班锚剑班，后队落点 = 前队质心 − 行进方向 × gap
		if fs != null and fs.has_method("set_squad_follow_squad"):
			for si in squad_defs.size():
				var gap: float = float(squad_defs[si].get("follow_gap", 0.0))
				if gap <= 0.0 or si == 0:
					continue
				fs.set_squad_follow_squad(left_squad_ids[si], left_squad_ids[si - 1], gap)
				fs.set_squad_follow_squad(right_squad_ids[si], right_squad_ids[si - 1], gap)
	# 收掉开局引导大卡（demo_quest 每次新装配都弹，屏幕正中挡观察 6 秒；
	# 观察场不看新手引导）
	var opening_hint: Node = get_tree().root.find_child("OpeningHint", true, false)
	if opening_hint != null:
		opening_hint.queue_free()
	_camera_following = true
	_reveal()


# ─────────────────────────────── 开场遮罩 ────────────────────────────────

## 全屏遮罩：盖住 GameRoot 装配默认村图 → 切 battlefield 之间的渲染帧，
## 否则进入演练场会先闪现一下游戏主场景（2026-08-31 观察场审计）
func _build_cover() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ArenaCover"
	layer.layer = 100
	add_child(layer)
	_cover = ColorRect.new()
	_cover.color = Color(0.05, 0.05, 0.05)
	_cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_cover)


## 演出就绪（战场已加载、相机已对位）后淡出揭幕
func _reveal() -> void:
	if _cover == null or not is_instance_valid(_cover):
		return
	var tw := create_tween()
	tw.tween_property(_cover, "modulate:a", 0.0, 0.4)
	tw.tween_callback(func() -> void:
		if is_instance_valid(_cover):
			_cover.get_parent().queue_free()
		_cover = null
	)


## 创建小队并任命班长（班长 = 队列中间成员，rank 1 由 formation 侧写入）。
## 返回 squad_id（失败返回 ""）。
func _make_squad(fs: Node, units: Array, squad_name: String) -> String:
	if fs == null or not is_instance_valid(fs) or units.is_empty():
		return ""
	var sid: String = ""
	if fs.has_method("create_squad"):
		sid = fs.create_squad(units, squad_name, SQUAD_PRESET)
	if sid.is_empty():
		return ""
	var leader: Node = units[units.size() / 2]
	if fs.has_method("assign_leader"):
		fs.assign_leader(sid, leader)
	return sid


## 建排并任命排长（排长 = 排内第一班的队首成员，rank 2 由 formation 侧写入；
## 班长固定取队列中位，队首 ≠ 中位，两职不重合）。返回 platoon_id（失败返回 ""）。
func _make_platoon(fs: Node, squad_ids: Array, squads_units: Array, squad_indices: Array) -> String:
	if fs == null or not is_instance_valid(fs) or squad_ids.is_empty():
		return ""
	if not fs.has_method("create_platoon"):
		return ""
	var pid: String = fs.create_platoon(squad_ids)
	if pid.is_empty():
		return ""
	var lead_units: Array = squads_units[int(squad_indices[0])]
	if not lead_units.is_empty() and fs.has_method("assign_platoon_leader"):
		fs.assign_platoon_leader(pid, lead_units[0])
	return pid


## 班劈两个火力组（创始人编制口径：一个班除班长外劈两个火力组）。
## 劈法：班长不入组（班 = 班长 + 两火力组），其余成员按**出生序对半劈**——
## 出生序 = 武器行主序（前排武器行在先、行内自南向北），前半 = 一号火力组
##（靠前接敌），后半 = 二号火力组（靠后火力支援），人数奇数时前半多一。
## 组长 = 组内首员（无标记不占军衔，formation 侧语义）。返回 ft_id 数组。
func _make_fireteams(fs: Node, squad_id: String) -> Array:
	if fs == null or not is_instance_valid(fs) or squad_id.is_empty():
		return []
	if not fs.has_method("create_fireteam"):
		return []
	var pool: Array = fs.get_squad_units(squad_id)
	var leader: Node = fs.get_squad_leader(squad_id)
	if leader != null and is_instance_valid(leader):
		pool.erase(leader)
	pool = pool.filter(func(u) -> bool: return is_instance_valid(u))
	if pool.is_empty():
		return []
	var half: int = int(ceil(pool.size() * 0.5))
	var ft_ids: Array = []
	var ft1: String = fs.create_fireteam(squad_id, pool.slice(0, half), "一号火力组")
	if not ft1.is_empty():
		ft_ids.append(ft1)
	if half < pool.size():
		var ft2: String = fs.create_fireteam(squad_id, pool.slice(half), "二号火力组")
		if not ft2.is_empty():
			ft_ids.append(ft2)
	return ft_ids


## 出生一个演练单位：脚部对齐 + 不附身 + 注入编队系统 + 设主手武器。
func _spawn_unit(map: Node2D, pos: Vector2, wtype: int, fs: Node) -> Node2D:
	var e: Node2D = map.spawn_entity(_StickmanScene, pos)
	if e == null:
		return null
	# 脚部对齐：HD-2D 图 origin 即视觉脚线（billboard 脚锚），不上移；
	# 2D 图 origin=髋、脚在 origin+foot_offset，仍需上移校正（口径同 world.InitialContent）
	if e.get("foot_offset") != null \
			and not (e.has_method("is_on_billboard_map") and e.is_on_billboard_map()):
		e.global_position.y = pos.y - e.foot_offset
	if e.has_method("set_possessed"):
		e.set_possessed(false)
	# 编队系统注入（审计 P1-1）：职责过滤/小队集火查询需要
	if fs != null and e.has_method("set_formation_system"):
		e.set_formation_system(fs)
	# 设主手武器类型（weapon_type 在 WeaponMount 上，重挂会同步 attack_range）
	var wm: Node = e.get_node_or_null("WeaponMount")
	if wm != null:
		wm.weapon_type = wtype
	# 防初始化竞态：hp 未就绪（<=0 会拖累战斗胜负判定）则自愈满血
	var hc = e.get("health_component")
	if hc != null and float(hc.get("hp")) <= 0.0:
		hc.set("hp", hc.get("max_hp"))
	return e


# ─────────────────────────────── 夺点模式 ────────────────────────────────

## 布夺点 + 装双方意图规划器（夺点模式开战逻辑）：三点横排中线、y 错开、行走带内
## 夹紧取整十；规划器接管开战推进——号令经 TacticalOrders 下发（AI 口径 tier=1），
## 单位数据经 provider 回传（tactics L2 零出向，本观察场是注入方）。
func _setup_capture_mode(mid_x: float, spawn_y: float, map: Node2D, fs: Node, to: Node,
		left_squad_ids: Array, right_squad_ids: Array) -> void:
	_arena_formation = fs
	var band_top: float = map.ground_y + CAPTURE_Y_MARGIN
	var band_bottom: float = map.ground_bottom - CAPTURE_Y_MARGIN
	var defs: Array = [
		{ "id": "capture_left", "pos": Vector2(mid_x - CAPTURE_X_SPREAD, spawn_y - CAPTURE_Y_OFFSET) },
		{ "id": "capture_center", "pos": Vector2(mid_x, spawn_y) },
		{ "id": "capture_right", "pos": Vector2(mid_x + CAPTURE_X_SPREAD, spawn_y + CAPTURE_Y_OFFSET) },
	]
	for d in defs:
		var pos: Vector2 = d["pos"]
		pos.y = snappedf(clampf(pos.y, band_top, band_bottom), 10.0)
		pos.x = snappedf(pos.x, 10.0)
		# CapturePoint 是 RefCounted（非 Node）：无类型注解承接，防赋值类型炸
		var point = _TacticsAPI.CapturePoint.new()
		point.setup(d["id"], pos, CAPTURE_RADIUS)
		point.capture_owner_changed.connect(_on_capture_owner_changed)
		_capture_points.append(point)
	# 双方各一台规划器；占领结算权归攻方那台（同局恰好一台，防双份积分——
	# 结算权纪律见 squad_intent_planner.gd 文件头）。规划器同为 RefCounted。
	var provider := Callable(self, "_capture_unit_snapshot")
	for side_v in [[1, left_squad_ids, true], [2, right_squad_ids, false]]:
		var side: Array = side_v
		var planner = _TacticsAPI.IntentPlanner.new()
		planner.setup(side[0], _capture_points, side[1], to, provider, side[2])
		_planners[side[0]] = planner


## 单位快照 provider（规划器每拍回调查询）：只交位置/阵营/班号值拷贝，
## 不交单位引用——tactics 侧零出向、无 freed 悬挂。
func _capture_unit_snapshot() -> Array:
	var snap: Array = []
	for u in _attacker + _defender:
		if not is_instance_valid(u) or u.is_dead():
			continue
		snap.append({
			"pos": u.global_position,
			"faction": u.get_faction() if u.has_method("get_faction") else 0,
			"squad_id": String(_arena_formation.get_unit_squad(u)) if _arena_formation != null else "",
		})
	return snap


## TeamAi 让位（夺点模式）：两方姿态机停发号令，号令权独归意图规划器。
## 帧末执行——BattleDirector 同帧帧末才注册生产 TeamAi，本调用排其后才拿得到实例。
func _suppress_team_ai(battle: Node) -> void:
	if battle == null or not is_instance_valid(battle) or not battle.has_method("get_team_ai"):
		return
	for f in [1, 2]:
		# TeamAi 是 RefCounted（非 Node）：无类型注解承接，防赋值类型炸
		var tai = battle.get_team_ai(f)
		if tai != null and tai.has_method("set_planner_suppressed"):
			tai.set_planner_suppressed(true)


## 夺点易主（CapturePoint 模块信号）：立即刷旗点状态行（不等 0.25s HUD 节流）。
func _on_capture_owner_changed(_point_id: String, _from_faction: int, _to_faction: int) -> void:
	_update_hud()


## 旗点状态行（格式「旗：左我/中敌/右争夺」；视角 = 蓝方/攻方）。
func _flag_status_text() -> String:
	if _capture_points.is_empty():
		return ""
	var parts: Array = []
	for pi in _capture_points.size():
		parts.append("%s%s" % [CAPTURE_POINT_LABELS[pi], _point_token(_capture_points[pi])])
	return "旗：%s" % "/".join(parts)


## 单点状态词：争夺（双方在场拉锯，或单方正夺进度中）/ 我 / 敌 / 中立。
## （point 为 CapturePoint，RefCounted——无类型注解鸭子调用）
func _point_token(point) -> String:
	if point.is_contested() or point.get_progress() > 0.0:
		return "争夺"
	match point.get_owner_faction():
		1:
			return "我"
		2:
			return "敌"
		_:
			return "中立"


## 火力组计数行（"火：蓝 N / 红 M"= 仍有存活成员的火力组数；未编组/编队系统
## 已随局清理 → 空串不占位）。
func _fireteam_status_text() -> String:
	if _arena_fireteams.is_empty() or _arena_formation == null or not is_instance_valid(_arena_formation):
		return ""
	if not _arena_formation.has_method("get_fireteam_units"):
		return ""
	var parts: Array = []
	for f in [1, 2]:
		var alive_fts: int = 0
		for ft_id_v in _arena_fireteams.get(f, []):
			var any_alive := false
			for u in _arena_formation.get_fireteam_units(String(ft_id_v)):
				if is_instance_valid(u) and not (u.has_method("is_dead") and u.is_dead()):
					any_alive = true
					break
			if any_alive:
				alive_fts += 1
		parts.append("%s %d" % ["蓝" if f == 1 else "红", alive_fts])
	return "火：%s / %s" % [parts[0], parts[1]]


func _process(delta: float) -> void:
	# HUD 存活计数节流 0.25s（战斗性能优化：每帧 O(n) 双列表扫描不参与观察）
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.25
		_update_hud()
	_update_camera(delta)
	# 夺点意图规划（每方一台；规划器内部 0.5s 节拍 + 暂停守卫，此处只喂帧 delta）
	for k in _planners:
		_planners[k].tick(delta)


## HUD 节流计时
var _hud_timer: float = 0.0


## 质心跟随（审计 P0-6：每帧 lerp 平滑，替代旧 0.5s 定时器硬切）
func _update_camera(delta: float) -> void:
	if not _camera_following or _cam_proxy == null:
		return
	var sum: Vector2 = Vector2.ZERO
	var n: int = 0
	for u in _attacker + _defender:
		if is_instance_valid(u) and not u.is_dead():
			sum += u.global_position
			n += 1
	if n > 0:
		var target: Vector2 = sum / float(n)
		_cam_proxy.global_position.x = lerpf(_cam_proxy.global_position.x, target.x, minf(1.0, 3.0 * delta))
		# 纵深也跟随（HD-2D 俯角把带深压扁 2.3 倍——只跟 X 时大军会沉在屏幕下沿）
		_cam_proxy.global_position.y = lerpf(_cam_proxy.global_position.y, target.y, minf(1.0, 3.0 * delta))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ESCAPE:
				get_tree().change_scene_to_file(_MainMenuScene)
			KEY_R:
				get_tree().reload_current_scene()
			KEY_SPACE:
				_toggle_pause()
			KEY_1, KEY_2, KEY_3:
				_switch_preset(int(event.keycode) - int(KEY_1))


## 切换对战预设并立即重开（static _preset_idx 跨 reload 保持所选档位）。
func _switch_preset(idx: int) -> void:
	if idx < 0 or idx >= PRESETS.size() or idx == _preset_idx:
		return
	_preset_idx = idx
	get_tree().reload_current_scene()


func _toggle_pause() -> void:
	if TimeManager == null:
		return
	if TimeManager.current_speed == TimeManager.Speed.PAUSED:
		TimeManager.set_speed(TimeManager.Speed.X1)
	else:
		TimeManager.set_speed(TimeManager.Speed.PAUSED)


# ─────────────────────────────── HUD ────────────────────────────────

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "ArenaHud"
	layer.layer = 50
	add_child(layer)
	# 主题容器：整层吃 StickTheme（手写字体 + Flat 兜底），别再裸 Label
	var ui_root := Control.new()
	ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.theme = StickTheme.create()
	layer.add_child(ui_root)
	# 左上战况板：手绘面板托底（浮在画面上不与场景亮部打架），token 字号
	var board := SketchPanel.new()
	board.tone = SketchPanel.Tone.LIGHT
	# 避让左上常驻的 debug 启动图例（约 y12-120）：从 y132 起
	board.position = Vector2(16, 132)
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(board)
	var board_v := VBoxContainer.new()
	board_v.add_theme_constant_override("separation", 4)
	board.add_child(board_v)
	_left_alive_label = _make_label(board_v, Vector2.ZERO, Color(0.55, 0.75, 1.0), StickTokens.FONT_HUD)
	_right_alive_label = _make_label(board_v, Vector2.ZERO, Color(1.0, 0.62, 0.55), StickTokens.FONT_HUD)
	_flag_label = _make_label(board_v, Vector2.ZERO, Color(0.92, 0.85, 0.5), StickTokens.FONT_HUD)
	_ft_label = _make_label(board_v, Vector2.ZERO, Color(0.75, 0.9, 0.75), StickTokens.FONT_HUD)
	_hint_label = _make_label(board_v, Vector2.ZERO, Color(0.8, 0.8, 0.8), StickTokens.FONT_HINT)
	_hint_label.text = "演练场：ESC 返回 · R 重开 · 1/2/3 换预设 · 空格 暂停 · 滚轮缩放"
	# 控制面板（底部居中）：对战预设按钮组 + 重开按钮——点按立即重开
	var panel := SketchPanel.new()
	panel.name = "ControlPanel"
	panel.tone = SketchPanel.Tone.LIGHT
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	panel.position.y -= 16.0
	layer.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	for pi in PRESETS.size():
		var btn := StickKit.sketch_button(row, "%d·%s" % [pi + 1, PRESETS[pi]["name"]],
				_switch_preset.bind(pi), StickKit.ButtonKind.NORMAL, 30.0)
		btn.toggle_mode = true
		_preset_buttons.append(btn)
	StickKit.sketch_button(row, "重开 (R)",
			func() -> void: get_tree().reload_current_scene(),
			StickKit.ButtonKind.NORMAL, 30.0)
	_refresh_preset_buttons()


## 预设按钮高亮态（当前档位按下锁定）
func _refresh_preset_buttons() -> void:
	for pi in _preset_buttons.size():
		var btn: Button = _preset_buttons[pi]
		btn.set_pressed_no_signal(pi == _preset_idx)
		btn.disabled = pi == _preset_idx


func _make_label(parent: Control, _pos: Vector2, color: Color, size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)
	return l


func _update_hud() -> void:
	if _left_alive_label == null:
		return
	# 旗点状态行（夺点模式；回退模式无点 → 空串不占位）
	if _flag_label != null:
		_flag_label.text = _flag_status_text()
	# 火力组计数行（仍有存活成员的组数；未编组 → 空串不占位）
	if _ft_label != null:
		_ft_label.text = _fireteam_status_text()
	# 部队尚未生成完（数组为空）不能判胜负——空集双 0 会误显示"战斗结束"
	if _attacker.is_empty() or _defender.is_empty():
		_left_alive_label.text = "蓝方（攻）集结中"
		_right_alive_label.text = "红方（守）集结中"
		_hint_label.text = "演练场：ESC 返回 · R 重开 · 1/2/3 换预设 · 空格 暂停 · 滚轮缩放"
		return
	var la := _count_alive(_attacker)
	var ra := _count_alive(_defender)
	_left_alive_label.text = "蓝方（攻）存活 %d / %d" % [la, _attacker.size()]
	_right_alive_label.text = "红方（守）存活 %d / %d" % [ra, _defender.size()]
	if la == 0 or ra == 0:
		_hint_label.text = "战斗结束：%s 获胜 —— R 重开 / 换预设" % ("蓝方" if ra == 0 else "红方")
	elif _commander_down_text() != "":
		# 斩首提示（指挥官阵亡 = 该方立即战败；结算由战斗实例斩首分支收束，
		# 存活数不清零 → 全灭文案不会出现，斩首文案常驻到重开）
		_hint_label.text = _commander_down_text()
	else:
		_hint_label.text = "演练场：ESC 返回 · R 重开 · 1/2/3 换预设 · 空格 暂停 · 滚轮缩放"


## 斩首提示文案（任一方指挥官阵亡返回提示；无指挥官/都活着返回空串）。
func _commander_down_text() -> String:
	if not COMMANDER_ENABLED or _arena_commanders.is_empty():
		return ""
	if _is_unit_down(_arena_commanders.get(1)):
		return "蓝方指挥官阵亡——斩首！红方获胜 —— R 重开"
	if _is_unit_down(_arena_commanders.get(2)):
		return "红方指挥官阵亡——斩首！蓝方获胜 —— R 重开"
	return ""


## 单位是否已阵亡（null/失效/死亡都算——指挥官不会凭空消失）。
func _is_unit_down(u) -> bool:
	return u == null or not is_instance_valid(u) \
			or (u.has_method("is_dead") and u.is_dead())


func _count_alive(units: Array) -> int:
	var n := 0
	for u in units:
		if is_instance_valid(u) and u.get("health_component") != null \
				and not u.health_component.is_dead():
			n += 1
	return n
