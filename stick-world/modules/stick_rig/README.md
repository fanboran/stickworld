# stick_rig —— 火柴人视觉骨架（L1 渲染基础设施）

火柴人**唯一视觉骨架**（AGENTS.md 核心指令 6）：骨骼、动画、描边、头顶血条、crowd 批量渲染、
武器挂接表现，全部归本模块。实体侧（units）持有数据与状态机，渲染走本模块——2D 画布链路
不得再加角色视觉（血条/进度条等随身视觉一律随骨架做进 billboard，数据源留实体侧）。

## 目录结构

```
modules/stick_rig/
├── api.gd                    # 对外契约：脚本/场景常量出口 + 鸭子契约文档
├── README.md
├── scripts/                  # 骨架实现（自 units/scripts/rig/ 等聚合迁入）
│   ├── stickman_skeleton.gd  # 骨骼定义（纯静态数据 + 构建函数，零外部依赖）
│   ├── stickman_rig.gd       # 骨架节点（Skeleton2D；动画树/覆盖层/武器挂接）
│   ├── stickman_anims.gd     # 动画库（动画名/变体池/WEAPON_ATTACK_ANIM 单一真相源）
│   ├── stickman_batch_rig.gd # 批量骨架（crowd 合批用精简 rig）
│   ├── crowd_renderer*.gd    # crowd 合批渲染器（主控/烘焙/桶/覆盖桶）
│   ├── stickman_weapon.gd    # 武器挂接（骨挂武器表现；数值/装备逻辑在 units）
│   ├── stickman_outline.gd   # CanvasGroup 双 pass 描边（HD-2D billboard 消费）
│   ├── health_bar_indicator.gd # 头顶血条（HP 显示 + crowd GPU 烘制参数）
│   ├── procedural_overlay.gd # 程序化覆盖层
│   ├── stickman_test.gd      # 骨架测试/演示控制器（stickman_test.tscn 挂载）
│   └── crowd_*.gdshader      # crowd 血条摆动/武器图集 shader
├── animations/               # 烘焙动画 .tres（tools/baking 管线产物）
├── shaders/                  # 描边 shader（stickman_outline{,_id}）
├── scenes/
│   ├── stickman_test.tscn    # 骨架场景（实体场景与 HD-2D billboard 共用实例源）
│   └── components/           # 武器表现组件场景（weapon_*.tscn）
└── assets/textures/weapons/  # 武器纹理 png
```

## 机制要点

- **crowd 合批**：远景单位由 crowd_renderer 收进 MultiMesh 桶（血条摆动/武器图集走 GPU shader）；
  烘制参数常量在 health_bar_indicator，crowd_renderer_buckets 直接取用（同模块内部依赖）。
- **鸭子协议边界**：crowd_renderer / health_bar_indicator 对实体的访问全部走
  `has_method` / `get` / 节点名探查（`HealthBar`、`WeaponMount`、`OutlineGroup/StickmanRig`），
  不类型引用 units——L1 不反向依赖 L2。
- **动画管线**：动画 .tres 由 `tools/baking/`（bake_anims / spine_import / wash_anims）产出写入
  `animations/`；stickman_anims 运行时按名加载。

## 装配与消费

- 消费方（units 实体、combat BattleInstance、hd2d billboard）一律经 `api.gd` 常量取脚本/场景；
- 实体场景 `modules/units/scenes/stickman_entity.tscn` 实例化 `scenes/stickman_test.tscn` 作骨架子树；
- HD-2D billboard（hd2d/char_sprite_3d）加载骨架场景后摘脚本、只取 `OutlineGroup/StickmanRig` 节点，
  描边/血条脚本经 api 常量重挂。

## 相关文档

- 分层与依赖：docs/技术/架构/数据与契约/模块依赖关系.md
- 模块 API 契约：docs/技术/架构/数据与契约/模块API契约.md
- HD-2D 街景系统：docs/技术/架构/建筑管线/HD-2D街景系统.md
