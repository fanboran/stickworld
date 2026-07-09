# 战斗变量表

> **所有数值均为 [PLACEHOLDER] —— 在原型验证前不做任何承诺。**

---

## 一、单位基础属性

| 变量 | 默认值 | 说明 |
|------|--------|------|
| 火柴人基础 HP | [PLACEHOLDER] | 不同种族有系数加成 |
| 基础移动速度 | [PLACEHOLDER] 像素/秒 | |
| 基础攻击力 | [PLACEHOLDER] | |
| 基础攻击速度 | [PLACEHOLDER] 次/秒 | |
| 基础攻击范围 | [PLACEHOLDER] 像素 | 徒手 |
| 基础防御力 | [PLACEHOLDER] | 减伤公式：[PLACEHOLDER] |

---

## 二、武器系数

| 武器类型 | 攻击力系数 | 速度系数 | 范围加成 | 特殊效果 |
|----------|-----------|----------|----------|----------|
| 徒手 | 1.0 | 1.0 | 0 | 无 |
| 短剑 | [PLACEHOLDER] | [PLACEHOLDER] | [PLACEHOLDER] | |
| 长剑 | [PLACEHOLDER] | [PLACEHOLDER] | [PLACEHOLDER] | |
| 矛 | [PLACEHOLDER] | [PLACEHOLDER] | [PLACEHOLDER] | 对骑兵加成 |
| 弓 | [PLACEHOLDER] | [PLACEHOLDER] | [PLACEHOLDER] | 远程 |
| 弩 | [PLACEHOLDER] | [PLACEHOLDER] | [PLACEHOLDER] | 远程，穿甲 |
| 法杖 | [PLACEHOLDER] | [PLACEHOLDER] | [PLACEHOLDER] | 消耗沥青 |

---

## 三、盔甲减伤

| 盔甲类型 | 减伤率 | 移动惩罚 | 说明 |
|----------|--------|----------|------|
| 无甲 | 0% | 0% | |
| 皮甲 | [PLACEHOLDER]% | [PLACEHOLDER]% | |
| 链甲 | [PLACEHOLDER]% | [PLACEHOLDER]% | |
| 板甲 | [PLACEHOLDER]% | [PLACEHOLDER]% | |
| 魔法护盾 | [PLACEHOLDER]% | 0% | 消耗沥青维持 |

---

## 四、士气系统

| 变量 | 值 | 说明 |
|------|-----|------|
| 初始士气 | 100 | |
| 伤亡扣士气 | [PLACEHOLDER]/每%伤亡 | |
| 指挥官阵亡扣士气 | [PLACEHOLDER] | 一次性扣除 |
| 补给断供扣士气 | [PLACEHOLDER]/天 | |
| 侧翼被袭扣士气 | [PLACEHOLDER] | |
| 友军溃败扣士气 | [PLACEHOLDER] | 连锁效应 |
| 士气崩溃阈值 | [PLACEHOLDER] | 低于此值 → 溃退 |
| 士气恢复速度 | [PLACEHOLDER]/分钟 | 脱离战斗后 |

---

## 五、指挥链延迟

| 变量 | 值 | 说明 |
|------|-----|------|
| 单层命令延迟（口头） | [PLACEHOLDER] 秒 | 视线内 |
| 单层命令延迟（信使） | [PLACEHOLDER] 秒/千米 | |
| 单层命令延迟（魔法） | 0 秒 | 即时 |
| 信使被截杀概率 | [PLACEHOLDER]% | |
| 命令误解率（低自主权） | [PLACEHOLDER]% | 部队可能误判 |

---

## 六、补给影响

| 变量 | 值 | 说明 |
|------|-----|------|
| 无补给存活天数 | [PLACEHOLDER] | 之后开始饿死 |
| 半补给战斗力惩罚 | [PLACEHOLDER]% | |
| 弹药耗尽后战斗力 | [PLACEHOLDER]% | 只能肉搏 |
| 补给线最大有效长度 | [PLACEHOLDER] 千米 | |

---

## 七、战斗规模参数

| 规模 | 单位数/场 | 典型时长 | 地图大小 |
|------|----------|----------|----------|
| 个体 | 2-6 | 1-3 分钟 | 小型 |
| 小队 | 10-50 | 5-15 分钟 | 中型 |
| 军团 | 100-500 | 15-45 分钟 | 大型 |
| 方面军 | 1000+ | 1-4 小时 | 超大型 |

---

## 八、主观能动性

| 行为 | 触发概率 | 说明 |
|------|----------|------|
| 追击过深 | [PLACEHOLDER]% | 单位脱离队形追击 |
| 发现更优战术位置 | [PLACEHOLDER]% | 自主移动 |
| 在劣势前犹豫 | [PLACEHOLDER]% | 延迟执行进攻命令 |
| 擅自冲锋（骑士精神） | [PLACEHOLDER]% | 可能撕开防线，也可能送死 |
| 救助战友 | [PLACEHOLDER]% | 停下战斗去拖受伤战友 |

**概率受以下因素影响**：
- 指挥官能力
- 部队士气
- 文化传统（游牧→更主动，农耕→更守序）
- 自主决策权限设定

---

*所有数值等待第一个可玩原型后校准。*
