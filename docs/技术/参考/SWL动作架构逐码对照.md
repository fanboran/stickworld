# SWL 动作架构逐码对照（SWL × 本作）

> 目的：把《火柴人战争遗产》（下称 SWL）的**动作/动画架构**与本作逐代码构件对应，标出对齐项与差距项——弓手俯仰三轮返工的教训：不逐码对照就抄，抄到的只是表面。本文只写"双方各是什么、如何对应、差在哪"；修法裁决见 §9 差距总账。
> 标注口径沿用 [SWL-单位行为完整翻译.md](SWL-单位行为完整翻译.md)：【事实】= dump/骨架/反汇编直接可证；【推断】= 证据不足以实锤。

## 0. 证据源

| 侧 | 材料 | 位置 |
|---|---|---|
| SWL 代码签名 | Il2CppDumper dump.cs（9.8MB，Unity IL2CPP） | `external/il2cppdumper/out_legacy/dump.cs` |
| SWL 动画真值 | Spine 3.8.99 骨架 JSON（**93 动画 / 22 皮肤 / 5 事件**，含逐骨旋转关键帧） | `external/decompiled/legacy/spine_raw/核心单位骨架/[skeleton].txt` |
| SWL 指令级 | libil2cpp.so 反汇编（capstone + 方法名标注） | `external/il2cppdumper/disasm.py` |
| SWL 行为翻译 | 全字段/方法中文对照（本文不复述，按节引） | [SWL-单位行为完整翻译.md](SWL-单位行为完整翻译.md) |
| 本作代码 | stick_rig / units / hd2d / combat 模块 | `stick-world/modules/` |

## 1. 总架构：一体 vs 双城

| | SWL | 本作 |
|---|---|---|
| 引擎 | Unity + Spine 3.8 runtime | Godot + 自研 Bone2D 骨架 + Animation tres |
| 单位对象 | `Unit : MonoBehaviour`——逻辑(Update)与表现(SkeletonAnimation)同体同进程 | 逻辑/表现分离：battle_sim 确定性批模拟（SoA 数据）+ 表现镜像链 |
| 动画播放 | `Spine.AnimationState`（track 制）每单位一套 | `AnimationTree` 状态机 + LOD 节流手动 advance（`stickman_rig._process`） |
| 表现写入时机 | `LateUpdate()`（动画应用后、渲染前）——**运行时改骨的合法窗口** | 帧尾晚优先级 `_process`（`process_priority=1000`）+ 批渲染标脏 |
| 渲染 | 每单位 SkeletonRenderer（Unity 侧合批） | SubViewport 烘焙成卡 → `char_sprite_3d` billboard / 远景 MultiMesh 桶 |

**结构差异的代价【事实】**：SWL 里"直写表现"一行代码的事（`LateUpdate` 里 `FindBone().rotation = aim`），本作要走完整镜像链（实体态 → visual_controller → feed → char_sprite_3d → rig → overlay），且**必须晚于动画推进**。弓手俯仰第一版臂写挂在 `process_frame` 信号——该信号先于一切 `_process`（含 rig 的 AnimationTree advance），先写后必被轨道值覆盖，全帧失效、战场读数平射（探针 `tools/dev/aim_pitch_probe` 0 差异实锤）。这是镜像架构自带的坑，本文档后半每条链路都标注了对应窗口。

## 2. 骨骼层：逐骨对应表

SWL 主骨架 = Miner 基核 + 皮肤换装全兵种共用（22 皮肤）；本作 = 单一 `SKELETON_DATA`（`stickman_skeleton.gd`，骨 id 0~24，注释自证来自 SWL Swordwrath 骨骼数据补译）。【事实】

