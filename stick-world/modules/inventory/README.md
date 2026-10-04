# inventory：玩家背包与装备（L2，消费 items 域）

> 背包跟着玩家走，不跟火柴人：**列表制背包（无总数量限制，唯一上限=每类
> max_stack）** + 5 装备槽 + Hotbar 指派（10 格，仅武器/工具/消耗品）。
> 装备变化实时落地到当前附身实体（weapon_type/盾/护甲聚合/武器 stats 乘子），
> 脱离附身恢复原状；NPC 不感知背包。
> 物品定义/容器/转移原语在 [modules/items/](../items/README.md)（L1 物品域）；
> 系统级设计见 [docs/设计/系统/14-背包与装备系统.md](docs/设计/系统/14-背包与装备系统.md)。

---

## 目录结构

```
modules/inventory/
├── api.gd                       # 对外契约（InventoryAPI）：static get_service() 取全局背包服务 + 信号清单
├── scripts/
│   ├── player_inventory.gd      # 纯数据模型：列表制背包（items 域 ItemContainer 组合）/ 装备规则（双手锁副手）
│   │                            #   / Hotbar 指派与滚轮循环切武器（wield 共用路径）/ to_dict
│   ├── inventory_service.gd     # 运行时中枢（GameRoot 子节点）：附身桥接（weapon_type/盾/护甲/stats 乘子）
│   │                            #   / 消耗品治疗 / 开局发放 / world_state 表存档（module_name="inventory"）
│   └── ui/
│       ├── hotbar.gd            # 底部三段式物品栏（主副手镜像 | 指派格×10 可视 8 格滑动窗口 | 动作格 F/E）
│       ├── inventory_screen.gd  # E 键背包·角色合一模态（左装备+角色卡 / 右分类列表；StatsScreen 已并入）
│       ├── container_screen.gd  # 双栏容器转移窗口（翻包「翻检遗物」/ 村仓共用；ItemTransfer 原子转移）
│       ├── building_menu_screen.gd # 建筑交互菜单预制（actions 数据驱动；仓库实装/占位灰显）
│       └── item_slot_widget.gd  # 通用格子控件（背包/装备/Hotbar/动作四模式共用，缺图程序绘简笔）
└── （物品定义 item_def/item_stack/item_db 与村仓桥 region_storage 已升格
    items 域 modules/items/core/——本模块只做玩家侧容器消费与桥接）
```

---

## 对外契约

- 取服务：`GameRoot.inventory_service` 直引或 `InventoryAPI.get_service()`。
- Hotbar 使用：`use_hotbar_slot(index)`（数字键 1-9/0 与点击同路；武器=换装、
  消耗品=使用）；滚轮切武器 `cycle_weapon(dir)`（附身态滚轮语义，Shift+滚轮=缩放）。
- UI 只订阅 PlayerInventory 三信号 `inventory_changed / equipment_changed / item_used`，数据驱动不轮询。
- 附身边界：InventoryService 订阅 EventBus.possession_started/ended，装备槽聚合写入附身实体（含
  `equip_attack_mult/equip_speed_mult` 乘子——经 `weapon_mount.effective_damage()` 出口生效），
  记录附身前武器状态、脱离恢复。
- 存档：`world_state` 表 module_name="inventory"（背包/装备/hotbar 指派/选中格），
  game_saving/game_loaded 信号直写；实体侧个体 loadout 走 extra_data（save_handler）。

---

## 依赖

- `modules/items/`（L1 物品域：ItemContainer/ItemTransfer/ItemDB——本模块零物品定义职责）。
- `core/autoload/event_bus.gd`（附身/存档信号）；图标 `assets/icons/`。
- 被依赖：`modules/world/`（SystemSetup 装配服务与四块 UI；GameRoot 滚轮/数字键转发）、
  `modules/units/`（尸体遗物容器经 ItemsAPI 映射生成、翻包交互）。

---

## 扩展指引

- 加新物品：在 `modules/items/core/item_db.gd` 注册一条 def（excel 管线支持类型化导出后迁 .tres，查表入口不变）。
- 加装备/消耗品效果：聚合写入在 inventory_service.gd `_apply_equipment_to_entity`，消耗品分派在 `_on_item_used`。
- 新库存场景（工坊仓库/商店货柜等）：直接实例化 items 域 `ItemContainer` +
  `ContainerScreen.open_with(external, title)`，零新概念。
- 建筑交互菜单：给 `_open_building_menu` 的 actions 数组注册新动作（数据驱动，框架零改动）。
