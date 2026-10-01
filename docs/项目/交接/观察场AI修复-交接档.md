# 观察场AI修复-交接档

> 任务：大乱斗观察场战斗 AI 修复，总路线照小兵步枪（Ravenfield）：编班 + 班长继任 + 夺点驱动班级意图 + 视线索敌 + 参数化调校。
> 工作区：`.temp/观察场AI`（worktree，分支 `agent/arena-ai-fix`）。res:// 根 = `stick-world/`。
> 方向依据：2026-09-30 调研结论——全战/英雄连/小兵步枪/RTS 业界全部采用「编队为决策原子 + 规则涌现（士气/掩体/压制/夺点）」，无一用神经网络做单位决策；本项目继续传统状态机+效用打分。

## 团队分工与文件地盘（并行施工，防冲突边界）

| 代号 | 职责 | 地盘（只准改） |
|---|---|---|
| 夜枭 | 出手可信度：9u 弓手不放箭、9s 近战空挥、9h 卡死看门狗、开启并保守校准默认关的档案开关 | `modules/units/scripts/ai/` 全部 + `modules/tactics/scripts/target_finder.gd` |
| 血鹰 | 运动与结算：9k 让路（分离力对抗槽位红线）、溃逃收敛战斗结束判定、9j 脱战回血最简版 | `modules/units/scripts/entity/entity_motion.gd`、`stickman_entity.gd`（小修）、`modules/combat/scripts/battle/battle_instance.gd` |
| 军师 | 夺点大脑：CapturePoint、班级意图规划器（0.5s 节拍打分）、排长继任、观察场接线（3 夺点+旗状态 HUD+回退开关） | `modules/tactics/`、`team_ai.gd`、`formation_system.gd`（仅排长继任）、`tests/dev/battle_arena.gd` |
| 影子 | 参考建档（不入库）：`F:\VSCode\game-2\external\参考\大战场AI调研\` + 索引.md | external/（gitignored） |

指挥（主会话）负责：拼装集成、门禁（check_godot_errors + run_all）、批次提交、渲染验收出图。

## 关键设计口径

- 编队=唯一决策原子，个体只执行；下发一律走 TacticalOrders 现有 API，不许直调单位内部方法。
- 到旗边先停驻观察（约 0.8s，参数化）再入场；占领=半径内独占方积分（0→100，争夺冻结）。
- 士气只影响行为决策，不作伤害/属性乘子（02-战斗系统.md 行 69 创始人裁决）。
- 校准锚点优先取 `docs/项目/审计/小兵步枪AI逆向_2026-09-11.md`、`英雄连AI逆向_2026-09-11.md`、`总账/翻译缺口总账.md` 的原始数值，拍脑袋值一律注释「待实测校准」。
- 夺点关闭时必须回退到旧行为（回退开关在 battle_arena.gd，默认开夺点）。

## 自对弈 Benchmark 基建（创始人 2026-09-30 定）

- 目标：**下一版算法稳定战胜上一版**（胜率 ≥65%，换边轮换消除左右占位偏差），形成可证伪的迭代闭环；攻击模组变化后重训不重造轮子。
- 构成：`tests/dev/benchmark_brains/bench_brain_base.gd`（选手基类=观察快照+个人级/编制级命令门面）、`tests/dev/diag_arena_benchmark_driver.gd`（胜负判定/换边/稳定战胜线）、`tests/dev/diag_arena_metrics_driver.gd`（过程指标：疲于奔命率/追逐翻转/均匀度CV）、选手库 README（历任卫冕者表）。
- 迭代流程：挑战者 vs 卫冕者 headless 对跑 N 场换边轮换 → 过线接替、登记卫冕者表。首任卫冕者 = 内嵌默认 AI。
- RL 落点（创始人口径）：运行时保持传统打分（可调可查），打分权重留成常量表；离线用 RL/黑盒搜索在本 Benchmark 上挖参数、烤回选手脚本。

## 状态

- 2026-09-30：开工。四路并行施工中；门禁与集成由指挥统一执行（代理不跑引擎不渲染不 git）。
- 2026-09-30：主症状画像（均匀分布+疲于奔命追逐）与数据点测试台已下发；基线采集进行中；Benchmark 基建落库（cfac806d 之后的批次）。
- 2026-09-30：**四路全部交付并按归属分批落库**（278d5eaa 夜枭 / 21579d52 血鹰 / f9120b5c 军师 / bd7e6ea7 指挥集成落锚）。改后指标四签名向好（疲于奔命率 46→17%、追逐翻转 15.5→4.0、CV 0.88→1.42、互为最近对 51.8→28.6，48v48 60s，战斗有歼灭不僵局）；严格基线对比待基线采集完成。已知待查：test_melee_combat 武器镜像断言（嫌疑=char_sprite_3d headless 豁免），门禁期定位。
- 2026-09-30：**门禁全绿**（39 过 / 1 环境项 mapdata_consistency 悬置）。三失败定位修复（336e6059）：spawn_jitter timing_state 钉方差 0、melee 镜像断言无头豁免（确认系本批 headless 豁免所致，属预期行为改测试适配）、retreat C3 场景撤腿短于追腿（**AI 变强打穿场景前提**：预测门槛落地后追兵不再空挥，守军撤离需贴缘 280px）。
- 2026-09-30：**基线对比定案**（旧代码库干净快照 vs 新系统，48v48/60s）：疲于奔命率残局 53%→17%（-68%，基线不降反升=主症状实证）、追逐翻转 16.8→4.0（-76%）、互为最近对 50.6→28.6、基线 60s 仍 86+ 人胶着 vs 新系统有歼灭推进。基线 worktree 卡死根因=快照内指标台带 `var key :=` 编译错（cfac806d 原始版），sed 打同款补丁后采通。
- 2026-09-30：**Benchmark 对打**：新指挥（夺点规划器）vs 旧指挥（TeamAi 四姿态，`incumbent_teamai_brain.gd` 压制本方规划器+解除让位实现）**6:0 完胜**、换边无偏（攻/守两侧胜率对称），战力比碾压（旧残 6~19 vs 新稳剩 22~35）。自检（新 vs 新）暴露**攻方侧偏置**（攻 67% vs 守 0%，含占领结算权单台归攻方的设计不对称）——后续校准项：结算权对称化或换边补偿。1 场无效为 12 进程并行墙钟超时，非战斗异常。
- 2026-09-30：渲染五阶段落 `F:\VSCode\game-2\temp\观察场AI验收\`（t4=红方全灭/三旗尽取/蓝方建制收场；旗行 HUD 上线）。**分支待创始人验收后合并 main**；fps≈10 为旧渲染线性能账（渲染修复在 agent/arena-25d-fix 分支，两条合并后一并生效）。
- 2026-09-30：**RL 训练线开工**（创始人方向：AlphaGo 式自博弈、随机不对称对阵+正反两局平均防过拟合、一个网络执掌双方、评估裁判=赢手调规划器）。泰坦 C++ GDExtension 训练核落库（`ea92b665`，addons/rl_core）：对拍误差 1e-15、**吞吐 230~240 倍**（261 局/s vs 1.12）、checkpoint 与 GDScript 版双向兼容；GPU 判断书留档（当前网络规模上 GPU 是负优化，向量化 compute shader + 大网络/10⁵ 轮才值得）。阿尔法 GDScript 设施施工中（tests/dev/rl/ + nn_brain）。
- 2026-09-30：**【删溃逃、立避战】方向裁决落地**（e1465a3b）：is_routed/rout_threshold 退役、is_disengaging() 行为态立起（谁执行谁置位）、压制触发避战、避战带打带跑、C3 指挥层撤仗与可下令 RETREAT 保留、士气降级为避战打分输入；结算=全灭/离场/超时(duration_limit)。全量 39 过 / 1 环境项；benchmark 选手与指标台同步适配（`438d67d7`）。**本轮验收产物中的"溃逃"口径自此作废**，观察场数字以避战版复测为准。
- 2026-09-30：**RL 训练线全链贯通**（阿尔法批）：57 维镜像观察/正反两局合批/REINFORCE 断点续训/nn_brain 部署位，343 轮 538 场零自身崩溃、熵 3.84 无塌缩、攻守无偏置（49.3/50.7）；评估协议=每 50 轮 vs 军师规划器 3 组正反（当前 50%——网络未形成泛化优势，符合预期）。**无限循环训练已在后台续跑（iter 340 起）**，杀 godot 进程即停、重跑 `res://tests/dev/rl/selfplay_trainer.tscn` 即续。运行档 `user://rl/`（checkpoint/train_log/eval_log）。
- **RL 后续项**：① 泰坦 C++ 环境为 47 维紧凑规格，与阿尔法真实环境 57 维**不同构**（"互通"仅 JSON 格式）——切 `RLTrainer.train(n)` 长期跑之前须把 C++ env 对齐 57 维真实规格（GDScript env 留作对拍锚点）；② arrow_projectile.gd 在 time_scale=5 下有命中已释放目标的竞态报错（非致命，待修）；③ 评估对手是单台规划器，其改版会造成基准漂移。
- 2026-10-01：**弓手拉弓+持弓行走动画线收尾核实通过**（工笔二号接前任半成品，未改代码、纯核实+门禁）：① AI 持瞄激活链闭环——`behavior_attack._update_aim_rhythm` 持瞄开始拍调 `weapon_mount.get_sustained_fire_heat()`（全库唯一调用点）→ 内部 `_mark_bow_aim_started()` 拉起表现窗，AI 侧零侵入；玩家蓄力走 `begin_player_draw` 独立窗（无超时+附身守卫收口）。② 持瞄中移动→站定干净——`weapon_mount._process` 逐帧仲裁（移动让位 walk / 站定重拉 attack_bow_hold），与 entity_motion 的 attack 前缀守卫、减速写 idle 的一拍交互无冲突；死亡经 dead 终态门禁+超时兜底（5s）收口；HOLD 播完回 idle 再重拉 = 原版弓手循环拉弦观感。③ billboard 镜像零透传——镜像 rig 与 2D 共用 `StickmanAnims.setup_tree`（HOLD/RELEASE 状态同源入库），walk_bow 换装在 `char_sprite_3d.set_weapon_type`（2D 侧在 `WeaponMount._reload_weapons`），动画镜像经 `_current_anim` 字符串直通消费无白名单过滤。④ 资产保真——attack_bow_hold 定格帧对照原版 Archidon-Draw@0.5s：inner 臂链（拉弓主动作）差 <0.04 rad，outer 链（拉弦手）~0.1 rad 小漂移非质变；Drawn@0.5 / Hit@0.5333 真值时序在 weapon_mount 头注释。⑤ 门禁：test_stickman_anims + combat 系（melee/feedback/control）全过；check_godot_errors 65 条报错全部归属他线（formation×2 / battle_instance / units-ai 测试桩=队友半成品，organization/texture_gen=既有测试负例），弓手线零报错（仅测试桩无骨架实体的预期 push_warning）。⑥ 验收图两张已出：`F:\VSCode\game-2\.temp\观察场AI\temp\观察场AI验收\动画\bow_aim_draw.png`（持瞄拉弓三相位，0.18 拉弦中程→0.42 近满→1.50 定格绷住）与 `bow_walk.png`（持弓行走三相位，迈步+持弓），由 `tools/baking/render_bow_anims.gd` 走真实 .tres+AnimationTree.advance 通道渲染。
- 2026-10-01（重启恢复批收官）：四线全部落库——军衔标记 c4c5fd8b / 弓手动画 3d924760 / 指挥官+斩首 545976b1+743b4bce（守卫全号令类型+追击 leash+decapitation 优先级+单测 8 例）/ 编制重排 87c2c110（班 8~12·排聚合层·椭圆分离双常量·聚拢弹簧内核·三预设 17/49/97）。指挥集成落库 3a86cf73：椭圆分离 11 消费点全覆盖（实体链移动/静态/让路 + sim 链分离循环/推力查询）+ 聚拢弹簧接入运动链（api 宿主注册通道，掉队站桩回拉）+ formation_system 生命周期登记。门禁 39 过/1 环境项；全效果五阶段验收图落 `temp\观察场AI验收\全效果五阶段\`（t0=49v49 新编制+军衔点+指挥官后方坐镇；t2=混战纵向有层次不叠罗汉）。**泰坦三号施工 v2 定稿中**（新维度 8 班+排长层+指挥官，深蓝诊断的 v2 配方：真镜像/规划器混对手/奖励塑形/课程学习；新权重从头训属预期——维度变了）。

## 下一步

1. 三路施工完成 → 指挥逐 diff 审查拼装，解决跨地盘遗留项。
2. 门禁：`godot --headless --import` → `bash stick-world/tests/run_all.sh -Changed` → `bash stick-world/tools/check_godot_errors.sh`（退出码 0）。
3. 渲染验收（代码先行，渲染最后）：跑 `tests/dev/diag_arena_25d_shots.tscn` 五阶段截图（若该 driver 只在 agent/arena-25d-fix 分支，则在分支上补最小截图 driver），产物复制到 `F:\VSCode\game-2\temp\观察场AI验收\`，贴图交创始人复验。
4. 收线：合并 main（含本交接档）、删 worktree/分支、登记档流转。

## 恢复指引（新会话「继续 观察场AI修复」）

1. `git worktree list` 确认 `.temp/观察场AI` 存在；不在则从登记档查分支名重建 worktree。
2. 读本文档「状态」与各报告遗留清单（收线前的集成记录在本文档追加）。
3. 门禁与渲染命令见「下一步」2/3。
