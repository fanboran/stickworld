# hd2d：HD-2D 渲染栈（3D 世界 + 烘焙卡 + 2D 角色 billboard）

> 八方旅人式渲染：3D 场景承载 Blender 烘焙的建筑/道具/自然物卡与地面分带，
> 2D 绘制的火柴人经 SubViewport 贴到 billboard quad 站进场景。本模块定位 L1
> 基础设施——只管"怎么把世界画出来"，物理/输入/AI/地图规则都在消费方的 2D
> 宿主里（modules/world 的 Hd2dMapBase 系地图）。
>
> 渲染协议（坐标投影 / remap_fx_pos / 屏幕映射 / 地面分带）统一见
> [HD-2D 街景系统](../../docs/技术/架构/建筑管线/HD-2D街景系统.md)，本文件不重复展开。

---

## 目录结构

```
modules/hd2d/
├── api.gd                          # Hd2dAPI：世界场景路径常量 + 宿主消费的 duck 方法清单
├── scenes/
│   └── hd2d_world.tscn             # 3D 世界根场景（Hd2dWorld，挂 hd2d_world.gd）
├── scripts/
│   ├── hd2d_world.gd               # Hd2dWorld：世界构建（卡摆放/墙/地面/天空云/光照/相机镜像）+ duck API + 布局/战场/资源图模式 + 原型截图跑法（--shots）
│   └── char_sprite_3d.gd           # 角色 billboard：2D 火柴人 → SubViewport → 相机同基 quad；接地影/脚下框/劳作进度条/武器镜像
├── shaders/
│   ├── card.gdshader               # 建筑卡：亮度差分伪法线吃真 3D 光照 + 日/夜版混切 + 台基裁剪
│   ├── char_billboard.gdshader     # 角色卡：SubViewport 像素原样输出（unshaded）+ 写深度参与遮挡 + UV 镜像翻面
│   ├── char_shadow.gdshader        # 角色接地影：贴地径向软影
│   ├── building_shadow.gdshader    # 建筑接地影：贴地椭圆软影（把建筑钉在路肩带上）
│   └── post_hd2d.gdshader          # 屏幕空间后处理：暗角/移轴/色彩分级（DOF/Glow 走 Environment）
└── assets/tex/
    ├── proto25d/                   # 建筑卡：cards.json 元数据 + cards/*.png（日/夜/发光版）
    ├── proto_hd2d/                 # 道具卡 props/、自然物卡 nature/、布局 JSON（hd2d_layouts/*.json）
    └── ground_tiles/               # 地面分带贴图（路肩/路面/草地/夯土；src/ 源图、transitions/ 过渡）
```

---

## 对外契约

- 场景：宿主 instantiate `Hd2dAPI.WORLD_SCENE` 后 add_child；add_child 前注入模式——
  `layout_name` / `layout_data`（布局驱动，读 assets/tex/proto_hd2d/hd2d_layouts/*.json）、
  `battlefield`（战场野地）、`resource_field`（城外资源图）；全空 = 手摆主街
- duck API（宿主消费，全表见 api.gd）：`enable_play_characters` / `spawn_character` /
  `set_cam_x` / `set_cam_zoom`（与 2D CameraRig 逐像素 1:1）/ `set_light_mode("day"/"night")` /
  `get_solid_rects` / `get_gates` / `get_wall_x` / `get_building_rects` /
  `spawn_nature_card_at` / `get_open_work_sites` / `get_layout_width` /
  `get_ground_squash` / `get_ground_lift_world` / `get_ground_lift_px`

---

## 依赖

- `modules/units/`（StickmanRig 场景与描边脚本、WeaponMount 武器场景表——角色卡内容
  来自 2D 火柴人管线）；被 `modules/world/` 的地图宿主消费

---

## 开发注意事项

- 角色卡 = 相机对齐 billboard（与建筑卡同取向正对相机），只有"脚底锚定地面点"是
  3D 的，不给角色加任何角度；尺寸契约（SubViewport 像素 ↔ 格换算、比例锚）见
  `char_sprite_3d.gd` 头注释，改动前先读
- 光照纪律：环境光 + 太阳能量总和 ≈ 1.0（防双计）；色调映射用 LINEAR
  （卡是已带光照的烘焙图，filmic/aces 会压灰）
