# -*- coding: utf-8 -*-
"""音效合成管线库（`tools/sfx/`）。

模块分工：

  synth.py   合成原语（瞬态 / 共振体 / 模态打击 / 拟音 / 金属与木质碰撞）
  design.py  每个音效一份**显式设计配方**（这是什么声音、由哪些成分构成、为什么）
  post.py    母带链与音效专用客观指标（事件响度 / 裁剪 / 立体声化 / 频段占用）

外部依赖：只 import `tools/music/musiclib/` 里的 `loudness` 与 `dsp`
（音乐管线已验收的成熟件），不改动 `tools/music/` 下任何文件。
"""
