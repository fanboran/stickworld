# SWL 单位行为完整翻译（Stick War Legacy 反编译材料穷尽翻译）

> 深蓝小组·首席翻译官。本档是项目重实装 SWL 单位战斗行为的**唯一真相源**，对 `external/` 下 SWL 反编译材料做穷尽翻译。
>
> **资料边界声明**：il2cpp dump（`dump.cs`）只有类字段与方法签名、**没有方法体**。因此本档的"完整翻译"= 字段体系 + 方法签名 + Spine 动画全集 + 字符串字面量真值的穷尽罗列；一切"行为逻辑"均为按命名与领域知识做的推断，逐条标注【事实】（签名/字段名/字符串直译/常量值）或【推断】（附依据与置信度）。**凡标注"签名无体，不可译"的条目，行为细节在本材料体系内不可恢复**，实装时按推断语义自行定值。unity 序列化默认值（prefab 里各 `attackAnimations[]` 到底填了什么）不在本材料体系内，同样不可译。

## 资料源与类索引

| 资料 | 路径 | 说明 |
| --- | --- | --- |
| il2cpp dump | `F:\VSCode\game-2\external\il2cppdumper\out_legacy\dump.cs`（279050 行） | 字段+签名，无方法体 |
| 字符串字面量 | 同目录 `stringliteral.json`（8337 条） | 动画名/事件名/音效名/教学串真值 |
| Spine 骨架 | `F:\VSCode\game-2\external\decompiled\legacy\spine_raw\核心单位骨架\[skeleton].txt`（93 动画 22 皮肤）+ `meric.txt`（5 动画） | 含每动画事件帧实测 |

dump.cs 行号索引（便于回查）：ArrowVolley 270054 / HealSpell 270080 / LightningStorm 270256 / SpawnUnit 270439 / SpeartonMadness 270460 / Spell 270482 / SummonElite·Giant·GoldenSpearton 270522-270567 / SwordwrathRage 270567 / Arrow 270636 / Personality 270742 / Level 272619（嵌套类 272876-272983）/ Archer 273368 / CastleArchers 273565 / ConversionChannel 273588 / Giant 273623 / HealthBar 273773 / King 273811 / Magikill 273823 / Meric 274032 / Miner 274140 / Minion 274249 / Spearton 274261 / Statue 274349 / Swordwrath 274441 / Team 274518 / Unit 274795（Type 枚举 275667 / DAMAGE_TYPE 275705 / DamageParameters 275716）/ Zombie 275775 / Ai 276050 / ArcherAi 276254 / Formation 276343 / GiantAi 276399 / MagikillAi 276432 / MericAi 276456 / MinerAi 276474 / SpeartonAi 276507 / SwordwrathAi 276547 / TeamAi 276562 / ZombieAi 276660 / ArrowEffect 276720 / DirectionalBlood 276796 / HealthTick 266586 / GameController 269037。

标注图例：字段表"标注"列 = `【事实】字段名与常量值` + 语义置信度（高/中/低）；签名无体不可译的写明。

---

## ① Unit 基类（`Unit : MonoBehaviour`，命名空间 StickWar.Game.Entities）

全部单位（含五兵种、Giant/Miner/Statue/Zombie/Minion/King/Barricade）的公共基体。字段按职责分组；方法按调用族分组。

### 1.1 静态常量（值全部随 dump 落盘，【事实】）

| 常量 | 值 | 语义 |
| --- | --- | --- |
| `SKIN_STUN_REDUCTION` | 0.2 | 皮肤增益：受眩晕时长减免 20%（置信度高） |
| `USER_CONTROLLED_ATTACK_SPEED` | 1.3 | 玩家手操单位攻速 ×1.3（置信度高） |
| `BONUS_TO_ZOMBIE_RATIO` | 1.3 | 对僵尸伤害加成 ×1.3（置信度高） |
| `LIFESTEAL_RATIO` | 0.2 | 吸血比例 20%（置信度高；配 `ApplyLifeSteal` 族） |
| `USER_CONTROLLED_SPLASH_HIT_LIMIT` | 4 | 手控近战溅射最多 4 个目标（置信度高） |
| `USER_CONTROLLED_SPLASH_RANGE` | 1 | 手控溅射半径 =1（世界单位，置信度中） |
| `USER_CONTROLLED_SPLASH_MODIFIER` | 0.2 | 溅射伤害系数 20%（置信度高） |
| `SKIN_DAMAGE_REFLECT` | 0.2 | 皮肤增益：反伤 20%（置信度高；配 `ApplyDamageReflect`） |
| `BURN_PERIOD` | 13 | 燃烧状态持续 13 s（置信度中——"period"也可能指重燃间隔） |
| `BURN_AMOUNT_PER_SECOND` | 8 | 燃烧每秒 8 点（置信度高） |
| `BURN_TIMES_PER_SECOND` | 0.25 | 燃烧结算频率 0.25 次/秒（置信度高） |
| `SLOW_TIME_PERIOD` | 1 | 减速持续 1 s（置信度中） |
| `SLOW_TIMESCALE` | 0.5 | 减速时时间流速 ×0.5（置信度高） |
| `FREEZE_TIME_PERIOD` | 1.3 | 冻结持续 1.3 s（置信度中） |
| `FREEZE_TIMESCALE` | 0 | 冻结=时间流速 0，完全定格（置信度高） |
| `LEAF_BUILD_COST_DESCREASE` | 0.9 | 皮肤"叶子"系造价 ×0.9（原作拼写 DESCREASE；置信度中） |
| `WALL_THICKNESS` | 0.6 | 墙体判定厚度 0.6（配 `IsXBehindWall`/`WallBoundary`；置信度中） |

### 1.2 静态字段（值在 .cctor 里设置，签名无体，数值不可译）

| 字段 | 语义 | 标注 |
| --- | --- | --- |
| `static Unit.Type[] formationOrder` | 出兵界面/队列的兵种顺序表 | 【事实】存在；内容不可译 |
| `static Unit.Type[] buyOrder` | 商店购买顺序表 | 同上 |
| `static float BLOCK_COOLDOWN` | 全兵种统一格挡冷却（全局值） | 【事实】存在，数值不可译【推断】格挡触发后多久内不能再格挡，置信度高 |
| `static float healthRegenPerSecondWhenUserControlled` | 手控单位回血速率 | 【事实】存在，数值不可译 |
| `static float healthRegenTimePeriod` / `lastHealthRegenTime` | 手控回血节拍与上次回血时刻 | 【事实】存在【推断】静态共享节拍=全场手控单位同一时刻回血，置信度中 |

### 1.3 兵种身份与经济字段

| 字段 | 推断类型 | 语义 | 标注 |
| --- | --- | --- | --- |
| `type` | Unit.Type 枚举 | 实际实例类型（含精英/领袖变体） | 【事实】 |
| `prefabType` | Unit.Type | prefab 原型类型（区分"普通矛兵"与"金矛兵同 prefab"）【推断】置信度中 | 【事实】 |
| `cost` / `buildTime` / `population` | int | 造价/建造时长/人口占用 | 【事实】语义高置信 |
| `formationGroup` | Formation.Group 枚举 | 编队分组（GIANTS/MEELEE/CASTERS/ARCHERS/MINERS/GENERALS/HEALERS/DEADS） | 【事实】 |
| `isSelectable` | bool | 可否被点选控制 | 【事实】 |
| `IsMilitaryUnit()` | →bool | 是否战斗单位（矿工/雕像之外的判定） | 【事实】签名【推断】语义高置信 |
| `ShouldTeamLoseIfThisUnitDies` | bool 属性 | 该单位死亡即判负（VIP/领袖单位；配 Team.VipUnitHasDied） | 【事实】 |

### 1.4 移动与物理字段

| 字段 | 推断类型 | 语义 | 标注 |
| --- | --- | --- | --- |
| `runPower` | float | 跑动力：施加给刚体的推进力主参数【推断】Rigidbody2D 力学模型的速度/力量源，置信度高 | 【事实】 |
| `runModifier` / `runOverrideModifier` | float | 跑速乘数 / 覆盖型跑速乘数（SetRunOverrideModifier 写入；Level.UnitOverrides.runOverrideModifier 喂入）【推断】override 直接替换而 modifier 相乘，置信度中 | 【事实】 |
| `GetRunModifier()` | →float virtual | 取跑速乘数（子类可改，如 Zombie 按爬行态给不同值） | 【事实】 |
| `stoppingDrag` / `runningDrag` / `blockingDrag` / `staticDrag` | float ×4 | 四态阻力：停/跑/格挡/静立【推断】UpdateDrag 按当前状态切换刚体 linearDrag，实现"松手滑行、举盾更沉"的手感，置信度高 | 【事实】 |
| `USER_CONTROLLED_SPEED` / `DEFAULT_USER_CONTROLLED_SPEED` / `USER_CONTROLLED_EXTRA_SPEED` | float ×3 | 手控速度三档 | 【事实】数值不可译 |
| `directionFacing` / `intendedRunDirection` | float | 朝向（±1）/意图跑向 | 【事实】语义高置信 |
| `rigidbody2d` / `collider2d` | Rigidbody2D/Collider2D | 2D 刚体与体碰体 | 【事实】 |
| `critCollider2d` / `headShotCollider2d` / `boxCollider2d` | Collider2D ×3 | 暴击体/爆头体/盒体——**同一单位挂多个碰撞体分层判定**（弓箭命中语义见 §7） | 【事实】 |
| `pushAwayFactor` | float | 被推开（PushApart/击退）的响应系数【推断】各兵种可配不同"推挤权重"，置信度中 | 【事实】 |
| `CanBePushed()` | →bool virtual | 可否被推挤 | 【事实】 |
| `PushApart()` | virtual | 同伴间相互推开（Archer/Zombie 重写） | 【事实】 |
| `originalScale` / `originalBoxColliderScale` / `scaleModifier` / `SetScaleModifier()` | — | 缩放体系（召唤小法师 0.65 之类由外部传入） | 【事实】 |
| `isInSimpleColliderMode` / `allBodyColliders` / `allBoneFollowers` / `bonesToUpdatePerFrame` / `boneIndex` / `SetToSimpleColliderMode(bool)` / `ShouldUseSimpleColliderMode()` / `UpdateBoneFollowers()` / `SetAllBodyColliderLayers()` | — | 性能简化模式：把多骨骼跟随碰撞体换成一个简单碰撞体【推断】大群单位时降耗；置信度高 | 【事实】 |
| `IsAtEndOfAttackAnimationAndSoCanNotChangeDirections()` | →bool virtual | 攻击动画末段锁转向 | 【事实】语义高置信 |

### 1.5 战斗核心字段

