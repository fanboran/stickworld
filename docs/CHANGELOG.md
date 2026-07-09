# 变更日志

本文档记录 Stick World 项目所有值得注意的变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [未发布]

### 架构设计 (2026-07-09 · 第三轮)
- 代码 vs 文档对照审计完成——文档超前代码 2 个大版本，代码骨架好但缺血肉
- 新建 `docs/technical/architecture/` 目录，6 份底层架构文件
- **精简 `.trae/rules/rule.md`**：364 行 → ~230 行，砍掉说服性散文和 PowerShell 规范，新增项目文档导航和"设计先行"规则：
  - `entities.md` — 9 个核心实体的完整属性 + 状态机
  - `interactions.md` — 8 层系统交互矩阵 + EventBus 事件目录 2.0（28→50+ 信号）
  - `data-flow.md` — 命令下发/经济调节/信息上报三条流 + 三层存储架构
  - `apis.md` — 8 个模块的 api.gd 完整接口规范（含前置/后置条件）
  - `autoloads.md` — 6+3 个 Autoload 依赖图 + 初始化顺序
  - `balance-framework.md` — 变量→公式→数据表→调优面板完整管线

---

- **重大修正**：基于创始人 22 题 Q&A，纠正对核心系统的理解错误
- 删除 `phasing-system.md`（阶段演进不是独立系统，合并到 GDD）
- **重写 `organization.md`**：从"军事指挥链"→"通用五层级项目管理系统"（军事/科研/工程/行政/商业同一套工具）
- **重写 `combat.md`**：编制部分移除（归属 orgnization），聚焦战术层面的附身操控和《英雄连》式 AI
- **重写 `gdd.md`**（v4.0）：整合八层纵切+五层级横切、组织全能但特化、UI 工作区预设、价格信号融入
- 更新 `design-pillars.md`、`core-loop.md`、`ui-ux.md`、`economy.md`、`expansion.md`
- 新增：平衡性数据表、UI/UX 设计规范

---

## [0.1.0] — 2026-06-20

### 新增
- 初始游戏设计文档（GDD v2.0）——"管理学模拟器/组织机构搭建模拟器"
- 八层核心结构设计（经营建设/科技/资源/扩张/建设/组织/战斗/运输）
- 用户画像与 OPC 商业分析（资源盘点、价值主张、商业模式）
- 技术架构与开发规范文档
- AI 工作流指南
- 架构改进待办项
- AI 项目引导启动流程文档
- Godot 项目骨架（stick-world/）

---

## 版本说明

- 当前项目处于原型阶段，版本号仅用于文档追踪
- 游戏本身尚未进入 Alpha
