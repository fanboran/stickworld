# resources：区域化资源经济（库存 / 价格 / 供需）

> 管理"资源 × 区域"的库存与价格：consume/produce/transfer 全走本模块 api.gd，
> 库存/价格结构为 `{resource_id: {region_id: amount}}`。价格由供需 tick 驱动
> （每 5 现实秒一拍，暂停不累计），基价来自 BalanceConfig 的 resources.resources 表。
> ResourceManager 是纯数据层（RefCounted，不发信号），所有外部调用经 api.gd 代理。

---

## 目录结构

```
modules/resources/
├── api.gd                          # ResourcesApi（Node，GameRoot 子节点）：信号契约 + 消耗/生产/转移/定价代理 + 5s 价格 tick
└── scripts/
    └── resource_manager.gd         # ResourceManager：库存/价格/上限下限/税率/运输损耗 + 供需定价计算
```

---

## 对外契约

- 信号：`resource_changed(resource_id, amount, delta, region_id)` /
  `resource_not_enough(resource_id, required, available, region_id)` /
  `price_changed(resource_id, old_price, new_price, region_id)`
- 查询与操作：`get_stock`（region_id 空 = 全局总量）/ `get_price` / `consume` /
  `produce` / `transfer`（含运输损耗）/ `set_price_ceiling` / `set_price_floor` / `set_tax_rate`
- 调试接口（DebugToolsPanel 专用，生产代码勿用）：`debug_force_market_tick` /
  `debug_resource_rows` / `debug_tax_rate`

---

## 依赖

- `core/`（TimeManager.sim_delta、BalanceConfig 基价表）；装配方 `modules/world/`
  （SystemSetup 实例化并注入 ResourceManager，construction 经 set_resources_api 挂接）

---

## 开发注意事项

- 供需参数集中在 `resource_manager.gd` 常量区（均衡库存/价格弹性/单拍最大调幅/价格下限）
- tick 累加器须保留超出部分（清零会丢帧 delta，长期产生节奏漂移）
