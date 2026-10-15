# HD-2D 代码职责拆分 v2（缓期，2026-09-15 裁决）

> 当日 main 上 HD-2D 代码被并行会话演进 ~1000 行/20 新函数，试合并实证拆分冲突面过大 → 挂起；成果存档分支 `agent/hd2d-split-wip`（仅供结构参考）。旧"从头重做"尝试基于迁址前代码写就且半步搁置，同样作废——重做按当前 main 起步，需考古时 bundle `F:\VSCode\stickworld-pre-rewrite-20260916.bundle` 可找回旧实现。触发条件：城镇生成器/投影收线批次收口、函数面稳定。

- [ ] `hd2d_world.gd` 瘦身为编排门面 + 职责组件（world 根编排 + cards/placer/ground/walls/char_stage 组件化），街道/战场宿主公共代码上提 `Hd2dMapBase` 基类；组件映射表 v2 与恢复指引见 [`HD-2D架构正式化.md`](../交接/HD-2D架构正式化.md)
