# 变更日志

本文档记录 Stick World 项目所有值得注意的变更。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

---

## [未发布]

### L1 湖泊-陆地无缝 + Tab 跟随玩家当前 L1（2026-08）

- **湖泊-陆地交界缝隙**：湖泊 mesh 与城市块 mesh 是**两套独立 extract**（湖从湖 mask 提、地块从城市划分提），交界处两套多边形边界不重合（0~2px 缝），且城市块直线边界 vs 湖弧线之间露缝。修复：`export_l1_view_context.py` **城市块湖边段顶点投影到湖泊 polygon 边**（地块边界"套用湖泊轮廓"，把地块填充到缝隙上；旋转使湖边段不跨数组起点 + 整段自交时从两端二分裁剪保留贴合段；自交检查局部化加速）；`map_renderer._bake_base_mesh` **湖泊最后画**（盖邻居/城市色块）——交界处由湖弧线决定，严丝合缝。已重跑出生 + 全部 69 个 `l1_packs`
- **Tab 跟随玩家当前 L1**：Tab 打开显示**玩家当前所在 L1**（现在=出生 L1）；L2 点击 L1 下钻改为**临时查看**（ESC 返回 L2，不再改变 Tab 的 L1）。api 记录当前 L1（`get_current_l1_label`）+ `ensure_player_l1`（Tab 打开时切回玩家 L1，切换才重载并重置视角）；controller 加 `_player_l1_label` + `set_player_l1`（预留游戏内跨 L1 移动时更新，Tab 跟随）
- **验证**：P0 9/9（含新增"Tab 跟随/湖泊-城市不重叠"）、L2 7/7、全量 23/24（1 项预存无关失败）、check_godot_errors 干净

### L1 地图描边修复：跨环乱飞线 + 缩放粗细滞后跳变（2026-08）

- **L1 权威轮廓跨环乱飞线**：老 L1 多连通（大陆 + 岛屿）时 `extract_mesh` 输出多个外环，`export_l1_view_context.py` 的 `extend` 把多环串接成单个点列 → renderer `_closed` + 单条 `draw_polyline` 把不相连环串成跨海乱飞连接线（下钻打开含岛屿的老 L1 时出现；出生 L1 为单连通不受影响）。修复：`export_l1_view_context.py` 的 `l1_polygon` 只取最大环（主大陆）——岛屿不画 L1 轮廓粗线，由城市色块/描边呈现；renderer 恢复单环闭合绘制。已重跑出生 + 全部 69 个 `l1_packs`
- **缩放后描边粗细滞后跳变**：MapCamera 缩放/平移用节点 transform（`target.scale`）不触发 CanvasItem 重绘，描边宽度（屏幕像素固定，`width/zoom`）按旧 zoom 计算 → 缩放后粗细不变、hover 触发重绘才跳到新值。修复：MapCamera 加 `set_map_renderer`，缩放/平移后 `queue_redraw()`，描边宽度即时跟随 zoom（`strategic_map_controller` 接线）
- **验证**：P0 7/7、L2 7/7、全量 23/24（1 项预存无关失败）、check_godot_errors 干净

### L2→L1 下钻：L2 点击 L1 地块打开对应老 L1 地图 + Tab 城市中心小点（2026-08）

- **L2 点击 L1 下钻**：L2 地图单击任一 L1 地块 → 打开该老 L1 的 Tab 视图（城市细分），ESC 返回 L2。数据侧：`export_l2_view_packs.py` 为每个 L1 地块写新字段 `global_l1_label`（`tiles_8192` 与 `legacy_l1_labels_8192` 逐像素对齐、多数投票映射局部 label → 老 L1 全局 label，region_013 局部 1/2/3 ↔ 全局 67/68/69）；`export_l1_view_context.py` 加 `--out-dir` 支持批量，导出全部 69 个老 L1 上下文到 `config/strategic_map/l1_packs/l1_%03d/`（l1_world.json + l1_base.png + l1_mask.png，含 `parent_l1_label`）。运行时侧：`api.open_l1(label)` 加载指定 L1 数据（替换 _data、renderer/camera 同步切换）；`StrategicMapController.open_l1` 打开并重置视角适配新 context；`L2MapController` 左键点击 L1 地块（复用 hover 同路径：`screen_to_map − tiles_offset` → 索引图查询）触发下钻，隐藏 L2 并显示 L1，L1 ESC 经 `back_requested` 信号返回 L2；`system_setup.gd` 装配 L2→L1 接线（L2 Content 注入 L1 controller）
- **Tab 城市中心小点**：`map_renderer.gd` 在 L1 地块描边后绘制城市中心圆点（`settlement.position`，屏幕固定 3px 圆点 + 细环，不随缩放，悬停/交互不变）
- **验证**：P0 7/7、L2 集成 7/7（新增「L2 单击 L1 地块→打开对应老 L1，ESC 返回」）、全量 23/24（1 项预存无关失败）、check_godot_errors 干净

### L1 Tab 运行时性能优化：描边缓存 + 静态色块层烘焙（2026-08）

- **描边/轮廓几何缓存**：原 `_draw` 每次重绘重建 4750 段城市描边并对每段遍历湖全部 91 边做距离计算（≈43 万次 GDScript/每次 hover 触发，hover 卡顿源）→ `set_data` 后首帧构建一次缓存，hover 重绘 = 1 次 `draw_multiline`；邻湖判定加湖 bbox 预筛（仅中点落湖 bbox 内的边做精确距离）
- **静态色块层 ArrayMesh 烘焙**：海洋/湖泊/邻居/城市色块（8 城 4750 点 + 邻居 1623 点 + 湖）→ `Geometry2D.triangulate_polygon` 一次性 earcut 烘焙成单张 ArrayMesh（顶点色），每帧 1 次 `draw_mesh`，免每帧多边形三角剖分
- **验证**：P0 7/7、全量 23/24（1 预存无关）、check_godot_errors 干净

### 城市层升 8192：L1 Tab 全链路原生精度（2026-08）

- **根因**：L1 Tab 链路中城市层（city_split_v2）与 L1 context 导出一直锁 2048（其余导出——L3/L2 overview/湖泊/老 L1 拼图——早已 8192），Tab 长期"2048 小图放大 3 倍"，45° 斜线锯齿、文字问题皆源于此
- **城市层 8192**：`city_split_v2.py` 加 `--res 8192` 默认——全局老 L1 蒙版 8192 原图（不降采样）、城市点 spacing 160、膨胀按老 L1 bbox 裁剪局部化（8192 级全图 watershed 内存/时间不可行）、面积下限 1440；产出 `city_labels_8192.npy`（1040 城）/ `city_preview_8192.png` 等；**同 seed 布局与 2048 版一致**（69 号区域仍 8 城，面积÷16 与 2048 级吻合 <3%）
- **Tab context 导出 8192**：`export_l1_view_context.py` 直接读 8192 城市标签（去掉"质心×4 重膨胀"中间态）；context 200 → 798×798，默认整图适配 zoom 3.06→0.77（原生 1:1），45° 像素楼梯屏幕 <1px 不可见
- **L2 城市预览**：`export_l2_city_previews.py` 改读 `city_preview_8192.png`（同级索引，不再 //4）
- **废弃清理**：`export_player_l1_cities.py` / `export_player_l1_cities_v2.py` / `l1_worldgen.py` 移入 `tools/worldgen/archive/`（防误跑覆盖 config 回退 2048）
- **验证**：p0 7/7、全量 23/24（1 项预存无关失败）、check_godot_errors 干净

### 2048 死数据整理：L2 冗余字段 + 389 废弃体系清理（2026-08）

- **L2 冗余死字段移除**：`export_l2_packs.py` 不再产出 `mask_2048.png` / `index_mask_2048.png`，`info.json` / `regions_meta.json` 去掉 `area_px_2048` / `polygon_2048` / `files.mask_2048`——全仓 grep 确认**零消费者**（L2 渲染几何来自 `tiles_8192`，2048 字段是 region 划分遗留死数据）；`color_map.json` 有消费者保留
- **389 废弃体系归档**：`city_split.py` / `l1_world_split.py` 移入 `archive/`（389 版 L1 划分 + 城市细分，被老 L1 体系取代）
- **Tab 导出纯 8192**：`export_l1_view_context.py` 移除 `--res 2048` 回退（city_data 升 8192 后 2048 分支坐标 scale=0 已损坏），强制 8192
- **config 死文件删除**：`l1_partition_2048.png` / `l1_preview_2048.png`（389 版，零消费者）
- **验证**：p0 7/7、check_godot_errors 干净

### Tab L1 出生地块更正为 region_013 3 号 + 地块特写 + 细线 + 居中（2026-08）

