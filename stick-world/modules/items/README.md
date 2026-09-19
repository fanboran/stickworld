# items —— 物品域(L1 基础设施)

独立于背包与仓储的物品系统:全项目唯一的物品定义/实例/容器/转移原语。
玩家背包(inventory 模块)、区域仓储桥(RegionStorage)、尸体遗物、未来的
工坊仓库/载具货舱都是 `ItemContainer` 的消费者。

- `api.gd` — 契约:资源品映射(resources.resource_id ↔ ItemDef.id)
- `core/item_def.gd` — 物品定义(id/类别/max_stack/weapon_type/stats/图标)
- `core/item_stack.gd` — 运行时堆(def_id + count;装备槽的最小存储单元)
- `core/item_db.gd` — 注册表(内置 GDScript 真相源,类型化导出后迁 .tres)
- `core/item_container.gd` — 列表制容器(**无总数量限制,唯一上限=每类
  max_stack**;容器级 stack_overrides 可覆盖单类上限)
- `core/item_transfer.gd` — 容器间原子转移(move/move_all,翻包/村仓共用)

分层:零依赖(不引任何模块);`docs/设计/系统/背包与装备系统.md` §2.2。
