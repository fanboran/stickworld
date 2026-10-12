extends Node
## 战斗演练场（观察用，非 CI 测试）：按预设双方各 16~96 人、多班多排按武器分排编队推进互殴。
##
## 用途：肉眼观察战斗画面自然度——编队推进/站姿/走姿/挥砍/受击/死亡/血条/阵营对抗。
## 入口：项目主场景（F5 直进）或主菜单「战斗演练」→「大乱斗观察场」。
## 控制面板（底部居中）：预设按钮（遭遇战·16 / 密度压力·48 / 极端压力·96，点按或
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
##   失去集火号令，到战斗结束无法补员（班长轮转不受影响）。
##   兵种结构落到班级：矛兵班（先锋，射程 120 卡线）→ 剑士班（中坚）→
##   火力班（杖+弓，射程 300 压制）。三档编成（"platoons" = 班下标分组建排）：
##     遭遇战·16 = 指挥官直统 2 班（矛兵班 8 + 中坚火力班 8；Tier0 小档不设
##       排长层，02 一-A.1）+ 阵地护卫 0 名（9v9 档口径）——设计观感标定主档
##     密度压力·48 = 2 排 ×2 班（矛 12 + 矛剑混编 12 ｜ 剑 12 + 火 12，4 班 ×12 人）
##       + 阵地护卫 2 名
##     极端压力·96 = 4 排 ×2 班（矛×2 ｜ 混编+剑 ｜ 剑×2 ｜ 火×2，8 班 ×12 人）
##       + 阵地护卫 3 名（96 档封存，仅作极端压力对照）
##   （观感验收默认档 = 16 = 设计口径「每侧最多十几二十几」；48/96 为密度/极端
##   压力档——高于设计标定 2~3 倍，观感问题可能被密度放大，验收对号入座）
##   一屏战场（创始人：战场范围限定在屏幕一样大）：出生中心 ±430、组方阵
##   出生（近战组/远程组各一个组级方阵，纵向铺满行动带）+ 指挥官后撤——三档
##   全场横向跨度最大 ≈ ±1170（96 档含指挥官），观战一屏内可见。
##   开战推进 = 战线（battle_line）：双方各一条，组方阵沿 x 连续推向敌阵、
##   接战即停/冻结、打完续推；纵深超上限的余部二线驻位待命。接战后
##   FormationSystem 排长集火 + 兵种行为档案（冲脸/持阵/风筝）接管；排长
##   阵亡该排失去集火但班仍执行规划器号令。
##
## 开战推进（夺点模式已退役，CAPTURE_ENABLED 默认关——夺点/旗/占领圈是 AI 线
##   自立的开发态模拟非游戏机制，创始人裁决整体下线；战斗输赢 = 全面战争式
##   全灭/撤离/超时，02 八-A）：战线推进（SWL Team.Attack + MoveInFormation
##   直译，battle_line.gd）——双方各一条战线，近战组/远程组各一个组级方阵沿 x
##   连续推进，接战即停/冻结，打完续推；未接战成员收随线号令（engage_in_range
##   敌进射程即战）。旧「先锋班 ADVANCE 压中线 + 跟队链」退役。
##   夺点规划器（SquadIntentPlanner）与其号令粘性（保持期/未完成续期/事件节流）
##   作为资产保留在 tactics 模块，正式宏观意图源接入时复用。
##
## 相机（审计 P0-6 + 批2 稳定锚）：camera_rig 保持启用（滚轮缩放/边界钳制/平滑
##   全可用），居中模式跟随"稳定锚代理"——锚 = 双方前线（修剪均值）的中点，
##   死区 + 限速（02 二-B #11 治理：质心代理死亡/换令即跳变 = 镜头级拉扯感）；
##   开纵向跟随（rig 侧钳在行走带内）；缩放 0.46 全景演示档（正常游玩 1.0，
##   验收快照双视角对照）——3D 侧战场契约把地面钉半屏高（地平线在屏幕中线），
##   地面恒占 2/3（HD-2D街景系统.md §4.1）。
##
## 热键：ESC 确认后回主菜单（DevSceneEscape 统一弹窗拦截）· R 重新开局 · 空格 暂停/继续（TimeManager 全局暂停）。

const _GameRootScene: PackedScene = preload("res://modules/world/scenes/game_root.tscn")
const _StickmanScene: PackedScene = preload("res://modules/units/scenes/stickman_entity.tscn")
const _MainMenuScene := "res://modules/ui_global/scenes/menus/main_menu.tscn"
const _TacticalOrders := preload("res://modules/tactics/scripts/tactical_orders.gd")
## tactics 模块契约出口（夺点/意图规划器资产；跨模块 preload 走 api.gd 惯例）
const _TacticsAPI: GDScript = preload("res://modules/tactics/api.gd")

## 武器类型（对齐 WeaponMount.WeaponType：0 剑 1 矛 2 弓 3 镐 4 杖）
const W_SWORD: int = 0
const W_SPEAR: int = 1
const W_BOW: int = 2
const W_PICKAXE: int = 3
const W_STAFF: int = 4
const W_MERIC: int = 5

