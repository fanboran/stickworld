# 兵种 AI 复刻执行计划（批次总览与审计基线）

> 2026-08-31 定稿，2026-09-01 结构重排。兵种 AI 复刻工作的**唯一计划文档**，新对话从这里接续。
> 配套状态记录：[`待办事项.md`](待办事项.md)。工作方式：**全程 Vibe Coding**，估算口径 = 会话轮次（非人天），见 §七。
>
> **编号约定**：批次 ID（6/5/9/2/7a/7b/7c/10/11a~e/12）为历史沿用锚点（待办/CHANGELOG 引用它们），**不再改动**；执行先后用 P1~P13 表示。§二.9 = 批次 9 缺陷清单，§三 = AI 覆盖率审计，§四 = 全模块对账。

---

## 一、总览与执行顺序

| 顺序 | 批次 ID | 内容 | 估算（轮次） | 状态 |
|---|---|---|---|---|
| P1 | 9 | 观察场反馈缺陷清单（六轮验收积累，详表 §二 P1） | 余 ~1 | **18 项已修 ✅**（9d 并入 P5），待修 9h/9j/9k/9s + 用户验收 9t/9u（2026-09-05） |
| P2 | 11a | Ai 基类补全簇（y 对齐 6 函数 + 统一 Face + IsUnderThreat 真值；含 9p 首个消费者） | 1.5 | **已完成 ✅**（2026-09-01，含 9f/9p/9r 同轮修） |
| P3 | 9q | 小鬼脚对齐随 body_scale（可与 P2 同轮顺手修） | 0.3 | **已完成 ✅**（2026-09-01） |
| P4 | 11b | Formation 列队形（row/col 阵列 + 落点稳定 + 追赶状态） | 1.5 | **已完成 ✅**（2026-09-01） |
| P5 | 2 | 数值校准（对表解包/wiki；含 11d 射速系） | 2 | **已完成 ✅**（2026-09-02，wiki 真值落表 + 9d + 11d；录屏实测抽查待用户验收） |
| P6 | 7c+11c | TeamAi 逐函数直译（21 函数，含 9i+ 溃逃增强） | 2.5 | **已完成 ✅**（2026-09-03，21 函数直译 + 9i+ 五项增强 + 3 套件 30 用例） |
| P7 | 7b | 祭司 Meric 兵种+治疗 | 1.5 | **已完成 ✅**（2026-09-03，MericAi 3 函数直译 + HEAL 持续回复 + 后排站位 + L2 降级通用动画 + 12 用例套件） |
| P8 | 7a | 巨人兵种+抓掷（含 GutSpinner 投射物） | 2.5~3 | 待开工 **← 下一项**（风险项） |
| P9 | 10 | 物品栏系统（BG3/MC 式；热键核心已落地） | 2~3 | 核心 ✅，UI 待开工 |
| P10 | 12 | 特效扩容（血溅/焦痕/震地/天气，对齐原版 Effects 16 类） | 1 | 待开工 |
| P11 | 4 | 法术一部分（**Spell 基类先行**；建议 ArrowVolley + HealSpell） | 1~2 | 用户确认范围后做 |
| P12 | 3 | 阵营皮肤（不复制素材，自绘；代码侧皮肤槽 1~2 轮，美术另计） | — | 排后 |
| P13 | 1 | 音效接线（事件真值已导出，纯接线） | 0.5~1 | 用户放延后，可插队 |
| ✅ | 6 | 编队动态跟队（锚定 + 前队接敌后队支援） | 2 | **已完成待复验** |
| ✅ | 5 | 盾姿态分层动画（端盾行军/待命/三连刺 + 持盾减速） | 1.5 | **已完成待复验** |
| 挂起 | 11e | 玩法依赖簇（Zombie/Statue/Barricade/CastleArcher/Miner 路障） | — | 挂[复刻缺口总账](../审计/总账/翻译缺口总账.md)缓 |
| 随手 | — | 矛兵一次性掷矛（`EnableASingleSpearThrow`，复用箭矢投射物） | 0.5 | 挂 9f/5 复验后 |

**合计约 14.5~17 轮**（不含 P12/P13）。执行顺序 = 表中 P1 → P13 自上而下。

> **🔻 下一上下文开工指引（2026-09-03 P7 收尾）**：P7（批次 7b 祭司 Meric 兵种+治疗）已完成——MericAi 3 函数（Update/CanAttack/UpdateTarget）逐函数直译落 `behavior_heal.gd`（无桩），WeaponMount 治疗 3 方法（can_cast_heal/cast_heal/is_casting_heal）+ 3 字段直译，StatusEffects HEAL 类型 + `_apply_hot` 正向结算（禁入 DamagePipeline），TargetFinder.find_weakest_ally 血量最低友军筛选（含自身），后排站位（is_rear_line + FormationSystem 尾列取向），kite 撤而不打，施法停移。**L2 降级**：Spine 源数据 `[meric].txt` 缺失，祭司用通用动画（治疗功能不受阻），weapon_mericstaff.tscn 复用 magicstaff 贴图。12 用例单元套件全过（test_meric_heal），既有 25 套件零回归，battle_sim 扩展 2 场景 + heal_cast 指标采样。覆盖率 53%→**55%**（MericAi 0%→**100%**，见 §三）。**关键 BUG 修复**：ai_controller `_try_combat` 缩进错位致全单位 idle（已修）。下一项从 **P8（批次 7a 巨人兵种+抓掷）** 开工。**每轮改完更新 §三 覆盖数**。

---

## 二、批次逐项拆解（按 P1~P13 顺序）

### P1 · 批次 9：观察场反馈缺陷清单（2026-08-31~09-01 六轮验收积累）

