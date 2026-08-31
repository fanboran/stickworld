# RTS 游戏角色动画技术 — 英雄连 & 小兵步枪

> 调研目标：分析两款"灵动"表现突出的游戏中角色动画的核心技术，提取可应用于 stick-world 火柴人的方案。
>
> 调研日期：2026-07-25

---

## 一、英雄连（Company of Heroes）— Relic Entertainment, 2006

引擎：Essence Engine（自研）+ Havok 3.0 物理

### 1.1 "Animation Brain"（动画脑）系统

一个内置的动作素材库，包含约 **700 种不同动作**（作为对比，Relic 前作《战锤40K：战争黎明》仅 150 种）。不是 700 个完整动画，而是 700 个可混合的动作片段。

当士兵需要切换行为时（如从行军→找掩体），系统在素材库中**自动选择**最合适的候选动作，而不是跳到固定姿势。同一个"趴下"，在墙边和开阔地表现不同。

### 1.2 "战场感知系统"（Battlefield Awareness）

士兵无需玩家下指令，自动根据环境选择适当行为：

| 场景 | 自动行为 |
|------|----------|
| 穿过开阔地 | 自动快跑 + 左右观察 |
| 接近敌人火力线 | 自动弯腰 + 寻找掩体 |
| 掩体后 | 自动探头射击 + 蹲回去装弹 |
| 被压制 | 自动趴下匍匐 |
| 爆炸/炮击附近 | 自动扑倒或踉跄 |

本质是一个**基于状态的动作选择器**：把环境参数（敌我位置、掩体距离、压制状态）喂给动画系统，系统在素材库中选出最匹配的动作。

### 1.3 分层骨骼混合（Layered Bone Blending / Bone Masking）

核心架构——上下半身独立控制：

```
Layer 0 (Base):      下半身：idle / walk / run / crouch 循环
Layer 1 (Upper):     上半身：瞄准 / 射击 / 换弹 / 投掷（骨骼遮罩=胸部以上）
Layer 2 (Additive):  呼吸起伏（叠加在脊柱骨骼上，幅度很小）
Layer 3 (IK):        脚贴地 + 手贴枪
Layer 4 (Override):  中弹受击 → 覆盖全身
```

通过骨骼遮罩（Bone Mask），**上半身播放射击动画的同时下半身继续走路**——两条动画各自独立，互不干扰。

### 1.4 物理驱动的二次运动

- 爆炸冲击波把士兵掀飞 → ragdoll 物理，非预设动画
- 被子弹击中 → 上半身 ragdoll + 下半身保持站立
- 尸体落地姿态完全由物理决定，没有两个一样的

### 1.5 上下文感知的骨骼动画

所有步兵使用骨骼动画，且动画选择是**上下文感知**的（context-sensitive）：
- 标准行军
- 急速冲锋
- 谨慎推进（边走边左右观察）
- 匍匐前进
- 根据所处地形自动切换

---

## 二、小兵步枪（Running with Rifles）— Osumia Games, 2015

引擎：OGRE（自研封装）+ 体素地形

### 2.1 核心哲学："玩具兵"美学

视角固定俯视，角色极小（十几个像素），不需要精细的肢体变化。**一个像素的偏移就能传达"蹲下"和"站立"的区别。** 小尺度下，pose 的可读性 > 动画帧数。

### 2.2 涌现式 AI 行为

士兵不是按脚本行动。每个 AI 独立决策——找掩体、还击、撤退——都是基于战场状态实时计算。这种"不可预测性"就是灵动感的来源。

关键特性：
- 单兵会被流弹随机击杀（"一枪一个"），没有血条
- AI 会根据小队形势自主决定进退
- 玩家只是"战场的普通一兵"，不是总指挥

### 2.3 物理驱动的战场细节

- 子弹有弹道飞行时间和散布
- 移动速度受地形和负重影响
- 掩体和地形对战局有真实影响

这些物理细节叠加在简单动画上，产生了一种"这不是播动画，这是在模拟"的感觉。

### 2.4 技术要点

- 体素（voxel）地形系统：低多边形 + splat map 纹理
- 自定义引擎，可渲染数百个战斗单位 + 弹道
- 适合低配硬件的性能优化

