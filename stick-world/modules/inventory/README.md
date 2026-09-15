# inventory：玩家背包与装备

> 背包跟着玩家走，不跟火柴人：24 格背包（前 4 格 = Hotbar 物品组）+ 5 装备槽。
> 装备变化实时落地到当前附身实体（武器/盾/护甲减伤），脱离附身恢复原状；NPC 不感知背包。
> 系统级设计见 [docs/设计/系统/背包与装备系统.md](docs/设计/系统/背包与装备系统.md)。

---

## 目录结构

```
modules/inventory/
├── api.gd                       # 对外契约（InventoryAPI）：static get_service() 取全局背包服务 + 信号清单
├── data/
│   ├── item_def.gd              # ItemDef：物品静态定义（7 大类 / 堆叠上限 / 武器类型映射 / 双手标记 / 数值参数）
│   ├── item_stack.gd            # ItemStack：运行时堆（def_id + count），序列化只存 id，ItemDB 查表还原
│   └── item_db.gd               # ItemDB：物品注册表（内置 GDScript 定义；图标目录 assets/icons/）
├── scripts/
│   ├── player_inventory.gd      # 纯数据模型：格子操作 / 装备规则（双手锁副手、卸装需空位）/ to_dict
│   └── inventory_service.gd     # 运行时中枢（GameRoot 子节点）：附身桥接 / 消耗品治疗 / 开局装备发放
└── ui/
    ├── hotbar.gd                # 底部常驻物品栏（主副手镜像 | 物品 1-4 | 动作格 F/H/E/C）
    ├── inventory_screen.gd      # E 键模态背包界面（光标堆拖放 / 右键智能装备与一键卸下）
    ├── item_slot_widget.gd      # 通用格子控件（背包/装备/Hotbar/动作四模式共用，缺图程序绘简笔）
    └── stats_screen.gd          # C 键角色属性面板（生命/五属性/情绪/状态效果/装备概览）
```

---

## 对外契约

- 取服务：`GameRoot.inventory_service` 直引或 `InventoryAPI.get_service()`；数字键 1-4 / Hotbar 点击走 `use_hotbar_item(index)`。
- UI 只订阅 PlayerInventory 三信号 `inventory_changed / equipment_changed / item_used`，数据驱动不轮询。
- 附身边界：InventoryService 订阅 EventBus.possession_started/ended，装备槽聚合写入附身实体，记录附身前武器状态、脱离恢复。

---

## 依赖

- `core/autoload/event_bus.gd`（附身信号）；图标 `assets/icons/`。
- 无对其他玩法模块的 preload；装备对战斗数值"只入数据不应用"（攻击倍率等由 BalanceConfig 校准管）。
- 被依赖：`modules/world/`（SystemSetup 装配服务与三块 UI；GameRoot 键盘转发 Hotbar 使用）。

---

## 扩展指引

- 加新物品：在 data/item_db.gd 注册一条 def（excel 管线支持类型化导出后迁 .tres，查表入口不变）。
- 加装备/消耗品效果：聚合写入在 inventory_service.gd `_apply_equipment_to_entity`，消耗品分派在 `_on_item_used`。
