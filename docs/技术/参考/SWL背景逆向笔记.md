# SWL 背景逆向笔记（火柴人战争遗产 Unity 版）

> 来源：创始人提供的 APK（`火柴人战争遗产_2022.1.9_APKPure.apk`，Unity IL2CPP），
> 经 UnityPy 解包扫描（`external/swl_apk/legacy/`，导出样张 `legacy_out/`）。
> **仅作逆向参考，贴图不直接入游戏资产**（与 Terraria Demo 资产政策区分开——SWL 是
> 在售商业游戏，只学架构不搬素材）。

## 一、总体架构：一张大背景板 + 少量条带层

场景对象命名（GameObject 全量扫描）还原的层级结构：

```
Sky → Mountains(Mountain ×10) → HillsAndMiniMountains(hill1~3)
→ background:grass_1~4（每层多实例平铺）→ background:shadow_1~7（多层，单层 30+ 实例）
→ background:trees_2 / tree1~3 → background:midground_2 → background:foreground
→ Foreground:Layer3/Layer4
（关卡变体：Ashes:Layer3~8、Armory:Layer1~2、grave_* 墓地关）
装饰：Cloud(6)~(70) 单场景 65 个云实例；UnitsInBackground / UnitsInBackground2（背景层远景小人）
```

贴图实测：

| 贴图 | 尺寸 | 形态 | 作用 |
|------|------|------|------|
| `background day` | 1024×1024 | 全不透明，白顶→蓝渐变→白底 | 整关卡背景板（天空+氛围一次性画完） |
| `sky` | 1024×779 | 全不透明，灰蓝低饱和 | 阴天/夜关背景板 |
| `bg` | 812×608 | 全不透明，青绿 | 特殊关背景板 |
| `classicBG` | 496×817 | 全不透明，天→棕绿原野→白雾 | 经典关背景板（**原野+地平线画在板里**） |
| `trees` | 2048×1166 | 64% 不透明 | 透明底大树线层（视差） |
| `Cloud1~5` | 512×101 横条 | 白色半透明 | 横条状云带（非零散云朵） |
| `IceHills` | 128×32 | 小图 | 小尺寸山丘条（平铺/拉伸用） |

## 二、关键结论（回应创始人的三个疑问）

1. **"人家压根没有地平线？就是山线？"**——对：地平线不存在于场景拼装里，它**画在背景板内部**
   （classicBG 垂直色带：天空 #a3cbe9 → 棕绿原野 → 底部白雾渐变）。场景层只叠山/丘/树线，
   每层与下一层的衔接靠美术把边缘画进彼此的形状里（山脚插进雾里），不靠运行时过渡。
2. **"多层显示像越来越远的原野、上方有蜿蜒河流"**——那是一张 1024 级**手绘背景板**的内容，
   不是程序生成；shadow_1~7 多层实例是阴影/地形条带，配合做视差与纵深。
3. **"人家是每关都画图吗？"**——是：每关一张大背景板 + 条带层手工组装。我们不能走这条路
   （美术短板），我们的对应做法是**背景板程序化生成**：按生物群系参数离线烘焙
   "天空渐变 + 远山剪影 + 原野 + 河流 + 地平线雾"整板（PIL 管线，同九宫格贴图哲学），
   条带层（树线/云带/山条）分层生成后叠加，运行时挂 sky_decor 既有的 modulo 视差机制。

## 三、可直接学的三个技巧

- **背景层里放远景小人**（UnitsInBackground）：远处有几个小剪影在走动/劳作，"世界活着"的
  感知成本极低——我们的场景图可加同款装饰层（程序放置的远景火柴人剪影）
- **云是横条带不是零散云**：512 宽横条云带平铺，比单朵云更"远"、更整洁
- **层间衔接画进贴图里**：山脚/树根在贴图内就带雾化边缘，场景层之间不需要运行时过渡逻辑
  ——我们的生成管线应把"边缘雾化"作为条带贴图的固定输出规格（底部 alpha 渐变带）

## 四、对地平线问题（提案 C 节）的修正

消灭"地面材质硬截断"的本质 = **地平线处必须有内容物**（原野/雾/山脚），且内容物的边缘
自带渐变。参数化生成的整板背景（含画进去的地平线雾+原野）比"多层条带 + 运行时雾带补丁"
更接近 SWL 观感；条带层保留做视差纵深。

## 五、单位行为 dump 真值（il2cpp 签名实录，2026-10-13 裁决#32 对照核对）

来源：`external/il2cppdumper/out_legacy/dump.cs`（火柴人战争 Legacy，9.8MB）、
`external/il2cppdumper/out_saga/dump.cs`（Stick War 3/Saga，50MB）。IL2CPP dump
无方法体——方法名/字段名即行为流程实录，语义由命名与参数推断。