## 每方编制 rows 自前向后；兵种射程 矛120 / 剑80 / 杖280（施法）/ 弓300 →
## 矛先锋卡线、火力压后。platoons = 班下标分组建排（排聚合层，2~3 班/排），
## 每排任命排长（rank 2）。出生位 = 战线组方阵槽位本位（近战组/远程组各一个
## 组级方阵，列高/槽深同 BattleLine 静态式——出生即成阵，无开战收拢走位）。
##
## 对战预设（控制面板 1/2/3 切换，重开保持所选档位）：
const PRESETS: Array = [
	{
		"name": "遭遇战·16",
		"squads": [
			{
				"name": "矛兵班",
				"rows": [{ "weapon": W_SPEAR, "count": 8 }],
			},
			{
				"name": "中坚火力班",
				"rows": [
					{ "weapon": W_SWORD, "count": 4 }, { "weapon": W_STAFF, "count": 1 },
					{ "weapon": W_BOW, "count": 2 }, { "weapon": W_MERIC, "count": 1 },
				],
			},
		],
		# Tier0 主档（02 二-A.1 小档不设排长层）：2 班编不足一排的规模由
		# 指挥官直接统班，不另设排长；阵地护卫 0 名（9v9 档口径）
		"guards": 0,
	},
	{
		"name": "密度压力·48",
		"squads": [
			{
				"name": "矛兵班",
				"rows": [{ "weapon": W_SPEAR, "count": 12 }],
			},
			{
				"name": "矛剑混编班",
				"rows": [{ "weapon": W_SPEAR, "count": 4 }, { "weapon": W_SWORD, "count": 8 }],
			},
			{
				"name": "剑士班",
				"rows": [{ "weapon": W_SWORD, "count": 12 }],
			},
			{
				"name": "火力班",
				"rows": [{ "weapon": W_STAFF, "count": 4 }, { "weapon": W_BOW, "count": 8 }],
			},
		],
		# 2 排 ×2 班（每班 12 人 = 48）；阵地护卫 2 名（人数多时两三个）
		"guards": 2,
		"platoons": [[0, 1], [2, 3]],
	},
	{
		"name": "极端压力·96",
		"squads": [
			{
				"name": "矛兵一班",
				"rows": [{ "weapon": W_SPEAR, "count": 12 }],
			},
			{
				"name": "矛兵二班",
				"rows": [{ "weapon": W_SPEAR, "count": 12 }],
			},
			{
				"name": "矛剑混编班",
				"rows": [{ "weapon": W_SPEAR, "count": 4 }, { "weapon": W_SWORD, "count": 8 }],
			},
			{
				"name": "剑士一班",
				"rows": [{ "weapon": W_SWORD, "count": 12 }],
			},
			{
				"name": "剑士二班",
				"rows": [{ "weapon": W_SWORD, "count": 12 }],
			},
			{
				"name": "剑士三班",
				"rows": [{ "weapon": W_SWORD, "count": 12 }],
			},
			{
				"name": "火力一班",
				"rows": [{ "weapon": W_STAFF, "count": 4 }, { "weapon": W_BOW, "count": 8 }],
			},
			{
				"name": "火力二班",
				"rows": [{ "weapon": W_STAFF, "count": 4 }, { "weapon": W_BOW, "count": 8 }],
			},
		],
		# 4 排 ×2 班（每班 12 人 = 96）：矛排 ｜ 混编+剑排 ｜ 剑排 ｜ 火排；
		# 阵地护卫 3 名（设计上限口径）
		"guards": 3,
		"platoons": [[0, 1], [2, 3], [4, 5], [6, 7]],
	},
]
## 当前预设下标（static：场景 reload 重开/切预设后保持所选档位）。
## 默认 0 = 遭遇战·16——观感验收主档对齐设计口径（02-战斗 二-A.1「每侧最多
## 十几二十几」，96 档封存；48/96 只作密度压力对照）
static var _preset_idx: int = 0
## 左右两团出生中心 x 相对地图中线的偏移。一屏战场（创始人两次定口径：地图 =
## 正常游玩缩放 1.0 下一屏，双方视野各半）：1.0 可见宽 1920px——出生 ±430 +
## 阵列纵深（48 档最前 150 最深 -100）+ 指挥官后撤，全场跨度 ≈ ±640，
## 整场在游玩视野内。
##【提案/待定·待实测校准】
const TEAM_OFFSET_X: float = 430.0
## 行动带半宽（px）：一屏战场的地面行动带半宽（见出生段注释）。
## 2026-10-12 底部空带治理（创始人点正「画面最底下的一片范围没有利用上」）：
## 360px 档实测（1080p/缩放 0.75）单位只占到地面 63%、底部空 200px——
## 半宽扩到 456px（19 格），配合带心下移，近排脚线落屏底 8% 余量内。
const ACTION_BAND_HALF_PX: float = 456.0
## ── 一屏战场竖直构图（02 二-A.2「半屏高」直给参数，z 从草远端 BF_HORIZON_Z 起算）──
## 地面占屏幕比例：0.5 = 地面占屏下 1/2、天空占上 1/2
const BF_GROUND_RATIO: float = 0.5
## 单位带中心（格）：可见地面 ≈51~68 格（随缩放档）；带心从 23 下移到 32
## 用满下半屏（旧 23 档带体 [8,38] 悬在可见地面上半，底部 1/3 空置——
## 创始人 2026-10-12 点正），前缘留 85-51≈余量防脚贴底沿。
const BF_UNIT_BAND_CENTER_Z: float = 32.0
## 单位带半径（格）= 行动带半宽 456px / 24
const BF_UNIT_BAND_HALF_Z: float = 19.0
## 编制预设 id（FormationSystem 加载自 config/formations/formation_presets.tres）
const SQUAD_PRESET := "fp_combat_squad"

