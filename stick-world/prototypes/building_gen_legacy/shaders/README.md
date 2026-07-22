# 旧版 Shader 实验归档

本目录存放 `modules/building_gen/materials/thatch/shaders/` 中不再使用的实验性 Shader。

## 文件说明

| 文件 | 说明 |
|------|------|
| `thatch_edge.gdshader` | "零后处理"方案实验：直接采样纹理 alpha，不做程序化边缘生成。该方案依赖预生成贴图，与新架构的纯 Shader 实时生成叶片冲突，故归档。 |

## 当前方案

新架构使用 `modules/building_gen/materials/thatch/shaders/thatch.gdshader`：

- 在 fragment shader 中实时生成每根茅草叶片
- 叶片完整渲染或完全不渲染，不依赖外部贴图 alpha
- 支持平行四边形边界、层间色调、下边缘随机参差
