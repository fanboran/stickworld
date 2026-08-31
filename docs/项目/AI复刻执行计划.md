# 兵种 AI 复刻执行计划（2/5/6/7 高优先级批次）

> 2026-08-31 定稿。本批次工作的**唯一计划文档**，新对话从这里接续。
> 配套状态记录：[`待办事项.md`](待办事项.md)（1~8 轮已完成项，按轮次倒序）。
> 工作方式：**全程 Vibe Coding**，估算口径 = 会话轮次（非人天），见 §5。

---

## 一、范围与优先级（用户已拍板）

| 序 | 项 | 优先级 | 估算（轮次） | 状态 |
|---|---|---|---|---|
| 6 | 编队动态跟队 | 高 | 2 | 待开工 ← **从这开始** |
| 5 | 盾姿态分层动画 | 高 | 1.5 | 待开工 |
| 2 | 数值校准（对表解包/wiki） | 高 | 2 | 待开工 |
| 7c | TeamAi 姿态机 | 高 | 1.5~2 | 待开工 |
| 7b | 祭司 Meric 兵种+治疗 | 高 | 1.5 | 待开工 |
| 7a | 巨人兵种+抓掷 | 高（风险项） | 2.5~3 | 待开工 |
| — | 矛兵一次性掷矛（`EnableASingleSpearThrow`，复用箭矢投射物） | 中 | 0.5 | 待开工（可搭 5 盾姿态批次顺做） |
| 4 | 法术——**只要一部分**（建议 ArrowVolley 箭雨 + HealSpell 群疗，各 0.5~1 轮） | 中 | 1~2 | 用户确认范围后做 |
| 3 | 阵营皮肤——**不复制素材**，学原版组织方式自绘；代码侧皮肤槽系统 1~2 轮，美术工时另计 | 中 | — | 排后 |
| 1 | 音效接线（事件真值已导出，纯接线 0.5~1 轮） | 用户放延后 | — | 可随时插队 |

**合计约 10.5~12.5 轮**（不含 3/4）。执行顺序 **6 → 5 → 2 → 7c → 7b → 7a**（前三轮后观察场可见跟队行军+盾墙完整形态）。

---

## 二、逐项实施拆解

### 6. 编队动态跟队（2 轮）
- **目标**：前队移动时后队自动锚定跟随（`MoveInFormationBehindAnotherFormation` + `GapBetweenFormationGroups` 直译）。
- **改动点**：
  - [formation_system.gd](../stick-world/modules/combat/scripts/command/formation_system.gd)：加 `follow_squad_id`/`gap` 锚定字段；`_decide_squad_targets`（0.5s tick）里后队落点 = 前队质心 − 前队行进方向 × gap；前队全灭 → 解除锚定转自主决策
  - [battle_arena.gd](../stick-world/tests/dev/battle_arena.gd) 三班接线：矛班=先锋（ADVANCE_ALL 到中线），剑班锚矛班 gap≈150，火力班锚剑班
- **验收**：观察场三班保持纵深推进；前队接敌停下后后队落点稳定；formation 相关测试套件回归（`tests/run_all.sh -Match formation`）。

### 5. 盾姿态分层动画（1.5 轮）
- **目标**：矛兵举盾时 走/攻击/待命 全部切换持盾变体（`Spearton-Block-Attack1/2/3` 三连刺、`Block-Crouch`）。
- **改动点**：
  - [spine_import.gd](../stick-world/tools/baking/spine_import.gd) ANIM_MAP 追加盾形态映射（Spearton 组 21 动画内挑选）→ **增量导入**（`-- --only=a,b,c`，勿全量重建冲掉洗稿稿）
  - [behavior_profiles.gd](../stick-world/modules/units/scripts/ai/behavior_profiles.gd) 加"持盾动画组"（SPEAR：walk→block_walk、attack→Block-AttackN 随机）
  - rig 播放分支：`weapon_mount._blocking` 时 `play_attack` 改走盾攻组——**机制已验证**：`Anims.set_state_animation(sm, 状态名, 变体名)` 动态换状态节点动画，不增状态节点
- **验收**：矛兵行军端盾走盾步、攻击播三连刺、举盾被击走 Block-Hit 池（已就位）。

