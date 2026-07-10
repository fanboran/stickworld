## Units 模块公共接口契约
##
## 本模块提供火柴人角色系统，包括：
## - StickmanRig: 渲染骨架（骨骼、纹理、动画、武器）
## - StickmanSkeleton: 骨骼数据与构建
## - StickmanTextureGen: 纹理生成
## - StickmanAnims: 动画系统
## - StickmanWeapon: 武器挂载
##
## 外部模块应通过 StickmanRig 的公共 API 与本模块交互：
##   - play(anim_name: String)          播放动画
##   - get_current_anim() -> String      获取当前动画名
##   - get_bone_by_id(id: int) -> Node2D 获取骨骼节点
##   - get_bone_ids() -> Array           获取所有骨骼 ID
##
## 常量：
##   - StickmanRig.ANIM_IDLE / ANIM_WALK / ANIM_ATTACK / ANIM_DEAD
##   - StickmanRig.WeaponType (SWORD, SPEAR, BOW, SHIELD, UNARMED)
##
## 信号：
##   （当前模块不对外发射信号，预留扩展）