extends RefCounted
## 火柴人 LOD 分档助手 —— 从 stickman_entity 拆出的表现层性能分档子域。
##
## 职责：按 UnitLodDirector 下发的档位调整表现层频率/可见性（rig 动画频率、
## 血条频率与显隐）。只动表现层——物理与战斗逻辑不受影响：命中帧结算走 rig
## 播放位置轮询，节流后事件最多晚 1 个节拍、不丢失不重发。
## 死亡/接管优先于 LOD：死者不触碰（尸体血条语义由死亡收口权威管理），
## 接管单位恒近景全速（玩家视点所在身体）。
##
## 纪律：无自持状态，rig/_health_bar/user_controlled 全经 _entity 回引。

## 实体回引（构造注入；Node 不参与引用计数，无循环持有）
var _entity: Node = null


func _init(entity: Node) -> void:
	_entity = entity


# ─────────────────────────────── 档位常量 ────────────────────────────────
## 档位常量（与 UnitLodDirector.Tier 对齐；独立定义避免实体反向依赖 combat 侧）
const PERF_TIER_NEAR: int = 0   ## 近景：全速
const PERF_TIER_MID: int = 1    ## 中景：动画/叠加 15Hz、血条 10Hz
const PERF_TIER_FAR: int = 2    ## 远景/离屏：动画/叠加 5Hz、rig 与血条隐藏
## 各档更新频率（Hz；60 = 每帧全速，与未接入 LOD 时的行为等价）
const LOD_HZ_FULL: float = 60.0
const LOD_HZ_MID: float = 15.0
const LOD_HZ_FAR: float = 5.0
const LOD_HZ_BAR_MID: float = 10.0


## 设置性能档位（由 UnitLodDirector 按相机距离分档下发；无 director 时无人调用
## = 一切保持现行全速行为）。
## p_anim_hz：动画频率直传（hz 策略唯一真相源在 UnitLodDirector——T0 频率随
## 存活单位密度 60/30/20 自适应，T1/T2 固定 15/5）；<=0 = 未指定，按档位默认。
## 血条：T0 跟随动画频率、T1 固定 10Hz、T2 隐藏停更。
func set_perf_tier(tier: int, anim_hz: float = -1.0) -> void:
	if _entity.is_dead() or _entity.is_queued_for_deletion():
		return
	if _entity.user_controlled:
		tier = PERF_TIER_NEAR
	match tier:
		PERF_TIER_MID:
			_apply_perf_tier(true, anim_hz if anim_hz > 0.0 else LOD_HZ_MID, LOD_HZ_BAR_MID, true)
		PERF_TIER_FAR:
			_apply_perf_tier(false, anim_hz if anim_hz > 0.0 else LOD_HZ_FAR, 0.0, false)
		_:
			var hz: float = anim_hz if anim_hz > 0.0 else LOD_HZ_FULL
			_apply_perf_tier(true, hz, hz, true)


## 档位落点：rig 可见性/动画频率（rig 内部同步转发 ProceduralOverlay 同档节流）
## + 血条频率/显示。rig.visible 由 LOD 独占管辖（受击闪红走 modulate，不依赖 visible）；
## 小兵渲染代理模式下 rig 让位（CrowdRenderer 全权渲染，LOD 只管血条）。
func _apply_perf_tier(rig_visible: bool, anim_hz: float, bar_hz: float, bar_visible: bool) -> void:
	var rig: Node2D = _entity.rig
	if rig != null and is_instance_valid(rig) and not rig.is_crowd_proxied():
		rig.visible = rig_visible
		if rig.has_method("set_anim_update_hz"):
			rig.set_anim_update_hz(anim_hz)
	var bar: Node = _entity.get_health_bar()
	if bar != null and is_instance_valid(bar):
		if bar.has_method("set_update_hz"):
			bar.set_update_hz(bar_hz)
		if bar.has_method("set_display_visible"):
			bar.set_display_visible(bar_visible)