## ── 夺点模式（已退役，默认关：夺点/旗/占领圈非游戏机制——创始人裁决下线；
## 开 = 旧夺点规划器接管开战〔RL/benchmark 资产调试用〕，关 = 推进+跟队开战）──
const CAPTURE_ENABLED: bool = false
## 夺点占领半径（px）【提案/待定·待实测校准】（RL v3 一屏口径 120；v2 战场是 180）
const CAPTURE_RADIUS: float = 120.0
## ── 旧夺点布点参数（随夺点退役仅存档于常量：RL/benchmark 调试开 CAPTURE_ENABLED
## 时消费；正式开战 = 推进+跟队，无点无旗）──
## 阵线点距中线（px）【提案/待定·待实测校准】
const CAPTURE_X_SPREAD: float = 480.0
## 后排点距中线（px，指挥官阵地前）【提案/待定·待实测校准】
const CAPTURE_REAR_X: float = 860.0
## 夺点纵向错开偏移（px，相对行走带中心；阵线上带/后旗下带 = 浅车道近似参差）
const CAPTURE_Y_OFFSET: float = 200.0
## 纵向夹紧安全边距（px：点心离行走带上下沿至少此值，再取整十）
const CAPTURE_Y_MARGIN: float = 100.0
## 旗点状态行用方位标签（与布点顺序一一对应：中线/蓝阵/红阵/蓝后排/红后排）
const CAPTURE_POINT_LABELS: Array = ["中线", "蓝阵", "红阵", "蓝后排", "红后排"]

## ── 战场指挥官（将领+卫队，全战式编制）：双方后方各 1 名留守 ──
const COMMANDER_ENABLED: bool = true
## 指挥官出生在本方阵列最末行再后退的纵深（px；一屏口径收紧——v2 战场 200，
## 阵列收拢后 120 即可脱离接战第一排；越界由实体地面约束钳到图缘）
##【提案/待定·待实测校准】（批2 拉大到 200：120px 在观战缩放 0.46 下仅 ~55px
## 屏距，指挥官+护卫小群与主力贴成一团辨不出「后方阵地」）
const COMMANDER_REAR_OFFSET: float = 200.0
## 指挥官出生 y 相对带中心的错开（px）。**0 = 居中**（创始人多次定口径居中；
## 旧 300 防挤参数已无必要——x 向已在阵列后 200+ 与主力天然错开）
const COMMANDER_Y_OFFSET: float = 0.0
## 指挥官武器（佩剑；持旗视觉后议，机制先行）
const COMMANDER_WEAPON: int = W_SWORD

## ── 阵地护卫（02 一-A.4：指挥前方阵地配 0~3 名，各档人数见 PRESETS guards）──
## 护卫守位行为面与指挥官同款（guard_post 职责：留守+LEASH 迎击+号令拦截），
## 不判任何全局胜负（rank 0 士兵）——守位判定口 StickmanEntity.holds_post()。
## 护卫相对指挥官的前向偏移（px，朝中线方向 = 指挥前方"阵地"）
##【提案/待定·待实测校准】
const GUARD_FORWARD_OFFSET: float = 90.0
## 多名护卫间纵向错开（px；≥分离纵半径防出生互推）
const GUARD_Y_STAGGER: float = 90.0
## 护卫武器（剑：近身自卫）
const GUARD_WEAPON: int = W_SWORD

## ── 相机稳定锚（批2，02 二-B #11：质心代理死亡/换令即跳变 → 稳定锚）──
## 锚 = 双方「前线」的中点。前线取修剪均值（朝敌方最前分位的存活单位均值）：
## 个别人死亡/逃兵的单点扰动被修剪分位吸收，锚只随战线整体推移而动。
## 前线修剪分位（每方取最前 25% 存活单位）【提案/待定·待实测校准】
const FRONT_QUANTILE: float = 0.25
## 锚点死区（px）：前线中点漂移不出此窗相机不动（滞回，防拉锯微动）
const ANCHOR_DEAD_ZONE: float = 60.0
## 锚点跟随速率（1/s，越小越缓）：镜头永远缓，不追瞬态（旧质心代理 3.0 的 40%）
const ANCHOR_SMOOTH: float = 1.2

