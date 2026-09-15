# fx：2D 特效服务（粒子爆发 / 环境闪光 / 战斗演出）

> 本模块是无状态特效服务：无 api 节点实例、无信号契约——对外入口是全局类
> `FxPool` / `FxLibrary` 的静态方法（组查找模式，业务方不持有池节点引用）。
> 池实例由 world 装配层挂到 GameRoot（group "fx_pool"）；无池环境（纯逻辑测试）
> 静态入口静默跳过不报错。效果配置纯代码、贴图运行时程序化生成，视觉基准对齐
> 《药剂工艺》环境闪光；占位素材替换项见 docs/项目/待办事项.md。

---

## 目录结构

```
modules/fx/
├── api.gd                                  # 契约说明（无 class_name，不实例化）
├── scripts/
│   ├── fx_library.gd                       # FxLibrary：效果 ID → GPUParticles2D 配置库；伤害飘字/剑光弧/胜利彩带/坐标重映射
│   ├── fx_pool.gd                          # FxPool：爆发特效对象池（每效果 6、硬上限 16）+ 静态入口 spawn_burst
│   ├── ambient_sparkle_spawner.gd          # AmbientSparkleSpawner：0.5s 扫 resource_node 组，视野附近挂闪光、远视野卸载（挂载界 320 / 迟滞 800）
│   ├── crystal_sparkles.gd                 # CrystalSparkles：资源点连续闪光组件（基础层 + 5 强度子系统，按宿主轮廓点集发射，CPUParticles2D）
│   ├── ingredient_visual_effect.gd         # IngredientVisualEffect：演员特效数据（帧集合+物理参数+淡出，Resource）
│   └── ingredient_visual_effect_controller.gd  # 演员特效执行器（Sprite2D 手写物理 + 池化）
└── assets/
    ├── sparkle_seq_CrystalSparks1_6.png 等 # 强度子系统帧序列贴图（1~5 层，帧深 6/8/9/10/12 递增）
    ├── sparkle_dot_default_particle.png    # 基础层柔点贴图
    └── demo/                               # tools/fx_gif.gd 出图工具用的样例贴图
```

---

## 对外契约

- 爆发特效：`FxPool.spawn_burst(tree, effect_id, global_pos)`；效果 ID 常量在 `FxLibrary`
  （BUILD_DUST / GATHER_DEBRIS / HIT_SPARK / MAGIC_BLAST / AMBIENT_SPARKLE）
- 战斗演出：`FxLibrary.spawn_damage_text`（combat 的 DamagePipeline 结算后调用）、
  `spawn_slash_arc`（units 的 WeaponMount 命中帧调用）、`spawn_confetti`（ui_global 胜利画面）
- 环境闪光：`CrystalSparkles.attach_to(host, z, theme, tier)`（AmbientSparkleSpawner 自动挂载）

### 2D 特效坐标重映射（fx_pos_remapper 组协议）

HD-2D 图地面在 3D 视图受俯角前缩，2D 画布直绘会与 3D 世界错开。本模块是协议**消费端**：
`FxLibrary.remap_pos(tree, pos)` 查场景 `fx_pos_remapper` 组节点并调其 `remap_fx_pos`；
注册方是 world 侧 HD-2D 宿主地图（`modules/world/scripts/map/hd2d_street_map.gd`）。
投影公式与协议细节见 [HD-2D 街景系统](../../docs/技术/架构/建筑管线/HD-2D街景系统.md)。

---

## 依赖

- `core/`（WorldZ z 序常量）。不依赖任何游戏模块，任何模块可安全依赖 fx（单向无环）

---

## 开发注意事项

- 新爆发特效：`fx_library.gd` 加 ID 常量 + `_config_*` 分支，池自动扩容
- 消费方只使用 FxPool/FxLibrary 两个全局类，禁止引用其余内部脚本