- **出生 L1 地块更正**：`label 66`（region 12 的 3 号，13 城）→ **`label 69`（region 13 的 3 号，8 城）**——经旧分区 `player_start=219` 质心落在 69 号块内验证；69 恰好符合 GDD"出生 L1 7-8 聚落"规格（之前用的 66 是错误地块，故 Tab 与"13号地块3号地块"长得不一样）
- **地块特写 + 贴裁**：context = 出生 L1 **贴近裁剪正方形**（地块 bbox + 四周 `--margin 15` 边距，200×200），以 **bbox 中心**居中（四周边距均匀）；默认整图适配即特写、出生 L1 居中
- **细线（屏幕比例）**：城市界/出生轮廓/hover 的屏幕像素上限压到 L2 视觉一致——城市界 `7.8→3.5px`、出生轮廓 `13→5.5px`、hover `11.7→5.0px`（L1 高缩放下此前顶到 2~3 倍粗）

- **斜线去锯齿（共享边安全简化）**：像素蒙版轮廓的 45° 楼梯（1px 一格台阶）用 Douglas-Peucker(tol=1.0) 折成直线、短边(<1px)残留清零；**共享段只 DP 一次写回所有含它的环**（同源同参数 → 相邻地块描边数据一致、重合为一条线），修复整环 DP 因各环起点不同把共享边界简化成不同折线、描边变两条"分离"线的问题；外段各自简化
- **自交兜底（修复湖附近"乱飞"）**：同一对地块的共享边界可被湖切成多段，共享缓存若按环集合做 key 会冲突（第二段拿第一段的 DP 结果 → 自交尖刺，earcut 剖分失败渲染成乱线）——缓存 key 改按**段内边的集合**（段内边在两边环里完全相同、跨环稳定命中）；产出环仍自交时回退到 pre-DP 简单环（裁边碎条等兜底）
- **圆角默认关闭**：`corner_radius` 默认 0——圆角在凹角/湖凹口附近可能切出自交多边形，且视觉收益不大
- **城市描边恢复（细）+ 地块-湖泊不描边 + 修复描边/色块不重合**：城市描边 `draw_multiline` 重画——**只跳过"地块-湖泊"边界**（边中点距湖多边形 ≤1.5 地图单位不描边），内部城界与出生 L1 块边界全画，屏显上限 `3.5→2.5px`、hover `5.0→3.5px`；**块边界改由城市外边缘描出**（与色块同源、天然贴合），不再单独画 `l1_polygon`——此前 l1（legacy 网格，膨胀 ~0.5px）与城市外缘（城市网格，收缩 ~0.5px）两条不同来源的线分离，即"描边与色块交接不重合"（`TILE_BORDER_*` 常量恢复，`BORDER_*` 移除）
- **默认缩放 = 整图适配（100%）**：`DEFAULT_ZOOM_MULT` 1.75 → 1.0；L1 相机 `max_zoom` → 5.0（fit=4.59 不被卡住，100% 正好显示贴裁方块）
- **F3 城市编号屏幕恒定字号**：`LABEL_SCREEN_SIZE=22`（÷缩放 clamp），不再"雷霆大字"
- **索引图健壮加载**：`l1_world_data.gd` 改 `tex.get_image()` 兼容 texture/image 两种导入类型
- **生成脚本**：`export_l1_view_context.py` 改 `--margin` 贴裁 + bbox 中心居中 + `jsonable()` 转 numpy 标量
- **测试**：p0 7/7、l2 6/6、l3 8/8 全绿；check_godot_errors 干净；全量回归仅剩历史遗留 test_menu_navigation（combat_feedback 为并行 flake）

### Tab L1 地图改为 L2 同款矢量渲染（彩色城市 + 灰色邻居 + 海洋）（2026-08）

- **渲染样式对齐 L2**：`map_renderer.gd` 重写为 L2MapRenderer 同款分层矢量绘制——海洋背景 → 湖泊(浅蓝) → 灰色邻居老 L1 块 → 当前 L1 城市块(政权色) → 城市描边 + 出生 L1 权威轮廓(深色) → hover 描边；配色/线宽全部复用 L2 常量
- **去掉大点大字**：移除聚落大圆点 + 名称大字（"雷霆大字/大点"来源）；F3 调试才显示小号城市编号
- **周围灰色地块**：新增邻居老 L1 块（label 65）灰色显示 + 出生 L1 周围海洋；`l1_world.json` 新增 `context_size/neighbors/lakes`，坐标整体平移到上下文
- **新生成脚本** `tools/worldgen/l1/export_l1_view_context.py`：统一网格（mesh_extract）提取城市/邻居/湖泊/出生轮廓，无缝铺满；重生成 `l1_world.json` + `l1_mask.png`（389×389，rank 直编，聚落命中逐一对齐）+ `l1_base.png`
- **测试**：p0 7/7（索引图命中/悬停换算/HUD/居中全绿）、l2 6/6、l3 8/8；check_godot_errors 干净

### L2 默认 1.75×=100% 居中 + Tab L1 结构对齐 L2（2026-08）

- **L2 默认视角 = 整图适配 × 1.75（HUD 记为 100%）**：打开即贴近城市细节（此前 175% 的缩放值成为真正的 100%），并**居中显示**（context 中心对准屏幕中心）
- **Tab L1 地图结构对齐 L2**：`strategic_map.tscn` 挂同款底部 HUD（缩放条 + 百分比，默认=100%、可拖动 + 滚轮同步）；首次打开适配到 1.75×整图适配（小图顶到相机 max_zoom=3.0，13 城邦仍全部可见）并居中，重开保留用户位置/缩放
- **默认缩放夹在相机范围**：L2/L1 控制器 `clampf(fit×1.75, min_zoom, max_zoom)`，保证 HUD 打开即 100%
- **测试**：l2 6/6（下钻默认视角 = 1.75×适配 + 居中）、p0 7/7（新增 L1 结构对齐 L2：HUD/默认 100%/居中/重开保留状态）、l3 8/8 全绿；check_godot_errors 干净

### HUD 组件化 + 双 HUD 叠加修复 + L2 恒城市模式（2026-08）

- **HUD 组件化（不再自绘抽象矩形）**：`l3_zoom_indicator.gd`(MapHUD) 重写为 StickTheme/StickKit 主题组件——细分按钮 = 主题 **Button**、缩放条 = 主题 **HSlider** + 百分比 **Label**，外观与其他 UI 一致
- **缩放百分比归一化**：默认缩放 = 100%（L3 初始 0.36 = 100%，L2 fit 整图 = 100%）；HUD 显示 `zoom/默认 ×100%`，滑块可拖动 + 滚轮双向同步，带 100% 刻度
- **修双 HUD 叠加根因**：L3 下钻 L2 时 L3 的 ZoomIndicator 未隐藏（此前 L3/L2 两个 HUD 同时显示叠在底部 → 左下角元素重叠）；现下钻隐藏 L3 HUD、返回恢复
- **L2 恒城市模式**：L2 本身即"具体到城市"，默认恒 MODE_CITY（贴 l2_city_preview），移除 L2 细分开关（toggle_display_mode/N 键）——MapHUD 对 L2 不显示细分按钮
- **布局**：左下角单行 `[细分按钮(L3)] [缩放条] [百分比]` 互不重叠；根节点 PASS 鼠标，仅控件收事件不挡地图拖拽/下钻
- **测试**：l2 6/6、l3 8/8（新增默认 100% + 三元素互不重叠 + HUD 显隐断言）、p0 6/6 全绿

### 描边微调(原×1.3) + 细分开关双入口 + HUD 布局不重叠（2026-08）

- **描边=原值×1.3**（翻倍太粗）L3 hover 6.5/cap10.4、L2 边界 11.7/cap20.8；L2 tile 5.2/cap7.8、hover 7.2/cap11.7、邻居 8.45/cap13
- **细分开关（"模式"= 开关 L3/L2 细分显示城市预览效果）**：左下角按钮显示「细分:关/开」+ **N 键**开关双入口；开启后 L3 显示全图城市（贴 city_preview）、L2 显示该地区城市（贴 l2_city_preview）——即"具体到城市的预览图"效果
- **HUD 布局**：按钮左下角(12,6,130x26)、轨道居中、缩放文字放轨道上方，三者分离不重叠；移除轨道右端 MAX 文字
- **测试**：l2 6/6、l3 7/7、p0 6/6 全绿

### 描边翻倍 + HUD 按钮左下角 + HUD 默认隐藏（2026-08）

### 描边翻倍 + HUD 按钮左下角 + HUD 默认隐藏（2026-08）