#### 已修摘要（16 项 ✅）

| 项 | 一句话 | 关键实现 |
|---|---|---|
| 9a 暂停只停位移、肢体还动 | TimeManager 门禁补全 | rig `set_anim_paused` + 箭矢/武器挂载门禁 + batch_runner 隔离 |
| 9b 后队全员卡死 | 前队接敌 → 后队越过 gap 推进支援 | `_update_squad_follow` 锚点改前队质心、不带 hold |
| 9c 弓箭贴地小半圆插前线 | GROUND_DROP=屏幕 y 深度误判 | 解算飞行时间 t + 瞄准点地面线，落点=目标脚下 |
| 9e 法师无爆炸 | `_cast_magic` 延迟直结无 AOE/FX | `spell_aoe_radius`(90) 溅射+击晕 + MAGIC_BLAST 粒子（dump `CastStun/StunOpponents/unitsToDamage` 真值） |
| 9g 反向拉弓 | 风筝撤退朝向翻转 | 实体 `face_towards` + 开火前 `_face_target()` |
| 9i 怯战者后排站死 | 战斗中士气永不恢复 + 溃逃贴墙 | 脱火 ≥3s 半速恢复 + retreat 方向夹紧可走带 |
| 9l 法师召唤无上限 | 每 12s 无条件召 2 只 | 按施法者跟踪存活 ≤ summon_count（对齐 dump `minions/IsAtMaxMinions`） |
| 9m 尸体永存 | 只禁碰撞不清理 | 停留 4s → 1.2s 淡出移除（fadeOutOver 语义） |
| 9n 召唤位置/体型 | 二维指向向量跑纵深；体型未做 | 面朝方向（facing ±x）正前方 72px + 纵深排开；`body_scale` 档案字段 |
| 9o 主控走 A | 攻击动画锁死移动 + walk/run 覆盖拉弓 | 远程不锁移动 + attacking 动画保护 + 主控攻速 ×1.3（dump 真值） |
| 9f 矛兵攻击不是戳刺 | 无盾矛攻只有 Attack1 横扫观感 | 攻击池 `Spearton-Attack1/2/3` 随机混出（Hit 事件 @0.87/0.93/0.93s 真值导入） |
| 9p 弓手朝纵深正上目标照射 | y 偏移大时照出手=故意射空 | 11a y 对齐簇首个消费者：档案 `y_aim_tolerance`，射程内 \|Δy\| 超阈值先 y 走位不出手 |
| 9q 小鬼垂直坐标偏上 | body_scale 缩 rig 但 foot_offset 未随缩放 | `_foot_offset_base` 基准 + `_apply_scale` 重算 foot_offset/Collider/命中框 y 全随 body_scale |
| 9r 矛士站姿仍不对 | 静态 Stand1 观感不符 | 站姿池 `Into-Stand1/2`"落定成站姿"随机抽取（visual_controller `_pick_idle_variant`） |
| 6 编队跟队 | （上一批次，已并入本清单联动） | 锚定字段 + hold_on_arrive + follow_order 标记 |
| 5 盾姿态 | （上一批次，已并入本清单联动） | block_walk/crouch/block_attack_1~3 + 持盾减速 |

#### 待修（7 项，按批次归属；9s 并入 9k 计）

| 项 | 根因 | 修法 | 归属 |
|---|---|---|---|
| ~~9d 弓手射速不科学~~ | cooldown 1.35s（剑对齐值）未对 SWL 弓手攻速真值；冷却与动画时长无约束 | **已修 ✅（2026-09-02，P5）**：per-weapon 冷却（弓 2.0/矛 2.0/法 7.0）+ 冷却≥命中帧检查；顺手修"冷却≤命中帧重挥自打断"边界 bug | **P5（2）** |
| 9h 卡死复验 | 9b 修后若仍现全员卡死 | 观察场调试 HUD（逐单位 行为/号令/眩晕/溃逃/锚定，热键开关）定位 | 复验后定 |
| 9i+ 溃逃保真度增强 | 逃开后再战/保持招架/沿敌人垂直位游走/前排怯战试探接敌/包抄 | 并入 7c（姿态机天然覆盖"何时再战"） | **P6（7c）** |
| 9j 脱战回血（MOBA 延迟血条） | 无 HP 恢复机制、血条无渐补表现 | 脱战 5s 后回、上限 25% max_hp；血条绿色延迟残影（复用 trail）；dump 依据 `healthRegenPerSecondWhenUserControlled` | **P1 内** |
| 9k 群体避让 + 空挥 | 无 RTS 让路；近战无友军遮挡判定（隔队友出刀/对空气挥刀）；避战扎堆 | 移动绕行分量 + 出手前友军遮挡射线 + 攻击名额对表 `NumberOfUnitsThatCanHit` | **P1 内** |
| 9s 剑士接近战对空气挥刀 | 接近中目标移速超命中帧二次确认窗口；can_attack 可打断尾段提前出手 | 出手时机门槛（目标速度×命中帧时长预判）+ 友军遮挡射线 + 挥空率进 battle_sim | **并入 9k** |
| 9t 战场狗叫声（用户验收 2026-09-05） | 游戏内偶发狗叫。声音选择机制 = weapon_mount.gd `SFX_PATHS` 事件→路径映射表，音频由 `tools/ai/extract_swl_sfx.py` 从 SWL 资产批量提取入库（b16b4e5 冻结批次）；**代码层无狗叫逻辑，嫌疑是某 wav 内容与文件名错配**（提取索引错位） | 人耳逐个试听 headbutt / bodyfall_a-c / thump_a-b / clang_a-b 定位错配文件 → 重提取或换源；长期：素材替换清单补「试听验收」列 | **P1 内** |
| 9u 弓箭手不放箭（用户验收 2026-09-05） | 弓箭手的箭用不了。放箭链 = AI 决策 → WeaponMount 弓 attack → attack_bow 动画 Hit 事件（无元数据时 0.5s 兜底延迟）→ spawn arrow。**静态审查线索**（2026-09-05，未复现定位）：在途战斗性能修改（工作区未提交批次）四条链路嫌疑——① AI 半频化（AI 决策 30Hz 传 2×delta，开火节拍/风窗计时错拍，**嫌疑最大**）② target_finder `_collect_enemies` 网格预筛路径（query_neighbors 316px 半径，静态审查未见明显 bug，需实测目标获取）③ battle_instance `get_alive_enemies_of` 存活缓存帧过滤时机 ④ stickman_entity.tscn collision_mask 改动（与箭矢无关，**已排除**） | 观察场 48 人预设盯弓箭手复现 → 调试 HUD（9h 资产）看 target/attack 状态 → 按嫌疑链排查；快速验证 ①：临时 `_ai_rate_div=1` 对照。**归属：战斗性能批次的回归修复，与该在途修改同会话处理** | 随战斗性能批次 |