| 字段 | 推断类型 | 语义 | 标注 |
| --- | --- | --- | --- |
| `attackDamage` | float [SerializeField] | 基础攻击伤害 | 【事实】 |
| `attackRange` / `attackRangeSecondLine` | float ×2 | 一线攻击距离 / 二线攻击距离【推断】第二排单位用更长距离够前排间隙（长矛后排平刺），置信度高 | 【事实】 |
| `attackRangeMultiplier` | float [HideInInspector] | 射程乘数（升级/法术喂入） | 【事实】 |
| `attackSpeedModifier` / `customAttackSpeedModifier` / `DetermineAttackSpeed()` | float ×2 +方法 | 攻速乘数两层 + 攻速结算【推断】custom 由外部叠加（法术/手控），置信度中 | 【事实】 |
| `attackPushPower` | float [SerializeField] | 攻击命中推力（击退幅度）【推断】Giant 地震 HitTarget 有 attackPushPowerModifier 参数佐证此字段是击退力，置信度高 | 【事实】 |
| `health` / `maxHealth` / `MaxHealth` / `healthMutliplier`（原作拼写）/ `damageMultiplier` / `SetMultipliers()` | — | 血量体系与双乘数 | 【事实】 |
| `headShotBonusDamage` | float | 爆头额外伤害 | 【事实】语义高置信 |
| `critBonusDamageInflictedToSelf` | int | 暴击时反噬自身的伤害【推断】某皮肤/单位"打出暴击自损"，置信度中 | 【事实】 |
| `hitAppliesStun` | bool | 该单位的攻击附带眩晕【推断】配合 Spearton 头槌/巨人，置信度中 | 【事实】 |
| `healthPercentageToSkirmishUntil` | float | 游走（skirmish）血线阈值【推断】接敌拉扯行为：血量高于该百分比前允许脱离纠缠游斗；与 Ai.NeedsToRunAway 族配合。置信度低——签名无体，具体方向（高于游走/低于撤退）不可译 | 【事实】字段存在 |
| `doesAlwaysAttack` / `doesAlwaysAttackStatue` | bool ×2 | 无视射程持续进攻 / 无视射程专攻雕像【推断】ZombieAi.AlwaysAttacks 重写点即此语义，置信度高 | 【事实】 |
| `AlwaysAttacks()` | →bool virtual（Ai 上） | AI 层"永远进攻"开关 | 【事实】 |
| `isSpawnedAsReinforcement` / `SetAsReinforcement()` | bool +方法 | 作为增援出生（不算常规队列） | 【事实】 |
| `IsBeingDamaged()` / `lastDamagedTime` / `lastInflictor` / `LastAttacker()` | — | "正在被打"状态与最近伤害来源记录 | 【事实】 |
| `isBeingReaped` / `IsBeingReaped` | bool | 正被"收割"（ConversionChannel 转化中/尸体被拖走类状态）【推断】Miner 重写此属性（被己方回收？），置信度低 | 【事实】 |

### 1.6 格挡体系（全兵种字段，实际只有持盾者配置生效【推断】）

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `blockChance` | float：受击时格挡成功的概率 | 【事实】语义高置信 |
| `blockResetInterval` | float：格挡重置间隔【推断】两次格挡判定之间的最小时隔，防连挡；置信度高 | 【事实】 |
| `BLOCK_COOLDOWN`（static）/ `lastBlockTime` / `blockTime` | 全局冷却 + 上次格挡时刻 + 处于格挡的时长 | 【事实】 |
| `Block()` / `IsBlocking()` / `IsInBlockAnimation()` / `IsInBlockTransition()` | 进入格挡/三个状态查询 | 【事实】 |
| `BlockAttack()` / `CanBlockAttack()` / `ShouldAttackWithBlockAttack()` / `attackWhileBlockingAnimations` / `ReleaseAttack()` | 盾中刺（持盾状态下攻击）与收招 | 【事实】 |
| `blockAnimations` / `standWhileBlockingAnimations` / `runWhileBlockingAnimations` / `blockingDrag` | 格挡姿态四件套：格挡起手/持盾站/持盾行/持盾阻力 | 【事实】 |
| `neutralAnimationAfterBlocking` | string：格挡解除后回归的过渡动画 | 【事实】 |
| `IsAnEventFromABlockTrack(TrackEntry)` | 判断 Spine 轨道事件是否来自格挡轨【推断】格挡在独立 track 上叠加播放，置信度高 | 【事实】 |
| `BlockUpdate()` / `InBlockUpdate()` / `NotBlockingUpdate()` | 每帧格挡状态机三分支 | 【事实】 |
| `blockSound` | string：格挡音效名 | 【事实】 |
| `cooldownAfterAttackForBlock`（Ai 字段） | 攻击后转入格挡的冷却窗【推断】攻完→举盾的节奏节拍，置信度高 | 【事实】 |

### 1.7 动画字段体系（全部 [SerializeField] string / string[]，填什么动画名由 prefab 决定，本材料不可译）

| 字段 | 语义 |
| --- | --- |
| `runAnimations[]` / `standAnimations[]` / `transitionToStandAnimations[]` | 跑姿池 / 站姿池 / 落定成站姿的过渡池（跑步停下的衔接）【事实】 |
| `attackAnimations[]` / `attackAnimationsSecondLine[]` | 一线攻击池 / **二线攻击专用池**（配合 attackRangeSecondLine：后排用另一种攻击动作）【事实】 |
| `attackWhileBlockingAnimations[]` | 盾中刺攻击池【事实】 |
| `deathAnimations[]` / `headShotDeathAnimations[]` / `headShotFrontDeathAnimation` / `headShotSpearDeathAnimations[]` / `headShotSpearFrontDeathAnimation` | 普通死池 / 爆头死池 / 正面爆头单动画 / 长矛爆头死池 / 正面长矛爆头单动画——**死亡四分家：普通、爆头、矛爆头，各再分正/背**【事实】 |
| `blockAnimations[]` 等 §1.6 四件套 | 格挡姿态【事实】 |
| `idleAnimations[]` / `idleAnimationChance` / `idleAnimationGapTime` / `timeAfterStandingThatCanIdle` / `_lastIdleAnimationPlayTime` / `_nextIdleAnimationGapTime` / `SetNextIdleGapTime()` / `ShouldPlayAnIdleAnimation()` / `IsInIdle()` | 闲置彩蛋体系（Pushup 俯卧撑、Leader 等）：概率 + 间隔 + 站立多久后才有资格触发 + 双计时器【事实】 |
| `unitSelectedAnimation` / `SelectedUnit()` / `IsInUnitSelectAnimation()` | 点选单位时的应答动画【事实】 |
| `cheeringAnimations[]` / `CanCheer()` / `EndOfGameAnimationUpdate()` / `Level.ShouldUnitCheer()` | 胜利庆祝池（局末触发）【事实】 |
| `hitFrontHeadSmall[]` / `hitFrontHeadBig[]` / `hitBackHeadSmall[]` / `hitBackHeadBig[]` / `hitFrontMidSmall[]` / `hitFrontMidBig[]` / `hitBackMidSmall[]` / `hitBackMidBig[]` | 受击八池：前/后 × 头/躯干 × 小伤/大伤；`hitAnimationAlpha` + `HitAnimationAlphaUpdate` + `EaseOutCubic` = 受击动画叠层的透明度缓出【推断】受击动画在上层轨道播放并淡出，置信度高 |
| `SelectHitAnimation(damagePercentOfHealth, isFront, isHead)` | 受击动画选择器（Spearton/Zombie 重写）【事实】 |
| `fallAnimations[]` / `fallLongAnimations[]` / `knockdownAnimations[]` / `IsFalling()` / `CanFall()` | 被击倒/击飞三池【事实】 |
| `PlayAnimation(animation, loop, timeScale, track, playAfter, forcePlay)` | Spine 播放入口：支持多轨/延播/强插【事实】签名 |
| `RandomAnimation(string[])` / `PickAnimationFromArray(string[])` | 池内随机【事实】 |
| `SetAnAnimationIfNoneSet()` / `ShouldPlayTransitionToStandAnimation()` / `UpdateRunStandIdleAnimations()` / `RunUpdate()` / `StandAfterWasPreviouslyRunning()` / `RunUpdateWhenPreviouslyWasStanding()` / `StandAndIdleUpdate()` / `ShouldRunButIsCurrentlyStanding()` / `ShouldBeStandingButIsCurrentlyRunning()` | 跑/站/闲三态状态机全家族：跑↔站切换时插入过渡【事实】 |
| `basicRunWithOnlyArms`（Unity Animation）+ `CreateRunWithArmsAnimation()` + 字面量 `RunWithOnlyArms` | 遗留 Unity 旧版动画：仅手臂摆动的跑姿【事实】字段与字面量【推断】老版本遗留，实际新骨架不用，置信度中 |
| `SetAnimationMixDurationDefaults()` | 初始化 Spine 混合时长默认值【事实】 |
| `MustRunAtFullTimeScale()` | 慢动作下是否豁免（Zombie 重写）【事实】 |

### 1.8 受击→伤害结算链（方法签名族）

调用序按命名推断（置信度高）：

1. `Damage(amount, direction, inflictor, isHeadShot, isBlockable, damageType, isCrit, arrowHitLocation, canApplyDamageToBack)`——总入口（virtual；Giant/Spearton/Statue/Zombie 重写）。
2. `IsHitToBack(direction, inflictor)` / `ItHitToBack(inflictor, damageParameters)`——背击判定（`canApplyDamageToBack` 参数控制背击是否加成【推断】）。
3. `ApplyDamageModifiersBeforeHealthTick(amount, inflictor, damageParameters)`——结算前乘区（爆头加成/反伤判定/对僵尸加成等【推断】）。
4. `HitWithDamage(damage)` → Unit：格挡判定在此【推断】格挡成功返回伤害减免后的结果/或转发给格挡表现，置信度中。
5. `CreateHealthTick(...)` / `CreateParticleDamageEffects(...)` / `CreateBloodSplat(...)` / `ApplySound(inflictor, damageParameters)` / `DisplayTypeFromDamageType(damageType)`——飘字（HealthTick.DisplayType: NORMAL/FIRE/POISON/CRIT/HEALING）、粒子、血溅、音效四表现。
6. `RemoveHealth(amount)` / `HasBeenKilled(health)` / `KillAfterTakingDamage(inflictor, damageParameters)` → `Kill(isHeadShot, dir, isSpearHeadShot, inflictor)`（virtual）。
7. 附带状态：`ApplyBurn(inflictor)` / `ApplySlow(inflictor)` / `ApplyFreeze(inflictor)` / `ApplyLifeSteal(amount, inflictor)`（static）/ `ApplyDamageReflect(amount, inflictor, damageParameters)`。
8. 表现层重写钩子：`CanApplyHitAnimation()` / `ApplyHitAnimation(damagePercentOfHealth, isFront, isHead)` / `UpdateHitAnimation()`。
9. 音效节流：`PlayDamageSound` / `PlayPainSound` / `_lastTimePainSound` / `ShouldPlayDamageSounds(damageParameters)`【推断】群体受击时按参数决定要不要播pain，防音爆，置信度中。

`Unit.DamageParameters`（伤害参数包）【事实】全字段：`isCrit` / `isBlockable` / `isHeadshot` / `canApplyDamageToBack` / `arrowHitLocation: Nullable<Vector3>` / `direction: float` / `damageType: Unit.DAMAGE_TYPE`。
`Unit.DAMAGE_TYPE` 枚举【事实】：`NORMAL=0 / FIRE=1 / CRIT=2 / POISON=3`。