- **描边×2**：L3 hover 5→10 (cap 8→16)、L2 地区边界 9→18 (cap 16→32)；L2 tile 4→8 (cap 6→12)、hover 6→12 (cap 9→18)、邻居 6.5→13 (cap 10→20)——仍是"地图绝对粗细，放大超屏幕上限 clamp"
- **HUD 按钮移到左下角**：模式切换按钮 `_btn_rect` 从右下角改到左下角（x=14）
- **HUD 默认隐藏**：L3/L2 的 ZoomIndicator 节点 `visible=false`（此前游戏一启动就叠在左下角）；由各控制器 open 显示 / close 隐藏
- **测试**：l2 6/6、l3 7/7、p0 6/6 全绿；check_godot_errors 干净

### 描边绝对粗细 + HUD 修复 + L2 城市模式（2026-08）

### 描边绝对粗细 + HUD 修复 + L2 城市模式（2026-08）

- **描边=地图绝对粗细**：L3/L2 全部描边由"屏幕保底 max"改为"**地图单位固定宽，放大超屏幕像素上限时 clamp**"（`minf(map_w, cap_screen/zoom)`）——不随缩放变粗，仅极端放大有屏粒上限（L3 hover 5→cap 8px、L2 边界 9→cap 16px；L2 tile 4→cap 6px、hover 6→cap 9px、邻居 6.5→cap 10px）
- **修 HUD 文字半截/出屏**：`l3_zoom_indicator.gd` 泛化为 `MapHUD`（查 Content 下带 toggle_display_mode 的渲染器，L3/L2 通用）；文字/按钮全部放控件 44px 内（轨道 y=24、数值 y=16 上方），不再溢出到屏幕外
- **L2 城市模式**：新增 `l1/export_l2_city_previews.py` 生成 13 地区城市蒙版贴图（`l2_packs/region_XXX/l2_city_preview.png`，context 尺寸 RGBA，tiles 区域城市色/其余透明）；`L2MapRenderer` 加显示模式（L1 <-> 城市）+ `MapHUD` 模式按钮；L2 场景挂 HUD（open 显示/ESC 隐藏），L3 返回时恢复
- **测试**：l2 6/6（新增城市贴图/模式切换）、l3 7/7、p0 6/6 全绿；`check_godot_errors` 干净

### 修复 L3 老 L1 视觉层坐标序错位（描边/地块/hover 错位）（2026-08）

### 修复 L3 老 L1 视觉层坐标序错位（描边/地块/hover 错位）（2026-08）

- **根因**：`export_l3_l1_view.py` 生成 `l3_l1.json` 时把 mesh 角点从 `(y,x)` 转成了 `(x,y)`，而渲染端统一按 `(y,x)` 读取（`Vector2(p[1],p[0])`）→ 老 L1 地块沿 y=x 镜像错位，hover 高亮随之错位；L2 地区边界是老数据 `(y,x)` 反而没错——于是"描边与地块错位"
- **修复**：`build_layer` 不再翻转坐标，`l3_l1.json` 与其他 L3 数据统一存 `(y,x)` 角点（渲染 Vector2(p[1],p[0])）；坐标顺序约定在工具注释写明以防再犯
- **校验**：JSON 多边形质心 vs 蒙版质心×4 偏差已从镜像级(~2000px)降到采样噪声(<50px)
- **测试**：l3 新增 hover 命中老 L1 断言 → 7/7；p0 6/6、l2 5/5 全绿

### L3 配色鲜艳 + 双显示模式（L1/城市）+ 缩放条模式按钮（2026-08）

### L3 配色鲜艳 + 双显示模式（L1/城市）+ 缩放条模式按钮（2026-08）

- **配色鲜艳化**：`export_l3_l1_view.py` 老 L1 视觉层改为高饱和（s=0.85）+ 亮明度（0.5~0.98），平均饱和 0.85 / 明度 0.74——"鲜艳、亮色比例高"
- **L3 双显示模式**：底部新增**模式按钮**（`l3_zoom_indicator.gd`），点击在「模式:L1（69 块矢量）↔ 模式:城市」间切换；城市模式直接贴 `l3_city_preview_2048.png` 栅格（即用户认为最好看的 city_preview，零剖分快速）；**hover 恒命中老 L1**（新 `l3_l1_index_2048.png` 索引图），点击下钻仍按 L2
- **M 默认缩放 0.36**：L3 首次打开即看更大范围（`l3_map_controller.open`）
- **修复**：test_l3 类型推断解析错误（挂死）
- **测试**：l3 6/6（断言 20，含城市贴图/模式切换）、p0 6/6、l2 5/5 全绿

### L3 视觉显示老 L1 + 缩放指示条 + Tab 放大（2026-08）

### L3 视觉显示老 L1 + 缩放指示条 + Tab 放大（2026-08）

- **L3 视觉 = 老 L1 地块**（"L3 直接把 L1 显示出来"，同 L2 地区相似色、丰富配色，类 city_preview）：新 `l1/export_l3_l1_view.py` 生成 `config/strategic_map/l3_l1.json`（69 块老 L1，8192 级多边形/洞/配色）；`l3_map_renderer` 渲染老 L1 色块为底 + **L2 地区粗描边**标识可下钻单元；**交互不变**——hover/点击仍按 L2 索引图下钻
- **修 L3 编号坐标**：地区 centroid 是 2048 级，渲染 8192 级 → 原来文字堆左上角且不随缩放；现在 ×4 换算（`_draw_l2_labels` 按 size/mask 比例）
- **L3 缩放指示条**：新 `l3_zoom_indicator.gd`（CanvasLayer 底部轨道+滑块+数值"缩放 x.xx"），M 打开显示、ESC 关闭隐藏、L2 下钻时隐藏
- **Tab 放大**：`strategic_map_controller.open` 由硬编码 1024 改为按实际 `data.size` 适配（85% 屏高），出生 L1 图更清晰；`export_player_l1_cities_v2` 默认 margin 60→120（size 347→467）
- **测试**：l3 5/5（断言 15，含老 L1 视觉层 69 块）、p0 6/6、l2 5/5 全绿

### 出生 L1 定案（region_012 老L1#3）+ L3 显示 L2 编号（2026-08）

### 出生 L1 定案（region_012 老 L1#3）+ L3 显示 L2 编号（2026-08）

- **出生 L1 定案**：region_012 的 3 号老 L1 地块（全局老 L1 label 66，质心 (928,932)/2048，面积 21752px）为玩家初始默认地块——`export_player_l1_cities_v2.py` 基于 v2 城市层重建 Tab 数据源（`l1_world.json`/`l1_base.png`/`l1_mask.png`）；13 城市 / 13 城邦 / 12 MST 道路，城市点 100% 命中 mask；出生 L1 权威轮廓 `l1_polygon` 731 点
- **L3 显示 L2 编号**：L3 大世界视图 F3 调试模式下在 13 个 L2 地区质心标 `L2#编号`（`l3_map_renderer._draw_l2_labels`）——配合 L2 下钻的 `L1#编号`，从头到尾可认层
- **废弃清理**：旧 `export_player_l1_cities.py`（389 版）不再使用（标记废弃）
- **测试**：l3 5/5（新增 F3 L2 编号）、p0 6/6（13 城市断言 49 次）、l2 5/5 全绿

### 层级纠偏：老 L1 之下细分城市 v2 + 废弃 389 蒙版（2026-08）

### 层级纠偏：老 L1 之下细分城市 v2 + 废弃 389 蒙版（2026-08）

- **用户纠偏**：真实分层 = L3(老 13 地区) → L2 下老 L1 划分(保持老，69 块) → 城市(在老 L1 之下细分)。"本来想细分 L1，误说成细分 L2"——按细分 L2 误解生成的 389 L1 蒙版 + 基于它的城市层**整体废弃**；L3 V 键 389 蒙版叠加已移除（`l1_overlay.gd`/`test_l1_overlay` 删除）
- **新增 `l1/city_split_v2.py`**：13 地区老 L1 tiles 拼全局蒙版（69 块，EDT 补 0.01% 陆地缺口）→ 城市点（jittered grid spacing 40）→ 按老 L1 分组多源膨胀 → 面积下限。**1038 城 / 69 老 L1**（平均每 L1 15 城），产物 `output/l1_v2/`
- **L2 F3 标号**：L2 下钻视图在 F3 调试下给每个老 L1 地块标 `L1#编号`（调试指认不再靠颜色）
- **校验**：0 跨老 L1、0 多连通、城市点 100% 在自身城市、每老 L1 ≥1 城、面积和=陆地、同老 L1 色相差 0.0046
- **测试**：`test_l2_strategic_map` 5/5（含 F3 标号）、p0 6/6、l3 4/4 回归全绿
- **待办**：出生 L1（Tab 城市视图）基于废弃 389 临时占位，待确认"region 13 最右老 L1"后重建；L3 蒙版叠加待接老 L1 蒙版后恢复