### P2 · 批次 11a：Ai 基类补全簇（~1.5 轮）✅ 2026-09-01 完成

- **范围**（原版函数清单见 §三 逐簇对账）：y 对齐 6 函数语义化（`AdjustGoalYToMoveTowardsTarget` 系，替换纯随机漂移；首个消费者 = 9p 弓手 y 对齐出手）+ 统一 `Face` 调用 + `IsUnderThreat` 真值化 + `IsTargetReallyClose` + `DetermineXRunPower`。
- **顺手修**：9f/9r（矛士戳刺与站姿增量导入）。
- **完成情况**：y 对齐 6 函数直译落 `behavior_attack.gd`（`_should_adjust_y_towards_target` / `_determine_y_component` / `_apply_y_walk` 等，档案新增 `y_align_x_range` / `y_align_early` / `y_align_strength` / `y_aim_tolerance`）；`face_target`/`face_position` 统一入口落 `behavior_base.gd`；`_is_under_threat`（THREAT_RANGE 内存活敌人）落 `ai_controller.gd` 作为溃逃前置真值；9f 攻击池 `Attack1/2/3`、9r 站姿池 `Into-Stand1/2` 增量导入（`spine_import.gd`）+ 档案 `attack_pool`/`stand_pool` + `visual_controller` 随机抽取。**battle_sim 回归零 ERROR，6 场景全部正常收敛**（attack 占比 91%+，弓矛单挑交战距离中位 312px）。

### P3 · 批次 9q：小鬼脚对齐（~0.3 轮）✅ 2026-09-01 完成

- `_apply_scale`/foot_offset 乘 body_scale；出生 y 以法师脚部 y 为基准。验收：小鬼脚落地、不悬空。
- **完成情况**：`stickman_entity.gd` 新增 `_foot_offset_base`（body_scale=1 基准，_ready 从 marker 计算一次），`_apply_scale` 重算 `foot_offset` 并同步缩放 Collider 尺寸/位置与命中框 y——全部消费点（地面带约束/出生日/存档对齐）读缩放后真值。

### P4 · 批次 11b：Formation 列队形（~1.5 轮）✅ 2026-09-01 完成

- **范围**（原版 `Formation` 类 7 函数 + 基类 3 函数）：row/col 阵列（`UNITS_PER_COLUMN/ROW_GAP/formationOrder`）+ `FormationPositionIsStable` 落点稳定检测 + `UpdateCatchingUpToFormation` 追赶状态 + `FilterDownARandomRow/ShouldSwitchUnitsInFormation` 补位换位。
- **验收**：三班 row/col 阵列推进，掉员自动补位；§三 覆盖数更新（编队稳定/结构 ❌→✅）。
- **完成情况**：[formation_system.gd](../../stick-world/modules/combat/scripts/command/formation_system.gd) 落槽位制编队——小队新增 `slots`（iid→Vector2i(col,row)），`_assign_formation_slots` 在建队/入队/离队/掉员时全量重算（Add/Remove 直译；FilterDownARandomRow 等价=列数随减员收缩不留空列）；`ShouldSwitchUnitsInFormation` 直译为贪心互换（互换后总行走距离缩短则换，近者填前排）；`get_squad_dest` 新增 `"formation"` 模式（前列贴锚、后列退 ROW_GAP×col、同列横展 SPREAD_SPACING）；`_formation_position_is_stable`（死区内不重发号令）与 `is_unit_in_formation`（IsInTheFormation 直译）落查询侧；跟队 tick 与 ADVANCE_ALL/SPRINT 号令全切 formation 模式。追赶：距槽位 >140px 下 `run+catching_up` 号令（UpdateCatchingUpToFormation），[behavior_move.gd](../../stick-world/modules/units/scripts/ai/behavior_move.gd) 追赶中收盾疾跑、落定恢复端盾（UpdateBlockWhenInFormation 真值语义）。新套件 `test_formation_slots`（槽位双射/落点/补位/换位/稳定 5 用例）；battle_sim 回归 6 场景正常收敛、21 套件全过。常量 UNITS_PER_COLUMN=3/ROW_GAP=56/CATCHUP_RUN_DIST=140 无 dump 真值，**待实测校准**。

### P5 · 批次 2：数值校准（2 轮）✅ 2026-09-02 完成