var _game_root: Node = null
var _left_alive_label: Label = null
var _right_alive_label: Label = null
const _TARGET_MAP := "battlefield"
## 武器对照阵容模式（tools/dev/arena_shot_boot.tscn `-- --lineup`）：六兵种一排
## 站桩不开战——逐武器检查镜像挂接（握位/角度/盾位），战场观感工位件
static var lineup_mode := false   # HD-2D 战场：观察场=真实生产观感（血条随骨架进 billboard）
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
## 双方指挥官（faction -> 单位；HUD 阵亡提示用）
var _arena_commanders: Dictionary = {}
## 相机跟随代理（camera_rig 居中模式目标；缓动到稳定锚——前线中点）
var _cam_proxy: Marker2D = null
## 稳定锚目标（死区过滤后的双方前线中点；相机缓动终点）
var _cam_anchor: Vector2 = Vector2.ZERO
## 战斗开始后开启锚跟随
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
	# 观战机位：本工具只看不打，收起底部物品栏（观战者没有背包语境，物品栏
	# 只挡战场画面）。置位后 SystemSetup 装物品栏时会自动套用，故可先置。
	if _game_root.has_method("set_observer_view"):
		_game_root.set_observer_view(true)
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
	if lineup_mode:
		await _spawn_lineup()
		return
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
	# 单位带中心 = 构图参数（z 从草远端起算落回 2D y）——旧"资产带中点"在
	# 半屏构图里偏前（脚贴底沿）
	var spawn_y: float = map.ground_y + BF_UNIT_BAND_CENTER_Z * 24.0
	# 地面占比锚（半屏高直给）：草远端钉屏上 1/2 处——地面=屏下 1/2
	var hd: Node = map.get("_hd") if map.get("_hd") != null else null
	if hd != null and is_instance_valid(hd) and hd.has_method("set_bf_ground_ratio"):
		hd.set_bf_ground_ratio(BF_GROUND_RATIO)
	# 接管相机（审计 P0-6）：不停用 rig——滚轮缩放/边界钳制/平滑全保留；
	# 居中模式跟随"质心代理"；缩放让整场一屏内可见：一屏战场全宽最大 ≈2340px
	#（96 档 ±1170 含指挥官）< 0.75 缩放可见宽 2560px（1920/0.75），全宽入画
	var rig: Node = _game_root.get("camera_rig")
	# 垂直锁定 = 行动带正中（一屏战场终极口径：地图可走范围=视野，竖直取景
	# 恒钉死——地面零漂移、战场带居中半屏、脚永不出屏；旧 follow_target_y
	# 竖直跟随 + 1242 钳制带是旧大地图遗产，正是"全员沉底/脚出屏/地平线
	# 乱跳"三症状的同根）
	if rig != null and rig.has_method("set_vertical_lock"):
		rig.set_vertical_lock(spawn_y)
	# 一屏战场：小地图/相机边界 = 战场行动区（创始人口径：战场就只有视野这么大
	# ——地图资产 ±3072 是地图口径，若小地图显示整图，战场缩成中间一小段）
	var arena_left: float = mid_x - 720.0
	var arena_right: float = mid_x + 720.0
	if rig != null and rig.has_method("set_map_bounds"):
		rig.set_map_bounds(arena_left, arena_right)
	var minimap: Node = _game_root.get("_minimap")
	if minimap != null and is_instance_valid(minimap) and minimap.has_method("set_map_info"):
		minimap.set_map_info(arena_left, arena_right, map.ground_y, map.ground_ratio)
	if rig != null and rig.has_method("set_centered_mode"):
		rig.set_centered_mode(true)
		# 纵向贴住战场质心（rig 默认把视野下边界锚死 ground_bottom，混战线
		# 南漂时大军沉出屏幕下沿；RTS 观战开 Y 跟随，rig 侧带内钳制）
		if rig.has_method("set_follow_target_y"):
			rig.set_follow_target_y(true)
		# 一屏战场（创始人两次定口径：地图 = 正常游玩缩放一屏大，双方视野各半
		# ——全场即视野，不设全景档）：全程 1.0 游玩缩放
		if rig.has_method("set_user_zoom"):
			rig.set_user_zoom(1.0)
		_cam_proxy = Marker2D.new()
		_cam_proxy.name = "ArenaCamProxy"
		add_child(_cam_proxy)
		_cam_proxy.global_position = Vector2(mid_x, spawn_y)
		# 稳定锚初值 = 战场中心（双方对峙的中点即初始前线中点）
		_cam_anchor = Vector2(mid_x, spawn_y)
		if rig.has_method("set_follow_target"):
			rig.set_follow_target(_cam_proxy)
		if rig.has_method("snap_to_follow_target"):
			rig.snap_to_follow_target()
	# 按编制出生（左攻右守，镜像）——出生位 = 战线组方阵槽位本位（02 二-A.3
	# 「组方阵纵向铺满行动带」落码）：近战组/远程组各一个组级方阵，列高/槽深
	# 用 BattleLine 静态式（单一真相源），出生序 = 槽序 = 入线序——开局即成阵
	# 面向敌军，无收拢期倒走/横穿（旧按班行块出生与战线槽位两套几何，开战
	# 走位 transient = 「全员回头」根因之一）。祭司随远程组（SWL 层序 HEALERS
	# 后置，battle_line.add_unit 同口径）。
	var squad_defs: Array = PRESETS[_preset_idx]["squads"]
	var squads_left: Array = []
	var squads_right: Array = []
	var fs: Node = _game_root.get_formation_system()
	# 战场疏排档（创始人 2026-10-12 点正「出生点有些摆位本身就有点密」，#18
	# 「出场排面稀疏一档」再加档）：横距 140→170、列距 80→100（+21%/+25%）。
	# 只覆写战场编队几何——村居/劳作小队维持 FormationSpacing 默认档。
	fs.SPREAD_SPACING = 170.0
	fs.ROW_GAP = 100.0
	var melee_total: int = 0
	var ranged_total: int = 0
	for def in squad_defs:
		for row in def["rows"]:
			if int(row["weapon"]) in [W_BOW, W_STAFF, W_MERIC]:
				ranged_total += int(row["count"])
			else:
				melee_total += int(row["count"])
	var upc_m: int = BattleLine.group_upc(melee_total, ACTION_BAND_HALF_PX, fs.SPREAD_SPACING)
	var upc_r: int = BattleLine.group_upc(ranged_total, ACTION_BAND_HALF_PX, fs.SPREAD_SPACING)
	# 远程组出生基线 = 近战组全纵深 + GROUP_GAP（与 ranged_line_x 同式：开局
	# 远程恰好站进自己的随行槽位）
	var ranged_base_off: float = BattleLine.block_depth(melee_total, upc_m, fs.ROW_GAP) \
			+ BattleLine.GROUP_GAP
	var ranged_depth: float = BattleLine.block_depth(ranged_total, upc_r, fs.ROW_GAP)
	var line_x0_l: float = mid_x - TEAM_OFFSET_X + 150.0
	var line_x0_r: float = mid_x + TEAM_OFFSET_X - 150.0
	var melee_idx: int = 0
	var ranged_idx: int = 0
	for si in squad_defs.size():
		var def: Dictionary = squad_defs[si]
		var l_units: Array = []
		var r_units: Array = []
		var rows: Array = def["rows"]
		for row in rows:
			var ranged_grp: bool = int(row["weapon"]) in [W_BOW, W_STAFF, W_MERIC]
			for _k in int(row["count"]):
				var idx: int = ranged_idx if ranged_grp else melee_idx
				var upc: int = upc_r if ranged_grp else upc_m
				var slot := Vector2i(floori(float(idx) / float(upc)), idx % upc)
				var lateral: float = (float(slot.y) - float(upc - 1) * 0.5) * fs.SPREAD_SPACING
				var depth: float = BattleLine.rank_depth(slot.x, fs.ROW_GAP) \
						+ (ranged_base_off if ranged_grp else 0.0)
				var y: float = spawn_y + lateral
				# 左军面向 +x：后列向自方退（−depth）；右军镜像（+depth）
				var lt := _spawn_unit(map, Vector2(line_x0_l - depth, y), int(row["weapon"]), fs, 1)
				if lt != null:
					l_units.append(lt)
					_attacker.append(lt)
				var rt := _spawn_unit(map, Vector2(line_x0_r + depth, y), int(row["weapon"]), fs, -1)
				if rt != null:
					r_units.append(rt)
					_defender.append(rt)
				if ranged_grp:
					ranged_idx += 1
				else:
					melee_idx += 1
		squads_left.append(l_units)
		squads_right.append(r_units)
		await get_tree().process_frame
	# 战场指挥官（将领，全战式编制）：双方后方各 1 名——留守后方，不编班不下
	# 推进令，被近身自卫反击（行为层 LEASH 内迎击 + 避战豁免）。阵亡不判负
	# （旧"斩首即败"已退役）：他是纪律线打击因子（01-组织系统 §3.1，纪律线
	# 后续批次实装），战斗仍打到全灭/撤离/超时收束。
	# 站位从实际出生阵形推导（近战块 + 远程随行距 + 远程块全纵深再后退
	# COMMANDER_REAR_OFFSET——旧按班行结构推后排，与组方阵出生几何脱节）。
	if COMMANDER_ENABLED:
		var rear_off: float = ranged_base_off + ranged_depth + COMMANDER_REAR_OFFSET
		# 图内钳制：站位 = |TEAM_OFFSET_X + rear_off|（rear_off 为正深），不得越过
		# 图缘贴边站——离图缘至少 500px。超深阵形触此限时指挥官会落到阵列纵深
		# 中部（图幅不够的无解退化），属编制与图幅的匹配问题，不在此放大
		# offset 硬顶。
		var half_width: float = (map.map_right - map.map_left) * 0.5
		rear_off = minf(rear_off, half_width - TEAM_OFFSET_X - 500.0)
		# y 相对带中心错开：编队出生带沿 y 展开占满中位区，同 y 出生会遭分离推挤
		var cmd_y: float = spawn_y + COMMANDER_Y_OFFSET
		var l_cmd := _spawn_unit(map, Vector2(mid_x - TEAM_OFFSET_X - rear_off, cmd_y), COMMANDER_WEAPON, fs, 1)
		var r_cmd := _spawn_unit(map, Vector2(mid_x + TEAM_OFFSET_X + rear_off, cmd_y), COMMANDER_WEAPON, fs, -1)
		if l_cmd != null:
			l_cmd.set_rank(3)
			_attacker.append(l_cmd)
			_arena_commanders[1] = l_cmd
		if r_cmd != null:
			r_cmd.set_rank(3)
			_defender.append(r_cmd)
			_arena_commanders[2] = r_cmd
		# 阵地护卫（02 一-A.4）：指挥官前方（阵地）配 0~3 名——守位行为面同指挥官
		#（guard_post：留守+LEASH 迎击+号令拦截），不判任何全局胜负（rank 0 士兵）。
		# 站位 = 指挥官前向 GUARD_FORWARD_OFFSET（阵地），多名时纵向对称错开
		# GUARD_Y_STAGGER（≥分离纵半径，防出生互推）。
		var guards_n: int = int(PRESETS[_preset_idx].get("guards", 0))
		for gi in guards_n:
			var g_y: float = cmd_y + (float(gi) - float(guards_n - 1) * 0.5) * GUARD_Y_STAGGER
			var l_guard := _spawn_unit(map, Vector2(mid_x - TEAM_OFFSET_X - rear_off + GUARD_FORWARD_OFFSET, g_y), GUARD_WEAPON, fs, 1)
			var r_guard := _spawn_unit(map, Vector2(mid_x + TEAM_OFFSET_X + rear_off - GUARD_FORWARD_OFFSET, g_y), GUARD_WEAPON, fs, -1)
			if l_guard != null:
				l_guard.set("guard_post", true)
				_attacker.append(l_guard)
			if r_guard != null:
				r_guard.set("guard_post", true)
				_defender.append(r_guard)
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
		# 战线推进（SWL Team.Attack + MoveInFormation 直译）：双方各一条战线——
		# 近战组/远程组各一个组级方阵，前列贴线连续推进，接战即停/冻结，打完续推；
		# 未接战成员收随线号令（engage_in_range 敌进射程即战）。
		# 旧「先锋班 ADVANCE 压中线 + 跟队链」退役（班各为阵 = 全军挤中间的根因）。
		if fs != null and fs.has_method("create_battle_line"):
			var goal_l: float = mid_x + TEAM_OFFSET_X + 150.0
			var goal_r: float = mid_x - TEAM_OFFSET_X - 150.0
			var line_l: RefCounted = fs.create_battle_line(1, 1, goal_l,
					mid_x - TEAM_OFFSET_X + 150.0, spawn_y, ACTION_BAND_HALF_PX)
			var line_r: RefCounted = fs.create_battle_line(2, -1, goal_r,
					mid_x + TEAM_OFFSET_X - 150.0, spawn_y, ACTION_BAND_HALF_PX)
			# 个性 y 漂移种子：按战斗 id 派生（同战斗可复现、跨战斗不同相）
			if line_l != null and line_l.has_method("seed_drift"):
				line_l.seed_drift(hash("arena%d_1" % (battle.get_battle_id().hash() if battle != null and battle.has_method("get_battle_id") else 0)))
			if line_r != null and line_r.has_method("seed_drift"):
				line_r.seed_drift(hash("arena%d_2" % (battle.get_battle_id().hash() if battle != null and battle.has_method("get_battle_id") else 0)))
			for u in _attacker:
				if u != null and is_instance_valid(u) and not _holds_post(u):
					line_l.add_unit(u)
			for u in _defender:
				if u != null and is_instance_valid(u) and not _holds_post(u):
					line_r.add_unit(u)
			print("[Arena] 战线就绪: 蓝 goal=%.0f / 红 goal=%.0f" % [goal_l, goal_r])
		else:
			push_warning("[Arena] FormationSystem 无战线 API，推进跳过")
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
## 守位单位判定（指挥官 rank 3 / 阵地护卫 guard_post）：留守后方不随战线推进
func _holds_post(u: Node) -> bool:
	return u.has_method("holds_post") and u.holds_post()


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
## 武器对照阵容：六兵种一排站桩（间距拉开互不遮挡），不开战不编队——
## 截图逐武器检查镜像挂接（握点落手骨/角度/盾位）
func _spawn_lineup() -> void:
	for i in 1800:
		if _game_root.get("_boot_world_phase") == false and _game_root.get_current_map() != null:
			break
		await get_tree().process_frame
	var loader: Node = _game_root.get("scene_loader")
	if loader != null and loader.has_method("load_map"):
		loader.load_map(_TARGET_MAP)
	for i in 300:
		await get_tree().process_frame
		var m: Node2D = _game_root.get_current_map()
		if m != null and "battlefield" in str(m.scene_file_path):
			break
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		push_error("[Arena] lineup: 地图未加载")
		return
	for e in map.get_entities():
		if is_instance_valid(e):
			e.queue_free()
	for i in 3:
		await get_tree().process_frame
	var mid_x: float = (map.map_left + map.map_right) * 0.5
	# 3D 视野垂直锚死地平线（z=0 在屏幕中线），2D 相机 Y 不改 3D 取景——
	# lineup 行必须落在可见 z 带内：战场 z=(y-516)/24，取 z=28 格（地面中段
	# 稍靠前，脚下留出生长空间，不贴 UI 底栏）
	var row_y: float = 516.0 + 28.0 * 24.0
	var types: Array = [
		["剑士", 0], ["矛士", 1], ["弓手", 2], ["矿工", 3], ["法师", 4], ["祭司", 5],
	]
	for i in types.size():
		var pos := Vector2(mid_x + (i - (types.size() - 1) * 0.5) * 200.0, row_y)
		var e: Node2D = _spawn_unit(map, pos, int(types[i][1]), null)
		if e != null:
			e.add_to_group("arena_lineup")
	# 相机对准阵容（挂杆检查要看清握点）：居中模式 + 代理钉阵容中点 + 贴近缩放
	var rig: Node = _game_root.get("camera_rig")
	if _cam_proxy == null or not is_instance_valid(_cam_proxy):
		_cam_proxy = Marker2D.new()
		_cam_proxy.name = "ArenaCamProxy"
		add_child(_cam_proxy)
	_cam_proxy.global_position = Vector2(mid_x, row_y)
	# 居中模式 + follow_target_y（纵向贴住代理）——相机纵向默认钉 ground_bottom，
	# 不开 follow_target_y 会停在出生带而看不到阵容
	if rig != null:
		if rig.has_method("set_centered_mode"):
			rig.set_centered_mode(true)
		if rig.has_method("set_follow_target_y"):
			rig.set_follow_target_y(true)
		if rig.has_method("set_follow_target"):
			rig.set_follow_target(_cam_proxy)
		if rig.has_method("snap_to_follow_target"):
			rig.snap_to_follow_target()
		# 不覆盖缩放：保持 0.75 契约档（与实战同取景，阵容才落在可见 z 带内）
	_camera_following = true
	_reveal()
	await get_tree().create_timer(1.0).timeout
	var cam2d := get_viewport().get_camera_2d()
	var first := map.get_tree().get_first_node_in_group("arena_lineup")
	print("[Arena] 武器对照阵容就绪：6 兵种 @ y=%d" % int(row_y))
	if cam2d != null:
		print("[Arena]   cam2d=%s zoom=%s" % [cam2d.global_position, cam2d.zoom])
	if first != null:
		print("[Arena]   first_unit=%s hp_ok=%s" % [first.global_position, first.get("health_component") != null])
	else:
		print("[Arena]   first_unit=null（分组后已丢？）")