### 2. 数值校准（2 轮）
- **数据源**：①SWL wiki（全单位 HP/伤害/价格/冷却公开值）②dump 字段语义核对（`F:\VSCode\game-2-aux\external\decompiled\legacy\dump\`、`legend\dump\`）③存疑项录屏实测抽查。
- **改动点**：数值表进 `config/units/stickmen.tres`（或扩展 BalanceConfig）；仿真平衡回归——**镜像局应接近五五开、10v10 时长量级合理**。
- **风险**：wiki 与实测可能有出入 → 以仿真表现仲裁，宁可贴近原版观感不迷信单一来源。

### 7c. TeamAi 姿态机（1.5~2 轮）
- **目标**：双方 TeamAi 自动切换 attack/defend 姿态（legacy `TeamAi.StanceUpdate` 直译）：兵力比 + 侵略参数决定压上/回防。
- **改动点**：新 TeamAi 决策层（挂 BattleInstance 或 battle_ai_director 旁）；滞回防抖；**与 TacticalOrders 优先级调和：玩家手动号令 > 姿态自动切换**（自动姿态只在无号令时生效）。
- **验收**：仿真里双方出现"压上→胶着→回防"节奏，不出现全线站桩。

### 7b. 祭司 Meric（1.5 轮）
- **资产**：`[meric].txt` 骨架 5 动画全齐（Heal1/Heal2/Stand/Walk/Death）。
- **改动点**：导入映射 + 兵种数据（后排站位、无近战）+ 治疗 AI（选血量最低友军、Heal1/2 随机、持续回复走 StatusEffects 的 HealOverTime 扩展或直接 heal）。
- **验收**：观察场加 1-2 祭司，前排存活时长显著延长。

### 7a. 巨人+抓掷（2.5~3 轮，风险项）
- **资产**：`[giant].txt` 18 动画全齐（含 `Giant-Grabbng-Spearton` 抓掷专用动画）。
- **改动点**：大比例渲染（骨架缩放或 scale）+ 单位数据（超高 HP/慢速/AOE 挥击已有字段）+ **抓掷状态机**（近身抓取判定→举起→抛物投掷→被掷单位物理弹射+落地 AOE）。
- **风险**：三处易出运行时 bug（抓取目标选择、被掷单位物理接管、落地结算）——每处先 grep 现有 API 再调用。

---

## 三、关键路径与数据源

| 资源 | 路径 |
|---|---|
| universal 主骨架（剑矛弓镐杖全动画） | `F:\VSCode\game-2-aux\external\decompiled\legacy\spine_raw\核心单位骨架\[skeleton].txt`（100 动画全量清单用 python 读 `animations` 键） |
| 巨人/祭司/僵尸等骨架 | 同目录 `[giant].txt` `[meric].txt` `[zombie].txt` 等 |
| legacy dump（14 个 Ai 类签名） | `F:\VSCode\game-2-aux\external\decompiled\legacy\dump\legacy_AI_classes.cs` |
| legend dump（组件/系统清单） | `F:\VSCode\game-2-aux\external\decompiled\legend\dump\` |
| 动画导入输出 | `res://modules/units/animations/`（spine_import 缺省目录） |
| 两代对比分析（机制清单） | `F:\VSCode\game-2-aux\external\decompiled\两款解包游戏完整代码分析与移植决策.md` |
| 行为参数档案（兵种个性唯一入口） | `res://modules/units/scripts/ai/behavior_profiles.gd`（RWR 式基线+覆盖） |

## 四、验收工具与命令

```bash
# 战斗仿真统计器（每轮改完必跑；输出行为占比/发呆检测/远程交战距离/收敛）
godot --headless --path . res://tests/dev/battle_sim.tscn
# 场景矩阵在 battle_sim.gd SCENARIOS 常量，可增删

# 观察场（人工验收）：主菜单 → 战斗演练 → 大乱斗观察场（R 重开 · 空格暂停 · 滚轮缩放）
# 当前观察场参数：镜头 0.55 · 两军间距 800 · 行距 90/110 · 战场 6144×(432~1674)

# 动画增量导入（--only 后跟逗号分隔的映射键名）
godot --headless --path . res://tools/baking/spine_import.tscn -- --only=dead_v2,hit_block_1

# 单脚本语法检查（报错白名单=autoload 误报：EventBus/TimeManager/BalanceConfig/WorldState/ConfigManager/depended）
godot --headless --path . --check-only --script res://<脚本路径>
```

## 五、工作方式约定（新对话必读）

1. **轮次口径**：直译/接线类一轮 3~5 子项；新机制 1 轮 1 主体 + ~30% 返工率。用户验收节奏决定日历时间。
2. **新调 API 先 grep 方法签名**（教训：`register_unit` 不存在，真名 `add_unit(unit, faction)`）。
3. **跨类引用一律显式 preload**（防 headless `class_name` 未注册误报；先例见 weapon_mount 的 ScriptBehaviorProfiles/ScriptStatusEffects）。
4. **类型化数组常量不经三元表达式**（退化为 untyped Array 运行时报错，先例 stickman_anims.pick_hit_anim）。
5. **用户已定决策（勿反转）**：盾牌只绑矛兵；staff 不风筝（召唤护卫方案）；法术只要一部分；皮肤不复制素材。
6. **每轮改完**：语法检查全部 touched 文件 → battle_sim 回归 → 用户游戏内验收。
7. 行为改动尽量进 **behavior_profiles 参数**而非硬编码（RWR 制度）；新机制做成能力开关（档案字段）。