### 地块标号 + L1 边界强调（2026-08，调试指认用）

### 地块标号 + L1 边界强调（2026-08，调试指认用）

- **地块标号（G 键切换）**：L3 视图 V 键开启 L1 蒙版叠加后按 **G** 在每个 L1 细胞城市点旁显示地块编号（`l1_overlay.gd`，黑描边白字）；Tab 出生 L1 城市视图按 **G** 显示城市编号 `L1城#XXXX`（`map_renderer.gd`，解析 `tile_id`）。解决"颜色认错地块"——从此按编号指认
- **L1 边界权威轮廓**：`export_player_l1_cities.py` 输出出生 L1 的权威轮廓（`l1_world.json` 新增 `l1_polygon`，从 L1 蒙版同源提取，194 点）；Tab 视图 G 开启时 L1 边界用粗线标出，**贴 L1 边缘的城市对外边界即套用 L1 边界**（数据已保证：城市并集 == L1 mask、贴边城市 46/104 顶点落在 L1 边界上）
- **预览改进**：`player_start_l1_cities_preview.png` 分为"城市间细线 + L1 外边界粗线"两级，城市贴 L1 边界一目了然
- **校验**：L1 叠加测试 3/3、P0 测试 7/7（新增标号切换与 l1_polygon 断言）、战略图 4 套件回归全绿

### 修正出生 L1 定位：region 13（#28bd72）最东地块（2026-08）

- **出生 L1 修正**：定位标准改为「游戏内 L3 地图中 `#28bd72` 色（L2 地区 13 区色，`l3_world.json` 精确命中）内最东侧的 L1 地块 = **label 219**」。此前按全图预览颜色近邻误选 region 3 的 label 69（`#a2ee36` 实为 L2 地区 3 的地区色，非 L1 色）——已用 `--player-start-label 219` 重跑整条链
- **数据**：出生 L1=219（area 2733px）内 4 城市（面积和=2733）/ 4 城邦 / 3 条 MST 道路；`l1_world.json` + `l1_base.png` + `l1_mask.png`（Tab 数据源）与 `player_start_l1_cities_preview.png` 预览全部更新为 label 219
- **校验**：城市点在自身 mask 内全部命中；P0 测试 6/6 + 战略图 4 套件回归全绿；`check_godot_errors` 干净

### 玩家初始 L1 地块 + Tab 城市划分视图（2026-08）

- **出生 L1 定案**：L1 label 69（region 3，即预览图中 `#28bd72`（region 13 地块）下方的 `#a2ee36` 色块）标记为玩家初始默认地块——`l1_world_split.py` 新增 `--player-start-label`，`l1_data.json` 写入 `player_start: true`
- **Tab 战略图 = 出生 L1 的城市划分**：新增 `l1/export_player_l1_cities.py`，把出生 L1 的 4 个城市导出为 L1WorldData 兼容格式（`l1_world.json` + `l1_base.png` + `l1_mask.png` 覆盖 Tab 数据源）——每城市 = 1 地块 1 聚落（城市点/级别按面积分档/独立城邦政权/MST 道路/出生城市 = 最大城市）；城市暂无 map_id → 双击不可进入（空 map_id 保护，可玩地图接入后自动恢复）
- **城市层加密**：`city_split.py` 默认间距 36 → 22（3203 个城市，平均每 L1 ~8 个；出生 L1 内 4 个城市）；城市轮廓抽稀 tol 0.8 → 0.3
- **预览**：`config/strategic_map/player_start_l1_cities_preview.png`（出生 L1 城市划分放大图，含城市点）
- **测试**：`test_strategic_map_p0` 更新为城市层语义 6/6 绿（数据加载/城市点查询/悬停换算/无 map_id 不可进入/暂停恢复）；战略图 4 套件回归全绿

### 城市细分层 + 回滚 L2 视图改动（2026-08）

- **新增 `l1/city_split.py`**：L1 地块之下细分"城市"——城市点（jittered grid，`--spacing 36`，每 L1 至少 1 点）→ 按 L1 分组多源膨胀（城市不跨 L1/海/湾，一个 L1 的两个半岛不共城市）→ 面积下限合并（`--min-city-area 90`）。1236 个城市 / 389 L1，同 L1 相似色（父 L1 色相 + 明度阶梯）。产物 `output/l1/city_*`（labels/预览/索引图/城市点图/JSON）
- **回滚 L2 视图改动**：撤销"L2 下钻显示 L1 细分"（L2 视图恢复原始划分，`l2_l1_overlay.gd`/`export_l1_l2_split.py`/`test_l2_l1_overlay` 移除）——方向修正：L2 视图保持原样，细分目标改为 **L1 之下再分城市**
- **校验**：城市 0 跨 L1、0 多连通、0 跨海；城市点 100% 在自身城市内；每 L1 ≥1 城市；面积和 == 陆地；同 L1 内城市最大色相差 0.003（量化噪声级）；L2 视图测试 4/4 绿

### 全大陆 L1 蒙版划分 v2：细胞质膨胀（2026-08，L3 层直裁为 L1）

- **算法升级**（`l1/l1_world_split.py`）：由欧氏 Voronoi 改为**岛×L2 分组多源同步膨胀**（flat watershed）——细胞在陆地内生长被海阻挡：**单个 L1 细胞不跨海、不跨湾，同一大陆的两个半岛不共用地块**；岛屿 = 独立计算单元（"孤立的岛屿单独算"，岛内像素只归岛内城市点竞争）；城市点贴近陆地边缘时向陆内均匀膨胀到与其他细胞相近大小；新增 `--min-tile-area` 面积下限合并（无同组相邻细胞可并的极小岛豁免标注 `small_exempt`）。389 个 L1 / 13 地区 / 83 岛全部覆盖。
- **校验**：陆地零未分配像素；0 跨海细胞、0 多连通组件细胞、0 跨 L2 污染；城市点 100% 在自身胞内；每岛 ≥1 城市点；低于下限非豁免 0；面积和 == 陆地面积；邻接对称（`test_l1_overlay` 2/2 + 战略图 4 套件回归绿）
- **消费端不变**：L3 战略图 V 键叠加仍走 `l1_overlay.gd`（ArrayMesh 静态烘焙），数据格式向后兼容

### 全大陆 L1 蒙版划分（2026-08，L3 层直裁为 L1）

- **生成端**：新增 `tools/worldgen/l1/l1_world_split.py`——在 L3 层把整块大陆划分为 423 个 L1 地块：城市点 = 均匀网格平铺 + 细微扰动（jittered grid，每岛至少 1 点）；受限 Voronoi 直线细胞边界（跨 L2 处采用 L2 地区边界，0 地块跨区污染）；同 L2 地区相似色蒙版（区内明度阶梯）。产物 `output/l1/`（labels npy / 相似色预览 / label 直编索引图 / 元数据 JSON）并拷贝至 `config/strategic_map/`
- **消费端**：L3 战略图（M 键）新增 **V 键**切换 L1 蒙版叠加层（`modules/world_map/scripts/l1_overlay.gd`，加载时把全部地块三角剖分/线段烘焙为静态 ArrayMesh，每帧仅 2 次 draw_mesh 零 CPU 剖分）；新增集成测试 `test_l1_overlay`（2/2 绿），战略图相关 4 套件回归全绿
- **文档**：08-程序化世界生成.md 增补 §二十一 L3-L；世界地图数据流.md / 编辑器工具索引 / worldgen README / 待办事项同步

### 架构审计修复（2026-08）：依赖环 + 生命周期清理 + 工具链

- **P0 依赖环**：units→construction 内部类强引用（BehaviorWork/BehaviorHaul 的 ConstructionProject 类型）改为鸭子类型；construction→units 的 Hitbox.CollisionLayer 改为本地常量；combat→units 的 WeaponMount.Mood 改为本地同值枚举；texture_gen 的 white_tex.png 迁入本模块 assets 并修正全部 debug 场景/脚本路径，删除引用 building_gen 归档场景的 smithy_thatch_preview
- **P1 功能缺陷**：GlobalHUD 速度/时间标签节点路径修正；AIController 职责门控修复（仅 WORK_HAUL 的工人队现在可搬运）；insert_tier 修正层级不变量（above 无空层拒绝 / below 挂目标之下）并重写单测；disband_organization 从容器与 WorldState 移除；BattleInstance 结束后清引用并 queue_free、BattleDirector 裁剪失效实例、GlobalHUD 接线 battle_started/ended；SaveManager 存档加事务、读档加 30s 兜底关 DB、save_meta 保留 created_at；建造资源扣减加回滚且扣减移到选址校验之后；possess 实体销毁时补发 possession_ended；FormationSystem 死亡清理同步组织模块并清 role
- **工具链**：run_all.sh 修复 Windows Git Bash（TMP 路径 cygpath 归一化、Godot 用 Windows 路径、xargs 并行池改为原生 chunked 并发、复用 SUITE_TIMEOUT 表）
- **测试**：unit 9/9、integration+smoke 22/22 通过

