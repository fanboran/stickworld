# building_gen 模块开发日志

> 不适合写进 docs/ 的零碎信息、调试记录、试错过程记在这里。
> 结构化设计文档见 `docs/技术/教程/程序化材质设计.md`。

---

## 2026-07-23 茅草材质 Shader 阶段1调试

### 当前目标

让 `thatch_debug.tscn` 运行后能看到单叶片。

### 已做改动

1. 创建 `shaders/thatch.gdshader`
   - 初始版本用 `##` 注释 → 编译报错：`Tokenizer: Unknown character #35: '#'`
   - 修复：所有注释改为 `//`
2. 创建 `scenes/thatch_debug.tscn` + `scripts/debug/thatch_debug.gd`
   - 右侧参数面板实时调整 uniform
3. 参考图配色分析（OpenCV KMeans）
   - 主色：#e6b578 / #d19759 / #ba783c / #9b5b2d / #693a1f
   - 输出：`reference/thatch_palette_swatch.png`
4. 叶片判断逻辑迭代
   - v1: 投影到局部坐标系（along/perp）→ 用户反馈无叶片
   - v2: 点到线段距离 → 用户反馈无叶片
   - v3: 加 epsilon + UV 可视化调试（当前）

### 调试过程记录

| 步骤 | 操作 | 结果 |
|------|------|------|
| 1 | Shader 用 `##` 注释 | 编译报错：`Tokenizer: Unknown character #35: '#'` |
| 2 | 改 `//` 注释；else 分支输出 `vec4(uv.x, uv.y, dist*5, 1)` | 用户看到纯蓝色方块 |
| 3 | else 分支输出 `vec4(UV.x, UV.y, 0, 1)` | UV 渐变正常，确认 UV 可用 |
| 4 | 完整叶片判断 + 大参数 (length=1.2, width=0.15) | 待用户验证 |

### 关键发现

- **Polygon2D 的 UV 是正常的**，问题不是 UV 映射
- **叶片判断逻辑正确**，但默认参数让叶片在 UV 空间中非常细小，难以看到
- 解决方向：放大默认叶片尺寸（length=1.2, width=0.15），让单叶片清晰可见

### 截图工具状态（已解决）

`tools/capture_debug.gd` 在自动化命令行环境中无法可靠捕获 Godot 窗口内容。已尝试：
- 等待多帧 + `RenderingServer.frame_post_draw`
- 加载 .tscn vs 程序化创建场景
- Polygon2D vs Sprite2D
- D3D12 vs OpenGL3 渲染驱动

问题根源：命令行启动的 Godot 显示窗口在自动化环境中可能无法实际渲染到 viewport，导致 `viewport.get_texture()` 只能拿到默认背景。

**解决方案**：使用 Godot Movie Maker 的 PNG 序列模式。

- 脚本：`tools/capture_movie.ps1`
- 核心命令：
  ```powershell
  godot --path <project> --write-movie modules/building_gen/reference/thatch_movie_frame.png --quit-after 60 --fixed-fps 30 --position 10000,10000
  ```
- 要点：
  1. **不要用 `--headless`**。必须保留真实显示驱动，否则 viewport 只能拿到默认背景。
  2. `--write-movie` 路径以 `.png` 结尾时，Godot 输出 PNG 序列：`thatch_movie_frame00000000.png`、`thatch_movie_frame00000001.png`……
  3. `--quit-after N` 控制渲染 N 帧后自动退出。
  4. `--position 10000,10000` 把窗口移到屏幕外，避免干扰桌面。
  5. 脚本取第 30 帧（`FrameIndex = 30`，0-based）复制为 `thatch_debug_capture.png`。

**验证结果**：`thatch_debug_capture.png` 成功显示 UV 渐变，证明截图工具可靠，且 Polygon2D 的 UV 传递正常。

### 当前参数（最保守测试）

- `blade_angle = 0.0`（竖直向下，排除角度问题）
- `blade_length = 1.0`（从顶部到底部）
- `blade_width = 0.3`（很粗，确保命中）
- `blade_color = #e6b578`
- Polygon2D 已设置 4x4 白色 texture 以激活 UV 传递