## 出生一个演练单位：脚部对齐 + 不附身 + 注入编队系统 + 设主手武器 + 开局朝向。
## face ±1 = 按阵营面向敌军（右军默认朝 +x 背对敌人 = 开战全员回头的半个根因；
## 出生首翻不受节流限，try_set_facing 直放行）；0 = 不设（lineup 站桩等）。
func _spawn_unit(map: Node2D, pos: Vector2, wtype: int, fs: Node, face: int = 0) -> Node2D:
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
	# 开局朝向：先于一切行为/移动意图落定（战列对峙的第一眼）
	if face != 0 and e.has_method("try_set_facing"):
		e.try_set_facing(face)
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

## 旧夺点模式开战逻辑（CAPTURE_ENABLED=true 时走：RL/benchmark 调试资产）：
## 布五个抽象点 + 装双方意图规划器，号令经 TacticalOrders 下发（AI 口径 tier=1），
## 单位数据经 provider 回传（tactics L2 零出向，本观察场是注入方）。默认关。
func _setup_capture_mode(mid_x: float, spawn_y: float, map: Node2D, fs: Node, to: Node,
		left_squad_ids: Array, right_squad_ids: Array) -> void:
	_arena_formation = fs
	var band_top: float = map.ground_y + CAPTURE_Y_MARGIN
	var band_bottom: float = map.ground_bottom - CAPTURE_Y_MARGIN
	## owner 初始归属：0 中立 / 1 蓝（左=攻方）/ 2 红（右=守方）
	var defs: Array = [
		{ "id": "mid_line", "owner": 0, "pos": Vector2(mid_x, spawn_y) },
		{ "id": "blue_line", "owner": 1, "pos": Vector2(mid_x - CAPTURE_X_SPREAD, spawn_y - CAPTURE_Y_OFFSET) },
		{ "id": "red_line", "owner": 2, "pos": Vector2(mid_x + CAPTURE_X_SPREAD, spawn_y - CAPTURE_Y_OFFSET) },
		{ "id": "blue_rear", "owner": 1, "pos": Vector2(mid_x - CAPTURE_REAR_X, spawn_y + CAPTURE_Y_OFFSET) },
		{ "id": "red_rear", "owner": 2, "pos": Vector2(mid_x + CAPTURE_REAR_X, spawn_y + CAPTURE_Y_OFFSET) },
	]
	for d in defs:
		var pos: Vector2 = d["pos"]
		pos.y = snappedf(clampf(pos.y, band_top, band_bottom), 10.0)
		pos.x = snappedf(pos.x, 10.0)
		# CapturePoint 是 RefCounted（非 Node）：无类型注解承接，防赋值类型炸
		var point = _TacticsAPI.CapturePoint.new()
		point.setup(d["id"], pos, CAPTURE_RADIUS, int(d["owner"]))
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