### 全项目审计修复（2026-08）：架构收敛 + 信号清理 + 文档校准

- **EventBus 清理**：67 个声明信号中 35 个零引用信号删除（未实现系统的预留信号 + 与 construction/api.gd 重复且签名冲突的 building_* 5 个）；`strategic_map_*` 动态 `emit_signal` 收口为类型安全 `.emit()` 并消除本地+EventBus 双重发射；信号唯一真相源与文档（系统交互与EventBus.md / EventBus信号契约.md）逐条对齐
- **UI 根红线修复**：SavePanel / SettingsMenuPanel 从 `Control.new()`（挂 CanvasLayer 根）改为 `UIKit.full_rect()` + ModalOverlay 槽
- **双向耦合消除**：SavePanel 删除 group 反查 game_root，改 `setup_load_callback` 注入（world→ui_global 单向）；stickman_entity 的 InputDispatcher 查找改走 PlayerControlAPI 静态注册表（units→player_control api）
- **契约闭合**：texture_gen/api.gd 补 `class_name TextureGenApi`，building_exterior 改走契约；world_map 战略图开/关信号收敛为 EventBus 单通道
- **死代码清理**：technology 空壳模块整体删除（阶段 1 按「征服获得」策略重建，待办已登记）；building_snap.gd（零挂载）归档至 building_gen/archive/
- **文档校准**：AGENTS.md 路径修正（docs/项目、UI.md、check_godot_errors.ps1 前缀等）；modules/README §9/§10 同步现行信号与 8 个 autoload（标注 BalanceConfig/AudioManager/WorldState/ConfigManager 为预留）；模块API契约.md 的 world_map「死模块」登记更新为已实装契约；待办事项 0.9c/d/e 勾选
- **测试**：test_battle_ui 断言同步 HudOverlay 槽位化（Minimap 已于 c6d8e10 迁移）；全量 31 套件通过

### L2 描边 / 补丁感修复（2026-08，同源重烘焙）

- **填充与描边同源**：根因是填充三角剖分（DP 简化）与描边（独立 Chaikin 平滑）使用**两套不同多边形** → 渲染时色块边缘与描边偏差最大 20px，呈"补丁感"。改为填充与描边**共用同一份金标准多边形**（`mesh_extract.simplify_mesh` 产物），描边零额外形状处理。Hausdorff 距离 = 0.0px，严丝合缝。
- **毛边/像素台阶消除 + 顶点压缩**（`mesh_extract.py`）：新增 `_dp_simplify` + `_near_collinear_merge`（DP tol=0.2，亚像素精度降顶点，面积偏差 0.0012%），`simplify_mesh` 处理顺序改为「simplify_collinear → Chaikin×3 → DP 压缩」，解决 Chaikin 后曲线上 90% 冗余分点导致的 earclip O(n²) 卡顿。顶点数 107K→30K（3.5×），region_008 大湖剖分从卡死降至 ~68s。
- **描边同源修复**（`l2_bake.py`）：`_triangulate_ring` 移除 DP 简化；`_ring_to_border_segs` 取消 `_angle_merge_light`（其 max_dev=0.3 > DP tol=0.2，会误删关键点导致描边跨过凸起）。
- **数据重烘焙**：全量 13 地区 `l2_geom.bin`/`l2_world.json` 重生成（Chaikin×3 平滑 + DP 压缩 + 同源描边）。

### L2 渲染性能与描边优化（2026-08）

- **运行时零几何计算（烘焙）**：三角剖分（earcut）与描边过滤/共线合并全部从运行时提前到素材阶段。新增 `tools/worldgen/l2_export/earclip.py`（纯 Python 单环耳切，大环先 Douglas-Peucker 简化消除 O(n²) 性能瓶颈，10659 顶点湖 0.23s）+ `l2_bake.py`（输出 `l2_geom.bin` 二进制：4 个 mesh 段=地块/洞/湖泊/邻居 + 2 个描边段）。修复打开 L2 卡顿数秒（原 `_build_static_mesh` 对 27.5 万顶点逐个 `Geometry2D.triangulate_polygon` 运行时剖分）
- **渲染器改读烘焙 mesh**（`l2_map_renderer.gd`）：`_build_static_mesh` 直接读 `_data.baked_meshes` 组装 ArrayMesh，删除 `_add_polygon_mesh`/`Geometry2D.triangulate_polygon`/湖泊边界点网格等运行时计算；描边段直接读烘焙数据
- **描边毛刷消除**：描边段烘焙时 DP 简化 + 共线合并（`_merge_collinear_segments`），短碎线段数量大幅下降（region_008 描边段 10711/18316），`_draw` 逐段 `draw_line` 数量锐减，抗锯齿叠加毛刺消失
- **数据体积**：region_008 `.bin` 仅 1.26 MB（原 `l2_world.json` 7.3 MB），加载更快
- **验证**：13 地区 `.bin` 全部解析成功、无空 mesh；退化三角形（面积<0.01 亚像素）不影响填充/描边/塌陷

### 世界地图战略图：L3→L2 下钻 + 真 8K 素材管线（2026-08）

- **L3→L2 下钻**：M 键 L3 战略图单击地区进入该 L2 详细视图（L1 地块分块 + hover 描边），ESC 返回 L3（CanvasLayer 102，`l2_world_data`/`l2_map_renderer`/`l2_map_controller`/`strategic_map_l2.tscn`）
- **M 键关闭/重开保留状态**：相机位置/缩放 + 当前所在 L2 视图（首次才设初始视角；L2 同地区重开不重置）
- **纯矢量渲染（ArrayMesh 静态几何缓存）**：地块/地区几何加载时一次性三角剖分合并为单个 mesh，每帧 1 次 `draw_mesh`（零 CPU 剖分，修复逐帧 draw_colored_polygon 卡顿）；洞预剖分；hover 描边 `draw_polyline` 抗锯齿
- **真 8K 素材管线**：地区划分保持 2048 定稿（人工调整不变），海岸线按 8K 大陆蒙版（`locked_continent_8192.png`）裁切 → 全部素材 8192 级；共享顶点网格提取（`mesh_extract.py`，P 社省份网格架构：相邻地块共享角点无缝）+ 自接触分割 + 共线简化 + Chaikin 边界平滑
- **交互优化**：相机等比缩放（×1.1/×0.9）、min_zoom 0.02、L3 首次 1:1 像素完美居中、hover 坐标换算（渲染 8192 ↔ 索引图 2048）
- **清理**：废弃位图渲染资源（l3_base/l3_border 等）与死工具归档 `archive/`（标记/切分工具）、删除历史中间产物
- **测试**：新增 `test_l2_strategic_map`（加载/索引命中/下钻-返回/状态保留，23 断言）；L3/L2/L1 战略图测试全绿；全量 31 套件通过
- **L2 直角角塌陷修复**（`mesh_extract.py` `chaikin_smooth`）：原 Chaikin 平滑删除**所有**顶点（含真实长边直角角），把直角角切成 45° 斜边，放大后表现为"直角角落塌陷成三角形"（疑似 3D 删顶点）。改为：相邻两条边都 >=3px 视为真实角并**保留原顶点不切角**；1~2px 像素台阶仍做 Chaikin 平滑。判定只依赖共享边长/角 → 相邻地块结论一致，无缝保持。修复后：全部 13 地区 earcut 剖分 0 失败、0 塌陷，L2 集成测试 4 用例通过。
- **L2 湖泊/描边修复**（`l2_map_renderer.gd`）：原地块描边与相邻地区分界线沿湖泊边界绘制，把湖泊描成"小孔"并产生"湖泊与地块接壤处描边"。改为**预计算**描边分段（构建湖泊边界点网格 + 容差判定），滤除湖泊接壤段与画框边缘段后再逐段绘制：
  - 湖泊不再被描边收缩（渲染面积 ~98% 期望，接近无描边基准）
  - 湖泊与地块/相邻地区接壤处描边消除（湖邻深色像素 644→305，接近纯抗锯齿基准 240）
  - 内部省份（地块-地块）边界仍保留；画框边缘"贴边分界线"消除（每边边界色像素 ≤18~48）
  - 湖泊边界点网格 + 预计算分段在 `_build_static_mesh` 一次性完成，`_draw` 仅绘制，无每帧剖分开销

### 独立审计收敛（2026-08，三轮）

