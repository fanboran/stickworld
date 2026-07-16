## Units 模块公共接口契约
##
## 本模块提供火柴人角色系统，包括：
## - StickmanRig: 渲染骨架（骨骼、纹理、动画、武器）
## - StickmanSkeleton: 骨骼数据与构建
## - StickmanTextureGen: 纹理生成
## - StickmanAnims: 动画系统
## - StickmanWeapon: 武器挂载
## - StickmanEntity: 物理+碰撞外壳（CharacterBody2D），持有 StickmanRig
## - AIController: 🆕 AI 决策大脑（行为状态机调度，详见 §7.1/§7.2）
## - BehaviorStateMachine: 🆕 行为状态机
## - BehaviorBase / BehaviorIdle / BehaviorMove: 🆕 行为节点
##
## 外部模块应通过 StickmanRig 的公共 API 与本模块交互：
##   - play(anim_name: String)          播放动画
##   - get_current_anim() -> String      获取当前动画名
##   - get_bone_by_id(id: int) -> Node2D 获取骨骼节点
##   - get_bone_ids() -> Array           获取所有骨骼 ID
##
## StickmanEntity 公共 API：
##   - set_possessed(bool)               切换玩家附身
##   - is_possessed() -> bool            查询附身状态
##   - get_facing() -> int               朝向（1=右，-1=左）
##   - get_current_anim() -> String      当前动画名
##   - ai_move(dir: Vector2, run: bool)  🆕 AI 设定移动方向
##   - ai_stop()                         🆕 AI 停止移动
##   - get_ai_controller() -> Node       🆕 获取 AIController 引用
##   - set_ground_constraints(...)       注入地面约束参数
##   - set_map_reference(map: Node2D)    注入地图引用
##
## AIController 公共 API：
##   - get_current_behavior() -> String  当前行为名（idle/move/...）
##   - get_state_machine() -> BehaviorStateMachine  状态机引用
##
## 常量：
##   - StickmanRig.ANIM_IDLE / ANIM_WALK / ANIM_ATTACK / ANIM_DEAD
##   - StickmanRig.WeaponType (SWORD, SPEAR, BOW, SHIELD, UNARMED)
##   - StickmanEntity.WALK_SPEED / RUN_SPEED / BASE_SCALE
##
## 信号：
##   （当前模块不对外发射信号，预留扩展）
class_name UnitsAPI
extends RefCounted