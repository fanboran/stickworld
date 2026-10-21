# HD-2D 代码职责拆分 v2（已执行，分支 `agent/hd2d-split-v2` 待验收）

> 2026-09-15 缓期（当日 main 被并行会话演进 ~1000 行/20 新函数，试合并冲突面过大）；
> 2026-10-21 函数面稳定后解缓执行——在 worktree `.temp/wf-hd2d`（分支
> `agent/hd2d-split-v2`，自 main@6855edb6 起）完成拆分，**行为不变红线**经
> 门禁对账：unit 批 76/76、HD-2D 探针组（map/battlefield/f3/building_host/
> minimap_rebake/minimap_bake/minimap_cull）与拆分前基线逐项一致、
> `audit_deps` 零新增环、mapdata 守门 1/1。合并回 main 由创始人验收后进行。

- [x] `hd2d_world.gd` 瘦身为编排门面 + 职责组件：门面保留世界编排/solids/相机/光照/烘焙/出图（约 1700 行），六组件落 `scripts/` 职责子目录——`cards/`（卡呈现）、`placer/`（摆街）、`ground/`（地面）、`walls/`（城墙）、`char_stage/`（角色舞台）、`clouds/`（云牌，节点即 Clouds 容器）；组件经门面回引 `w` 互访，对外 duck API 与探针可见内部成员（`_front_occ`/`_prop_root`/`_cloud_root` 等）原样留在门面
- 街道/战场宿主公共代码上提 `Hd2dMapBase` 基类一项**本轮不动**（基类已存在且在役，映射表 v2 的 ②b 项当年已落地）
- 落地映射与映射表 v2 的出入清单见 [`../交接/HD-2D架构正式化.md`](../交接/HD-2D架构正式化.md) §三