---

## 三、通用的分层动画技术

### 3.1 标准分层架构（AAA 级别）

| 层级（从底到顶） | 内容 | 类型 | 骨骼范围 |
|-----------------|------|------|----------|
| Layer 0 | 移动（idle/walk/run/crouch） | Base | 全身 |
| Layer 1 | 战斗姿态 | Override | 上半身 |
| Layer 2 | 呼吸/疲劳（叠加微动） | Additive | 脊柱 |
| Layer 3 | 瞄准偏移 | Additive | 脊柱+手臂 |
| Layer 4 | 上半身动作（换弹/投掷） | Override | 上半身 mask |
| Layer 5 | 面部表情 | Override | 头部 mask |
| Layer 6 | 受击反应 | Override | 全身或上半身 |
| Layer 7 | 过场动画/剧情 | Override | 全身 |

### 3.2 骨骼遮罩（Bone Mask）原理

```
for each bone in skeleton:
    if bone is in upper_body_mask:
        final_pose[bone] = blend(base_pose, upper_layer_pose, weight)
    else:
        final_pose[bone] = base_pose[bone]  # 下半身不动
```

上半身动作层只影响胸部及以上的骨骼（spine → shoulders → arms → head），髋部和腿部骨骼完全由 base layer 控制。

### 3.3 关键规则

- 骨盆（hip/pelvis）通常属于下半身，由 base layer 独占
- 脊柱是上下半身的分界点
- Additive layers 用于叠加小幅度的持续性微动
- Override layers 用于一次性动作的完全接管

---

## 四、对 stick-world 的应用方案

### 4.1 当前架构（单层）

```
AnimationTree
└── AnimationNodeStateMachine
    ├── idle
    ├── walk
    ├── run
    ├── attack
    └── dead
```

**问题**：attack 动画时脚也停止移动，无法边走边打。

### 4.2 目标架构（分层）

```
AnimationTree
└── AnimationNodeBlendTree (root)
    ├── Lower Body (BlendSpace2D)
    │   └── idle / walk / run（按速度混合）
    └── Upper Body (StateMachine, mask=chest+arms+head)
        ├── idle_upper
        ├── attack
        └── reload
```

**优势**：attack 时脚继续走路，换弹时依然能移动，受击时上身踉跄下身不倒。

### 4.3 不改架构也能立即加的（代码驱动）

| 效果 | 实现方式 | 成本 |
|------|----------|------|
| 武器指向鼠标 | IK target 跟随鼠标偏移 | 5行代码 |
| 脚步适应地形 | IK target Y 根据地面高度微调 | 10行代码 |
| 身体轻微晃动 | hip.rotation 叠加 Perlin 噪声 | 3行代码 |
| 呼吸起伏 | hip.position.y 正弦波 | 2行代码 |
| 受击闪白 | modulate 瞬间变白再恢复 | Tween |

### 4.4 实施优先级

1. **分层动画**（改动 .tscn，一劳永逸）
2. **武器指向 IK**（最直观的灵动提升）
3. **身体微动噪声**（零成本增加"活着"的感觉）
4. **受击反馈**（闪白 + 后退 + camera shake）

---

## 五、参考资料

- 英雄连开发幕后：<https://www.pcgamer.com/uk/the-making-of-company-of-heroes-design-prototypes-and-the-donkeyschreck/>
- 英雄连"动画脑"系统中文介绍：<https://news.17173.com/content/2008-04-28/20080428100140656.shtml>
- 英雄连技术分析：<https://www.rockpapershotgun.com/how-company-of-heroes-made-a-destructible-battlefield>
- Unreal Engine 动画分层文档：<https://dev.epicgames.com/documentation/en-us/unreal-engine/blend-masks-and-blend-profiles-in-unreal-engine>
- Unity 动画分层教程：<https://blog.csdn.net/qq_33060405/article/details/151871177>
- 动画分层通用指南：<https://mocaponline.com/blogs/mocap-news/animation-layers-guide>
- Running with Rifles 开发者信息：<https://shapes.inc/fandom/running-with-rifles/author>
