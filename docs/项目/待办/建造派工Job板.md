# 建造派工 Job 板化

- [x] WorkCrewAssigner（construction/scripts/work_crew_assigner.gd）扩展为搬运/建造通用 Job 板：任务分发与执行解耦，工人按池认领（参考监狱建造师/环世界 Job 系统）
- [x] 同批吸收建筑总账 10.3（工位重排）/ 10.4（派工看距离）——同文件强耦合债

## 实施结果

- **Job 板形态**（`work_crew_assigner.gd`）：板不维护独立任务对象列表，任务是项目状态的派生视图——每个活跃项目在板上提供两类任务：`build`（接受工人期间常驻可领）与 `haul`（`needs_material()` 期间随需可领）。认领即物化一条 Job 记录 `{kind, project}` 挂工人名下（`_worker_to_job`）；两族都经 `project.assign_worker` 项目成员化（首人自动开工、完工/取消释放、工位分配同源，与板化前的成员语义一致）。
- **决策/执行解耦**：定族规则收敛在板内（`_family_for`：缺料且 `can_haul` 且 `has_warehouse` → haul，否则 `can_build` → build）；AIController（`ai_controller.gd` `_try_work`）只持提示词（`_job_hint`：编队职责过滤 + 仓库可达性）认领/刷新 + 按 kind 转发 behavior "work"/"haul"；行为层零改动只执行。族别换向（缺料 build→haul、材料到货 haul→build）经 `refresh_job` 原项目内原地换 kind，不发射派工信号、不动池。
- **行为保持面**：现有建造派工的可观测行为除 10.4 距离排序外零变化——提示词缺省两族皆可（旧调用面兼容）、`get_worker_project`/`worker_assigned`/`worker_unassigned`/幂等语义不变；搬运提族后行为层的换向时机与板化前一致（work 行为因缺料 finish → 下次决策认领/刷新为 haul）。
- **消费面新增 API**：`api.gd` `get_worker_job` / `refresh_worker_job` / `try_assign_worker(worker, hint)`（hint 可选）。
- **顺带根除**：`construction_project.gd` 死代码 `try_claim_hauler`/`release_hauler`/`_hauler`（零调用的"单搬运工认领"残留，被板上 haul 族取代）；`behavior_haul.gd` 陈旧头注修正。
- **已知遗留**（不属本件）：`_try_work` 入口门禁 `_can_work(WorkTypeBuild)` 挡住仅含 WORK_HAUL 的劳工队（fp_worker_crew）——2026-08-15 `b555e518` 的搬运修复只改了族分支未放开入口，现行为保持；板的提示词机制已支持 haul-only 认领，入口口径放开归后续行为树演进（G6/G7 线）定夺。

## 验证

- 单测 `tests/unit/test_work_job_board.gd`（11 用例：池生命周期/两族认领/提示词回退/族别换向无信号/距离三态/完工取消释放/10.3 工位重排/兼容面），已登记 `tests/batch_runner.gd`
- 集成 `test_construction_cycle` 仍悬置（HD-2D 重建线，4.3）；单参 `try_assign_worker(worker)` 经默认 hint 保持编译兼容
- 门禁：run_all 全绿 + audit_deps 零新环（详见分支提交）