### 1.9 死亡/尸体/亡灵链

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `Kill(isHeadShot, dir, isSpearHeadShot, inflictor)` | 死亡总入口，区分矛爆头（Spearton 掷矛击杀专用死亡变体） | 【事实】签名 |
| `deadToSpawn: Unit.Type` / `deadHealthModifier` / `deadDamageMultiplier` / `deadScaleModifier` / `boneToSpawnDeadFrom` | 死后原地转生为指定类型（尸潮：人死变僵尸）；转生体血/伤/缩放乘数；从哪根骨骼处生成 | 【事实】语义高置信 |
| `DetermineRemoveOrSpawnAsDead(inflictor)` / `ShouldSpawnDeadOnDeath()` / `WasLastHitByUnitThatCausesDeadSpawnOnDeath(inflictor)` | 是否转生 + 是否由"致尸杀手"打死（特定杀手才产尸【推断】） | 【事实】 |
| `SpawnAsUndeadOnTeam(teamToSpawnOn, delay)`（协程）+ `isSpawnedFromUndeadSkin` | 延迟尸变加入指定队伍 | 【事实】 |
| `Remove()` / `RemoveWithoutKilling()` / `RemoveAllArrows()` / `RemoveTheSwoosh()` | 移除族：直接移除/不触发死亡表现/拔掉插在身上的箭/移除挥击残影（swoosh） | 【事实】 |
| `deathSound` / `headShotDeathSound` / `painSound` / `impactSound` / `strikeSound` / `spawnSound` | 音效名串六件套 | 【事实】 |
| `IsDead()` | 死亡判定 | 【事实】 |

### 1.10 状态效果（眩晕/燃烧/减速/冻结/中毒）

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `Stun(t, shouldFall)` | virtual：眩晕 t 秒，可选拌倒（`timeStunnedTill` 计时；`CanFall()` 决定能否倒地；Giant/King/Zombie 重写——大体型不可晕倒【推断】） | 【事实】 |
| `IsStunned()` | 眩晕查询 | 【事实】 |
| `Burn(burnAmount=8)` / `IsBurnt()` / `UpdateBurn()` | 燃烧（默认值=常量 BURN_AMOUNT_PER_SECOND，签名即数值证据【事实】） |
| `Slow()` / `UpdateSlow()` / `IsSlowed()` / `GetSlowTimeScale()` | 减速（Giant 重写 timescale——巨型减速效果弱【推断】） | 【事实】 |
| `Freeze()` / `CanBeFrozen()` / `IsFrozen()` / `UpdateFreeze()` | 冻结（Swordwrath 重写 CanBeFrozen=false？签名无体不可译，仅知其重写） | 【事实】 |
| `Poison(amount)` / `IsPoisoned()` / `poisonPerPeriod` / `poisonTimePeriod` / `lastPoisonTime` / `PoisonFixedUpdate()` | 中毒 DoT | 【事实】 |
| `Heal(amount, canCure=True, isLifeSteal=False)` | 治疗入口：canCure=顺带解毒【推断】置信度中 | 【事实】签名 |

### 1.11 阵地/驻防/墙体

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `Garrison()` / `UnGarrison()` / `IsGarrisoned()` / `isGarrisoned` / `garrisonHealRatePerSecond` / `garrisonTimePeriod` / `lastGarrisonHealthTime` / `HealWhenGarrisonedFixedUpdate()` | 驻防（回城）：驻防中按秒回血【事实】语义高置信 |
| `HealWhenUnitIsSelectedFixedUpdate()` | 被选中单位回血（手控回血的实例侧，配静态 healthRegen 字段） | 【事实】 |
| `IsBehindWall()` / `IsXBehindWall(x)` / `WallBoundary()` / `PreventUnitFromGoingPastEnemyWall()` | 敌墙判定与越墙禁止 | 【事实】 |
| `PreventFromGoingPastBarricades()` | 不许越过（己方/敌方）路障线【推断】拒马前站桩，置信度高 | 【事实】 |
| `PushUnGarrisonedUnitsOutOfBaseFixedUpdate()` | 把未驻防单位推出基地范围【推断】开局把堆在雕像旁的单位挤出，置信度中 | 【事实】 |
| `UpdateBattleFieldScale()` / `UpdateAchievementsForUnitControlledKills()` | 战场缩放 / 手控击杀成就 | 【事实】 |
| `IsMassive()` | 是否巨型单位（Giant/GiantBoss/Zombie 重写=true；箭对 massive 减伤挂钩，见 §7） | 【事实】 |
| `UnitCenter()` / `GetHeight()` / `height` | 单位中心/身高（血条挂点、箭命中高度用） | 【事实】 |

### 1.12 皮肤槽位体系（SWL 卖点：武器头盔箭袋全可换）

`slot_helm / slot_weapon / slot_arrow1 / slot_bag / slot_quiver`（序列化槽位名）+ 静态 `SLOT_ARROW/SLOT_QUIVER/SLOT_BAG/SLOT_WEAPON/SLOT_HELMET/SLOT_GIANT_HELMET` + `SetSlots()/SetSlot()×2/SetCustomSlots()/SetSlotsFromCampaignData()/SetSlotsForSkinSelect()/ResetUpgradeSlots()/SetSkin()/GetCurrentSkin()/currentSkin/skinLevelOverride/enemySkin/skin`。【事实】全部存在。【推断】slot 名即 Spine 附件槽名，换皮肤=换附件，置信度高。

### 1.13 Unit.Type 枚举全表【事实】

`MINION=0, SWORDWRATH=1, ARCHER=2, SPEARTON=3, MAGIKILL=4, GIANT=5, MINER=6, STATUE=7, SWORDWRATH_GENERAL=8, GIANT_BOSS=9, GIANT_LEADER=10, SPEARTON_GOLD=11, SPEARTON_ELITE=12, ARCHER_ELITE=13, BARRICADE=14, ZOMBIE=15, ZOMBIE_RISER=16, ZOMBIE_TANK=17, ZOMBIE_THROWER=18, ZOMBIE_RUNNER=19, ZOMBIE_RISER_CRAWLER=20, ZOMBIE_KAI=21, MERIC=22, ZOMBIE_LEADER=23, ZOMBIE_TANK_LEADER=24, SPEARTON_ATREYOS=25, SWORDWRATH_ENDLESS_DEADS=26, ZOMBIE_KAI_GIANT=27, ZOMBIE_STONE_GIANT=28, KING=29, ARCHER_GOLDEN=30`。
注意：五兵种的枚举位= `SWORDWRATH=1 / ARCHER=2 / SPEARTON=3 / MAGIKILL=4 / MERIC=22`（MERIC 排在僵尸族之后，是后加兵种的位置特征【推断】置信度中）；实体的类名体系里弓手叫 `Archer`（枚举叫 ARCHER，无 Archidon 类）。工厂方法 `CreateUnit(type)` / `GetUnitData(type)`【事实】。

---

## ② 五兵种实体类与 AI 类逐条

### 2.1 Swordwrath 剑士（`Swordwrath : Unit`，274441）

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `jumpAttackDamage` | float：跳劈伤害 | 【事实】 |
| `jumpAttackAnimations[]` | 跳劈动画池（骨架实测 Swordwrath-Jump / Jump2 两段） | 【事实】 |
| `JumpAttack()` / `IsInJumpAttack()` / `hasJumpAttackHit` / `lastJumpAttack` | 跳劈动作/状态/已命中标志/上次跳劈时刻 | 【事实】 |
| `JUMP_ATTACK_COOLDOWN`（static float） | 跳劈全局冷却 | 【事实】数值不可译 |
| `Run(x, y, shouldFaceDirection)` **重写** | 剑士重写跑动入口【推断】跑动中可触发跳劈（接近敌人时把普通 Run 换成 JumpAttack），置信度中——签名无体，触发条件不可译 | 【事实】重写存在 |
| `UpdateDrag()` 重写 + `originalRunningDrag` | 狂暴时降低阻力（配 `rageRunningDragDecrease`）→ 狂暴更滑更快【推断】置信度高 | 【事实】 |
| `rageParticleEffect` / `rageRunningDragDecrease` | 狂暴粒子 + 狂暴阻力减量 | 【事实】 |
| `CanBeFrozen()` 重写 | 剑士免疫冻结【推断】重写点通常是返回 false（近战快兵不被冰），置信度低 | 【事实】重写存在 |
| `Hit()` / `Attack()` / `Update()` / `FixedUpdate()` / `Kill()` / `IsAttacking()` / `IsAtEndOfAttackAnimationAndSoCanNotChangeDirections()` 全重写 | 标准战斗钩子全套 | 【事实】 |
| `swordwrathDamagePercentagePerLevel` / `swordwrathSpeedPercentagePerLevel` / `swordwrathHealthPercentagePerLevel` | 每升级成长：伤/速/血 | 【事实】 |
| `swordUpgrades[]` / `helmetUpgrades[]` | 皮肤升级附件表 | 【事实】 |

**SwordwrathAi**（276547）：仅 1 个自有字段 `rigidbody2d`（自己再持一份刚体引用【推断】Update 里直接操纵速度做冲锋/跳劈脉冲，置信度中）+ 仅重写 `Update()`。【事实】**无任何个性参数字段——基础冲锋+跳劈就是剑士全部 AI。**

### 2.2 Spearton 矛兵（`Spearton : Unit`，274261）

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `speartonBlockChance` | 矛兵专属格挡率（覆盖基类 blockChance 用【推断】Init 时替换，置信度高） | 【事实】 |
| `originalSpeartonBlockChance` / `blockChanceUpgradePercentargePerLevel`（原作拼写 Percentarge） | 原始格挡率 + 每级格挡成长 | 【事实】 |
| `shieldUpgradePercentagePerLevel` / `helmetUpgradePercentagePerLevel` / `spearDamageUpgradePercentagePerLevel` | 盾/盔/矛伤害每级成长 | 【事实】 |
| `spearDamage` / `sword` | 掷矛伤害 / 拔剑态武器附件名 | 【事实】 |
| `spearThrowAnimation` | 掷矛动画名（骨架实测 Spearton-Throw） | 【事实】 |
| `ThrowSpear()` / `IsThrowingSpear()` / `SpawnSpear()` / `PullOutSword()` / `hasThrownSpear` / `timeSpearThrown` / `spearToReattach` / `swordToAttach`（Spine Attachment） | 掷矛全流程：掷出→（矛附件消失）→拔剑→FixedUpdate 里计时→重新长出矛【推断】附件换装 + 计时回补，置信度高；SpawnSpear 生成投射物（复用 Arrow 类或纯附件表现，签名无体不可译，置信度低） | 【事实】 |
| `headButtAnimations[]` / `HeadButt()` / `IsInHeadButtAnimation()` | 头槌攻击池与状态 | 【事实】 |
| `hitAnimationsBlock[]` | **举盾被击**的受击动画池（字面量 `Hit-Spearton-Block-1/2`） | 【事实】 |
| `madnessEffect` / `madnessEffect` 挂点 | 狂乱（SpeartonMadness 法术）视觉 | 【事实】 |
| `SelectHitAnimation(...)` 重写 | 受击动画分流：举盾时走 hitAnimationsBlock【推断】置信度高 | 【事实】 |
| `CanApplyHitAnimation()` 重写 | 何时可播受击动画 | 【事实】签名无体不可译 |
| `Damage(...)` 重写 | 矛兵格挡在此判定【推断】盾兵被击先过格挡，置信度中 | 【事实】 |
| `Attack()` / `Hit()` / `Kill()` / `FixedUpdate()` / `IsAttacking()` 重写 | 标准钩子 | 【事实】 |

**SpeartonAi**（276507）【事实】：
- 字段：`canThrowASpear`（是否允许掷矛）+ `_lastArrowThreatTime`（上次感知箭威胁的时刻）。
- 方法：`Attack()` 重写 / `Update()` 重写 / `UpdateBlock()` 重写 / `IsAnyArrowThreat()` / `EnableASingleSpearThrow()`。
- 【推断】行为模型（置信度高）：`Update` 每帧调 `IsAnyArrowThreat`（扫描朝己方飞来的 Arrow）→ 有威胁则 `UpdateBlock` 强制举盾；`EnableASingleSpearThrow` 由外部（玩家指令/教程关）解锁"仅此一次"掷矛 → `Attack()` 里若 canThrowASpear 则 ThrowSpear→PullOutSword 连段。`_lastArrowThreatTime` 用于威胁记忆节流。

