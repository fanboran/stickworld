# unit 批并行轮转修复（已收线待验收）

> 排查任务：`run_all.sh -Filter unit`（并行形态）下 `[BATCH-FAIL]` 失败集轮转。已定案双根因并修复，根因链/复现数据/证伪记录见 [待办/测试假失败与不稳定项](../待办/测试假失败与不稳定项.md) unit(batch) 节（本档只记状态与路径）。

- 分支：`agent/unit-batch-flake`（worktree `F:\VSCode\game-2\.temp\wf-flake2`），提交 `869b454e`，**未并 main，留创始人验收后合并**
- 修复面：
  - `stick-world/tests/lib/class_cache_guard.sh`（新增）——class_name 全局类缓存预检+自愈+并发锁，接入 `tests/run_all.sh` / `tests/run_unit.sh`
  - `stick-world/tests/unit/test_townlife_save_persistence.gd`——SQLite 临时库路径进程号隔离+收尾自清
  - `stick-world/tests/batch_runner.gd`——`SW_BATCH_TRACE` 观测位（默认关闭，排查并行问题用）
  - `stick-world/tools/dev/repro_batch_parallel.sh` / `repro_unit_vs_pool.sh`（新增复现台，已登记编辑器工具索引）
- 验证口径：提交 `869b454e` 上并行 3 实例 × 3 轮 `-Filter unit` 全部 exit=0、失败集为空（含一轮投毒类缓存走自愈路径）+ 全量 `run_all.sh` 绿；单测 80/80
- 验收建议：创始人过目 [待办/测试假失败与不稳定项](../待办/测试假失败与不稳定项.md) 定案段与提交 diff；确认后合并 `agent/unit-batch-flake`