## 可走域看门狗（一屏战场执法）：单位位置每帧钳在视野行动区内——
## 地图=视野（创始人口径），任何原因（分离推挤/追击/风筝）出界立即拉回，
## 脚出屏在几何上不可能。【钳制域=出生域+追击余量，非硬贴边】
const ARENA_X_HALF: float = 700.0
## 可走域 y = 单位带 ± 60px 余量（追击/分离出界拉回；带本身在可见地面内，
## 脚出屏几何不可能）
const ARENA_Y_MARGIN: float = 60.0


func _clamp_units_into_view() -> void:
	var map: Node2D = _game_root.get_current_map()
	if map == null:
		return
	var mid_x: float = (map.map_left + map.map_right) * 0.5
	var y_top: float = map.ground_y + (BF_UNIT_BAND_CENTER_Z - BF_UNIT_BAND_HALF_Z) * 24.0 - ARENA_Y_MARGIN
	var y_bottom: float = map.ground_y + (BF_UNIT_BAND_CENTER_Z + BF_UNIT_BAND_HALF_Z) * 24.0 + ARENA_Y_MARGIN
	for u in _attacker + _defender:
		if not is_instance_valid(u):
			continue
		var p: Vector2 = u.global_position
		var cy: float = clampf(p.y, y_top, y_bottom)
		var cx: float = clampf(p.x, mid_x - ARENA_X_HALF, mid_x + ARENA_X_HALF)
		if cx != p.x or cy != p.y:
			u.global_position = Vector2(cx, cy)


