# a12_inventory — 背包与装备系统工作目录

分支：`agent/inventory-equipment`（自 `agent/playable-demo` 拉出）
正式设计文档：`docs/设计/系统/背包与装备系统.md`（本目录只放工作过程产物）

## 任务范围（用户需求 → 实现落点）

| 用户要求 | 实现 |
|---|---|
| 武器在背包内，不再 1-5 直切 | `modules/inventory/` 新模块；删 entity `_handle_weapon_hotkey` |
| 装备栏：头/胸/腿 + 盾 + 武器 | `PlayerInventory.SlotType` 5 槽 |
| 弓是双手武器（占副手） | `ItemDef.two_handed`；装弓锁副手、盾自动卸回；持双手时禁装盾 |
| 按 E 打开背包 | GameRoot `_unhandled_input` KEY_E → `toggle_inventory()`（模态栈让位规则） |
| MC/泰拉瑞亚式物品栏 | 24 格背包 + Hotbar 物品组 = 背包前 4 格（数字键 1-4 使用） |
| 格子下面显示按键字母 | `ItemSlotWidget.caption`（左键/右键/数字/字母），三组布局 |
| 角色快捷键也显示图标 | Hotbar 动作组：交互 F / 脱困 H / 背包 E（程序绘简笔图标） |
| 主副手左键/右键使用 | 左键攻击（既有）；右键按住举盾走 `WeaponMount.set_blocking()`（新接） |

## 键位变更全表（用户须知）

| 键 | 旧 | 新 |
|---|---|---|
| E | 附身交互 | **开关背包** |
| F | 空挥 | **交互**（采集/建造/取放） |
| G | — | 空挥（原 F，降级） |
| 右键 | — | **按住举盾**（副手有盾时） |
| 1-4 | 直切武器 | **使用 Hotbar 物品格** |
| 5 | 直切法杖 | 删（开背包换装） |
| T / B | 循环武器/盾开关 | 删（调试功能退役） |

## 关键决策记录

1. **weapon_type 单点驱动不动**：装备变化最终只写 `WeaponMount.weapon_type`，战斗全链路（模型/动画/射程/数值校准/AI 档案）零改动 → battle_sim 零回归。
2. **WeaponType 加 NONE（=6）**：徒手=卸下武器模型+`can_attack()` 恒 false+射程 0。动画映射 `.get()` 兜底回落剑姿（不会播出攻击因为 can_attack 拦截）。
3. **盾双轨制**：`shield_enabled`（兵种默认，仅矛兵挂模型——原版语义，NPC 不动）+ `equipped_shield`（玩家装备，任意武器配盾）。格挡判定只看盾实例，两条路殊途同归。
4. **数据真相源 = ItemDB 内置 GDScript 表**：excel 的 weapons.tres 是无类型 variables 字典且 icon 全悬空；类型化导出落地后迁移（换 `_build_defs` 数据源）。
5. **武器 stats 只入数据不应用**：attack_mult 等乱动会打破 BalanceConfig 校准；留 P5 数据化批次接。
6. **护甲只做减伤+移速**：减伤挂 DamagePipeline"单位类型减伤"段（`get_armor_factor()` 单入口，反伤不吃护甲）；移速进实体 `_handle_acceleration` 乘子链。
7. **背包跟玩家不跟火柴人**：InventoryService 挂 GameRoot；附身记录实体原武器、脱离恢复；NPC 永不感知背包。
8. **E 键让位规则**：其他模态打开时 E 不抢占（ESC 先退栈）；背包开着 E 关背包。
9. **UIModalStack.Layer.INVENTORY=4**（EMPIRE_PANEL 与 CONFIRM 之间，确认框可盖背包）。全项目 Layer 引用都是枚举名，改 CONFIRM 数值安全。

## 第二轮（2026-09-06 用户反馈收敛）

| 用户反馈 | 实现 |
|---|---|
| 背包只存装备和矿物 | ItemDB 加四矿物（石50/铁30/金20/钻10 堆叠限量）；设计文档明确类型白名单 |
| 材料不能存（占双手） | 建材不进背包（走 carrying 搬运）；**搬运中锁玩家攻击/空挥/举盾**（`_player_attack`/`_player_swing`/`_set_player_blocking` 前置 `is_carrying()`） |
| 装备可无限存 | 装备 1件/格不堆叠，24 格容量全类型物品最大数 15+矿物堆叠，余量充足 |
| 角色属性面板（伤痕状态种种，无名字） | `StatsScreen`（C 键模态）：生命条/五属性（实体 `attributes` 出生掷骰 10±3）/战场情绪/伤痕状态（`StatusEffects.list_active()` 新接口）/装备概览（点击跳背包）；**不显示名字** |
| 绷带确实可以有 | 保留（消耗品，Hotbar 数字键使用） |

键位新增：**C = 角色属性面板**（Hotbar 动作组第四格，人形剪影图标）。
注：矿物当前只是背包合法物品类型（定义+堆叠限量就绪）；采集链路仍直入区域库存，矿物进包走未来掉落/拾取批次。

## 遗留（下批次）

- 武器 attack_mult/speed_mult 数据化应用（P5）
- 拾取/掉落、商店（InGameShop 形态）
- 背包拖拽交互、整理按钮
- 背包存档接线（to_dict/from_dict 已就绪，SaveManager 玩家数据段挂链下批验证）
