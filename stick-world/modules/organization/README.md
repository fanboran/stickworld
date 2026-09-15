# organization：五层级组织树与指挥链

> 组织是游戏最核心的通用管理单元——军队、科学院、工程队、行政体系、商队共享同一套底层逻辑：
> - 组织树 CRUD、编制/装备模板、人事任免与跨组织调人（organization_manager）
> - 逐层指挥链：命令分解出 hop 计划 + 传输层算物理传播延迟（command/）
> - 上报流：`evaluate_report_gate` 门控 → `report_filed`（战斗挂点先门控后提交；补位引擎 commander_lost 必报）
> - 招兵与人口再生（recruit_manager）、组织 UI 四件套（ui/）
>
> 系统级设计见 [docs/技术/架构/组织系统架构.md](docs/技术/架构/组织系统架构.md)、[docs/设计/系统/01-组织系统.md](docs/设计/系统/01-组织系统.md)。

---

## 目录结构

```
modules/organization/
├── api.gd                              # 对外契约：组织树/编制/人事/预设/指挥链/招兵全部入口 + 4 公共信号
├── scripts/
│   ├── organization_manager.gd         # 管理逻辑：TIER 1-5 / 七标签校验、补位引擎（succession）、上报门控
│   ├── recruit_manager.gd              # 招兵（扣资源+空闲村民变身士兵）与人口再生节律，常驻 GameRoot
│   ├── default_behavior_writer.gd      # 按 config/ai/org_default_behavior.tres 灌 default_behavior（总闸缺省关）
│   └── command/
│       ├── org_command_dispatcher.gd   # 逐层命令分解：hop 0 玩家跳 + BFS 层序展开到 L1（同令透传）
│       └── transport_layer.gd          # 延迟 = 距离 ÷ 传令速度；位置/距离查询经装配层注入的 provider
└── ui/
    ├── org_panel.gd                    # 组织树管理窗口：新建/插删层/解散/任免/调人/预设/导出蓝图
    ├── command_chain_view.gd + command_chain_view.tscn   # 指挥链沙盘窗口（订阅 EventBus relay 信号）
    ├── command_chain_board.gd          # 兵棋沙盘：层级树兵牌 + 命令逐跳传播动画
    ├── strategic_overview_panel.gd     # 全组织报表 + 上报流时间线
    └── org_report_narrator.gd          # report_filed → EventBus.ui_notification toast（补位叙事）
```

---

## 对外契约

- 信号：`org_created / org_restructured / org_disbanded / report_filed`。
- 高频入口：`transfer_stickman(stickman_id, from_org, to_org)` 跨组织调人原子接口（校验一体、失败零改动，成功对双方各发一次 org_restructured）；`build_dispatch_plan` + `get_delivery_time` 逐层投递；`evaluate_report_gate → file_report` 上报流；`recruit()` 招兵。
- 组织状态实体为 core/entities/organization_state.gd，注册进 WorldState 容器，存档由 WorldState 统一序列化。

---

## 依赖

- `core/`：WorldState / EventBus / OrganizationState。
- 配置：`config/balance/variables.tres`（指挥链三参数：传令速度/跨图距离/伤亡上报阈值）、`config/formations/presets.tres`（预设母本）、`config/ai/org_default_behavior.tres`（默认行为档案）。
- 零出向模块依赖：跨模块查询（实体坐标/玩家位置/跨图距离）全部经 set_transport_providers 注入的 Callable。
- 被依赖：`modules/combat/`（tactical_orders 逐跳执行、formation_system 订阅 commander_assigned 回写）、`modules/units/`（招兵交互）、`modules/world/`（SystemSetup 装配与指挥官注入）。

---

## 扩展指引

- 调整上报三档门控规则：organization_manager 的 evaluate_report_gate；消费端范式见 ui/org_report_narrator.gd（不做二次门控）。
- 换传输模型（v1 直算延迟 → v2 信使任务）：只替换 scripts/command/transport_layer.gd，接口不变。