- **数据源**：①SWL wiki（namu，当前版 Normal 模式面板值）②dump 字段语义核对（`legacy_AI_classes.cs`：MissingArrowsTolerance/NextGaussian/attackSpeedModifier 等）③录屏实测抽查**待用户验收**。
- **改动点**：数值表进 `config/units/stickmen.tres`（或扩展 BalanceConfig）；镜像局接近五五开、10v10 时长量级合理；含 11d（ArcherAi `MissingArrowsTolerance` + `NextGaussian(min,max)` 三参版）与 9d（射速）。
- **风险**：wiki 与实测有出入 → 以仿真表现仲裁，贴近原版观感不迷信单一来源。
- **完成情况**：`stickmen.tres` 新增 6 行 SWL 校准 def（剑 80HP/12伤/1.0s冷却/125金、矛 440/15/2.0s/500、弓 70/10+爆头加值22=32/2.0s/300、矿工 100/10/0.8s/150、法师 150/50爆炸/7.0s/1200+召唤冷却档案 12s→**5.0s** 对齐 wiki、巨人 1000/25/2.5s/1500 留 P8 消费）；[weapon_mount.gd](../../stick-world/modules/units/scripts/entity/weapon_mount.gd) 新增 `WEAPON_DEF_ID` 映射 + `_apply_balance_calibration` 整行读取覆盖（HP 首次装载校准、换武器不动当前 HP；`_ready` 改 deferred 完整 reload 让场景预置武器也吃校准）。**9d**：per-weapon 冷却取代全局 1.35s + `_check_cooldown_vs_anim` 检查项（硬约束=冷却≥命中帧；软提示=冷却<动画全长依赖打断语义，剑士 1.0s vs 1.33s 原版同款）；**顺手修边界 bug**——冷却 ≤ 命中帧时长时每次重挥都在命中帧结算前打断自己（can_attack 增补"上一击未挥到命中帧不许重挥"门禁，1剑v1剑 45s 打不死 → 10.25s 收敛）。**11d**：`MissingArrowsTolerance` 直译（档案 `missing_arrows_tolerance` BOW=10 待实测校准；`_arrows_wasted` 门禁：目标在飞箭伤害估计超"击杀所需+容忍"不出手；`incoming_arrow_damage` 发射登记/箭矢终态扣减）+ `NextGaussian(mean,std,min,max)` 三参版直译（Box-Muller+区间重掷/钳制，`_fire_arrow` 散布改走该入口 ±2σ 截断）。验收：battle_sim 6 场景全收敛——1剑v1剑 10.25s、10剑v10剑 15.25s、10剑v20剑 9.25s、1矛v1剑 14.25s（矛克剑✓）、1弓v1矛 33.25s（矛克弓✓）、镜像混编 45s 拉锯 16/20 存活（矛 440HP 坦克肉度原版感）；run_all 全量绿。

### P6 · 批次 7c+11c：TeamAi 逐函数直译（2.5 轮）✅

- **范围**：原版 `TeamAi` 21 函数**逐函数直译**（不做概念近似）：`StanceUpdate` / `BalanceOfPowers` + `BalanceOfPowersRatio` 真值公式 / `ShouldAttack/ShouldDefend` / `ShouldGarrison` + Garrison 系 5 函数 / `BuildUnitsUpdate`（桩，依赖经济系统联动）/ `EnemyArmyIsCloseToUs` / `CompareUnitTypes` / 3 桩函数（Barricade/Statue/Desperation）。含 9i+ 溃逃增强五项。
- **约束**：与 TacticalOrders 优先级调和（玩家手动号令 > 姿态自动切换）；滞回防抖。
- **验收**：3 套件 30 用例全过（姿态机/号令守卫/9i+ 增强）；battle_sim 姿态序列采样就位（`_team_ai` 变体场景 + `stance_summary` 汇总）；§三 覆盖数 TeamAi 0%→100%（含桩）。

### P7 · 批次 7b：祭司 Meric（1.5 轮）✅ 2026-09-03 完成

- **资产**：`[meric].txt` 5 动画全齐（Heal1/Heal2/Stand/Walk/Death）——**L2 降级**：Spine 源数据缺失，祭司用通用动画上线，治疗功能不受阻。
- **改动点**：导入映射 + 兵种数据（后排站位、无近战）+ 治疗 AI（选血量最低友军、Heal1/2 随机、持续回复走 StatusEffects HealOverTime）。
- **验收**：观察场加 1-2 祭司，前排存活时长显著延长。
- **完成情况**：MericAi 3 函数（Update/CanAttack/UpdateTarget）逐函数直译落 [behavior_heal.gd](../../stick-world/modules/units/scripts/ai/behavior_heal.gd)（无桩，全部数值经档案 `_p()` 读取标注待实测校准）；WeaponMount 治疗 3 方法（can_cast_heal/cast_heal/is_casting_heal）+ 3 字段直译；StatusEffects HEAL 类型 + `_apply_hot` 正向结算（禁入 DamagePipeline，heal() 正向入口，minf max_hp 钳制）；TargetFinder.find_weakest_ally 血量最低友军筛选（hp_ratio 升序+距离次键，含自身可自疗）；后排站位（StickmanEntity.is_rear_line + FormationSystem 尾列取向分组）；kite 撤而不打（档案 kite_range/kite_run）；施法停移（ai_stop + cast_heal）。EventBus.heal_cast 信号可观测。**L2 降级**：`[meric].txt` 不存在 → 祭司用通用动画，weapon_mericstaff.tscn 复用 magicstaff 贴图。12 用例单元套件（test_meric_heal）全过，既有 25 套件零回归。battle_sim 扩展 2 场景（8矛2祭_v_8矛 / 8矛2祭_v_镜像）+ heal_cast 指标采样，8 既有场景零回归。battle_arena 预设 1/3 加祭司。**关键 BUG 修复**：ai_controller `_try_combat` 中 `return false` 缩进错位致全单位 idle+dazed（已修）。覆盖率 53%→55%（MericAi 0%→100%，见 §三）。**待验收**：6.2 观察场人工验收（7 观察项+4 仲裁项，需用户游戏内确认）。