| SWL 骨（Spine） | 本作骨（id/名） | 对应注记 |
|---|---|---|
| `root`（地面原点） | `hip`(0) | SWL root 为空基准、`bone` 才是髋；本作 hip 兼任根 |
| `bone`（髋，x=−4 y=183，**腿挂其下**） | `spine_root`(21) | 本作拆纯传动层；腿挂 spine_root 下【事实】（SWL 腿挂 bone 下，等价） |
| `minertorso1` | `lower_torso`(6) | 腰枢 |
| `bone2` | `chest_mid`(22) | 胸中段（SWL Draw 动画里 −10~−16° 胸倾的承载骨） |
| `bone3` | `upper_torso`(7) | 上胸 |
| `minerhead1` | `head`(10) | 本作头圆挂 head 骨 + `HEAD_ORBIT=23` 附件式上偏（SWL 同为骨+附件偏置语义）【事实】 |
| `minerarm1/2` | `upper_arm_outer`(18)/`forearm_outer`(1) | 外臂 = 拉弓手（SWL `Arrow1` 盾/弦通道挂此链） |
| `minerarm3/4` | `upper_arm_inner`(19)/`forearm_inner`(14) | 内臂 = **持弓臂**（`pickaxe1` 弓挂此链） |
| `pickaxe1` | `weapon_hand`(23) | 武器骨（弓/矛/镐换装） |
| `Arrow1` | `shield_hand`(24) | 盾/箭通道骨 |
| `minerleg1..4`/`minerfoot1..2` | `thigh/shin/foot` ×2 (16/3/4、17/11/12) | 腿足 |
| —（Giant-Rider/Dead-Leader 子树） | — | 巨人骑手/死灵领袖皮肤骨，本作未建（无对应兵种） |

SWL 有而本作无的骨设施【事实】：`allBodyColliders`/`allBoneFollowers`/`SetToSimpleColliderMode`（骨骼跟随碰撞体，大群时降级单碰撞体）、死亡 ragdoll（`AttachBoundingBoxRagdollColliders`）——本作死亡走动画 + 尸体渐隐，无 ragdoll（既有设计取舍）。

## 3. 动画数据层：逐动画对应（Archidon 全集）

