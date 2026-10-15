# PLACEHOLDER 素材替换清单（Demo 占位 → 自制资产）

| # | 文件 | 现状 | 替换方向 |
|---|---|---|---|
| P1 | `modules/fx/scripts/fx_library.gd` | 运行时生成的软圆点贴图 + 手调粒子参数 | 特效对画面为负作用、游戏内已关闭——不做贴图替换（创始人裁决） |
| P2 | `environment_system.gd::_ensure_camp_light` | GradientTexture2D 径向光斑跟随视口 | 逐光源布点：火把/建筑窗光挂 PointLight2D 到场景节点，本光退化为调试用 |
| P3 | `thatch.gdshader` | 程序化草束（参数可用级） | 美术调参或换手绘屋顶贴图混合程序化细节 |
| P4 | `barracks.gd/_post_build` | 几何军旗+八边形盾饰 | 军旗手绘贴图+摆动动画、纹章盾徽 |
| P5 | `warehouse.gd/_post_build` | 几何货箱堆+椭圆麻袋 | 木板纹货箱贴图、麻袋手绘、货物随库存变化 |
| P6 | `audio_manager.gd::SFX_EVENTS` | 表已全映射真实文件（34 个 wav 入库：程序化合成 SFX 33 + 氛围 BGM 1，1eedf83e/cdf158d5）；音质/风格待美术复核 | 换录制/采购成品直接替换，调用点零改动 |
| P7 | `modules/fx/assets/demo/`（水晶簇/岩壁带/墙纹/接触阴影） | 从药工解包资源与实机截屏提取的**本地演示占位**（fx_gif authentic 舞台用，游戏内资源点未引用） | 自制手绘水晶簇与岩壁纹理替换；发布导出须排除该目录 |