### P8 · 批次 7a：巨人+抓掷（2.5~3 轮，风险项）

- **资产**：`[giant].txt` 18 动画全齐（含 `Giant-Grabbng-Spearton` 抓掷专用）。
- **改动点**：大比例渲染（body_scale 体系）+ 单位数据（超高 HP/慢速/AOE 挥击）+ **抓掷状态机**（抓取→举起→抛投→被掷单位物理弹射+落地 AOE）+ GutSpinner 投射物（§四）。
- **风险**：三处易出运行时 bug（抓取目标选择、被掷单位物理接管、落地结算）——每处先 grep 现有 API 再调用。

### P9 · 批次 10：物品栏系统（2~3 轮）

- **目标**：主控随时换武器/装备（"各种武器都可以用"），扩 BG3/MC 式格子背包。
- **已落地（最小核心）**：主控热键 1~5 换武器——`weapon_type` setter 已驱动重挂武器模型/站姿/攻击动画与射程/命中帧重解析。
- **待开工**：物品数据结构 ItemDef（武器参数数据驱动，并入 P5 数据化）；背包 UI（格子/拖拽/装备槽：主手+副手盾+消耗品，StickKit 复用）；拾取/掉落；换武器动作（原版有小动作+冷却）。原版形态参考：`InGameShop`/`HudInventory`（§四）。
- **验收**：主控 1~5 即时换武器全链路生效；背包 UI 开合/拖拽装备生效；battle_sim 无回归。

### P10 · 批次 12：特效扩容（~1 轮）

- **范围**（对齐原版 Effects 16 类，§四）：**DirectionalBlood 方向血溅 / ExplosionScorch 爆炸焦痕（兼召唤/爆炸地面标记，SpawnGroundScorch 同族）/ GroundSlam 震地 / Rain+Cloud 天气**。fx 模块现有 4 效果 → 扩到 8+。
- **验收**：近战命中方向血溅、法术/召唤地面焦痕、巨人震地（随 7a）；battle_sim 无回归。

### P11 · 批次 4：法术一部分（1~2 轮，用户确认范围后）

- **结构**：先立 **Spell 基类**（统一冷却/耗金/施放动画/效果，原版 15 法术全继承它，§四）→ 再挂 ArrowVolley 箭雨 + HealSpell 群疗。
- **验收**：战场施放两法术观感对齐原版；其余法术可按基类低成本追加。

### P12 · 批次 3：阵营皮肤（排后）

- 不复制素材，学原版组织方式自绘；代码侧皮肤槽系统 1~2 轮，美术工时另计。

### P13 · 批次 1：音效接线（用户放延后，可随时插队）

- 事件真值已导出，AudioManager SFX_EVENTS 框架已等价，纯接线 0.5~1 轮。

### ✅ 已完成批次存档

#### 批次 6：编队动态跟队（2 轮）——✅ 2026-09-01

- **改动点**：[formation_system.gd](../../stick-world/modules/combat/scripts/command/formation_system.gd) 加 `follow_squad_id`/`follow_gap` 锚定字段；0.5s tick 落点 = 前队质心 − 行进方向 × gap；前队全灭解除锚定；**前队接敌 → 后队越过 gap 推进支援**（9b 补丁）；[battle_arena.gd](../../stick-world/tests/dev/battle_arena.gd) 三班接线（矛先锋 ADVANCE_ALL，剑锚矛 gap150，火锚剑 gap150）；behavior_move `hold_on_arrive` 驻留 + 号令 `follow_order` 来源标记。
- **验收**：三班纵深推进；前队接敌后后队推进支援；formation 套件回归绿。

#### 批次 5：盾姿态分层动画（1.5 轮）——✅ 2026-09-01

- **已落地**：spine_import 增 `block_walk/block_crouch/block_attack_1~3`（5/5）；SPEAR 档案持盾动画组 + `block_move_mult 0.8`；visual_controller `set_block_stance` + `play_attack(blocking)` 随机三连刺（set_state_animation 换状态节点动画不增节点，命中帧订阅不受影响）。
- **验收**：端盾行军/蹲姿待命/三连刺；举盾被击走 Block-Hit 池。

#### 掷矛（0.5 轮）

- `SpeartonAi.EnableASingleSpearThrow` 直译，复用箭矢投射物——挂 9f/5 复验后做。

---

## 三、AI 覆盖率审计（2026-09-01，对账 `legacy_AI_classes.cs`）

> 方法：以 dump 原版 AI 层全部类签名为基准（`Ai` 基类 55 行为函数 + 11 兵种 Ai 类 61 函数 + `TeamAi` 19 + `Formation` 7 ≈ **133 个行为函数**），逐函数映射本项目实现（`modules/units/scripts/ai/` 99 函数 + `command/` 53 函数，跨类结构不同按**语义**对账）。状态：✅ 语义对齐 / ◐ 机制在但偏差 / ❌ 未复刻。**每轮批次完工后更新本表。**

### 覆盖率总览