- **P0 修复**：`set_resources_api` 注入点补齐（此前缺失导致建造资源检查/扣减/清场回收永久静默失效，has_method 守卫吞错）；EventBus 与模块 api 重复声明去重（resource_not_enough/tech_started/org_* 移除）；run_all.ps1 补 4 个遗漏集成套件（battle_ui/formation_system/placement_grid_units/tactical_orders）
- **架构收敛**：AI 侧改走 ConstructionApi（game_root 注入 api 实例，register_worker/unregister_worker 补齐转发）；interaction_controller 私有字段直读清零（get_map/is_possessed/set_player_build_timer）；实体销毁反注册派工池防悬垂；UnitsAPI.STICKMAN_ENTITY_SCENE 常量落实
- **组织模块**：insert_tier("above") 层级校验修复（原恒失败）；SaveManager 存档接入（register_module + 序列化含 next_id 防冲突）
- **僵尸清理**：SceneManager autoload 删除（全库零引用）；debug_GUI set_visible 遮蔽内建改名 set_overlay_visible；resource_node 依赖反转（EventBus.debug_visibility_changed 替代 DebugApi 直连）；road_a_b.tscn 出口目标 id 修复
- **测试配置防污染**：ConfigManager.set_auto_save(false)，测试进程不再写入 user://settings.cfg
- **单元覆盖补齐**：organization_manager（14 用例）、entity_states（7 用例）、resources_api（6 用例）；补测过程发现并修复 2 个真实 bug——`get_child_orgs` 返回类型崩溃（无类型 Array 赋给 Array[String]）、WorldState `from_dict` 系列 typed Array 赋值崩溃（存档恢复路径从未被调用过）
- **测试**：全量 28 套件通过（unit 9 + integration 17 + smoke 2）

### 设置菜单（齿轮/ESC 开关）替代临时主页菜单 + 健全地图系统

- **设置菜单**（SettingsMenuPanel，Minecraft 式居中布局）：左上角齿轮按钮 + ESC 键开关；常规区含时间速度控制（暂停/1x/2x/4x）；**调试区**（OS.is_debug_build）显示测试地图选择（村落/战场/道路/森林/村落B）——替代原主页菜单的测试场景入口；POSSESS 模式下 ESC 保留给退出附身
- **临时主页菜单已撤回删除**（MainMenuPanel 移除）
- **地图系统健全**（对照 GDD §6.7）：
  - 出口链式衔接：村 A ↔ 战场 ↔ 森林 双向步行出口（战场不再"回不去"）
  - 大世界地图面板动态化：打开时按当前地图生成目的地（步行出口 + 快速旅行其余地图），替代固定按钮列表
  - SceneLoader 新增 get_registered_map_ids / get_map_type 查询
- **战场默认步兵**：allies 不足 3 人时补 spawn 蓝方基础步兵（无队伍进战场也能打）
- **测试**：test_menu_navigation 改测设置菜单（装配/toggle/调试按钮）+ 动态导航 + 默认步兵；全量 21 套件通过

### 玩家战斗模式（Q 键）+ 小队跟随 + 攻击展开

- **Q 键切换建造/战斗模式**：玩家附身时按 Q 在 EXPLORE<->BATTLE 间切换；BATTLE 模式保持附身（ExploreHandler 不释放），左键=挥砍攻击（鼠标悬停 UI 时优先 UI，修复编制按钮被拦截的 bug）
- **小队跟随玩家**：编制窗口新增"跟随玩家"勾选（FormationSystem.set_squad_follow）；开启后成员进入新 BehaviorFollow 行为尾随玩家（70px 停步），战斗优先于跟随，跨图自动携带
- **攻击展开（防一字长蛇）**：BehaviorAttack 保角环绕——单位停在射程边缘并保持自身相对目标的方位，同线部队自然散布在目标周围弧线；配合已有分离彻底解决纵队推进
- **InputDispatcher 信号兼容**：`_notify_deactivated` 带 new_mode（供 ExploreHandler 判断保持附身），所有 handler 签名统一
- **dev 调试场景**（tests/dev/dev_playtest）：`--map battlefield --party 3 --enemies 4 --follow` 一键直达遭遇战（GameRoot 零改动，dev_enemy_count 字段默认 4）
- **测试矩阵**（tests/matrix.md）+ tests/README 更新（三层自动化 + dev 层）
- **清理**：移除仓库根 core/、modules/ 迁移残留（早期结构，无引用，正式版在 stick-world/ 内）
- **测试**：新增 test_combat_control（Q 切换/跟随行为/尾随移动/保角展开）；全量 20 套件通过

### 头顶血条 + 群体分离（战斗反馈与移动质量）

- **头顶血条**（HealthBarIndicator）：受击后显示 HP 比例（绿→黄→红三档），满血/死亡隐藏；自绘无资源依赖，仿 ActionProgressIndicator
- **群体分离**（防叠人/1字长蛇）：AI 移动方向叠加分离推力（半径 42px 内越近推力越大），参考 Stick War Legacy clone 的 soft-body separation 方案；玩家附身不受影响
- **测试**：新增 test_combat_feedback（5 用例：血条装配/显隐/死亡隐藏/分离推开/远处无影响）；test_melee_combat 固定命中率消除随机性

### 近战剑击：临时配剑 + 程序化挥砍 + 物理受击反馈

- **临时配剑**：所有火柴人自动挂载占位剑（WeaponMount 挂到 IK 手部 marker innerhand，GripPoint 握把对齐）；攻击距离 140→80（剑长）、伤害 12→15（对齐 stickmen.tres 平原步兵 base_attack）
- **程序化挥砍**：无 K 帧方案——Tween 驱动武器旋转（前摇 -100° → 挥出 +30° → 收招），attack.tres 空动画后续由用户 K 帧
- **物理受击反馈**：命中时目标获得击退冲量（`apply_hit_reaction`，随帧衰减）+ 身体受击红闪 + HitStop 顿帧（Engine.time_scale 冻结 0.06s，headless 自动禁用）
- **情绪系统保留**：Mood 枚举/命中率冷却修正（battle_ai_director 继续驱动）
- **测试**：新增 tests/integration/test_melee_combat（5 用例 16 断言：配剑/命中扣血击退/距离拒绝/挥砍旋转/冷却）；全量 18 套件通过
- **文档**：模块依赖关系.md 图改 Mermaid + 新增 §六 背包与装备系统预留设计

### 带队出征：跨图携带编队（原型循环"战斗"环节解锁）

- **编队跨图携带**：travel 时快照编队（`FormationSystem.export_squads`）→ 新图 spawn 玩家后跟随者随行（玩家右侧依次排开）→ `restore_squads` 重建（preset/职责/排长/角色）
- **战斗闭环打通**：村庄编好战斗班 → 带队跨图进遭遇战战场 → 队伍（玩家+随行）vs 4 敌交战，全灭收敛
- **修 bug**：`battlefield.tscn` 的 PlacementGrid 缺 `parent="."` 导致场景无法实例化；`FormationSystem._process` 对 freed 实例报错（跨图销毁残留）——快照后 `disband_all_squads` 清理 + 防御式遍历
- **修 bug**：`GameRoot.get_current_map()` 在旧图 queue_free 延迟销毁窗口返回旧图（跟随者 spawn 到旧图、战斗挂到旧图 BattleAnchor 随图销毁）——优先用 `SceneLoader.current_map`
- **测试**：新增 tests/integration/test_squad_travel（4 用例 19 断言：编队/跨图携带/重建/遭遇战双方人数）；全量 17 套件通过

### 队伍类型编制系统（P0 验收阻塞解除）

- **编制预设**：`config/formations/formation_presets.tres`（BalanceResource）定义三模板——战斗班（MILITARY/战斗）、建造队（ENGINEERING/建造+搬运）、工人队（LABOR/搬运+采集）
- **FormationSystem 预设化**：`create_squad(units, name, preset_id)` 按预设创建（组织标签 + 成员角色映射，旧签名默认战斗班向后兼容）；新 API：`get_all_presets`/`get_preset`/`get_squad_preset`/`get_squad_work_types`/`set_squad_work_types`（职责可调整）/`is_work_allowed`/`is_combat_squad`
- **行为职责过滤**：AIController 决策按队伍职责过滤——建造队不参战、战斗班不接建造派工；未编队单位保持全能（现有循环/测试不破）；TacticalOrders 拒绝非战斗职责小队的号令
- **组织系统**：VALID_TAGS 追加 `LABOR`（第六标签，劳动班组）
- **编制管理窗口**（FormationPanel，挂 UIRoot.ModalOverlay）：编队列表/创建（预设+勾选空闲火柴人）/职责勾选调整/成员管理（任命排长/移出）/解散；GlobalHUD 顶栏"编制"按钮 + BattlePanel"打开编制窗口"入口，Village/BATTLE 模式均可用
- **测试**：新增 tests/integration/test_formation_presets（6 用例 38 断言，预设加载/标签映射/职责过滤/调整/号令拒绝/角色读写）；全量 16 套件通过