func _process(delta: float) -> void:
	# HUD 存活计数节流 0.25s（战斗性能优化：每帧 O(n) 双列表扫描不参与观察）
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.25
		_update_hud()
	_clamp_units_into_view()
	_update_camera(delta)
	# 夺点意图规划（每方一台；规划器内部 0.5s 节拍 + 暂停守卫，此处只喂帧 delta）
	for k in _planners:
		_planners[k].tick(delta)


## HUD 节流计时
var _hud_timer: float = 0.0


## 质心跟随（审计 P0-6：每帧 lerp 平滑，替代旧 0.5s 定时器硬切）
## 相机稳定锚（批2，02 二-B #11 治理）：锚 = 双方前线（修剪均值）的中点。
## 治理对象 = 旧质心代理的镜头级拉扯（死亡/换令的瞬时质心跳变、全班同帧改向的
## 摆动）——修剪分位 + 死区 + 限速三层吸收，镜头只随战线整体推移缓慢平移。
func _update_camera(delta: float) -> void:
	if not _camera_following or _cam_proxy == null:
		return
	var front_l: Variant = _front_line(_attacker, 1.0)
	var front_r: Variant = _front_line(_defender, -1.0)
	# 一方全灭（前线无解）= 战斗将收束，保持末锚不动
	if front_l == null or front_r == null:
		return
	var anchor: Vector2 = ((front_l as Vector2) + (front_r as Vector2)) * 0.5
	# 死区（滞回）：锚漂移不出窗不更新目标——战线小幅拉锯镜头纹丝不动
	if absf(anchor.x - _cam_anchor.x) > ANCHOR_DEAD_ZONE:
		_cam_anchor.x = anchor.x
	if absf(anchor.y - _cam_anchor.y) > ANCHOR_DEAD_ZONE:
		_cam_anchor.y = anchor.y
	var k: float = minf(1.0, ANCHOR_SMOOTH * delta)
	var cur: Vector2 = _cam_proxy.global_position
	_cam_proxy.global_position = Vector2(
		lerpf(cur.x, _cam_anchor.x, k),
		lerpf(cur.y, _cam_anchor.y, k))