| 层 | 原版函数 | ✅ | ◐ | ❌ | 严格覆盖 | 含近似 |
|---|---|---|---|---|---|---|
| `Ai` 基类 | 55 | 40 | 3 | 12 | 73% | 78% |
| ArcherAi | 15 | 10 | 2 | 3 | 67% | 80% |
| SpeartonAi | 5 | 4 | 0 | 1 | 80% | 80% |
| MagikillAi | 5 | 5 | 0 | 0 | 100% | 100% |
| SwordwrathAi | 1 | 1 | 0 | 0 | 100% | 100% |
| MinerAi | 6 | 3 | 1 | 2 | 50% | 67% |
| MericAi（P7） | 3 | 3 | 0 | 0 | 100% | 100% |
| GiantAi（P8） | 2 | 0 | 0 | 2 | 0% | 0% |
| TeamAi（P6） | 21 | 17 | 4 | 0 | 81% | 100% |
| ZombieAi | 13 | 0 | 0 | 13 | 0% | 0% |
| StatueAi/BarricadeAi | 2 | 0 | 0 | 2 | 0% | 0% |
| Formation | 7 | 7 | 0 | 0 | 100% | 100% |
| **合计** | **133** | **73** | **6** | **54** | **55%** | **59%** |

### 逐簇对账（Ai 基类 55 函数）

| 簇 | 原版函数 | 本项目对应 | 状态 |
|---|---|---|---|
| 主循环 | Update | ai_controller._make_decision + behavior_*.update（结构不同：状态机 vs 多分支） | ◐ |
| 编队跟队 | MoveInFormationBehindAnotherFormation / MoveInFormationBehindFollowUnit / RunToFormationPosition / DetermineFormationTargetPosition / GapBetweenFormationGroups | formation_system._update_squad_follow / get_squad_dest / follow_gap | ✅ |
| 编队稳定 | FormationPositionIsStable / UpdateCatchingUpToFormation / IsInTheFormation | formation_system `_formation_position_is_stable`（死区内不重发号令）/ 追赶 = 距槽位超阈值下 `run+catching_up`（behavior_move 收盾疾跑、落定恢复端盾）/ `is_unit_in_formation`（11b） | ✅ |
| 编队结构 | Formation 类 7 函数（UNITS_PER_COLUMN/ROW_GAP/formationOrder/FilterDownARandomRow/ShouldSwitchUnitsInFormation/Add/Remove） | formation_system 槽位制（11b）：`slots` 成员↔槽位双射 + 增减员全量重算（Add/Remove 直译）+ 贪心换位近者填前排（ShouldSwitch 直译）+ 列随减员收缩（FilterDown 等价）；`get_squad_dest("formation")` 前列贴锚/后列退 ROW_GAP；常量 UNITS_PER_COLUMN=3/ROW_GAP=56 待实测校准 | ✅ |
| 举盾 | UpdateBlock / UpdateBlockWhenInFormation | behavior_move._update_formation_block + attack._update_arrow_threat_block | ✅ |
| 接近/走 A | RunToTarget / ShouldRunToTarget / IsTargetReallyClose / RunTowardsEnemyPosition / MoveToMiddleOfTheMap / MoveToWaypoint / SetWaypoint / AtWaypoint | behavior_attack 接近段 + 号令 move + engage_in_range（11a：`IsTargetReallyClose` 独立阈值已补；waypoint 系未做） | ◐ |
| y 走位 | personalityControlledY / AdjustGoalYToMoveTowardsTarget / DetermineYComponentWhenRunningToTarget / CanAdjustYPositionOnly / ShouldAdjustYPositionTowardsTarget / CanWalkTowardsTarget / IsCloseEnoughToAdjustYTowardsTarget | behavior_attack y 对齐 6 函数直译（11a：替换纯随机漂移；档案 y_align_* 四参；9p `y_aim_tolerance` 为首个消费者） | ✅ |
| 绕障 | RestrictTargetSpotWhenBehindWall / AdjustXSoWeDontRunToBehindWall / AdjustPositionOffStatue / IsMovingPastStatue / DetermineGoalYToAvoidStatue | （无城墙/雕像玩法；掩体仅 seek_cover） | ❌（玩法依赖） |
| 预判 | PredictedPosition | 箭矢 ARROW_LEAD_FACTOR 移动预判 | ◐ |
| 目标 | UpdateTarget / IsValidForForwardOnlyTarget / OnlyTargetsUnitsForward / InAgroRange / CanAttack / AiDistance | TargetFinder.find_target + 射程/集火（前向限制/威胁分级部分缺失） | ◐ |
| 攻击 | Attack / AttackFromRange / GetTargetAttackSpot | behavior_attack 攻击段 + 远程延迟发射 + 攻击槽位外圈 | ✅ |
| 溃逃 | NeedsToRunAway / IsUnderThreat | ai_controller 士气分支 + behavior_retreat（11a：`_is_under_threat` THREAT_RANGE 内存活敌人真值化，无威胁不溃逃） | ✅ |
| 面向 | FaceDirection / SetNaturalFacingDirection / Face | behavior_base `face_target`/`face_position` 统一入口（11a：AI 面向调用全部收口） | ✅ |
| 主控 | IsBeingUserControlledByPro | possessed + USER_CONTROLLED_ATTACK_SPEED 1.3 | ✅ |
| 杂项 | DetermineXRunPower / IsPositionBacktracking / AlwaysAttacks / ShouldStand* 3 虚函数 | DetermineXRunPower 已入接近段（11a）；IsPositionBacktracking/AlwaysAttacks/ShouldStand* 散布在档案或未做 | ◐ |

### 兵种 Ai 类缺口（批次方案）

