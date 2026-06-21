# Assets 素材目录

本项目所有游戏美术素材以 **SVG 矢量格式** 存放，Godot 原生支持导入 SVG。

## 目录结构

| 目录 | 内容 |
|------|------|
| `characters/` | 火柴人角色：玩家单位、NPC、敌人 |
| `buildings/` | 城市建设素材：房屋、工厂、市政建筑 |
| `ui/` | UI 组件：按钮、图标、面板装饰 |
| `environment/` | 地图环境：树木、山脉、草地 |
| `effects/` | 特效：粒子、动画帧、武器轨迹 |

## 美术管线

所有SVG通过独立的美术工作流生成：

```
ImageGen 参考图 → CV分析(analyze.py) → AI读取JSON → 手写语义化SVG
```

工具在 `F:\VSCode\art_pipeline/`，独立于本项目和 game/ 项目。