### 脱离卡死：随机传送 + HUD 按钮

- **脱困功能**：H 键 / HUD"脱困(H)"按钮——随机传送到附近空旷地带（半径 200px 起采样，逐级扩大至 1600px，兜底地图中心；只动 X）。按钮直接作用于当前玩家实体（`game_root.get_player_entity()`），不依赖附身系统
- **放置校验**：`start_construction_at`/`spawn_operational_building` 选址范围内有实体且其脚部位于建筑体高范围内时拒绝放置，玩家不会被罩进建筑，也不会因站在建筑脚下而误拦
- **工人站位**：`behavior_work.STANDOFF_X` 40→44（脚部半宽 41.5），工人贴近建筑边缘敲击
- **测试**：construction_cycle 覆盖放置校验与脱困；全量通过

### 行走与建造修复

- **敲击建造移动锁定**：按 E 敲击后 1.8s 内禁止移动
- **读档恢复完善**：工地障碍重建、工人派工池恢复、材料进度真实保存/恢复
- **存档策略**：自动存档已删除（启动定时自动存档/退出存档），启动默认新游戏；手动存档/读档框架保留（SaveManager / SavePanel / quick_save / quick_load），`--fresh-start` 保证 headless 测试互不影响
- **验证**：新游戏玩家出生在原点；`map_left=-4096` 为设计值（仓库 cell 15 + WALKABLE_MARGIN=128 格 → -128 cell）

### 测试体系重构：数字标号全清除 + 分层迁移

- ✅ **T0-7 stage 全部迁移完成**：`test_stage_01~08` 数字标号体系彻底清除，映射到分层命名——01→integration/test_game_root_assembly、02→integration/test_village_map、03→integration/test_ai_behaviors、05→integration/test_battle_lifecycle、06→integration/test_selection_formation、07→integration/test_possession、08→smoke/test_cross_map_travel。新增 unit/test_behavior_state_machine（状态机纯逻辑 7 用例，从 stage_03 抽出）。当前 15 套件：unit 6 文件 + integration 7 文件 + smoke 2 文件
- ✅ **P0-3 清理**：废弃 WorldMapController 已删除（零引用）
- ✅ **P0-4 修复**：stickman_rig.gd IK 调试 print 改为 push_warning（仅失败路径），成功路径日志删除；stickman_entity foot_offset print 删除
- ✅ **P0-1 防静默**：SceneLoader preload_chunk/unload_chunk 加"未实现"push_warning
- ✅ **文档同步**：在役文档 test_stage_NN 引用全部更新为分层命名（归档文档加映射注记）

### 测试体系重设计 T0 + 文档校准 T1

- ✅ **T0-1 TestRunner 加固**（tests/core/test_runner.gd）：零断言守卫（0 断言用例判失败）、async 用例内建（add_test 第三参 + run_async，免手动 begin/end_test）、断言扩充（assert_false/lt/gt/approx/null/not_null）、汇总输出断言总数
- ✅ **T0-2 测试规范**（tests/README.md 重写）：三层体系（unit/integration/smoke）替代数字标号、命名规则、确定性硬规矩（等就绪不数帧/必带超时/用例隔离/AAA/零断言即失败）、`-- --fresh-start` 运行约定
- ✅ **T0-3 第一批 unit 测试（5 文件 38 用例）**：health_component(8)、resource_manager(8)、command_chain(6)、formation_system(7)、placement_grid(9)——全部纯逻辑、不进树、确定性
- ✅ **T0-4 建造循环 integration**（tests/integration/test_construction_cycle.gd，5 用例起，后增至 7 用例含脱困/放置校验）：真村落地图 fixture 下的开工→派工→材料→敲击→完工注册完整循环 + 资源不足/未注册/无地图失败路径
- ✅ **T0-5 smoke 冒烟**（tests/smoke/test_new_game_smoke.gd）：新游戏启动运行 60s 零崩溃（S3-1 达成）+ `tests/run_all.ps1` 聚合器（unit/integration/smoke/stage 分组、超时、汇总）
- ✅ **T0-6 清理**：孤儿 uid（tests/integration/test_construction_cycle/09）、3 个 `*_result.txt` 残留
- ✅ **T1 文档校准**：架构 §四/§六（补 P0-10/11/13/14/15、统一编号、0.5/0.7/0.9 状态）、自动加载依赖（9 autoload 实测）、路线图（阶段 0 实测 + P1 解锁顺序 + 阶段 2 前置达成）、GDD差异分析（资源/附身/combat/logistics/双目录过时项修正）、归档废弃声明、P0重审方案完成度更新
- ✅ 全量回归：旧 stage 131/131 + 新测试 52 用例 = **183 用例全绿**（`tests/run_all.ps1` 一键运行）

### P0 测试链稳定化 S1-4 + 战斗链路 S2-1

- ✅ **S2-1 战斗链路确认**：`TacticalOrders.issue → CommandChain.deliver → AIController.set_order` 链路已装配（game_root.gd:437 `to.setup(_formation_system, _command_chain)`，tests/integration/test_selection_formation 覆盖）
- 📌 **战斗结束判定（胜负收束/溃散判定/尸体处理）：规划延后**——依赖战斗与碰撞系统稳定后实施，不在 P0 范围，见 待办事项.md 低优先级
- ✅ **全量基线 131/131**：01=15/15、02=29/29、03=11/11、05=8/8、06=29/29、07=16/16、08=23/23，全部通过

### P0 测试链稳定化 S1-4

- ✅ **tests/integration/test_village_map/03 挂死修复**：`tests/integration/test_village_map.gd:229` 使用未声明的 `ScriptPlacementSystem`（解析错误导致脚本加载失败、`_ready` 永不运行、进程无 quit 挂死）→ 修为 `ScriptPlacementValidator.new().validate_placement(g, 0, 2)`
- ✅ **tests/integration/test_possession 挂死修复**：headless 下 `TestHelpers` class_name 未注册 → 显式 `const TestHelpers := preload(...)` + `var ok: bool` 显式类型
- ✅ **存档污染守卫**：`game_root.gd` 自动读档处加 `--fresh-start` 守卫（跳过槽位 0 读档）；测试标准命令改为 `-- --fresh-start`
- ✅ **C 类真 bug**：`resource_node.gd:34 _update_debug_visibility` 接收 0 参数但 `DebugApi.visibility_changed` 发射 1 个 bool → 加默认参数
- ✅ **tests/integration/test_village_map 陈旧断言全部更新**（ground 810/0.25/1080、map_left 动态、player spawn 动态、camera 动态）→ 29/29
- ✅ **tests/integration/test_ai_behaviors AI 移动抖动修复**：固定 2s 等待改 `await_condition`（累计位移 >30px 或超时）→ 11/11
- ✅ **tests/integration/test_selection_formation HBox/Label 类型错修复**（测试自身变量类型注解）→ 29/29，stderr ERROR 清零

### 阶段 0.7 闭环

- ✅ **P0-1 修复**：PossessionInterface 装配代码已补全（[game_root.gd:363-399](../stick-world/modules/world/scripts/game_root.gd)）
- ✅ **InputDispatcher** 已注册 POSSESS handler（game_root.gd:370-371）
- ✅ **tests/integration/test_possession**：16 项测试通过（附身排长操控战斗）
- 📌 **附身完整版深化**后移到阶段 1/2 详细指挥系统开发（与 [路线图.md](项目/路线图.md) "完整指挥链设计"合并）
- 📌 **章节号迁移**：旧版"§十七"已变更为 [场景与战斗架构.md §六](技术/架构/场景与战斗架构.md)

### 阶段 0.1 - GameRoot 骨架 ✅

- **新增 `game_root.tscn` 主场景**：搭建 GameRoot 骨架，挂载 WorldClock / CameraRig / SceneLoader / InputDispatcher 四大根组件
- **新增 `EnvironmentSystem` 简版**：仅时间 -> 光照变化，无天气
- **新增 `UIRoot` 三层容器骨架**：HUD / Panel / Overlay 分层
- 详见 [`场景与战斗架构.md`](技术/架构/场景与战斗架构.md) §二、§十一

### 阶段 0.2 - 单张村落地图 ✅