| 类 | 缺失函数 | 复刻方案 | 批次 |
|---|---|---|---|
| ArcherAi | CastleArcherWallPositionX / GetCastleArcherXAttackPosition / RunToTargetCastleArcher（~~MissingArrowsTolerance~~ ✅ 11d / ~~NextGaussian 三参版~~ ✅ 11d） | 前两者已并入 P5 数值校准 ✅（脱靶容忍度=弹药浪费阈值，档案 `missing_arrows_tolerance`）；CastleArcher 簇依赖城堡玩法挂总账缓 | ~~11d~~ ✅ |
| SpeartonAi | EnableASingleSpearThrow | 掷矛一次性开关（0.5 轮） | 随手 |
| SwordwrathAi | —（Update=冲脸档案已对齐） | — | ✅ |
| MinerAi | IsBarricadeBlocking / IsBeingAttackedByAnotherMiner | 路障/矿工互殴依赖对应玩法，挂总账缓 | 11e |
| **TeamAi 全类** | StanceUpdate / BalanceOfPowers / BalanceOfPowersRatio / ShouldAttack / ShouldDefend / ShouldGarrison / Garrison 系 5 函数 / BuildUnitsUpdate / BarricadeExists 等 19 函数 | **逐函数直译**（不是姿态机概念近似）：BalanceOfPowers 真值公式、Garrison 驻防状态机、BuildUnitsUpdate 造兵（依赖经济系统联动） | P6 |
| ZombieAi | Pounce 扑击系 4 函数 / DefendModeForZombies / UpdateKaiSummon 等 13 函数 | 玩法依赖（感染/Kai 召唤），挂总账缓 | 11e |
| ~~MericAi~~ ✅ / GiantAi | ~~全类~~ | ~~P7~~ ✅ / P8 批次 | ~~P7~~ ✅ / P8 |

### 结论

- **AI 行为层真实覆盖率 ≈ 55%（严格）/ 59%（含近似）**（P7 完成后：MericAi 3 函数逐函数直译 3✅ 无桩，HEAL 持续回复 + 后排站位 + kite 撤而不打 + L2 降级通用动画；P6 TeamAi 21 函数 17✅+4 桩◐，9i+ 五项增强全开关默认关零回归）——缺口集中在**整类**（Giant/Zombie）与**簇**（绕障），不是零散函数。
- 消解路径：P8（Giant 整类），完成后覆盖率预计 55% → 60%+。

---

## 四、SWL 全模块对账（2026-09-01，python 统计 `dump.cs` 命名空间）

> 方法：流式统计 legacy `dump.cs` 全部类型（2966 个 / 187 命名空间），其中 `StickWar.*` 游戏代码 **363 类型 / 35 命名空间**（其余为 Unity 引擎/Spine/插件）。剔除平台服务（IAP/广告/云同步/成就/AB 测试/RemoteTuning ≈ 40 类型，不复刻），游戏性模块 14 个，对账如下。

| SWL 模块（类型数） | 内容 | 本项目对应 | 状态 / 参考价值 |
|---|---|---|---|
| **Game 核心**（15） | GameController / LevelLoader / GameCamera / ObjectPool / RenderLayer / Barricades / Mines / InGameShop / AssetCache | game_root / scene_loader / camera_rig / FxPool / 资源建筑 | ◐ 骨架在；**InGameShop（战场商店）→ 并入批次 10 物品栏**；Mines 挖金经济=不同路线（村民经济），参考平衡 |
| **Entities**（20） | Unit 基类 + 16 兵种/建筑（含 CastleArchers / King / GiantBoss / MainStatue / Statue / Minion / Zombie）+ Team + HealthBar + ConversionChannel | units 模块（stickman_entity + WeaponMount 单类多兵种）+ battle_instance 阵营 | ◐ 兵种数据化分型在；**缺：CastleArchers 城堡弓手、Statue/MainStatue（雕像=SWL 胜利目标）、King/GiantBoss（BOSS）、ConversionChannel（单位转化）**——雕像/BOSS 与本作大世界定位不同，按玩法批次决策 |
| **Entities.Ai**（14） | 133 行为函数 | ai/ + command/ | **严格 53% / 含近似 57%**，逐函数对账见 §三 |
| **Spells**（15） | Spell 基类 + ArrowVolley 箭雨 / HealSpell 群疗 / LightningStorm / LazerBeam / MinerGoldRush / RaiseGold / SpawnUnit / SpeartonMadness / SwordwrathRage / SummonElite / SummonGiant / SummonGoldenSpearton / TrainingHaste / TurretPower | ❌ 全缺（用户已拍板只要一部分：ArrowVolley + HealSpell） | **高参考**：Spell 基类统一"冷却/耗金/施放动画/效果"结构——P11 实施时先立基类再挂具体法术 |
| **Effects**（16） | Blood / DirectionalBlood（方向血溅）/ ExplosionScorch（爆炸焦痕）/ GroundSlam（震地）/ LightningOnUnit / EarthquakeEffect / Rain / Cloud / StatueDeath / ArrowEffect / FollowUnit / StoneParticleSystem | fx 模块（4 效果：尘土/飘屑/火花/法爆） | **高参考**：血溅与爆炸焦痕是战斗观感大头，P10 扩容清单：血溅/焦痕/震地/雨云天气；焦痕同时是召唤/爆炸的地面标记（SpawnGroundScorch 同族） |
| **Projectiles**（2） | Arrow（已深度参考）/ GutSpinner（巨人甩摆武器投射物） | arrow_projectile ✓ | Arrow 已对齐；GutSpinner 并入 P8 巨人批次 |
| **Levels**（14） | Level 基类 + Tutorial / ArchidonTutorial / Ambush / GiantBossLevel / Sandbox / Tournament / SuperDeathMatch / EndlessDeads / 关卡排序 | 战场图 + 观察场（Sandbox 等价物） | ◐ 本作走战略图大世界，关卡制不照搬；**Tutorial 系结构**（分兵种教学关）Alpha 后参考；SandboxLevel=观察场已等价 |
| **Modes**（13） | Campaign / Tournament / Missions（5）/ EndlessDeads（2）/ 存档数据 | ❌（战略图路线） | 模式**清单**可复用为玩法变体：无尽尸潮（EndlessDeads）/超级乱斗（SuperDeathMatch）适合做观察场/演练变体，成本极低 |
| **Game.UI**（9） | **HudInventory（战场物品条）** / HudUnitButton / Joystick / TutorialArrow / UnitUnlocked | ❌ | HudInventory = 批次 10 物品栏的原版形态参考；HudUnitButton（造兵按钮）/TutorialArrow（教学箭头）Alpha 参考 |
| **Sound**（4） | SoundManager / SoundEffects / MenuMusic / SoundSettingsData | AudioManager + SFX_EVENTS 框架 ✓（音效资产未接线） | **P13**（用户放延后）：框架已等价，纯接线 |
| **Personalities**（1） | Personality（兵种个性数据：y 走位偏好/激进度等） | behavior_profiles.gd（RWR 档案制） | ✅ 等价实现（档案字段即 Personality 数据） |
| **UserInterface**（159+12） | 菜单/面板/商店/设置全量 | ui_global（远少于 159） | 低优先：多数为商店/设置面板；**UX 流程参考**（主菜单→模式选择→解锁进度），Alpha UI 批次时按需 |
| **Animation**（3） | AnimationTimeOffset / Interpolate / SunSetAnimator（日落环境动画） | stickman_anims + environment 夜间压暗 | ◐ SunSetAnimator 对应已做的时间光照 |
| **Texture**（3）/ MiniLegends / GameLoopTesting | 文本注记工具 / 小游戏原型 / 循环测试 | — | 低参考；GameLoopTesting 思路=本项目 battle_sim/tests 已超集 |