**Legacy `StickWar.Game.Entities.Ai.Ai` 基类方法表（裁决#31-#32 逐项核对的基准）**：

- 真货（本项目已直译保留）：`DetermineXRunPower`（远跑近走）、`IsTargetReallyClose`
  （贴身压上）、`GetTargetAttackSpot`/`AttackFromRange`（攻击槽位）、y 对齐 6 函数
  （`ShouldAdjustYPositionTowardsTarget`/`DetermineYComponentWhenRunningToTarget`/
  `AdjustGoalYToMoveTowardsTarget`/`CanAdjustYPositionOnly`/`CanWalkTowardsTarget`/
  `IsCloseEnoughToAdjustYTowardsTarget`）、`OnlyTargetsUnitsForward`（前向锁定）、
  `PredictedPosition`（跑位截击用，非出手门）、`FaceDirection`/`Face`。
- ArcherAi 专属真货：`ShouldKite`（风筝）、`isAiming`/`GenerateNextShotRandomness`
  （高斯持瞄）、`MissingArrowsTolerance`（脱靶容忍）、`PushApartTolerance`
  （站桩间距）、`AttackLargeTarget`。
- **不存在**（此前自创/RWR 血统，已删）：犹豫（hesitate）、受击规避侧移、
  包抄走位、围攻名额外圈等位、连射点射、近战出手预判门。

**SW3（saga）`Quantum.Systems.Unit.Ai` 三件套补充**：

- `UnitAiSystem.UpdateUnitAi`：默认 `MoveToFormationPosition`（走编队位），接战条件
  满足则 `MoveAndAttackEnemy` → 近战 `MoveAttackTargetMelee`+`ComputeAttackerZStagger`
  （攻击者纵深错位，不做名队排队）、远程 `PositionRangedUnitToFireOnTargetWhenInRange`
  +拉弓瞄准释放链（`ShouldAim`/`Aim`/`ShouldReleaseRangedAttack`）。
- `MeleeAttackSystem`：`CanAttack`（`FrameNextCanAttack` 帧冷却）→ 动画命中帧
  `HasHitEventPassed` → `Strike`，命中判定 `InRangeForHit(xRange, zRange, targetWidth)`
  ——出手端无预判门，命中帧自检射程。
- `Movement` 组件：单一 `MaxSpeed` + `Acceleration`/`Braking`（无走跑双速切换），
  `IsCatchingUpToEnemy` 追击提速标记；`LimitFacingChangeRate` 朝向翻转限频防抖。
- `FindTargetAiSystem`：目标优先级 = 距离向量 + 折扣族（`PreferUnitsInRange`/
  `DiscountZAxisALittle`/`OutOfRangeDiscount`/`UserControlDiscount`）+ 攻击计数
  （`IncrementAttackerCount`/`DecrementAttackerCount`，选目标时给"少人打的目标"
  折价——是**选目标**的折扣，不是出手排队门）。

## 六、米拉奇战记（Miragine Battle）反编译提取

- 源：`F:\VSCode\WB\2026-09-07-03-04-16\米拉奇战记\米拉奇战记.swf`（4.6MB，三层
  加载器壳：壳 → BinaryData 嵌套 SWF → 再嵌套；真游戏在第三层 `miraqi_L3_2.swf`）。
- 工具链：JPEXS FFDec（`ffdec-cli`，PowerShell 通道运行——Git Bash 直跑 java 会段错误）；
  壳层剥取用自写 python tag 解析（DefineBinaryData 里签名 `CWS` 即嵌套 SWF）。
- 产物：`external/decompiled/miraqi/script/`（68 个 .as，包 `dragonforce.*` +
  主时间轴 `miragine_fla.*`；greensock 补间库占一半，游戏本体 ~1300 行）。
- **接敌 AI 全貌**（`Isometric2DEntity` 297 行——创始人点名的接敌效果实底）：
  每帧 `ai()` = `findTarget()`（最近敌，y 距离 ×30 折损 ≈ 只看横轴）→
  `approachTarget()`：走到「目标正前方 range 处」的停位点，`|Δx| ≤ range &&
  |Δy| ≤ 30` 即出手；出手 = `weaponSpeed` 帧冷却锁（锁定期间全停移动）+ 生成
  `Isometric2DAttack` 投射物（近战也是短程飞行的武器精灵），命中端同款
  `|Δy| ≤ 30` 纵深带复检。**无分离推挤、无预判、无任何多余门**——身体永不
  互穿的观感来自「停在自身射程外缘」+ 攻击全程站定。