### 2.3 Archidon 弓手（`Archer : Unit`，273368；实体类名叫 Archer，Ai 类叫 ArcherAi）

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `range` / `castleArcherRange` | 常规射程 / 城弓射程 | 【事实】 |
| `walkPower` | 弓手行走力（弓手有 walk 和 run 两套步态的力【推断】Walk/Walk2/Run 三动画对应，置信度中） | 【事实】 |
| `_currentAim` / `_targetAim` / `Aim(angle)` / `IsAimed()` / `UpdateAim()` / `GetAimRate()` | 瞄准体系：当前仰角→目标仰角插值，插值速率=GetAimRate【推断】置信度高 |
| `_directionToShootArrow` | 出箭方向缓存 | 【事实】 |
| `_startDrawPosition` / `_drawPower` / `CurrentDrawPower()` / `DrawBow(power)` / `DrawBowGradually(power)` / `UnDrawBow()` / `IsBowDrawn()` / `IsDrawingBowBack()` / `UpdateDrawBack()` / `hasReleased` / `_hasShot` / `_timeReleased` | 拉弓体系：拉弓位置/力度/渐拉/松弓/已射标志/释放时刻【推断】drawPower 同时影响初速与伤害（喂给 Arrow.Init 的 drawPower），置信度高 | 【事实】 |
| `GetDrawAnimationSpeed(animationName)` | 按目标拉弓时长反推 Draw 动画播放速度【推断】拉弓节奏=动画变速实现，置信度高 | 【事实】 |
| `SpawnArrow()` / `ArrowLaunchVector()` / `ArrowLaunchDirection(isForShot)` / `ArrowSpawnPosition()` | 生成箭 + 出射向量/方向/出生点三计算 | 【事实】 |
| `Hit()` 重写 | 命中帧回调：Spine Draw 动画的 Hit 事件触发→SpawnArrow【推断】配合骨架实测 Archidon-Draw 有 (0.5,'Drawn')+(0.53,'Hit') 两事件，置信度高 | 【事实】 |
| `IsReloading()` / `IsAiming()` | 装填/瞄准中查询（骨架有 Reload/Hold 动画） | 【事实】 |
| `IsAttacking()` 重写 | "正在攻击"=拉弓到射出全流程【推断】置信度高 | 【事实】 |
| `Attack()` / `ReleaseAttack()` / `CanRun()` / `Update()` / `LateUpdate()` / `Run(x,y,...)` / `Init()` / `DamagedATarget()` 重写 | 标准钩子；`DamagedATarget` 重写=命中统计清零（见下行）【推断】置信度高 | 【事实】 |
| `NumArrowsLaunchedWithoutDamagingATarget`（属性）+ `UpdateAiArrowLaunchCount()` | **连续未造成伤害的射箭计数**（脱靶计数器，喂给 ArcherAi.MissingArrowsTolerance）【推断】连射不中→AI 换目标/逼近，置信度高 | 【事实】 |
| `isCastleArcher` / `isCastleArcherActivated` / `castleArcherAttackDamage` / `castleArcherUpgradePercentagePerLevel` / `archerDamageUpgradePercentagePerLevel` / `castleArcherQuiverUpgrades[]` / `castleArcherHelmentUpgrades[]`（原作拼写 Helment） | 城弓身份/激活/伤害/升级 | 【事实】 |
| `PushApart()` 重写 / `IsBeingPushedApart()` / `_lastPushAwayTime` | 弓手被挤开逻辑（站位间距的实现点） | 【事实】 |
| `CanReceiveReflectDamage()` 重写 | 弓手不接受反伤【推断】远程打人不被反甲伤，置信度中 | 【事实】 |

**ArcherAi**（276254）【事实】字段：`isAiming` / `lastNotAimingTime` / `currentShotBodyRandomness`。
【事实】方法全表：`GenerateNextShotRandomness()` / `NextGaussian()` 三个重载（标准高斯采样）/ `AimAngle(distance, ref isAbleToHitTarget, v=15, target, source, currentShotRandomness=0.5)` / `ShouldAim(target, unit)` / `AttackLargeTarget()` / `ShouldKite()` / `MissingArrowsTolerance()` / `PushApartTolerance()` / `GetRange(includeOffset=True)` / `GetTargetAttackSpot()` 重写 / `InAgroRange()` 重写 / `CanAttack()` 重写 / `AiDistance()` 重写 / `IsCloseEnoughToAdjustYTowardsTarget()` 重写 / `AdjustXSoWeDontRunToBehindWall()` 重写 / `RunToTargetCastleArcher(unit, target, adjustYEarly)` / `GetCastleArcherXAttackPosition()` / `CastleArcherWallPositionX()` / `Update()` 重写。

- 【事实】`AimAngle` 签名自带数值：**发射垂直初速 v=15**（默认参数），**射击随机度默认 0.5**；`ref isAbleToHitTarget` = 抛物线解算顺带输出"这个角度够不够得着"。
- 【推断】完整射击链（置信度高）：`Update`→`ShouldAim`（目标进射程且自己站定）→ isAiming=true 播 Draw/Hold；`GenerateNextShotRandomness` 用 `NextGaussian(mean, sd, min, max)` 生成每次射击的身体随机偏移（currentShotBodyRandomness）；`AimAngle` 以 v=15 解抛物线仰角 + 高斯散布；命中不了目标（isAbleToHitTarget=false 或连射脱靶超 `MissingArrowsTolerance`）→ 改打大目标（`AttackLargeTarget`）或前压；被近身 → `ShouldKite` 后撤拉扯。
- `lastNotAimingTime`【推断】"刚结束瞄准"的计时——瞄准被中断后要等冷却才重新拉弓，置信度中。

### 2.4 Magikill 法师（`Magikill : Unit`，273823）

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `stunAnimation` / `summonAnimation` | 两套独立施法动画名（骨架实测 Spell1/Spell2 两段） | 【事实】 |
| `CastStun()` / `StunOpponents()` / `stunDuration` / `stunDamage` / `lastStunCast` / `CanCastStun`（无——Magikill 只有 `StunCooldown()`） | 眩晕法术：AOE 放倒一片 | 【事实】 |
| `STUN_COOLDOWN` / `STUN_RANGE` / `SUMMON_COOLDOWN` / `MAX_SPAWNED_MINIONS` / `MIN_SPAWNED_MINIONS`（static int ×5） | 法术数值五常量 | 【事实】数值不可译 |
| `CastSummon()` / `CanSummon()` / `IsAtMaxMinions()` / `SpawnMinion()`（协程）/ `UpdateMinions()` / `minions` / `minionsToRemove` / `maxMinions` | 召唤小法师体系（协程=带前摇的冒出） | 【事实】 |
| `CreateStunEffectForCast()` / `CreateStunOnWandCastingEffect()` / `CreateSummonOnWandCastingEffect()` | 施法特效三入口（对应字面量 MagikillStun/MagikillStunStaffCast/MagikillStunStaffFollow【推断】置信度中） | 【事实】 |
| `unitsToDamage` | 本轮眩晕要结算的目标列表【推断】StunOpponents 先收集再统一结算，置信度中 | 【事实】 |
| `stunUpgradePercentagePerLevel` / `extraMinionPerUpgradeLevel` / `magikillSpeedPercentagePerLevel` | 每级成长：眩晕/召唤数/速度 | 【事实】 |
| `userControlledDragMultiplier` / `userControlledCooldownMultiplier` | 手控时的阻力/冷却乘数 | 【事实】 |
| `CanAttack()` 重写 | 【推断】"能攻击"=眩晕或召唤可用（法师本体不近战），置信度高 | 【事实】重写存在 |
| `Attack()` / `Hit()` / `Update()` / `IsAttacking()` / `UpdateDrag()` / `CanReceiveReflectDamage()` 重写 | 标准钩子；法师不接受反伤【推断】同弓手，置信度中 | 【事实】 |
| `hatUpgrades[]` / `staffUpgrades[]` | 帽/杖升级附件表 | 【事实】 |

**MagikillAi**（276432）【事实】：无自有字段；`Update()` / `ShouldCastSummon()` / `InAgroRange()` 重写 / `AttackFromRange()` 重写 / `CanAttack()` 重写。
【推断】（置信度高）：`ShouldStandAsCasterInMiddleOfTheMap()`（基类 virtual，MagikillAi 大概率重写为 true——法师站中场；签名无体不可译）+ `AttackFromRange` 保持施法距离输出眩晕；己方兵不足时 `ShouldCastSummon` 补兵。

### 2.5 Meric 祭司（`Meric : Unit`，274032）

| 字段/方法 | 语义 | 标注 |
| --- | --- | --- |
| `healAmount` / `healCooldown` / `lastHealTime` / `healingAnimation` / `lastHealEffectSpawn` | 治疗五件套：量/冷却/上次治疗时刻/治疗动画名/上次治疗特效生成时刻 | 【事实】 |
| `CastHeal()` / `CanCastHeal()` / `IsCastingHeal()` | 治疗三函数 | 【事实】 |
| `Attack()` 重写 | 祭司"攻击"=治疗动作（MericAi.CanAttack 同构语义）【推断】置信度高 | 【事实】 |
| `Hit()` / `Update()` / `FaceDirection()` / `Kill()` / `IsAttacking()` 重写 | 标准钩子；Kill 重写【推断】播放 Meric 骨架专属 Death（字面量 MericDeath），置信度中 | 【事实】 |
| **无攻击伤害字段、无光环字段、无复活字段** | 原作祭司只有治疗 | 【事实】（字段全表穷尽后的否定性事实） |

**MericAi**（276456）【事实】：无自有字段；仅 `Update()` / `CanAttack()` 重写 / `UpdateTarget()` 重写 三函数。
【推断】（置信度高）：`UpdateTarget` 把目标选择重写为"选最需要治疗的友军"；`CanAttack` = CanCastHeal 资格判断；`Update` 主循环=够到治疗距离→CastHeal。**没有逃跑/风筝自有逻辑**（基类 NeedsToRunAway 通用撤退兜底）。

### 2.6 编队与队伍层（行为上半场的"指挥系统"）

**Formation**（276343）【事实】：`units: List<Unit>`；静态 `UNITS_PER_COLUMN`（每列人数）/ `ROW_GAP`（行距）/ `BOTTOM_X_OFFSET`（底线偏移）/ `BOTTOM_X_OFFSET_CASTLE_ARCHER`（城弓底线偏移）/ `formationOrder: Formation.Group[]`（编队前后顺序表——数值与内容均不可译）；方法 `GetFormationXOffset(unit)` / `FormationCols()` / `FilterDownARandomRow()`（随机抽掉一排补位）/ `ShouldSwitchUnitsInFormation(front, behind)`（前后换位判定）/ `Update()/Add()/Remove()`。
`Formation.Group` 枚举【事实】：`GIANTS=0, MEELEE=1, CASTERS=2, ARCHERS=3, MINERS=4, GENERALS=5, HEALERS=6, DEADS=7`（编队从前往后的层序即此顺序）。