### 结论

- SWL 除 AI 外的**可复刻游戏层**五块：**Spells 法术（15 类）**、**Effects 特效（16 类）**、**战场经济/商店（InGameShop+Mines）**、**模式变体（EndlessDeads/SuperDeathMatch 等）**、**剩余兵种实体（CastleArchers/Statue/King/GiantBoss/Zombie）**。
- 本项目已有等价或超集：Game 核心骨架、Unit/HealthBar/Team、Projectiles.Arrow、Personality（档案制）、Sound 框架、Sandbox（观察场）。
- 与本作大世界定位冲突、按需参考的：Levels 关卡制、Modes 战役/锦标赛、Statue 胜利目标（可抽象为"战争目标建筑"）。
- 立项：Spells 基类 → P11；Effects 扩容 → P10；InGameShop/HudInventory → 批次 10；模式变体 → Alpha 后低成本；CastleArchers → 城堡玩法批次（待拍板）。

---

## 五、关键路径与数据源

| 资源 | 路径 |
|---|---|
| universal 主骨架（剑矛弓镐杖全动画） | `F:\VSCode\game-2-aux\external\decompiled\legacy\spine_raw\核心单位骨架\[skeleton].txt`（100 动画全量清单用 python 读 `animations` 键） |
| 巨人/祭司/僵尸等骨架 | 同目录 `[giant].txt` `[meric].txt` `[zombie].txt` 等 |
| legacy dump（14 个 Ai 类签名） | `F:\VSCode\game-2-aux\external\decompiled\legacy\dump\legacy_AI_classes.cs` |
| legend dump（组件/系统清单） | `F:\VSCode\game-2-aux\external\decompiled\legend\dump\` |
| 动画导入输出 | `res://modules/units/animations/`（spine_import 缺省目录） |
| 两代对比分析（机制清单） | `F:\VSCode\game-2-aux\external\decompiled\两款解包游戏完整代码分析与移植决策.md` |
| 行为参数档案（兵种个性唯一入口） | `res://modules/units/scripts/ai/behavior_profiles.gd`（RWR 式基线+覆盖） |

## 六、验收工具与命令

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

# 测试（unit 批量秒级；-Match 按套件名过滤）
bash tests/run_all.sh
```

## 七、工作方式约定（新对话必读）

1. **轮次口径**：直译/接线类一轮 3~5 子项；新机制 1 轮 1 主体 + ~30% 返工率。用户验收节奏决定日历时间。
2. **新调 API 先 grep 方法签名**（教训：`register_unit` 不存在，真名 `add_unit(unit, faction)`）。
3. **跨类引用一律显式 preload**（防 headless `class_name` 未注册误报；先例见 weapon_mount 的 ScriptBehaviorProfiles/ScriptStatusEffects）。
4. **类型化数组常量不经三元表达式**（退化为 untyped Array 运行时报错，先例 stickman_anims.pick_hit_anim）。
5. **用户已定决策（勿反转）**：盾牌只绑矛兵；staff 不风筝（召唤护卫方案）；法术只要一部分；皮肤不复制素材。
6. **每轮改完**：语法检查全部 touched 文件 → battle_sim 回归 → 用户游戏内验收；**更新 §三 覆盖数**（对照审计表，不凭感觉）。
7. 行为改动尽量进 **behavior_profiles 参数**而非硬编码（RWR 制度）；新机制做成能力开关（档案字段）。
8. 批量测试进程内 autoload 全局状态会跨套件残留（教训 2026-09-01：battle_started 自动暂停把 TimeManager 置 PAUSED → 后续武器/投射物套件的 TimeManager 门禁全部空转）——batch_runner 每套件前重置 TimeManager；新增依赖全局状态的门禁时必查批量污染。
9. **先查解包再写复刻**（教训 2026-09-01：召唤位置按想象做错两轮）：新增机制先 grep `legacy_AI_classes.cs`/`legacy_animation_and_entities.cs` 字段与方法签名，标注 dump 真值依据；无真值的近似值须注明"待实测校准"并挂总账。
