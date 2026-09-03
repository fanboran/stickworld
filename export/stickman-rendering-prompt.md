# Stickman 渲染系统开发任务

## 参考资产

项目根目录下 `external/swl_extracted/` 包含 Stick War Legacy 四个单位的骨骼数据（.nodes 格式，StickNodes 应用的标准格式）。

**解析工具已就绪**：`npm install sticknodes-js` 已安装，以下脚本可解析任意 .nodes 文件：

```js
const sn = require('sticknodes-js');
const fs = require('fs');
sn.main();
const buf = fs.readFileSync('external/swl_extracted/SWL Swordwrath.nodes');
const sf = sn.Stickfigure.from_bytes(new Uint8Array(buf));
const indices = sf.get_all_node_indices();
for (const idx of indices) {
  const n = sf.get_node(idx);
  let parent = -1;
  try { parent = n.get_parent_index(); } catch(e) {}
  console.log(`id=${idx} parent=${parent} x=${n.local_x.toFixed(1)} y=${n.local_y.toFixed(1)} L=${n.length.toFixed(0)} T=${n.thickness} type=${n.node_type}`);
}
sf.free();
```

## 已解析的 SWL Swordwrath 完整骨骼数据（24 节点）

```
id=  0 p= -1 x=   0.0 y=   0.0 L=  0 T= 0  (根节点)
id=  1 p=  8 x= -34.7 y= -53.9 L= 64 T=23  roundSeg
id=  2 p=  1 x=  -3.1 y= -48.7 L= 49 T=23  roundSeg
id=  3 p=  0 x=  25.4 y= -60.9 L= 66 T=23  roundSeg  (右臂起点)
id=  4 p=  3 x=   2.9 y= -68.9 L= 69 T=23  roundSeg  (右上臂)
id=  5 p=  4 x=  11.0 y=   0.0 L= 11 T=23  roundSeg  (右前臂)
id=  6 p=  0 x=   1.8 y=  30.9 L= 31 T=23  roundSeg  (身体向下)
id=  7 p=  6 x=   5.7 y=  30.5 L= 31 T=23  roundSeg
id=  8 p=  7 x=  10.4 y=  29.2 L= 31 T=23  roundSeg  (身体核心)
id=  9 p=  8 x=  19.9 y=  45.9 L= 50 T=23  roundSeg  (左腿)
id= 10 p=  9 x= -15.1 y= -34.8 L= 38 T=23  circle   (左脚)
id= 11 p=  0 x=  -4.8 y= -65.8 L= 66 T=23  roundSeg  (左臂起点)
id= 12 p= 11 x= -16.9 y= -66.9 L= 69 T=23  roundSeg  (左上臂)
id= 13 p= 12 x=  11.0 y=   0.2 L= 11 T=23  roundSeg  (左前臂)
id= 14 p=  8 x=   1.1 y= -64.1 L= 64 T=23  roundSeg  (握剑手臂起点)
id= 15 p= 14 x=  33.8 y= -35.2 L= 49 T=23  roundSeg
id= 16 p= 15 x= 144.2 y=  91.9 L=171 T= 0  roundSeg  (剑柄)
id= 17 p= 16 x=-100.3 y= -64.0 L=119 T=18  triangle  (剑刃)
id= 18 p= 17 x= -28.7 y= -18.3 L= 34 T=18  triangle
id= 19 p= 18 x= -13.9 y=  -8.9 L= 17 T= 7  triangle
id= 20 p= 19 x= -11.8 y=  -7.5 L= 14 T= 7  triangle
id= 21 p= 20 x= -26.1 y= -16.7 L= 31 T=14  ellipse   (护手)
id= 22 p= 18 x= -15.4 y=  24.2 L= 29 T=18  triangle
id= 23 p= 18 x=  15.4 y= -24.2 L= 29 T=18  triangle
```

**坐标系**：Y 轴朝下（Godot 标准）。每个节点的 `(x, y)` 是相对于父节点的偏移。`L` = 段长度，`T` = 段粗细。

**节点类型**：0=roundSeg（圆头粗线，占大多数），2=circle（圆形），3=triangle（三角形），5=ellipse（椭圆）。

**SWL Spearton（132节点）、Giant（86节点）、Archidon（61节点）** 的完整数据可用同一脚本解析。

---

## 任务：在 Godot 4.x 中实现商业级火柴人渲染

### 技术要求

1. **Skeleton2D + Bone2D**：用 Godot 原生骨骼系统。每根骨头的 `position` 从 SWL 数据的 `(x, y)` 设置。层级关系按 `parent` 字段构建。

2. **身体部件**：每个 Bone2D 节点挂一个 Sprite2D 子节点。纹理为 **pill 形状**（圆头粗线，`roundSeg` 类型），程序化生成——用 Image.create + draw 逻辑画圆头矩形，再 ImageTexture.create_from_image。长度取 SWL 的 `L`，粗细取 `T`。

3. **武器部件**：剑刃用三角形纹理（`triangle` 类型），护手用椭圆（`ellipse`）。

4. **高清抗锯齿**：纹理在 2x 分辨率下生成，然后用 `Image.INTERPOLATE_LANCZOS` 缩回目标尺寸。

5. **AnimationPlayer**：预置 idle / walk / attack / dead 四段关键帧动画。动画通过修改 Bone2D 的 `rotation` 属性和 `position` 属性实现。每个动画的时长参考 SWL 原作手感。

6. **AnimationTree + StateMachine**：idle ↔ walk 双向切换，attack 从任意状态触发后回到 idle，dead 为终态。

7. **测试场景**：`stick-world/world/units/stickman_test.tscn`，一个 Node2D 根，挂载 StickmanRig，按 1/2/3/4 切换动画。

### 文件位置

```
stick-world/world/units/
├── stickman_rig.gd     (StickmanRig 类，完整渲染+动画逻辑)
├── stickman_test.gd    (测试控制器)
└── stickman_test.tscn  (测试场景)
```

### 不要做的事

- 不要用 `_draw()` 画线
- 不要用程序化正弦波动画
- 不要硬编码种族参数
- 不要做 4399 小游戏级别的像素渲染
