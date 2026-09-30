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

## 状态

- 2026-09-30：开工。四路并行施工中；门禁与集成由指挥统一执行（代理不跑引擎不渲染不 git）。

## 下一步

1. 三路施工完成 → 指挥逐 diff 审查拼装，解决跨地盘遗留项。
2. 门禁：`godot --headless --import` → `bash stick-world/tests/run_all.sh -Changed` → `bash stick-world/tools/check_godot_errors.sh`（退出码 0）。
3. 渲染验收（代码先行，渲染最后）：跑 `tests/dev/diag_arena_25d_shots.tscn` 五阶段截图（若该 driver 只在 agent/arena-25d-fix 分支，则在分支上补最小截图 driver），产物复制到 `F:\VSCode\game-2\temp\观察场AI验收\`，贴图交创始人复验。
4. 收线：合并 main（含本交接档）、删 worktree/分支、登记档流转。

## 恢复指引（新会话「继续 观察场AI修复」）

1. `git worktree list` 确认 `.temp/观察场AI` 存在；不在则从登记档查分支名重建 worktree。
2. 读本文档「状态」与各报告遗留清单（收线前的集成记录在本文档追加）。
3. 门禁与渲染命令见「下一步」2/3。
