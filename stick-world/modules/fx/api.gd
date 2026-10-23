extends Node
## fx 模块公共接口契约
##
## 契约形态：本模块是无状态特效服务，无 api 节点实例、无信号——对外面是
## 全局类 class_name（FxLibrary / FxPool / FxDamageTextPool），消费方直接
## 引用类名调用，不 preload 本文件。本文件是对该 class_name 公共面的登记：
## 改动下列任何入口的签名/语义，须同步更新本文件（audit_deps 口径 fx 零出向，
## 任何模块可安全依赖 fx，单向无环）。
##
## ── FxLibrary（静态入口，业务方不持有节点引用）──────────────────────
## 粒子爆发：FxPool.spawn_burst(get_tree(), FxLibrary.BUILD_DUST, global_position)
##   效果 ID 常量表在 FxLibrary 头部（BUILD_DUST 建造尘土 / GATHER_DEBRIS
##   采集飘屑 / AMBIENT_SPARKLE 环境闪光，纯代码配置零外部资产，PLACEHOLDER
##   替换清单见 docs/项目/待办事项.md）。战斗不产粒子特效（口径见 FxLibrary 文件头）。
## 伤害飘字：spawn_damage_text(tree, pos, amount, crit, ...) —— Label 池化
##   （FxDamageTextPool 域组件），combat damage_pipeline 与集成测试在用。
## 挥砍弧光：spawn_slash_arc(tree, pos, angle_rad, crit)
## 彩纸礼花：spawn_confetti(tree)
## 材料特效：spawn_ingredient(pool, effect_id, pos, velocity)
## 坐标重映射协议（飘字/挥砍弧/箭矢共用的世界→特效层换算）：
##   remap_pos(tree, pos) / body_lift(tree) / remap_body_pos(tree, pos)
## 运行时清理：clear_runtime_pools()（GameRoot._exit_tree 聚合调用——飘字池
##   + 材料特效静态持有对称清空）/ clear_ingredient_effects()
##
## ── FxPool（场景节点池）────────────────────────────────────────────
## 池实例由 SystemSetup 挂载到 GameRoot（group "fx_pool"）；静态
## spawn_burst 经组查找取池，无池环境（纯逻辑测试等）静默跳过不报错。
## take_from_pool / _release_to_pool 为池内协议，仅 fx 域与 IngredientVisualEffect
## 控制器使用，外部不要直接调。
##
## ── FxDamageTextPool（飘字域，静态类）───────────────────────────────
## spawn/clear 由 FxLibrary 转发驱动，外部一律走 FxLibrary 壳，不直接引用。