### 下一步

- 用户 F6 运行验证是否能看见黄色竖直粗叶片
- 如可见 → 角度/参数问题，逐步调回 -60° 并缩小 width
- 如仍不可见 → `UV` 变量在 Polygon2D 上实际不可用，需换用其他方式（如 Sprite2D 调试或 varying 传 VERTEX）

---

## 2026-07-23 茅草材质 Shader 阶段5-6 迭代：建筑双屋顶 + 笔刷形状 + 层间基调色

### 新增内容

1. **茅草建筑演示场景**：[scenes/thatch_building_demo.tscn](file:///f:/VSCode/game-2/stick-world/modules/building_gen/scenes/thatch_building_demo.tscn) + [scripts/debug/thatch_building_demo.gd](file:///f:/VSCode/game-2/stick-world/modules/building_gen/scripts/debug/thatch_building_demo.gd)
   - 动态创建 `RoofLeft`（-60°）和 `RoofRight`（+60°）两片屋顶
   - 共用同一份 `thatch.gdshader`，仅通过 uniform 区分角度与种子
   - 验证：建筑长度可变、左右对称、材质与几何耦合

2. **截图工具增强**：[tools/capture_standard.ps1](file:///f:/VSCode/game-2/stick-world/modules/building_gen/tools/capture_standard.ps1)
   - 新增 `-ScenePath` 参数，可指定要捕获的场景，例如：
     ```powershell
     .\modules\building_gen\tools\capture_standard.ps1 `
       -ScenePath "res://modules/building_gen/scenes/thatch_building_demo.tscn" `
       -OutputFrame "modules/building_gen/reference/thatch_building_demo_capture.png"
     ```

3. **Shader 笔刷形状升级**：[shaders/thatch.gdshader](file:///f:/VSCode/game-2/stick-world/modules/building_gen/shaders/thatch.gdshader)
   - 新增 uniform：`root_width_mul`、`tip_width_mul`、`width_noise`、`oil_roughness`
   - 根部更粗、梢部更细，中间宽度沿长度正弦抖动
   - 笔触边缘叠加低频噪声，产生油画/手绘毛边
   - 颜色混合从"完全覆盖"改为"油画式 alpha 融合"，重叠笔触自然混合

4. **层间基调色区分**
   - 上层偏亮暖，下层偏暗冷
   - `row_t` 驱动压暗（最多 50%）、轻微去饱和、暖棕色调偏移
   - 单片内仍保留随机亮度/色相抖动

5. **参考图配色校准**
   - 对比 `reference/thatch_ref.png` 与 `reference/smithy_lv1_full.png`
   - 将默认调色板从偏红棕调整为更金黄麦秆色

### 当前输出

- `reference/thatch_debug_capture.png`：单片屋顶，便于调参观察
- `reference/thatch_building_demo_capture.png`：左/右两片屋顶，验证建筑集成

### 测试

- [tests/modules/building_gen/test_thatch_shader.gd](file:///f:/VSCode/game-2/stick-world/tests/modules/building_gen/test_thatch_shader.gd) 增加对 `thatch_building_demo.tscn` 的异步实例化测试
- 全部 5 项测试通过：场景实例化、材质与 Shader、关键 uniform、CaptureHelper、建筑演示场景

---

## 2026-07-23 茅草材质 Shader 阶段2-4 迭代 & 截图工具标准化

### 截图工具：切换到标准运行方式

`tools/capture_movie.ps1`（Movie Maker PNG 序列）能工作，但会产生中间帧、需要清理。进一步迭代后，确认**标准运行方式**更简洁稳定：

- 脚本：`tools/capture_standard.ps1`
- 核心思路：正常运行项目，由场景内的 `scripts/debug/capture_in_game.gd` 等待若干帧、保存 viewport 截图后自动退出。
- 核心命令：
  ```powershell
  godot --path <project> --position 10000,10000
  ```
- 关键注意点：
  1. **不能用 `--headless`**。无窗口模式下 GPU 不会真正渲染 CanvasItem Shader，viewport 只能拿到默认背景/灰格。
  2. `--position 10000,10000` 把窗口移到屏幕外，避免干扰桌面；显示驱动仍在正常工作，截图有效。
  3. `capture_in_game.gd` 里等待 `RenderingServer.frame_post_draw` 多帧（默认 5 帧），确保 Shader 编译完成、画面稳定后再截图。
  4. 用 `--quit-after` 配合 Movie Maker 是备选方案；标准运行是首选。

- 外部参考：Godot 官方文档与社区讨论均指出 viewport 截图需要显示服务器（display server），headless / xvfb 下会得到灰格或黑色画面。
  - [Godot Docs: Command line tutorial](https://docs.godotengine.org/en/stable/tutorials/editor/command_line_tutorial.html)
  - [Godot Forum: use Godot script to create a picture](https://forum.godotengine.org/t/use-godot-script-to-create-a-picture/128574)
  - [Shaggy Dev: Easy in-engine screenshots](https://shaggydev.com/2025/02/05/godot-screenshots/)

### Shader 迭代记录

#### 坐标系修正

调试时发现 `Sprite2D.scale = (400, 300)` 实际世界尺寸是 `1600×1200`（因为 `white_tex.png` 是 4×4）。为了把 UV 空间与像素空间 1:1 对应，改为 `scale = (100, 75)`，同时 `Camera2D.zoom = (1, 1)`，这样 `resolution = (400, 300)` 就是真实像素范围。

#### 从单叶片到多层

1. **行方向垂直于叶片方向**：每一层沿垂直于茅草的线分布，层与层之间沿叶片方向向下推进，天然形成“一层压一层”。
2. **整片裁剪**：根部或梢部超出有效范围时，**整片不渲染**，不会出现半片。
3. **起始角自适应**：向左倾斜（-60°）时从右上角开始，向右倾斜（+60°）时从左上角开始，让叶片向区域内生长。

#### 下边缘随机余量

下边缘不是一条硬线，而是：
- 层间大波浪：`sin(row * 1.1 + seed)`
- 每片随机：`hash(...) * edge_noise`
- 最终允许范围：`bounds.w + margin_bottom * edge_factor`

这样部分“幸运叶片”会出头，形成做旧的自然边缘。

#### 单片随机

每个叶片在 hash 驱动下有独立参数：
- 长度 = `base + layer_wave + per_blade_normal`
- 宽度 = `base + per_blade_var`
- 角度 = `blade_angle ± angle_var`
- 弯曲度 = `curve_amount * sin(t·π) * length * per_blade_curve`
- 颜色 = 从 5 色调色板随机选取 + 梢部变暗 + 极细噪点

#### 当前默认参数

```
blade_angle      = -1.047  (-60°)
angle_var        = 0.12
curve_amount     = 0.18
rows             = 14
blades_per_row   = 48
row_spacing      = 28.0
blade_spacing    = 10.0
blade_length_base= 110.0
blade_width_base = 5.0
margin_bottom    = 45.0
edge_noise       = 0.9
```

### 当前输出

`reference/thatch_debug_capture.png` 已能渲染出密集的倾斜茅草块，具备：
- 独立完整叶片（无半截）
- 60°倾斜、层层叠叠
- 颜色变化与手绘噪点
- 下边缘随机参差

### 新增测试

`tests/modules/building_gen/test_thatch_shader.gd`：
- 验证 `thatch_debug.tscn` 可实例化
- 验证 Sprite2D 使用 `thatch.gdshader`
- 验证 Shader 包含关键 uniform
- 验证 CaptureHelper 挂载正确

运行：
```powershell
godot --path stick-world res://tests/modules/building_gen/test_thatch_shader.tscn
```

### 仍待优化

- [x] 边界改为平行四边形（或输入多边形），而非当前轴对齐矩形
- [x] 同一建筑生成左、右两片屋顶的集成示例
- [x] 进一步手绘感：笔刷形状、根部粗梢部细、层间颜色基调区分
- [ ] 性能：当前 12×36 = 432 次循环/像素，可接受但可继续优化
- [ ] 最上层根部允许被顶部边界截断（当前整片裁剪，顶部偶发稀疏）
- [ ] 屋顶可与木墙、木柱等几何进一步集成