## 单方前线（修剪均值）：朝敌方最前 FRONT_QUANTILE 分位存活单位的位置均值。
## 修剪均值抗单点扰动——个别人死亡/逃兵不动前线，成建制推进/后撤才动。
## dir = 敌方方向符号（攻方 +1 = x 大者为前；守方 -1 = x 小者为前）。
## 无存活单位返回 null（全灭信号）。
func _front_line(units: Array, dir: float) -> Variant:
	var alive: Array = []
	for u in units:
		if is_instance_valid(u) and not u.is_dead():
			alive.append(u.global_position)
	if alive.is_empty():
		return null
	alive.sort_custom(func(a: Vector2, b: Vector2) -> bool:
		return a.x * dir > b.x * dir)
	var take: int = maxi(1, int(ceilf(alive.size() * FRONT_QUANTILE)))
	var sum: Vector2 = Vector2.ZERO
	for i in take:
		sum += alive[i]
	return sum / float(take)


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
		# 指挥官阵亡战况提示（不判负——战斗照常收束，纪律线因子）
		_hint_label.text = _commander_down_text()
	else:
		_hint_label.text = "演练场：ESC 返回 · R 重开 · 1/2/3 换预设 · 空格 暂停 · 滚轮缩放"


## 指挥官阵亡提示文案（不判负——纪律线因子，战斗继续；只做战况提示）。
func _commander_down_text() -> String:
	if not COMMANDER_ENABLED or _arena_commanders.is_empty():
		return ""
	if _is_unit_down(_arena_commanders.get(1)):
		return "蓝方指挥官阵亡（军心动摇）"
	if _is_unit_down(_arena_commanders.get(2)):
		return "红方指挥官阵亡（军心动摇）"
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