**Team**（274518）【事实】：`castle/wall/statue/direction/enemyTeam/units/formations:Dictionary<Group,Formation>/castleArchers/buildQueue/numberOfUnitsInBuildQueues/teamVariables/mostForwardUnit/rowLeaders[]/unitSelected/unitsLost/spells:Dictionary<Item,Spell>`；时戳字段 `timeOfStanceChange/lastProjectileLaunchTime/lastTeamDamagedTime/lastTeamAgroedTime/lastFormationUpdate/nextFormationUpdateDelay/lastAttackX/averageMilitaryPositionX`。
方法族：`Attack()/Defend()/Garrison()`（全队指令三开关）+ `Team.Stance` 枚举 `GARRISON=0/DEFEND=1/ATTACK=2` + `OnStanceChanged` 事件；`MoveInFormation(goalX, garrison, isFollowTheLeader)`（编队整体平移，isFollowTheLeader=将军跟随模式【推断】置信度中）/ `GetFormationPositionX()/GetDefendPositionX()/AdjustDefendPositionBehindBarricade(pos)/GetGarrisonPosition()/GetYPositionFromRow(row, unitsInColumn)（static）/GetXOffsetFromY(x,y,unit)/GapIfGeneral(hadGeneralInThisFormation)（static：有将军的编队留更大间隙【推断】置信度中）/UpdateFormation()/UpdateBuildQueues()/QueueUnit()/DeQueueUnit()/BuildUnit()/HasLost()/NumActiveArrows（属性：全场存活箭数，箭的消长监控【推断】配合 Arrow.TimeToWaitAlteredForNumberOfActiveArrows 做箭量性能调节，置信度中）。

**TeamAi**（276562）【事实】：字段 `_lastStanceChangeTime/_lastGarrisonTime/_lastBuildUpdate`；决策函数全表：`Update()` / `StanceUpdate()` / `BuildUnitsUpdate()` / `ShouldAttack()` / `ShouldDefend()` / `ShouldGarrison()` / `IsAttacking()/IsDefending()/IsGarrisoned()` / `BalanceOfPowers()/BalanceOfPowersRatio()`（战力对比测算）/ `EnemyArmyIsCloseToUs()/EnemyIsShootingProjectilesAtUs()/WeHaveNoDefendersAndTheEnemyUnitsAreClose()/EnemyHasNoMilitaryUnits()/TeamHasAGiant()/StatueIsLowHealth()/BarricadeExists()/WeRecentlyDecidedToGarrison()/HasDesperationGroupThatSpawned()` / `CompareUnitTypes()`。
【推断】（置信度高）：原作敌方 AI 司令=血线/兵线/箭线三种观测 + 战力比值驱动三态切换；`_lastStanceChangeTime` 等三个时戳就是**指令防抖节拍**（三态切换与建造刷新都有冷却）。

### 2.7 Personality 人格（战役对手画像，影响行为参数）【事实】

字段：`type/tier/rating/name/description/statue/statueHealth/startingGold/aiAttackMilitaryPopulationTarget/startingUnits[]/customUnits[]/buildTargets[]/spawnGroups[]/desperationSpawnGroup/startOfBattle[] 等台词数组/specialAbilities[]（SpecialAbilityConfig{spell, timeToWaitBetweenCasts, lastCastTime}）/timeBetweenUnitSelections/timeOfNextUserControlAction`；方法 `Update()/UpdateUserControl()/PickAMinerToControl()/PickAnAttackingUnitToControl()/RefreshAiTimer()/IsInPassiveMode()/Say()`。
枚举【事实】：`Type`（FILLER/PLAYER/GRANDMA/CHEERLEADER/FOOTBALLER/CLIMBER/BIKER/GOTH/BRO/SKATER/NERD/GAMER/CRAZYJAY/PRO + FILLER1-18）；`Tier`（BOTTOM/MID/TOP）；`UserControlSkill`（LIMITED/USES_IT_BUT_NOT_WELL/PRO）。
【推断】（置信度高）：人格=AI 参数包（出兵目标/开局兵/法术冷却节奏 timeToWaitBetweenCasts/手控水平），**不是单位级行为**；`timeBetweenUnitSelections` 是 AI 手控单位轮换节拍。

### 2.8 其余单位速览（行为体系共用件）【事实】字段级

- **Giant**（273623）：`stunAnimation/STUN_COOLDOWN/STUN_RANGE/lastStunCast/targetsToHit/targetsHit/scaleIncreasePerLevel/healthIncreasePerLevel/originalMaxHealth/numberOfUnitsHitAtOnce/hitNumber/canAiCastStun`；`CastStun()/CanCastStun()/StunCooldown()/CastEarthQuake(damage,startPosition)/EarthQuakePoint(position,delay,damage,attackPushPowerModifier)（协程，多点位延迟落地）/FindTargetsToHit(position,damage,range,numCanHit,isOnlyInFront=True,attackPushPowerModifier=1)/HitTarget(...)`；重写 `Damage/HitWithDamage/IsMassive=true/Freeze/Slow/GetSlowTimeScale/Stun`。【推断】AOE 地震=按点序列延迟结算+限 `numberOfUnitsHitAtOnce` 个目标+只打正面可配，置信度高。
- **Minion**（274249）：只重写 `UpdateDrag()`——小单位阻力特调【推断】更轻更飘，置信度中。
- **Statue**（274349）：`passiveIncomePerSecond/passiveIncomeUpgradePerLevel/passiveIncomeAwardPeriod/statueHealthUpgradePercentagePerLevel/isPassiveIncomeEnabled/SHIELD_TIME/statueShieldTimeActivated/towerPowerAnimator/recentAttacks:LinkedList<RecentAttack{Unit,Time}>`；`ActivateShield()/IsShieldActivated()/ShouldReduceDamageBecauseTooManyAttacksHappening(inflictor,amount)/AddAttack()/PruneRecentAttacksList()`；免疫 Poison/Burn/Slow/Freeze（四个全重写为空语义【推断】置信度高）。【推断】雕像防秒杀：按 recentAttacks 滑窗统计集火强度→超阈值减伤，置信度高。
- **Zombie**（275775）：爬行态全套（`crawl*Animations×5/normal*Animations×4/isInCrawlMode/isAbleToCrawl/crawlChance[Range]/crawlPower/walkPowerVariation`）+ 扑击（`canPounce/pounceAttackDamage/pounceAttackAnimations/POUNCE_ATTACK_COOLDOWN/pouncePower`）+ 掷击（`isRangedZombie/zombieThrowAnimation`）+ 转化（`isAbleToConvert/convertCooldown/ConversionChannel`）+ 召唤（`isSummoner/summonCooldown/summonMinCooldown/numSummonsTillMinCooldown/giantKaiSummonAnimation`）+ 巨化技（`hasGiantKnockUpAttack/numberOfUnitsHitAtOnce/knockUpAttackAnimation/knockUpAttackCooldown/hasEarthQuakeAbility/earthQuakeAnimation/earthQuakeCooldown`，`GiantHitWithDamage/FindTargetsToHit/HitTargetGiant` 与 Giant 同构）+ `isImmuneToHeadShots`。**ZombieAi**（276660）：`AlwaysAttacks=true`【推断】+ `UpdatePounce/SetPouncePowerFromDistance(distance)`（扑击力度按距离定）+ `DefendModeForZombies()` + `UpdateKaiSummon()`。
- **Miner**（274140）：采矿经济单位（`mineAnimations[]/bagSize/amountMinedPerHit/miningRate/goldInBag` 等），**MinerAi**（276474）有 `NeedsToRunAway()` 重写 + `IsBeingAttackedByAnotherMiner()` + `IsBarricadeBlocking(mine)`——矿工被吓跑与绕路障【事实】。

---

## ③ Arrow / 投射物 / 伤害 / 格挡 / 治疗 / 召唤链

### 3.1 Arrow 类（StickWar.Game.Projectiles，270636）——全项目唯一投射物类

| 字段 | 推断类型 | 语义 | 标注 |
| --- | --- | --- | --- |
| `launchY` | float | 出射 Y 分量/发射点高度 | 【事实】语义中置信 |
| `rigidbody2d` | Rigidbody2D | 箭的刚体（抛物线=物理模拟）【推断】置信度高 | 【事实】 |
| `damage` | float | 箭伤害（Archer.Hit 里按 drawPower 算好传入）【推断】 | 【事实】 |
| `team` / `inflictor` | Team / Unit | 归属队伍与射手 | 【事实】 |
| `projectileSpeed` | float | 箭速 | 【事实】 |
| `hasStopped` | bool | 已落定 | 【事实】 |
| `canApplyDamageToBack` | bool | 该箭可背击加成 | 【事实】 |
| `doesStickIn` | bool | 是否可插嵌（插身/插地） | 【事实】 |
| `causesHeadShotAnimation` | bool | 该箭可触发爆头死亡动画 | 【事实】 |
| `poisonAmount` | int | 附毒量（毒箭皮肤） | 【事实】 |
| `hasReducedDamageToStatue` | bool | 已对雕像结算过减伤（防重复结算标志） | 【事实】 |
| `DAMAGE_REDUCTION_TO_STATUE` | const 0.3 | 箭对雕像伤害 ×0.3 | 【事实】 |
| `DAMAGE_REDUCTION_TO_MASSIVE` | const 0.66 | 箭对巨型单位伤害 ×0.66 | 【事实】 |
| `inFlightArrow` / `inGroundArrows[]` | SpriteRenderer | 飞行贴图 / **预置的插地箭贴图组** | 【事实】 |
| `trail` / `EnableTrailDelayed()/DisableTrail()` | TrailRenderer | 拖尾（延迟启用防性能浪费）【推断】 | 【事实】 |
| `_timePassedWhileWaitingToFadeOut` / `_timePassedWhileFadingOut` / `isFadingOut` / `_timeToWaitUntilFadesOut` / `fadeOutOver` / `TimeToWaitAlteredForNumberOfActiveArrows()` | 消亡体系：等待→淡出双计时，**等待时长按全场存活箭数动态调整**（NumActiveArrows 越多消失越快【推断】性能自适应，置信度高） | 【事实】 |
| `_numArrowsActive`（static int）↔ `Team.NumActiveArrows` | 全场箭数统计（双记账） | 【事实】 |

【事实】方法全表：`Init(Vector2 arrowVector, float drawPower, Unit inflictor)` / `OnTriggerEnter2D(Collider2D)` / `CalculateArrowWidth(Unit unit)` / `StopProjectile(Transform stuckInto, Unit unit, bool shouldStick=False)` / `SetInActive()` / `Update()` / `UpdateStuckInArrow()` / `UpdateRotation()` / `Start()/OnEnable()/OnDisable()`。

**命中语义**（详见 §7）：`OnTriggerEnter2D` 触发器碰撞进入→`CalculateArrowWidth(unit)`（按受击者身位算箭杆没入宽度）→伤害结算→`StopProjectile(stuckInto, unit, shouldStick)`：`stuckInto` 非空=插进单位（`UpdateStuckInArrow` 让箭跟着受击者骨骼走），否则插地（换 `inGroundArrows` 贴图），等待淡出。**没有任何 AOE/范围字段——箭是纯单体碰撞命中。**

### 3.2 伤害链（整合 §1.8）

`DamageParameters` 打包 → `Unit.Damage(...)` virtual → 背击判定 → 前置乘区（爆头加成 `headShotBonusDamage`/对僵尸 ×1.3/皮肤反伤 SKIN_DAMAGE_REFLECT）→ `HitWithDamage`（格挡判定点【推断】）→ 表现四件套（HealthTick 飘字 NORMAL/FIRE/POISON/CRIT/HEALING + DirectionalBlood.Setup(isCrit, color, hitHeight, dir) 定向血溅 + 粒子 + ApplySound）→ RemoveHealth → Kill 链（爆头/矛爆头分家、尸变 SpawnAsUndeadOnTeam、雕像 RecentAttack 减伤在 Statue.Damage 重写内【推断】）。
AOE 伤害不走 Arrow：Giant/Zombie 的 `FindTargetsToHit(position, damage, range, numCanHit, isOnlyInFront, attackPushPowerModifier)` 是 AOE 收集器，手控近战溅射走 `SplashDamage(position, amount, targetHit)` + `targetsToHitWithSplash` 列表 + 三个 USER_CONTROLLED_SPLASH_* 常量。【事实】字段链。

### 3.3 格挡链

触发：受击方 `blockChance` 掷签（`Spearton` 用 `speartonBlockChance`【推断】）→ 成功则 `Block()` 进格挡态（`blockAnimations` 起手）→ `IsBlocking()` 期间被击转 `hitAnimationsBlock`（Spearton 专属池）/播放 `blockSound` → 格挡攻击：`CanBlockAttack()`→`BlockAttack()`（`attackWhileBlockingAnimations`）→`ReleaseAttack()` 收招 → `BlockUpdate/InBlockUpdate/NotBlockingUpdate` 状态机维持，`blockResetInterval`+`BLOCK_COOLDOWN`+`lastBlockTime` 节流，`cooldownAfterAttackForBlock`（Ai 层）控制攻后举盾窗口，`neutralAnimationAfterBlocking` 收尾过渡。AI 主动举盾钩子：`Ai.UpdateBlock()`（virtual；SpeartonAi 重写加箭矢威胁）。【事实】签名链 +【推断】流程置信度高。

### 3.4 治疗链

单位侧：`Unit.Heal(amount, canCure, isLifeSteal)` 总入口（吸血复用：`ApplyLifeSteal` → 目标 `Heal(..., isLifeSteal=True)`【推断】）。
祭司侧：`Meric.CanCastHeal()`（冷却 `healCooldown` + `lastHealTime`）→ `CastHeal()`：播 `healingAnimation`（Meric 骨架 Heal1/Heal2，事件帧 0.67s 'hit' 触发结算【事实】）→ 生成治疗特效（`lastHealEffectSpawn` 计时；字面量 `MericHeal`/`Heal`/`HealGlobal`【推断】为特效/音效资源名，置信度中）。
道具法术侧：`HealSpell : Spell`（商店治疗道具）：`Start()` 选目标（`<>c.<Start>b__0_0(Unit x)` 谓词=筛最伤友军【推断】）→ `HealUpUnitWithDelay(unit, delay)` 协程（延迟+持续 `<timeHealedFor>` 字段名实证持续治疗【事实】）→ `HealBeam(unit, amountToHeal)` static 协程（治疗光束表现）。

### 3.5 召唤链（四条独立支线）【事实】签名

1. **Magikill 召小法师**：`ShouldCastSummon`（Ai）→ `CanSummon()`（`SUMMON_COOLDOWN`/`lastSummonCast`/`IsAtMaxMinions()`）→ `CastSummon()` → 播 `summonAnimation` → `SpawnMinion()` 协程（`CreateSummonOnWandCastingEffect()` 前摇特效）→ 生成 `Minion`（缩放 ×`scaleModifier`【推断】）→ `UpdateMinions()` 维护 `minions/minionsToRemove/maxMinions`（`MAX_/MIN_SPAWNED_MINIONS` + `extraMinionPerUpgradeLevel`）。
2. **队伍道具召唤**：`SummonElite/SummonGiant/SummonGoldenSpearton/SpawnUnit : Spell`（`SpawnUnit` 带 `unitToSpawn/isSelectable/spawnSound/overrides: Level.UnitOverrides`——按 UnitOverrides 全参生成）。
3. **尸变召唤**：Unit `deadToSpawn` 死转 + Zombie `SpawnRiser()/Rise()` + `Level.RiserSpawn(team, insideFriendlyArmy, unitToSpawnAround)`。
4. **法术基类节奏**：`Spell{cooldown, _castTime, item, Team}` + `AiShouldCast(team)` virtual（AI 自动施法判定，各子类重写：ArrowVolley/LightningStorm/SwordwrathRage/SpeartonMadness/MinerGoldRush/TurretPower 都有）+ `MayCast(item, team)` static + `GetCooldownRatioRemaining()`。注意 **HealSpell 没有 AiShouldCast 重写**【事实】=AI 不会自动放治疗道具。

---

## ④ 动画全集清单（Spine 骨架 JSON 实测）

主骨架 `[skeleton].txt`：22 皮肤（default/Archidon(_Red)/Giant/Giant-Rider-1/Magikill/Miner(6)(_Red)/Natives_Red/Spearton(_Red)/Swordwrath(_Red)(_Red5)/Zombie×6 等）、93 动画、5 个事件定义（Cast/Drawn/Hit/Mine/Sound，均无自定义载荷【事实】）。祭司独立骨架 `meric.txt`：1 皮肤、5 动画、1 事件（小写 `hit`）。

### 4.1 五兵种 + 祭司动画全表（含实测时长与事件帧，秒）

**Swordwrath 剑士（9 专属）**

| 动画 | 时长 | 事件帧 | 语义 |
| --- | --- | --- | --- |
| Swordwrath-Attack1 | 1.33 | 1.00 Hit | 普攻一式，命中在动画后段 |
| Swordwrath-Attack2 | 1.33 | 1.00 Hit | 普攻二式（变体池第二项） |
| Swordwrath-Block | — | 无事件 | 挥剑招架姿态 |
| Swordwrath-Jump | 1.33 | 0.97 Hit | 跳劈（jumpAttackAnimations 池项） |
| Swordwrath-Jump2 | 1.33 | 0.97 Hit | 跳劈变体 |
| Swordwrath-Leader | — | 无事件 | 领袖姿态（idleAnimations 池项【推断】） |
| Swordwrath-Pushup | — | 无事件 | 俯卧撑彩蛋（idleAnimations 池项【推断】） |
| Swordwrath-Run | — | 无事件 | 专属跑姿 |
| Swordwrath-Stand1 / Swordwrath-Walk | — | 无事件 | 站/走 |

**Spearton 矛兵（14 专属）**

| 动画 | 时长 | 事件帧 | 语义 |
| --- | --- | --- | --- |
| Spearton-Attack1 | 1.67 | 0.87 Hit | 突刺普攻 |
| Spearton-Block / Block2 / Block3 | — | 无 | 格挡三段【推断】起手/保持/受击变换，置信度中 |
| Spearton-Block-Attack1/2/3 | 1.67 ×3 | 各 0.87 Hit | 盾中刺三连池 |
| Spearton-Block-Crouch / Block-Walk | — | 无 | 蹲防 / 端盾行军 |
| Spearton-Jump | 1.33 | 0.97 Hit | 跳跃攻击（对应头槌类判定【推断】） |
| Spearton-Overhead | 1.67 | 0.87 Hit | 过顶砸（headButtAnimations 池项【推断】） |
| Spearton-Pushup | — | 无 | 俯卧撑彩蛋 |
| Spearton-Run / Stand1 | — | 无 | 跑/站 |
| Spearton-Throw | 2.50 | 1.17 Hit | 掷矛（命中帧在 47% 处，投掷出手点） |

**Archidon 弓手（9 专属）+ 城弓 1**

| 动画 | 时长 | 事件帧 | 语义 |
| --- | --- | --- | --- |
| Archidon-Draw | 2.00 | 0.50 Drawn + 0.53 Hit | 拉弓：Drawn=拉满确认（播 Hold 的切换点【推断】），Hit=放箭结算 |
| Archidon-Hold / Reload | — | 无 | 拉满保持 / 装填 |
| Archidon-Run / Stand1 / Walk / Walk2 | — | 无 | 步态四件套 |
| Archidon-Death1 / Death2 | — | 无 | 弓手专属死亡两段 |
| CastleArcher-Sit | — | 无 | 城弓坐姿 |

**Magikill 法师（4 专属）**

| 动画 | 时长 | 事件帧 | 语义 |
| --- | --- | --- | --- |
| Magikill-Spell1 | 1.67 | 1.00 Hit | 施法一式（stunAnimation【推断】：施法 60% 处结算） |
| Magikill-Spell2 | 2.00 | 1.40 Hit | 施法二式，更长（summonAnimation【推断】） |
| Magikill-Stand / Magikill-Walk | — | 无 | 站/走 |

**Meric 祭司（独立骨架 5 条）**

| 动画 | 时长 | 事件帧 | 语义 |
| --- | --- | --- | --- |
| Heal1 / Heal2 | 2.00 ×2 | 0.67 hit | 治疗两式（33% 处触发结算；小写 hit 是该骨架独有事件名） |
| Stand / Walk / Death | — | Death 无事件 | 站/走/专属死亡 |

**共享死亡/受击系**：`Death1/Death2`（普死）、`Death-Headshot`（2.07s，0.07+0.43 两声 Sound 事件）、`Death-Headshot-Spear`（2.07s，0.10+0.50）、主骨架无 Forward 变体（字面量里有 `Death-Headshot-Forward` / `Death-Headshot-Forward-Spear` / `Death-Headshot-Spearton-Spear`——来自 APK 深层资产的另一版本骨架，本仓骨架缺【事实】）。

**其余**（同骨架）：Giant-Attack(3.00s,1.67 Hit)/Giant-Attack2(4.27s,1.77 Hit)/Giant-Stand/Giant-Walk/Giant-Death；Giant-Rider-Attack/Stand/Summon(4.33s, 2.0 Cast)/Walk1/Death；Miner-Mine(2.33s, 1.2 Mine 事件)/Stand1/Walk；Zombie 系 34 条（Pounce 1.50s 0.87 Hit、Crawl 系、Stone-Boss 系等）。

### 4.2 攻击节奏实测结论【事实+推断】

所有近战攻击动画的 Hit 事件都在动画 **65%-75%** 处（Attack1 0.87/1.67、Swordwrath 1.00/1.33、Jump 0.97/1.33）；掷矛在 47%；弓箭 Drawn/Hit 几乎同时（0.50/0.53=拉满即射）；法师结算在 60%-70%。【推断】原作攻速机制=DetermineAttackSpeed 改变动画 timeScale，命中帧随动画等比缩放——**命中帧不是独立计时器**（PlayAnimation 有 timeScale 参数佐证），置信度高。

---

## ⑤ 字符串字面量里的行为线索（stringliteral.json 全筛）

### 5.1 代码硬编码的动画名真值（其余动画名都来自 prefab 序列化数据，不在此列）【事实】

`Spearton-Attack3`、`Spearton-Block-Attack2`、`Spearton-Run`、`Spearton-Lifted`（被巨人抓起姿态）、`Archidon-Hold`、`Archidon-Run`、`Archidon-Walk`、`Archidon-Walk2`、`Death-Headshot`、`Death-Headshot-Forward`、`Death-Headshot-Forward-Spear`、`Death-Headshot-Spear`、`Death-Headshot-Spearton-Spear`、`Hit-Spearton-Block-1`、`Hit-Spearton-Block-2`、`Giant-Attack`、`Giant-Attack2`、`Giant-Stomp`、`Giant-Stunned`、`Giant-Grabbng-Spearton`（原作拼写 Grabbng）、`Zombie-*` 11 条、`RunWithOnlyArms`、`Stand`、`Jump`/`jump`、`idle`/`walk`/`run`/`crouch`/`attack`/`block`（小写组为通用工具串）。

**关键否定性事实**：`Spearton-Attack1/2`、`Swordwrath-Attack1/2`、`Magikill-Spell1/2`、`CastleArcher-Sit`、`Archidon-Draw/Reload/Stand1` 都**不在**字面量里——它们只经 prefab 数组喂入；代码唯一点名 `Spearton-Attack3`（第三攻击式在代码里有专门引用点【推断】手控连击第三段，置信度低）。`Spearton-Into-Stand` 系列在本仓两份材料（骨架+字面量）均不存在，项目侧若引用系另一版本骨架资产。

### 5.2 Spine 事件名与特效/音效名【事实】

- 事件：`Hit`、`Drawn`、`Mine`、`Cast`、`Sound`（骨架定义）+ `BlockGeneric`、`BlockTick`、`HitUnits`、`MagikillStun`、`MagikillStunStaffCast`、`MagikillStunStaffFollow`、`MericDeath`、`MericHeal`、`GiantBossDeath`、`GiantBossLaugh`、`GiantStatueBreak`、`GiantStatueBreak2`、`GiantThump`（代码引用——多为此类特效 prefab 名或事件回调名【推断】置信度中）。
- 音效事件名（SoundManager 体系）：`Arrow / Attack / Cast / Death / Defend / Heal / Pain / Rage / Spear / Step / Swoosh`。
- 槽位/皮肤：`skin`、`skins`、`skin-base`、`skinData`、`skinName`、`Slot` 系（见 §1.12）。

### 5.3 教学/成就串里的行为要求（游戏规则旁证）【事实】

`Perform a Swordwrath jump attack`（跳劈是教学必教动作）、`Throw A Spear / Throw a spear while controlling the Spearton`（掷矛=手控专属操作）、`Have 8 Speartons stand together in a formation`（编队规模成就）、`First Kill As *` ×4 + `Kill an enemy unit while controlling a *`（手控击杀成就×4，Meric 无此成就=不能攻击的旁证）、`Max Swordwrath`、`Build 12 Archidons`、`Atreyos the Spearton survives 10 nights`（SPEARTON_ATREYOS=25 枚举对应角色）、`The Swordwrath are here! / The Archidon is training. / Nice shot! Tap here to deselect the Archidon.`（教程播报）、`hasArchidonTutorial: `（教程开关日志）、`STATUE HEALTH: / Statue health set: / Health: / Health bar y: / Zombies Killed before: / No statue fall if in endless deads mode and has lost`（调试日志串）。

### 5.4 数值魔法数

签名默认值即数值（【事实】，全部已录入 §①②③ 表）：`SKIN_STUN_REDUCTION=0.2、USER_CONTROLLED_ATTACK_SPEED=1.3、LIFESTEAL_RATIO=0.2、SPLASH_HIT_LIMIT=4、SPLASH_RANGE=1、SPLASH_MODIFIER=0.2、SKIN_DAMAGE_REFLECT=0.2、BURN_PERIOD=13、BURN_AMOUNT_PER_SECOND=8、BURN_TIMES_PER_SECOND=0.25、SLOW_TIME_PERIOD=1、SLOW_TIMESCALE=0.5、FREEZE_TIME_PERIOD=1.3、FREEZE_TIMESCALE=0、WALL_THICKNESS=0.6、DIRECTION_CHANGE_FREQUENCY=0.5、AimAngle v=15、currentShotRandomness=0.5、DAMAGE_REDUCTION_TO_STATUE=0.3、DAMAGE_REDUCTION_TO_MASSIVE=0.66`。**static 字段与 .cctor 赋值（AGRO_RANGE/FIGHTING_RANGE/BLOCK_COOLDOWN/STUN_COOLDOWN/STUN_RANGE/SUMMON_COOLDOWN/MAX_MIN_SPAWNED_MINIONS/JUMP_ATTACK_COOLDOWN/UNITS_PER_COLUMN/ROW_GAP/NUM_CASTLE_ARCHERS 等）数值全部不可译**——需实机标定或按手感定值。

---

## ⑥ 移动 / 跟随 / 编队 / 目标选择 / 指令节奏全线索

### 6.1 原作运动模型总述【推断，置信度高】

2D 侧视卷轴，单位=Rigidbody2D，**没有寻路网格、没有绕行寻路组件**（全 dump 无 NavMesh/Path/A* 类）。移动=三种模式直给速度/力：
1. `Run(x, y, shouldFaceDirection)`（virtual，Unit）——直给目标点；
2. `Ai.SetWaypoint(Vector2)` + `MoveToWaypoint()`/`AtWaypoint(unit, waypoint)` static——路点制；
3. `Ai.RunToPosition(position, adjustYEarly=False, avoidStatue=True, autoFaceCorrectDirection=True)`——带规避意图的高级移动（参数名即行为：提前调 y/绕雕像/自动朝向）。
y 轴是假纵深（`PsuedoZAxisFixedUpdate` + `z/dz` 字段）：跳跃/击飞在伪 z 轴结算【事实】方法存在+字段存在，【推断】语义置信度高。

### 6.2 跟随/编队系统（决策点 1 相关）

【事实】机制链：
- `Ai` 字段：`unitToFollowInFormation`（跟随对象）/ `unitToStayBehind`（站位基准对象）/ `rowInFormation/colInFormation/unitsInColumn/formationY/isAtFrontOfFormation` / `hasMadeItToFormationAfterSpawn` / `safetyOffset`（私有）/ `lastFollowUpdate`（私有，跟随重算节流时戳）。
- 方法链：`MoveInFormationBehindAnotherFormation()` / `MoveInFormationBehindFollowUnit()` / `RunToFormationPosition(toStayBehind, gap)`（**gap 参数=跟随间距**）/ `DetermineFormationTargetPosition(toStayBehind, gap)` / `FormationPositionIsStable(targetPosition, unitToStayBehind)`（**阵位稳定性判定=到位滞回，防抖**【推断】置信度高）/ `GapBetweenFormationGroups()`（编队层间距计算）。
- Team 侧：`MoveInFormation(goalX, garrison, isFollowTheLeader)` / `GetFormationPositionX()` / `GetYPositionFromRow(row, unitsInColumn)` / `Formation.ROW_GAP`/`UNITS_PER_COLUMN`（静态，数值不可译）。
- 将军跟随：`Unit.Type.SWORDWRATH_GENERAL` + `GapIfGeneral(hadGeneral)` + `Formation.GENERALS` 分组 + 字面量 Leader 姿态。

【推断】跟随行为全貌（置信度高）：每个单位知道自己在哪行哪列、跟谁、跟哪个编队；行进时以 `unitToStayBehind` 的实时位置 + gap 算目标点，`FormationPositionIsStable` 保证只在实际脱队时才追（到位即站定不抖动）；`lastFollowUpdate` 说明跟随重算不是每帧。**触发距离没有独立序列化字段**——间距=编队静态参数（ROW_GAP/UNITS_PER_COLUMN/GapBetweenFormationGroups/safetyOffset 四处合成，数值全部不可译）。实装建议按"行距/列距/层距"三参数建模。

### 6.3 遇敌拦路/绕行（决策点 2 相关）

【事实】四套规避系统并存：
1. **雕像绕行**：`IsMovingPastStatue(unitToMove, position)`（判路径是否穿雕像）→ `DetermineGoalYToAvoidStatue(unitToMove, position, goalY)`（改目标 y 绕开）→ `AdjustPositionOffStatue(targetPosition)`（落点外推）；`RunToPosition` 默认 `avoidStatue=True`；实体侧 `PushOffStatues()/PushOffStatue(teamStatue)`（已被卡住时物理顶开）。
2. **墙体钳制**：`AdjustXSoWeDontRunToBehindWall(position)`（virtual，ArcherAi 重写）/ `RestrictTargetSpotWhenBehindWall(p)` / `PreventUnitFromGoingPastEnemyWall()` / `IsBehindWall()/IsXBehindWall(x)/WallBoundary()` / `WALL_THICKNESS=0.6`。
3. **路障**：`PreventFromGoingPastBarricades()`（实体侧硬限位）/ `AdjustDefendPositionBehindBarricade(pos)`（Team 侧把防守位摆到路障后）/ MinerAi.IsBarricadeBlocking(mine)。
4. **同伴推挤**：`PushApart()`（virtual）+ `pushAwayFactor` + Archer 专属 `PushApartTolerance()`（间距容忍度）+ `IsBeingPushedApart()/_lastPushAwayTime`。

【推断】（置信度高）：原作"拦路"处理=**y 车道变换**（把目标 y 挪到障碍上/下方通过），不是寻路弧线；ai 无"卡住检测"，靠物理推挤兜底。实装等价物=目标 y 偏移 + 碰撞推开。

### 6.4 目标选择（决策点 4 相关：刷新节奏）

【事实】字段与方法链：
- `Ai.target`（当前目标，public）+ `UpdateTarget()`（virtual，MericAi 重写为治疗选target）+ `ShouldRunToTarget()/RunToTarget()/IsTargetReallyClose()/IsUnderThreat()`。
- 距离度量：`AiDistance(target, unit)`（virtual——**距离函数本身可被兵种重写**：ArcherAi/ZombieAi 都重写【推断】弓手按射程视角算"距离"、僵尸按扑击视角算，置信度中）+ `AGRO_RANGE`（仇恨半径，静态，数值不可译）+ `InAgroRange(target, unit)`（virtual，ArcherAi/MagikillAi/ZombieAi 各自重写）+ `FIGHTING_RANGE`（交战范围）。
- 前向过滤：`OnlyTargetsUnitsForward()`（virtual）/ `IsValidForForwardOnlyTarget(potentialTarget)`——只打身前目标【推断】防回头送，置信度高。
- 预判：`PredictedPosition(target, unit) → ValueTuple<Vector3, float>`——**对移动目标做提前量预测**（返回预测位置+某标量【推断】时间或速度，置信度中）；配合弓手高斯散布=先解算再撒随机。
- 攻击点选择：`GetTargetAttackSpot()`（virtual，ArcherAi/ZombieAi 重写）+ `AttackFromRange()`（virtual，保持射程的攻击推进，MagikillAi/ZombieAi 重写）。
- 撤退：`NeedsToRunAway()`（virtual，MinerAi/ZombieAi 重写）+ `neededToRunAway` 状态 + `healthPercentageToSkirmishUntil`（血线游走阈值，语义方向不可译）。
- 施法者站位：`ShouldStandAsCasterInMiddleOfTheMap()`（virtual）+ `MoveToMiddleOfTheMap()` + `moveToMiddleRandomOffset`（中场落点随机抖动）。
- 个性 y 漂移：`personalityControlledY` / `personalityNextYControlShift`——**单位在车道间缓慢漂移的个性化参数**【推断】让大军 y 分布不机械，置信度中。
- 转向：`DIRECTION_CHANGE_FREQUENCY = 0.5`（const，【事实】）——转向判定 0.5 秒一次；`CanChangeDirection()`/`DirectionFacingUpdate()`/`FaceDirection(direction)`/`Face(unit)`/`SetNaturalFacingDirection()`/`IsFacing(position)`/`lastDirectionChangeTime`（Unit 与 Ai 各一份）。

### 6.5 指令/刷新节奏字段全家福（决策点 4 汇总）

| 节奏字段 | 所属 | 数值可译性 |
| --- | --- | --- |
| `DIRECTION_CHANGE_FREQUENCY=0.5` | Ai 常量 | 【事实】0.5s |
| `lastFollowUpdate` | Ai 私有 | 数值不可译【推断】跟随重算节流 |
| `blockResetInterval` / `BLOCK_COOLDOWN` / `lastBlockTime` / `blockTime` / `cooldownAfterAttackForBlock` / `timeLastWasAttacking` | Unit/Ai 格挡与攻击节拍 | resetInterval 序列化每兵种可配；BLOCK_COOLDOWN 静态不可译 |
| `idleAnimationChance/GapTime` + `_lastIdleAnimationPlayTime/_nextIdleAnimationGapTime` + `timeAfterStandingThatCanIdle` | 闲置彩蛋三参数双计时 | 序列化可配（prefab 值不可译） |
| `lastFormationUpdate` / `nextFormationUpdateDelay` | Team 编队刷新节流 | 数值不可译【推断】编队重排不是每帧 |
| `_lastStanceChangeTime` / `_lastGarrisonTime` / `_lastBuildUpdate` | TeamAi 三态/驻防/建造节拍 | 数值不可译【推断】AI 指令防抖 |
| `timeBetweenUnitSelections` / `timeOfNextUserControlAction` / `RefreshAiTimer()` | Personality 手控轮换节拍 | 数值不可译 |
| `SpecialAbilityConfig.timeToWaitBetweenCasts` | 人格法术施放间隔 | 序列化可配 |
| `healCooldown/lastHealTime`、`STUN_COOLDOWN/SUMMON_COOLDOWN/lastStunCast/lastSummonCast`、`JUMP_ATTACK_COOLDOWN/lastJumpAttack`、`POUNCE_ATTACK_COOLDOWN/lastPounceAttack`、`knockUpAttackCooldown/_lastKnockUpAttack`、`earthQuakeCooldown/_lastEarthQuake`、`convertCooldown/lastConvertEndTime`、`summonCooldown/lastSummonTime/summonMinCooldown`、`STUN_COOLDOWN/lastStunCast`(Giant)、`SHIELD_TIME/statueShieldTimeActivated` | 各技能冷却对（静态常量+实例时戳的统一模式） | 常量值全部不可译 |
| `arrowSpawnChancePerFixedUpdate`（ArrowVolley）/ `lightningStrikeChangePerFixedUpdate`（LightningStorm） | 法术按 FixedUpdate 概率节拍 | 序列化可配【事实】命名证明原作用"每物理帧掷概率"做频率 |
| `lastProjectileShotAtMe` + `ProjectileJustShotAtMe()` | Unit：被箭射中的时戳（SpeartonAi.IsAnyArrowThreat 的数据源之一【推断】） | 数值不可译 |
| `_lastArrowThreatTime`（SpeartonAi）/ `lastNotAimingTime`（ArcherAi） | 威胁记忆/瞄准中断冷却 | 数值不可译 |
| `_timeReleased/_timeTransitionedToStanding/_timeOfLastLightning` 等时戳族 | 状态时点记录 | — |
| `burnLastBurn/burnStartTime/slowStartTime/freezeStartTime/lastPoisonTime/lastDamagedTime/lastInflictor/lastGarrisonHealthTime/lastHealthChange/lastHealthRegenTime/lastBlockTime` | 状态效果时戳族 | — |

### 6.6 队伍三态与整体推进【事实+推断】

`Team.Stance`（GARRISON/DEFEND/ATTACK）由 TeamAi.StanceUpdate 按战力比切换；`MoveInFormation(goalX, ...)` 把整个编队阵型平移到 goalX；防守位 `GetDefendPositionX()`（可被路障后移）；`mostForwardUnit`（最前单位——`AverageMilitaryPositionX` 与 `lastAttackX` 用于测"敌军是否压境"【推断】TeamAi.EnemyArmyIsCloseToUs 的数据源，置信度高）。驻防 `GetGarrisonPosition()` 把单位收回城墙内。攻防转换是**全队一刀切**（无 per-unit 命令），`TeamAi` 是唯一司令。【事实】签名。

---

## ⑦ 弓箭命中语义专节（决策点 3 汇总）

**结论先行**：SWL 的箭是**单体触发器碰撞命中，无范围/半径伤害**；"插身插地"是命中后的表现态；命中部位由受击方**多碰撞体分层**决定。全部证据如下。

### 7.1 命中判定的完整字段链【事实】

1. **受击方三碰撞体**：`Unit.collider2d`（体）、`critCollider2d`（暴击区）、`headShotCollider2d`（头区）+ `boxCollider2d`。箭的 `OnTriggerEnter2D(Collider2D)` 拿到的就是这三个之一——**爆头/暴击不是概率，是打中了不同的碰撞体**【推断】命名直证，置信度高。
2. **箭侧碰撞**：`OnTriggerEnter2D` → `CalculateArrowWidth(Unit unit)`（按受击单位算箭杆"宽度"——决定没入深度/近失判定【推断】置信度中）→ 结算 `damage`（Init 时按 `drawPower` 算好）。
3. **部位与参数打包**：`arrowHitLocation: Nullable<Vector3>` 一路传进 `Unit.Damage(..., isHeadShot, ..., arrowHitLocation, ...)` → 爆头死亡（`headShotDeathAnimations`/`Kill(isHeadShot, dir, isSpearHeadShot, ...)`）与 `DirectionalBlood.Setup(isCrit, color, hitHeight, dir)`（按命中高度喷血）。
4. **插嵌**：`doesStickIn`（该箭能否插）+ `StopProjectile(stuckInto, unit, shouldStick)`——stuckInto=受击者骨骼 Transform 时箭挂在人身上随走（`UpdateStuckInArrow()`），否则转 `inGroundArrows[]` 插地贴图（`SetSpriteRendererForInGround()`），按 `_timeToWaitUntilFadesOut`（`TimeToWaitAlteredForNumberOfActiveArrows()` 动态调短）→ 淡出（`fadeOutOver`）→ `SetInActive()` 回池。
5. **特种减伤**：`DAMAGE_REDUCTION_TO_STATUE=0.3`、`DAMAGE_REDUCTION_TO_MASSIVE=0.66`（IsMassive 单位）+ `hasReducedDamageToStatue` 防重标志 + `causesHeadShotAnimation`（能否触发爆头动画）+ `canApplyDamageToBack`（背击加成）+ `poisonAmount`（毒箭）。
6. **命中概率与散布在发射端**，不在箭上：`ArcherAi.AimAngle(distance, ref isAbleToHitTarget, v=15, target, source, currentShotRandomness=0.5)` 抛物线解算 + `NextGaussian(mean, sd, min, max)` 身体随机偏移（`currentShotBodyRandomness`）——**射失=物理上射偏了飞过去**（落点在别处），不是掷骰判定未命中【推断】置信度高。
7. **AOE 不存在**：Arrow 无 radius/splash 字段；全项目 AOE 只有三处——手控近战溅射（§3.2）、Giant/Zombie 地震（FindTargetsToHit）、法术（ArrowVolley 箭雨是"随机落箭"不是弹道 AOE：`arrowSpawnChancePerFixedUpdate` 每物理帧概率刷箭）。

### 7.2 弹道与射程【事实+推断】

- 出射：`Archer.ArrowSpawnPosition()`（出生点）→ `ArrowLaunchDirection(isForShot)` / `ArrowLaunchVector()`（方向/向量）→ `Arrow.Init(arrowVector, drawPower, inflictor)`；`projectileSpeed` + `launchY`；`AimAngle` 的 `v=15` = 解算用的垂直初速参数。`Update()` 里 `UpdateRotation()` 让贴图随速度矢量转向。`trail` 拖尾延迟启用。
- 拉弓力度 `drawPower`【推断】同时决定初速与伤害（Init 签名参数 + `CurrentDrawPower()` 查询 + `DrawBowGradually` 渐拉），置信度高；`GetDrawAnimationSpeed` 反推动画变速使拉弓时长可控。
- 射程体系：`Archer.range`（自身射程，喂给 `ArcherAi.GetRange(includeOffset)`【推断】offset=编队位置加成）+ `attackRange/attackRangeSecondLine`（基类近战射程）+ `castleArcherRange`；`MissingArrowsTolerance()` = 脱靶容忍（配合 `NumArrowsLaunchedWithoutDamagingATarget` 计数）。
- 箭威胁（对方视角）：SpeartonAi.`IsAnyArrowThreat()` 依据 `Unit.lastProjectileShotAtMe` + `ProjectileJustShotAtMe()` 时戳【推断】扫描来箭或最近被射记录，置信度中；`Team.lastProjectileLaunchTime` 队伍级最近射箭时戳（TeamAi.EnemyIsShootingProjectilesAtUs 的数据源【推断】）。

### 7.3 实装要点对照表

| 待实装问题 | SWL 答案 | 依据强度 |
| --- | --- | --- |
| 箭是否有命中半径 | 无。单体 OnTriggerEnter2D，碰撞体对碰撞体 | 【事实】签名链完整 |
| 爆头怎么判 | headShotCollider2d 单独碰撞体 + arrowHitLocation 传点 | 【事实】字段 +【推断】置信度高 |
| 插身/插地 | doesStickIn + StopProjectile(stuckInto,...) + UpdateStuckInArrow + inGroundArrows | 【事实】字段链完整 |
| 范围伤害 | 箭无；AOE 在近战溅射/地震/箭雨法术三处 | 【事实】否定性穷尽 |
| 命中率 | 无掷骰；散布在发射端（高斯身体偏移+抛物线解算） | 【推断】置信度高 |
| 对雕像/大体型 | ×0.3 / ×0.66 两常量 | 【事实】 |

---

## 附：四个待实装决策点依据汇总（速查）

1. **跟随系统的触发距离类字段**：无独立"触发距离"序列化字段。机制=RunToFormationPosition(toStayBehind, gap) 的 gap 由 GapBetweenFormationGroups()/Formation.ROW_GAP/Ai.safetyOffset 合成（数值全部不可译），`FormationPositionIsStable` 提供到位滞回（防抖），`lastFollowUpdate` 提供重算节流（数值不可译）。→ 实装自定"行距/列距/层距+滞回+节流"四参数即可等价。（§6.2）
2. **遇敌拦路时的行为**：y 车道变换绕雕像（IsMovingPastStatue→DetermineGoalYToAvoidStatue→AdjustPositionOffStatue，RunToPosition 默认 avoidStatue=True）+ 墙体 x 钳制（AdjustXSoWeDontRunToBehindWall 族，WALL_THICKNESS=0.6）+ 路障硬限位 + PushApart 物理推挤兜底。无寻路网格。（§6.3）
3. **箭的命中半径/范围语义**：单体碰撞命中、无范围伤害；爆头=专用碰撞体；插身插地=StopProjectile 两态；散布在发射端高斯；对雕像×0.3/对巨型×0.66。（§7）
4. **命令/目标刷新节奏**：唯一实测常量 DIRECTION_CHANGE_FREQUENCY=0.5s；法术用每物理帧概率节拍（*PerFixedUpdate 命名族）；其余全部为"静态常量+实例时戳"冷却对（数值不可译，需自定）；TeamAi 三态切换/_lastBuildUpdate、Team 编队 nextFormationUpdateDelay、Ai 跟随 lastFollowUpdate 证明原作大量使用节流而非每帧重算。（§6.5）
