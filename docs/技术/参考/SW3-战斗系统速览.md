# SW3 战斗系统速览（Stick War: Saga il2cpp dump 实录）

> 证据源：`F:/Downloads/Stick+War_+Saga_2026.5.7174_APKPure.xapk`（com.maxgames.stickwar3，v2026.5.7174）。
> 产物（git-ignored）：`external/il2cppdumper/in_saga/`（libil2cpp.so 126MB + global-metadata 19MB）、`external/il2cppdumper/out_saga/dump.cs`（49.8MB）。
> 复现：解包 xapk 取 `config.arm64_v8a.apk` 内 `lib/arm64-v8a/libil2cpp.so` + 主包 `assets/bin/Data/Managed/Metadata/global-metadata.dat`，跑 `external/il2cppdumper/tool/Il2CppDumper.exe <so> <metadata> out_saga`。
> 性质：il2cpp dump 只有签名/字段（无方法体），本文记【事实】= 签名与字段可证；行为语义为【推断】处标注。

## 架构【事实】

- sim = **Photon Quantum 确定性 ECS**（`quantum.code.dll`/`quantum.core.dll`/`PhotonDeterministic.dll` 独立程序集；游戏系统在 `Quantum.Systems` 命名空间，全部 `SystemMainThread`）。官方 2019 dev log "stable networked multiplayer physics engine" 即此；官方回放 blob（stickwar3replays.blob.core.windows.net）= 确定性的直接旁证。
- sim 速率 **15 FPS**（Movement 字段注释原话 "at the 15 FPS sim rate"）。
- 表现层 = Unity URP + **Spine 骨骼动画**（spine-csharp/spine-unity，`HitUpdate(Frame, SpineAnimator, ...)` 直证）+ FMOD 音频；官方视觉自述"3D 环境分层 + 2D 火柴人 sprite rig"。
- 行为层**相对 SWL 全量重写**：SWL 的 17 个 Ai 标识符（OnlyTargetsUnitsForward / DIRECTION_CHANGE_FREQUENCY / GetTargetAttackSpot / MoveInFormation 等）在三代 dump 仅 RunToFormationPosition/UpdateTarget/PredictedPosition 零星幸存。

## sim 系统全景（SystemMainThread，共 70+）【事实】

战斗行为按**单职责系统**拆分（对比 SWL 单个 Ai 类的大 Update）：`FindTargetAiSystem` / `MovementSystem` / `MeleeAttackSystem` / `RangedAttackSystem` / `ProjectileSystem` / `MissileSystem` / `FormationSystem` / `ArriveAtFormationAnimationSystem` / `TeamAiSystem` / `UnitAiSystem` / `UnitAiOverrideSystem` / `BlockStanceSystem` / `ParrySystem` / `IdleStandVariationSystem` / `CastleArcherAiSystem` / `MinerAiSystem` / `SpellAiSystem` / `AbilityCastingAiSystem` / `SleepSystem` / `StunSystem` / `BurnSystem` / `PoisonSystem` / `SlowSystem` / `RageSystem` / `BuffSystem` / `TeatherSystem`（拴绳）/ `FogOfWarSystem` / `CapturePointSystem` / `WallSystem` / `WallBuilderSystem` / `GarrisonHealSystem` / `KeepInBoundsSystem` / `TargetableSmoothSystem` / `UserControlSlowWhenRunThroughUnitSystem`（穿行减速）等。

## 对本项目最值钱的四条实录

### ① 朝向限频（我们 2026-10-06 修复的官方同款）【事实】

`Movement` 组件字段（注释原文照录）：

```csharp
[Header("Limit how often DirectionFacing can flip L/R. Anti-jitter for very fast melee units
(Riptor/Riprider) that overshoot their melee point at the 15 FPS sim rate.")]
public QBoolean LimitFacingChangeRate;
public int LastFacingChangeFrame;
```

- 官方也遇到"快速近战冲过攻击点 → 左右甩头"，解法同我们的 `try_set_facing` 节流。差异两处：SW3 按**帧号**（`LastFacingChangeFrame`，确定性可回放）而非墙钟；且是**按兵种开关**（只给高速近战开，不全局一刀切）。Movement 另有 `IsSliding` / `IsCatchingUpToEnemy` / `TimeHasBeenAtFullRunSpeedInXAxis`（满速时长——用于跑/急停判定）。

### ② 找目标 = 增量改进 + 滞回 + 驻留时长（FindTargetAiSystem）【事实签名/推断语义】

- `ImproveTargetIncremental`（增量换靶，不全量重扫）/ `RestoreBestTarget(..., FP hysteresis, ...)`（**滞回参数**入签名）/ `NotBeenOnTargetForEnoughTime`（目标**驻留时长**门槛）/ 分层阈值 `OutOfFireRangeTier` / `UnreachableTier` / `TargetPriority(..., FormationMember*, ...)`（打分含编队上下文）/ `PreferStatueWhenChasingPast`（追过头的雕像偏好）。
- 对照本项目：我们的 sticky target + 集火滞回是同族简化版；**驻留时长**与**分层阈值**是批 4/7 可直译的增量。

### ③ 近战攻击（MeleeAttackSystem）【事实】

- `AttackWhileRunningUpdate` / `UpdateTargetOffsetToRunTo`：**走 A 边打**是一等机制（移动中攻击有独立的目标偏移计算）。
- `HitUpdate(Frame, SpineAnimator s, ...)` + `HasHitEventPassed(Frame, SpineAnimator, FP t)`：命中帧走 **Spine 动画事件时点**（与我们批 1 的"Hit 帧表"同源思路）。
- `InRangeForHit(..., FP xRange, FP zRange, FP targetWidth)`：命中射程**分 x/z 双轴 + 目标宽度**（3D 化的椭圆判距）。

### ④ 编队（FormationSystem）【事实签名】

- `UpdateFormationStructure`（出 frontOfFormation / columnsInArmy / 三缓存锚点）+ `UpdateFormationToStandBehindFrontLines`（**二线站位锚在前线单位动态位置后**，非固定 x）+ `GetFormationGap`（**逐列间隙**）/ `GapBetweenColumnsModifier` + `SortInsideFormation`（阵内排序）+ `TryComputePushApart` / `PushApartFromRandomMembersOfThisFormation`（编队内推挤按确定性配对）+ `UpdateIsJoiningFormation` / `FixRandomUnitsInFormation`。

## 与本项目现状对照的读后判断【推断】

1. 单职责系统拆分 vs 我们 behavior 状态机 + 组件：SW3 的系统边界就是我们行为拆分的终态参照（格挡/招架/受击组各自成系统）。
2. `LimitFacingChangeRate` 按兵种开关值得我们跟进：全局节流对慢速单位是多余约束（当前无害，若批 3 出现转身迟滞再按档案开关收窄）。
3. 命中判距 x/z 双轴 + 目标宽度，比我们当前纯距离判定精细，批 7 打击感可直译。
