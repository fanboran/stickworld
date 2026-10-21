class_name WeaponAnimSfxBridge
extends Node
## 武器动画音效桥 —— 把"动画命中帧"接到 SFX_EVENTS 上，补 Spine 源的数据缺口。
##
## 背景（docs/技术/音频/音效触发规范.md §10.3/§12.2）：attack_bow / attack_pickaxe
## 的动画元数据里没有 Sound 事件（`sound_events = []`，不是被过滤，是 Spine 源
## 就没写）。正确的补法是改 Spine 源后重跑 spine_import（忠实直译管线）；
## 在那之前，弓射击与镐敲击完全无声。
##
## 本桥的职责：订阅 WeaponMount 的公共信号 `weapon_anim_event`（动画内嵌事件转发，
## 模块对外契约，零 units 模块改动），把"攻击动画的 Hit 命中帧"映射到
## AudioManager.play_event——播放策略（节流/合并/声部预算/定位）全部沿用
## SFX_POLICY 表驱动，调用侧不自带任何限流（触发规范 §六.4）。
##
## 为什么挂在 Hit 而不是等 Sound 数据：Hit@0.5333（弓放箭）与 Hit@0.6667（镐触石）
## 就是放弦/触石的时刻，与放箭计时（BOW_FIRE_DELAY）同帧，时序天然对齐。
##
## 与数据侧真相源的关系（自愈）：映射只对"Spine 源尚无 Sound 数据"的动画生效——
## 每次触发先查动画元数据里有没有 Sound 事件（rigless 直读 .tres），有则让位。
## 因此将来 Spine 源补上 Sound 后本桥**自动静默**，届时删掉映射表条目即可，
## 不会出现双发声。改动记录见 docs/项目/待办/音效触发尾巴.md。
##
## 已知边界（【提案/待定】听感验收）：玩家手动放箭（release_player_shot）箭在
## 松手瞬间离弦，而释放段动画的 Hit 在 0.5333s——音效比箭晚约 0.5s（AI 路径
## 放箭计时与 Hit 同帧，无此问题）。修齐需动 entity_user_control 链，归接管重构。
## 空挥（无目标出招）也会响一声"触石"——AI 出手前有距离门禁，空挥罕见，可接受。

## stick_rig 动画库（rigless 事件直读；L3 装配层经 stick_rig/api.gd 契约取用）
const Anims := preload("res://modules/stick_rig/api.gd").ANIMS_SCRIPT

## 攻击动画名 → SFX 事件键。**只列 Spine 源缺 Sound 数据的攻击动画**：
## - 弓：释放段（WEAPON_ATTACK_ANIM[BOW]）+ 全条对照动画（保留作回退），Hit = 放箭帧
## - 镐：Hit = 触石帧
## 剑/矛/杖的 Sound 数据在册（attack/attack_spear/attack_staff 的 Swoosh/MagikillBlast），
## 由 WeaponMount 自己播，不进本表——重复映射会同帧双发声。
const HIT_SFX: Dictionary = {
	"attack_bow_release": "weapon_bow_fire",
	"attack_bow":         "weapon_bow_fire",
	"attack_pickaxe":     "weapon_pick_hit",
}


func _ready() -> void:
	# WeaponMount 是逐单位子节点，随实体 spawn 进树——挂树级 node_added 逐个发现
	get_tree().node_added.connect(_on_node_added)


func _exit_tree() -> void:
	var tree := get_tree()
	if tree != null and tree.node_added.is_connected(_on_node_added):
		tree.node_added.disconnect(_on_node_added)


## 树级发现：带 weapon_anim_event 公共信号的节点（WeaponMount）即订阅。
## 连接随挂载点释放自动断开，这里不持有任何引用。
func _on_node_added(node: Node) -> void:
	if not node.has_signal("weapon_anim_event"):
		return
	if not node.is_connected("weapon_anim_event", _on_weapon_anim_event):
		node.connect("weapon_anim_event", _on_weapon_anim_event.bind(node))


func _on_weapon_anim_event(anim_name: String, event_name: String, _value: String,
		mount: Node) -> void:
	if event_name != "Hit":
		return
	var sfx: String = str(HIT_SFX.get(anim_name, ""))
	if sfx.is_empty():
		return
	# 数据侧自带 Sound 的动画让位（Spine 源补 Sound 后本桥自动静默，防双发声）
	if Anims.rigless_anim_event_time(anim_name, "Sound") >= 0.0:
		return
	# 世界坐标交给 AudioManager：spatial 事件据此做距离衰减与左右定位
	if mount is Node2D:
		AudioManager.play_event(sfx, (mount as Node2D).global_position)
	else:
		AudioManager.play_event(sfx)