- **新增 `VillageMap` + 单个 Chunk**：硬编码一张完整地图，暂不做流式加载
- **新增 `PlacementGrid`**：建筑选址网格
- **新增地面纹理渲染**：`GroundPolygon` + 草地噪波材质（Stochastic Tiling + FBM 噪波 GLSL Shader，远超"重复纹理"描述）
- **新增 `ground_y` / `ground_ratio` / `map_left` / `map_right` 字段**：地图边界与地平线定义
- **重构 `CameraRig`**：水平卷轴 + 1/4 区域跟随 + 垂直显示范围限定；DESIGN_HEIGHT=1080 三层缩放系统（base_zoom / user_zoom / effective_zoom）；拖动延迟弹回（5 秒冷却）+ 居中模式（松手即弹回，禁边缘滚动）
- **新增玩家 `StickmanEntity`**：WASD 控制移动，脚部锁定 `ground_y`，X 限界
- **新增 `DebugOverlay`**：F3 切换 + 6 个绘制器 + 图例面板 + FPS/实体数显示
- **建筑三层架构改造**：TerrainBuildings / InitialBuildingsList / 存档分离
- **新增 `WalkBarrier` 透明障碍 + `PassageBarrier` 建筑障碍**：火柴人寻路阻挡
- **新增 `BuildMask`**：不可放建筑区域
- **新增 `ForegroundLayer`**：前景遮挡层
- 详见 §三、§四、§7.1.2

### 阶段 0.3 - 火柴人行为 AI 基础 ✅

- **新增 `StickmanEntity` 节点结构**：AIController 作为子节点
- **新增 `AIController` + `BehaviorStateMachine`**：状态机驱动的行为决策框架
- **新增 `behavior_idle` / `behavior_move`**：随机游走
- **新增 `behavior_wander`**：基于 Reynolds Steering 的漫游行为，含卡住检测（0.2s 移动<3px 视为卡住）+ 120~240° 掉头恢复 + 冷却防抽搐 + 边界规避力
- **新增 `behavior_work`**：与阶段 0.4 建设系统耦合
- 测试：村民在村里自主走动（idle ↔ move 循环）

### 阶段 0.4 - 定居点建设 ✅

- **新增 `Building` 节点结构**
- **新增 `placement_system`**：选址 API（ghost 预览留到阶段 0.6）
- **新增 `construction_project` + `work_crew_assigner`**：工程量驱动的建造流程 + 工人派工
- 测试：选址 -> 派工 -> 建造 -> 完成循环（tests/integration/test_construction_cycle 7/7 通过）
- ⚠️ 遗留：`InitialBuildingsList` 未接入（后续阶段接入）

### 阶段 0.5 - 小队级战斗 ✅

- **新增 `Hitbox` / `HealthComponent` / `WeaponMount`**：挂载到 StickmanEntity，含攻击命中帧伤害逻辑
- **新增 `behavior_attack` / `behavior_seek_cover` / `behavior_retreat`**：战术 AI 行为
- **新增 `battle_instance`**：挂载到 VillageMap.BattleAnchor
- **新增 `BattleDirector` + `battle_ai_director`**：战场导演 + 情绪标签（压制 / 犹豫 / 溃逃）
- 测试：5v5 战斗，观察到掩体利用、火力压制、溃逃行为切换（tests/integration/test_battle_lifecycle 7/7 通过）

### 阶段 0.6 - 编队与指挥 + 小地图 ✅

- **新增 `selection_system`**：框选单位
- **新增 `formation_system`**：编队
- **新增 `tactical_orders` + `command_chain`**：战术指令 + 指挥链
- **新增 `BattlePanel` UI**：战斗面板
- **新增 `Minimap`**：缩略图 + 视野框 + 角色点 + 建筑图标 + 点击跳转
- **完善 `CameraRig` 手动控制**：拖动 + 边缘滚动 + 缩放（1.0~2.0）+ 居中模式按钮
- 测试：框选 -> 编队 -> 任命排长 -> 下令前进；小地图点击跳转（tests/integration/test_selection_formation 29/29 通过）

### 阶段 0.7 - 玩家附身 ✅（装配闭环见下段）

- **新增 `PossessionInterface`**：附身接口 + POSSESS 模式 handler + ESC 退出 + 时间降速
- **新增 `PossessPanel` UI**：HP / 士气 / 武器 / 行为 / 坐标 + 退出附身按钮
- **`BattlePanel` 新增"附身选中单位"按钮**
- **`StickmanEntity` 新增鼠标左键攻击**：`_player_attack` + `_find_nearest_enemy_in_range`
- **EventBus 新增 `possession_started` / `possession_ended` 信号**
- ⚠️ **P0-1 发现 PossessionInterface 未装配，待修复**：`game_root.gd` 缺失 `_setup_possession_interface()` / `_setup_possess_panel()` 方法，`InputDispatcher` 未注册 POSSESS handler，附身功能当前完全不可用。`tests/integration/test_possession_result.txt` 显示 16/16 通过是重构前旧版本残留，具有误导性。详见 §十七 P0-1。
  > **注**：已修复（见"阶段 0.7 闭环"段）。原章节号 §十七 已变更为 §六。

### 阶段 0.8 - 多场景衔接 ✅

- **新增地图间切换**：`SceneLoader.travel_to_map` + `ChunkTrigger` 出口触发器 + EventBus 信号转发
- **新增 `RoadMap`**：`road_map.gd` + 双向出口触发器
- **战略图进入聚落**：`enter_settlement` + `EventBus.travel_requested`
- 测试：村落 A -> 道路 -> 村落 B 完整链路（tests/smoke/test_cross_map_travel 23/23 通过）
- ⚠️ 遗留：Chunk 流式加载仍为占位（见 P0-1）；战略图 `close_strategic_map` 半成品（见 P0-2）；`WorldMapController` 废弃副本（见 P0-3）

### 世界生成
- **新增 `fractal_continent.py`**：分形大陆生成器，替代原 Azgaar 模板法方案
  - Delaunay 三角网格（100k 顶点 / 205k 三角形）上计算高度，不在像素网格上
  - 两阶段高度合成：阶段1外海距离场 → 阶段2内池随机 H + 非线性衰减
  - 内池影响限制在本岛屿内（连通分量隔离），不跨海
  - 河流在三角网上连续空间追踪（最陡下降 + Squig curve 分形弯曲）
  - 河流蒙版裁切 + 统一颜色 + 过滤 1px 细支流
  - 地形参数：OCEAN_DIST_SCALE=250, LAKE_DIST_SCALE=62.5(1/4), LAKE_FALLOFF_POW=2.5
- **蒙版更新**：锁定大陆掩码 `locked_continent_8192.png` 中最大两个内海已联通外海
- **目录整理**：`output/` 下历史实验归档到 `archive/`，诊断文件归入 `diag/`，河流实验代码归入 `experiments/`
- **文档更新**：`程序化世界生成.md` 新增 §二十二 分形大陆生成器完整文档；`河流算法需求.md` §十一 记录实际实现与偏离

### 文档维护
- 数据配置引用更新：四份文档新增 Excel 管线交叉引用
  - `.trae/rules/rule.md` 文档导航表新增"游戏数据表"行
  - `docs/README.md` 文档导航表新增"Excel 数据管线"行
  - `docs/技术/架构/平衡框架.md` 开头添加变量来源迁移说明
  - `export/agent-prompts.md` 顶部添加数据表迁移注释，指导 Agent 改 Excel 而非直接改 .tres

### 架构设计 (2026-07-09 · 第三轮)
- 代码 vs 文档对照审计完成——文档超前代码 2 个大版本，代码骨架好但缺血肉
- 新建 `docs/技术/架构/` 目录，6 份底层架构文件
- **精简 `.trae/rules/rule.md`**：364 行 → ~230 行，砍掉说服性散文和 PowerShell 规范，新增项目文档导航和"设计先行"规则：
  - `核心实体.md` — 9 个核心实体的完整属性 + 状态机
  - `系统交互.md` — 8 层系统交互矩阵 + EventBus 事件目录 2.0（28→50+ 信号）
  - `数据流.md` — 命令下发/经济调节/信息上报三条流 + 三层存储架构
  - `模块API.md` — 8 个模块的 api.gd 完整接口规范（含前置/后置条件）
  - `自动加载依赖.md` — 6+3 个 Autoload 依赖图 + 初始化顺序
  - `平衡框架.md` — 变量→公式→数据表→调优面板完整管线

---

- **重大修正**：基于创始人 22 题 Q&A，纠正对核心系统的理解错误
- 删除 `phasing-system.md`（阶段演进不是独立系统，合并到 GDD）
- **重写 `组织系统.md`**：从"军事指挥链"→"通用五层级项目管理系统"（军事/科研/工程/行政/商业同一套工具）
- **重写 `战斗系统.md`**：编制部分移除（归属 orgnization），聚焦战术层面的附身操控和《英雄连》式 AI
- **重写 `游戏设计文档.md`**（v4.0）：整合八层纵切+五层级横切、组织全能但特化、UI 工作区预设、价格信号融入
- 更新 `设计支柱.md`、`核心循环.md`、`UI设计规范.md`、`经济系统.md`、`扩张系统.md`
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
