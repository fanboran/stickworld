# 经济变量表

> **所有数值均为 [PLACEHOLDER] —— 在原型验证前不做任何承诺。**
> 本文档作为调优起点，在第一次可玩版本后用实际数据替换。

---

## 一、基础资源

| 变量 | 初始值 | 最小值 | 最大值 | 单位 | 调优说明 |
|------|--------|--------|--------|------|----------|
| 初始食物 | [PLACEHOLDER] | — | — | 单位 | |
| 初始木材 | [PLACEHOLDER] | — | — | 单位 | |
| 初始石料 | [PLACEHOLDER] | — | — | 单位 | |
| 初始金属矿 | [PLACEHOLDER] | — | — | 单位 | |
| 初始黑色沥青 | [PLACEHOLDER] | — | — | 单位 | 开局极少 |
| 每火柴人食物消耗/天 | [PLACEHOLDER] | [PLACEHOLDER] | [PLACEHOLDER] | 单位 | |
| 每士兵食物消耗/天 | [PLACEHOLDER] | — | — | 单位 | 士兵消耗 > 平民 |

---

## 二、生产效率

| 变量 | 基础值 | 范围 | 说明 |
|------|--------|------|------|
| 农夫食物产出/天 | [PLACEHOLDER] | — | 受科技/工具/土地肥力影响 |
| 矿工矿石产出/天 | [PLACEHOLDER] | — | 受矿脉质量/工具影响 |
| 伐木工木材产出/天 | [PLACEHOLDER] | — | |
| 建筑工建造速度 | [PLACEHOLDER] | — | 单位：工时/平方米 |
| 研究员研究点数/月 | [PLACEHOLDER] | — | 受教育水平影响 |

---

## 三、市场价格

| 商品 | 基础价格 | 波动范围 | 说明 |
|------|----------|----------|------|
| 食物 | [PLACEHOLDER] 金币/单位 | ±[PLACEHOLDER]% | 需求稳定，波动小 |
| 木材 | [PLACEHOLDER] | ±[PLACEHOLDER]% | |
| 石料 | [PLACEHOLDER] | ±[PLACEHOLDER]% | |
| 金属矿 | [PLACEHOLDER] | ±[PLACEHOLDER]% | 战争期间大涨 |
| 黑色沥青 | [PLACEHOLDER] | ±[PLACEHOLDER]% | 极其昂贵，战略物资 |
| 武器 | [PLACEHOLDER] | ±[PLACEHOLDER]% | |
| 盔甲 | [PLACEHOLDER] | ±[PLACEHOLDER]% | |
| 法术卷轴 | [PLACEHOLDER] | ±[PLACEHOLDER]% | |

---

## 四、经济制度参数

| 变量 | 默认值 | 范围 | 说明 |
|------|--------|------|------|
| 基础税率 | [PLACEHOLDER]% | 0-100% | |
| 通胀警戒线 | [PLACEHOLDER]%/年 | — | 超过触发民众不满 |
| 市场响应延迟 | [PLACEHOLDER] 天 | [PLACEHOLDER]-[PLACEHOLDER] | 价格信号到生产调整的延迟 |
| 腐败自然率 | [PLACEHOLDER]%/月 | — | 随帝国规模增大 |
| 运输成本占比 | [PLACEHOLDER]%/千米 | — | |

---

## 五、人口

| 变量 | 值 | 说明 |
|------|-----|------|
| 初始追随者数量 | 0-3 | 阶段1开局 |
| 自然增长率 | [PLACEHOLDER]%/年 | 无召唤时的人口增长 |
| 召唤1火柴人消耗沥青 | [PLACEHOLDER] 单位 | |
| 最大召唤人口 | 沥青储量 / 单位消耗 | 硬上限 |
| 人口幸福度影响阈值 | [PLACEHOLDER] | 低于此值 → 可能叛乱 |

---

## 六、科技

| 变量 | 值 | 说明 |
|------|-----|------|
| 基础研究速度 | [PLACEHOLDER] 点/研究员/月 | |
| 沥青消耗/研究员/月 | [PLACEHOLDER] | |
| 教育投资回报周期 | [PLACEHOLDER] 年 | 村塾→科学院 |
| 科技扩散速度 | [PLACEHOLDER]/年 | 邻国获得你的科技 |

---

## 七、扩张与管理

| 变量 | 值 | 说明 |
|------|-----|------|
| 地块控制度上升速度 | [PLACEHOLDER]%/月 | 驻军加速 |
| 侵略扩张(AE)衰减 | [PLACEHOLDER]/年 | |
| 过度扩张阈值 | [PLACEHOLDER] 地块 | 超此数触发惩罚 |
| 管理成本指数 | 地块数^[PLACEHOLDER] | 超线性增长 |
| 包围网触发 AE 阈值 | [PLACEHOLDER] | |

---

## 八、战斗

| 变量 | 初始值 | 范围 | 说明 |
|------|--------|------|------|
| 火柴人基础HP | [PLACEHOLDER] | [PLACEHOLDER]-[PLACEHOLDER] | 受种族/装备影响 |
| 基础攻击力 | [PLACEHOLDER] | — | |
| 士气崩溃阈值 | [PLACEHOLDER]% 伤亡 | — | |
| 命令传达延迟/指挥链层 | [PLACEHOLDER] 秒 | — | |
| 补给断供后存活时间 | [PLACEHOLDER] 天 | — | |

---

*所有数值等待第一个可玩原型后校准。*
