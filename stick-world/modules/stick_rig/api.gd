class_name StickRigAPI
extends RefCounted
## stick_rig 模块对外契约（L1 渲染基础设施——火柴人唯一视觉骨架）。
##
## 模块边界：骨骼 / 动画 / 描边 / 头顶血条 / crowd 批量渲染 / 武器挂接表现，全部归本模块。
## 实体侧（units）持有数据与状态机，渲染走本模块（AGENTS.md 核心指令 6：HD-2D billboard
## 骨架是火柴人唯一视觉骨架，角色随身视觉一律随骨架做）。
##
## 跨模块取脚本/场景一律走本文件常量；禁止 preload 本模块 scripts/ 内部文件
## （tools/audit_deps.py 越界 preload 棘轮按此口径计数）。tests/tools 等仓级脚本
## 不受模块审计约束，可直连内部路径。
##
## 鸭子契约（无类型依赖的运行时协作，节点名/属性名即契约）：
## - crowd_renderer：按名探查实体子树 HealthBar / WeaponMount / OutlineGroup/StickmanRig，
##   经 has_method / get 读状态（见 crowd_renderer.gd 文件头）；
## - health_bar_indicator：实体 health 组件的 damaged/healed/died 信号 + max_hp 属性，
##   骨架节点路径 RigHost/OutlineGroup/StickmanRig；
## - 骨架动画驱动：rig.play(名) / set_anim_speed / notify_pose_dirty 等（见 stickman_rig.gd）。

## 动画库脚本（StickmanAnims：动画名/变体池/WEAPON_ATTACK_ANIM 单一真相源）
const ANIMS_SCRIPT: GDScript = preload("res://modules/stick_rig/scripts/stickman_anims.gd")
## 头顶血条脚本（HealthBarIndicator：HP 显示 + crowd GPU 烘制参数）
const HEALTH_BAR_SCRIPT: GDScript = preload("res://modules/stick_rig/scripts/health_bar_indicator.gd")
## 描边脚本（StickmanOutline：CanvasGroup 双 pass 描边，HD-2D billboard 消费）
const OUTLINE_SCRIPT: GDScript = preload("res://modules/stick_rig/scripts/stickman_outline.gd")
## crowd 批量渲染器脚本（远景单位合批；combat BattleInstance 与 units 装配消费）
const CROWD_RENDERER_SCRIPT: GDScript = preload("res://modules/stick_rig/scripts/crowd_renderer.gd")
## 骨架场景路径（StickmanRig 根；实体场景与 HD-2D billboard 共用的唯一骨架实例源）
const RIG_SCENE_PATH: String = "res://modules/stick_rig/scenes/stickman_test.tscn"


## 武器类型枚举（装备状态的数值口径；units WeaponMount 与 hd2d billboard 镜像共用——
## 真相源在此，WeaponMount 经 const 转发保持旧引用点不变）
enum WeaponType { SWORD, SPEAR, BOW, PICKAXE, STAFF, MERIC, NONE }

## 武器表现组件场景路径（贴图由 tools/baking/extract_weapons.gd 从解包图集裁剪）。
## 消费方（weapon_mount 等）经本组常量取路径，不在自己文件里持有跨模块字面量。
const WEAPON_SWORD_PATH: String = "res://modules/stick_rig/scenes/components/weapon_sword.tscn"
const WEAPON_SPEAR_PATH: String = "res://modules/stick_rig/scenes/components/weapon_spear.tscn"
const WEAPON_BOW_PATH: String = "res://modules/stick_rig/scenes/components/weapon_bow.tscn"
const WEAPON_PICKAXE_PATH: String = "res://modules/stick_rig/scenes/components/weapon_pickaxe.tscn"
const WEAPON_MAGICSTAFF_PATH: String = "res://modules/stick_rig/scenes/components/weapon_magicstaff.tscn"
const WEAPON_MERICSTAFF_PATH: String = "res://modules/stick_rig/scenes/components/weapon_mericstaff.tscn"
const WEAPON_SHIELD_PATH: String = "res://modules/stick_rig/scenes/components/weapon_shield.tscn"

## 武器类型 -> 武器表现组件场景路径
const WEAPON_SCENE_PATHS: Dictionary = {
	WeaponType.SWORD: WEAPON_SWORD_PATH,
	WeaponType.SPEAR: WEAPON_SPEAR_PATH,
	WeaponType.BOW: WEAPON_BOW_PATH,
	WeaponType.PICKAXE: WEAPON_PICKAXE_PATH,
	WeaponType.STAFF: WEAPON_MAGICSTAFF_PATH,
	WeaponType.MERIC: WEAPON_MERICSTAFF_PATH,
}