SWL 骨架 93 动画全集见 [翻译档 §4](SWL-单位行为完整翻译.md#④-动画全集清单spine-骨架-json-实测)；弓手 9+1 专属对照：【事实】

| SWL 动画 | 时长 | 事件 | 本作对应 | 对齐状态 |
|---|---|---|---|---|
| Archidon-Draw | 2.00 | 0.50 `Drawn` + 0.53 `Hit` | `attack_bow`（2.0，metadata 事件 0.5/0.5333） | ✅ 事件时刻逐位同 |
| Archidon-Hold | 2.00 | — | `attack_bow_hold` | ✅ |
| Archidon-Reload | 1.17 | — | **缺** | ❌ 差距#3 |
| Archidon-Walk / Walk2 | — | — | `walk_bow` / `walk_bow_hold`（持瞄走） | ✅ |
| Archidon-Run | — | — | `run`（通用） | ≈（SWL 弓手有专属跑姿，本作共用） |
| Archidon-Stand1 | 2.67 | — | `idle_bow` | ✅ |
| Archidon-Death1/2 | — | — | `dead` 族（变体池） | ≈ |
| 城弓专属 ×1 | — | — | — | ❌（城弓兵种未规划） |

动画**内容**层面（非机制）注意【事实】：本作 attack_bow 三件套的姿势是手 K 原创（2026-08 批次），非 Spine 轨迹转译——SWL Draw 的臂/胸/头旋转曲线在 `[skeleton].txt` 里逐关键帧可查，可作为后续"姿势复刻"的精确基准（如 bone2 胸倾 −10.3→−15.7、minerhead1 头 −19.1→−6.3 的 Draw 曲线）。

## 4. 播放控制层：逐方法对应

| SWL（dump.cs 签名） | 本作 | 对齐注记 |
|---|---|---|
| `AnimationState.SetAnimation / ClearTrack` | `stickman_rig.play` / 状态机 travel；`visual_controller.play`（2D+镜像双路） | ✅ 同构（镜像侧加 seq 序号防同名重播丢失——本作特有） |
| `TrackEntry.timeScale` ← `GetDrawAnimationSpeed(name)` | `set_anim_speed`（**仅移动速率匹配**；oneshot 恒 1.0） | ❌ **拉弓动画变速未译**（差距#2）：SWL 按目标拉弓时长反推动画速度，drawPower 越大拉得越慢/初速越高 |
| `IsAttacking / IsReloading / IsAiming` | `has_pending_strike` / `can_attack` / 瞄准表现窗（`weapon_mount._aim_visual_active`） | ✅ 语义等价 |
| `Hit()` 命中帧回调 | 动画事件 `Drawn/Hit` → `weapon_mount` 计时（`BOW_FIRE_DELAY_FALLBACK=0.5333`） | ✅ 同一真值来源（Hit@0.5333） |
| `SelectHitAnimation`（部位×方向×强度变体池） | `Anims.pick_hit_anim` + 变体换装（swap 通道） | ✅ 直译（批1 曾修变体/状态分家） |
| — | LOD：`set_anim_update_hz` 分桶 + 批渲染 | 本作特有（SWL 靠 SimpleColliderMode 降耗，渲染不降档） |

## 5. 弓手战斗链：逐时序对应

```
SWL:  ShouldAim(站定+目标进射程) → isAiming → 播 Draw ──0.5s──▶ Drawn(拉满)
      → [UpdateAim 每帧追踪瞄准角] ──0.033s──▶ Hit 事件=SpawnArrow
      → drawPower 决定初速/伤害/动画速度 → Reload(1.17s) → 下一轮
本作: behavior_attack(can_attack+burst gate) → perform_attack → attack_ranged
      → 登记 _pending_ranged_target + BOW_FIRE_DELAY(≈0.5333) → fire_arrow
      (ArrowBallistics 抛物线解算+高斯散布+热度) → attack_bow 动画同事件对齐
      → 瞄准表现窗持瞄(attack_bow_hold/walk_bow_hold) → 下一轮
```

| 环节 | SWL | 本作 | 状态 |
|---|---|---|---|
| 射角解算 | `ArcherAi.AimAngle(dist, ref able, v=15, target, source, rand)` | `ArrowBallistics.solve`（ARROW_VX=850/G=2000） | ✅ 同构（v=15 为 Unity 单位制，量纲不同语义同） |
| 散布 | `NextGaussian`（currentShotBodyRandomness） | `next_gaussian` + sustained_fire 热度 | ✅ 直译 |
| 射角→姿势 | `UpdateAim`：Lerp 追踪 + `FindBone(骨).rotation = aim−4`（LateUpdate）【事实：反汇编；骨名 literal 静态不可解析，实机观感=**仅持弓臂抬**】 | `get_aim_pitch`（同源解算）→ `entity.aim_pitch` → feed → `rig.set_aim_pitch` → overlay（lerp 10/s=GetAimRate 等价）→ 晚优先级 `_process` 采样基值绝对写 `upper_arm_inner` | ✅（三轮收敛：头轨道→髋枢全身→**持弓臂**；修法=实机观感基准） |
| 拉弓力度 | `DrawBow(power)/DrawBowGradually/UnDrawBow`（AI 渐拉、玩家拖拽定力） | AI 恒满弓；玩家附身 `fire_arrow_manual(power)`（蓄力有、渐拉表现无） | ≈ 附身侧待做（拖拽弹道 UI，见[拉弓操控逆向](../../项目/审计/SWL拉弓操控逆向_2026-09-19.md)差距对照） |
| 装填 | `Reload` 动画 1.17s + `IsReloading()` | 无（冷却静默） | ❌ 差距#3 |
| 弹道 | `Arrow`（Rigidbody2D+gravityScale，`launchY`） | `arrow_projectile`（解算式抛物线+落点地面线） | ✅（弹道层已追平，插箭/爆头已有） |

## 6. 朝向与移动

| SWL | 本作 | 状态 |
|---|---|---|
| `FaceDirection` + X 翻转 | `try_set_facing`/`_apply_scale`（scale.x 翻面） | ✅ |
| `DIRECTION_CHANGE_FREQUENCY=0.5`（`lastDirectionChangeTime`） | 帧号制 15 帧节流（`_set_facing_rate_limited`） | ✅ 直译 |
| `OnlyTargetsUnitsForward`（前向目标过滤，按兵种开关） | `target_acquire.only_forward`（能力在、接线 false 按兵种分级待批4+） | ≈ |
| `AttackWhileRunning`（边打朝向锁） | `_combat_face_lock` + `_force_facing` 强制通道 | ✅（背身拉弓修复后同语义） |
| `walkPower`/`Run`（Rigidbody 力模型） | `entity_motion`（速度+换档斜坡，批3） | ≈ 架构不同、观感目标同 |

## 7. 编队/战线（创始人最新点正相关）

| SWL（`Formation` 类）【事实】 | 本作（`battle_line.gd`） | 差异 |
|---|---|---|
| `UNITS_PER_COLUMN`（每列人数常量）/`ROW_GAP` 行距 / `formationOrder` 兵种前后序 | `_upc = clampi(band*2/spread, 4, 8)`（组方阵列高夹 4~8）/`_spread` 槽距 | **列数语义相反且本作夹死 4~8**：SWL 列沿屏幕纵向排满（全队每人有列位），本作战线纵向只铺 4~8 列、余部纵深叠列到二线 |
| `GetFormationXOffset`/`FormationCols`/`FilterDownARandomRow`（随机抽排补位） | 槽位随员数重算 + 补位收缩 | ≈ |
| `MoveInFormation(goalX)` 全队连续平移 | `line_x` 连续推进 + 接战停线/远程冻结 | ✅（批5 已照抄） |

**差距#1（创始人 2026-10-09 点正「一堆人到处乱跑 / 够不到战线就在后面等着 / 上下距离这么大为啥不上下延长战线」）**：近战 36 人 = 6 宽×6 深——纵向行动带 ±360px 只被 6 列占掉大半，多余班在二线无槽可站（等位/游走）。SWL 语义是**纵向列满全员入线**。拟修方向（未落码）：`_upc` 夹钳放宽为按未入线人数扩展（列数=⌈存活近战/纵深上限⌉，上限仍受行动带高度约束），纵深超过 N 排的余部归二线驻位待命而非游走。

## 8. 渲染与性能

| SWL | 本作 | 注记 |
|---|---|---|
| SkeletonRenderer 逐单位网格 | SubViewport 烘焙成卡（idle 5Hz/近距 10Hz/远距 LOD 桶） | 本作为 96 单位上限 + HD-2D 26° 取景特化；SWL 移动端百单位网格 |
| `IsInSimpleColliderMode` 大群降耗 | sim 模式批推进 + 报表节流 | 架构不同 |
| 帧同步 | battle_sim 确定性（墙钟/RNG 治理过的双体制） | 本作强项 |

## 9. 差距总账（按影响排序，修法另行裁决）

1. **战线纵向不满编**（§7）：upc 夹 4~8 → 余部二线游走/干等。创始人已点正，拟修方向已记（纵向扩列+二线驻位）。**【创始人裁决项】**
2. **drawPower→动画变速/初速体系未译**（§4/§5）：`GetDrawAnimationSpeed` + 力度影响拉弓节奏——SWL 弓手射速节奏的"呼吸感"来源之一。影响：我们弓手每轮拉弓等长，节奏机械。
3. **Reload 装填动画缺**（§3/§5）：SWL 每轮射击间有 1.17s 装填表现；我们冷却静默站桩。补一个 `attack_bow_reload` 三件套即可挂现有时序。
4. **Draw 姿势精确复刻**（§3）：本作三件套手 K 原创；SWL 逐关键帧在骨架 JSON 可查——如需"像素级 SWL 观感"，可按 `[skeleton].txt` 曲线重写 tres 轨道（胸倾 −10~−16°、头 −19°→−6° 等）。
5. **附身弓手拖拽弹道 UI**（§5）：已有逆向档差距对照，随弓操控改造做。
6. SWL 弓手专属 Run 姿 / 城弓兵种 / ragdoll：低优先，兵种扩展时再说。

## 10. 三轮俯仰返工的教训（防再犯）

1. **抄机制先抄应用窗口**：SWL 任何"运行时改骨"都发生在 LateUpdate（动画后、渲染前）。本作镜像架构等价窗口 = 晚优先级 `_process` + 批渲染标脏；`process_frame` 信号在一切 `_process` 之前，写必被踩。
2. **反汇编骨名不是都能解**：literal pool 字符串运行时才填充（槽值/字面量表错位实锤）——拿不准的骨名用**实机观感**裁决，别拿推断当事实（髋枢全身倾斜版就是这么错的）。
3. **观感结论要确定性验证**：视觉模型问询会被提示词带偏（两版都被判"符合预期"）；像素 diff 探针（`tools/dev/aim_pitch_probe`）才是回归防线。

## 11. 架构问答与开放裁决（2026-10-09 创始人九问）

逐条如实回答"为什么"；结论分三类：**有据**（有记录的理由，但可再裁决）、**链式遗漏**（上游没做下游跟着没做，无独立理由）、**自创无据**（本作自己发明、SWL 没有的约束）。

1. **总架构（模拟/表现分离）为什么？** 有据：2026-10-06 创始人定方向"全方面照抄 SW3 架构"（`确定性模拟核心.md` 档头），SW3 = Photon Quantum 确定性 ECS + 表现镜像。收益=回放（P4 未落）/headless 批测/联机潜力。代价=每个表现语义一条镜像链+写序坑（俯仰三返工全在这层）。**当前实况：镜像税在缴、回放主收益未兑**。
2. **骨设施（ragdoll/BoneFollower）为什么没有？** 架构后果：SWL 箭是真 Rigidbody2D 物理弹、靠骨骼跟随碰撞体命中（爆头=撞头骨碰撞体）；本作箭是解算弹、命中在 sim 数学判定——骨碰撞体无用武之地。ragdoll 缺失是烘焙成卡管线的代价（尸体是烤好的卡，骨物理死了）——若渲染架构改直接 rig 渲染，ragdoll 变便宜。
3. **动画轨迹为什么不复刻？** 链式遗漏+时序：三件套手 K 于 2026-08-21，骨架逐帧数据系统利用（翻译档 §4）晚至 10-04，至今只对账事件时刻、未复刻轨迹。**没人写 Spine JSON→tres 转换器**（骨名/坐标制/y 轴向换算），数据一直在 `[skeleton].txt` 里躺着。这是本可电锯化却没造电锯的最大欠账（93 动画×逐骨曲线白放着）。
4. **拉弓动画变速为什么没译？** 链式遗漏：`GetDrawAnimationSpeed` 的输入是 drawPower 力度体系，AI 侧早裁"恒满弓"，力度不存在→变速无从谈起。若补力度体系（玩家侧已有蓄力骨架），变速随手可接。
5. **弓手战斗链差距在哪？** 时序/弹道/散布/事件已对齐（§5 表）；缺的全是"手感层"：力度变化（每轮拉弓等长=节奏机械）、装填可见拍、AI 渐拉、玩家拖拽瞄准 UI。
6. **装填为什么没有？** 同 3：手 K 批次没做这个动画，冷却静默站桩无人察觉缺口；骨架里 Archidon-Reload（1.17s 带全部曲线）在，转换器就位后机械移植。
7. **朝向真复刻了？为什么反复左右翻转（热锅蚂蚁）？** 复刻的是节流常数（0.5s/次），**没复刻的是翻转的源头治理**：SWL 单位移动意图稳定（编队锁定+PushApart 容差），本作未接战单位的移动意图在振荡（分离推挤换边/槽位路径横穿/y 微移），0.5s 节流只是限速不是稳态——实测 vx 翻转 worst 2.6/s（10-06 轮）。根治=批3（facing 滞回/换档斜坡/分离错峰，**未做**）+战线槽位稳定（差距#1）。症状真实存在，非复刻完成。
8. **编队/战线为什么不学全？** 自创无据：`_upc` 夹 4~8 是批5 战线落地时自创的"可读性"约束（SWL 无此值，SWL 语义=纵向列满全员入线）。无理由保留，差距#1 拟修方向已备（纵向扩列+二线驻位）。
9. **渲染端可否推倒（保留 HD-2D 26° 取景）？** 开放裁决。现状真实成本：每单位 SubViewport 烘焙+readback+坏帧闸+LOD 桶+feed 推送——本轮三个 bug 全活在这层。三条替换路线：
   - **A 共享视口图集**：一张大 viewport 渲全部单位 rig、quad 采样各自格子——杀掉 viewport 群与 readback 风暴，保留 3D 深度合成与 26° 取景，feed 链保留（改动最小）。
   - **B SWL 式直接画布**：角色直接 2D 渲染不进 3D 深度，26° 取景只留环境——最简单最像 SWL，代价=角色与建筑前后遮挡丢（可用 y-sort 近似）。
   - **C 3D MultiMesh 骨段直渲**：性能上限最高、重建量最大。
   待创始人圈路线；A 与 B 不互斥（近景 A 远景 B 类混合）。
