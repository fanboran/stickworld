# Stick World

> **火柴人版"从部落到大帝国"——P 社大战略 + 工厂自动化 + 无缝战术指挥的缝合怪单机游戏。**

你从一个只有几个追随者的部落首领起步，亲手设计帝国的每一个齿轮：指挥链、经济制度、科技体系、军事编制。从手操几个火柴人士兵微操，到以上帝视角调度整个帝国——像《戴森球计划》那样丝滑地完成尺度跃迁。

美术上参照《火柴人战争遗产》的纯黑线条风格，融合西幻世界观，不同地域的火柴人拥有独特的种族特征与文化。

---

## 核心特色

- **无缝尺度跃迁**：从控制一个火柴人的脸 → 连续缩放 → 帝国全图。随时"附身"到任意层级微操
- **组织架构即玩法**：用同一套五层级项目管理系统搭建军队、科学院、工程队、行政体系——军师团连排班就是科院的院所室课题组
- **自动化帝国**：你设计的层级架构自己运转——每个 AI 只指挥直属下级，像工厂产线一样自动运行
- **全能但特化**：每个组织理论上什么都能干（军事单位也能施工），但标签预设不同工作区 UI，底层能力全通
- **全真模拟底层**：放大看——每个火柴人都在真实工作/战斗/运输，不是抽象数值

---

## 文档导航

| 你想了解 | 去看 |
|----------|------|
| 游戏整体设计 | [`design/游戏设计文档.md`](design/游戏设计文档.md) |
| 设计支柱（为什么这么做） | [`design/设计支柱.md`](design/设计支柱.md) |
| 核心玩法循环 | [`design/核心循环.md`](design/核心循环.md) |
| 世界观与种族 | [`design/世界观设定.md`](design/世界观设定.md) |
| 通用项目管理系统 | [`design/mechanics/组织系统.md`](design/mechanics/组织系统.md) |
| 战斗系统 | [`design/mechanics/战斗系统.md`](design/mechanics/战斗系统.md) |
| 组织与指挥链 | [`design/mechanics/组织系统.md`](design/mechanics/组织系统.md) |
| 经济与市场 | [`design/mechanics/经济系统.md`](design/mechanics/经济系统.md) |
| 科技系统 | [`design/mechanics/科技系统.md`](design/mechanics/科技系统.md) |
| 扩张系统 | [`design/mechanics/扩张系统.md`](design/mechanics/扩张系统.md) |
| 物流运输 | [`design/mechanics/物流系统.md`](design/mechanics/物流系统.md) |
| 成就/图章系统 | [`design/mechanics/成就系统.md`](design/mechanics/成就系统.md) |
| UI/UX 设计 | [`design/UI设计规范.md`](design/UI设计规范.md) |
| 平衡性数据 | [`design/balance/经济变量表.md`](design/balance/经济变量表.md) |
| Excel 数据管线 | [`technical/excel-pipeline.md`](technical/excel-pipeline.md) |
| 技术架构 | [`technical/技术架构.md`](technical/技术架构.md) |
| 开发者指南 | [`technical/开发指南.md`](technical/开发指南.md) |
| 竞品分析 | [`business/竞品分析.md`](business/竞品分析.md) |
| 项目路线图 | [`project/路线图.md`](project/路线图.md) |
| 变更日志 | [`CHANGELOG.md`](CHANGELOG.md) |

---

## 技术栈

- **引擎**：Godot 4.x（GDScript）
- **美术**：纯 2D 火柴人矢量风格 + 骨骼动画
- **架构**：模块化，core/ + modules/ 分层
- **测试**：GdUnit4
- **CI/CD**：GitHub Actions
- **开发模式**：Vibe Coding + AI 辅助

---

## 当前状态

**原型阶段** —— 核心循环待验证。

---

## 贡献

目前为单人开发。当室友/他人加入时，参见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。

## 许可

[待确定]
