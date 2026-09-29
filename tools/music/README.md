# 音乐管线（tools/music）

> 从**作曲**到**游戏内可播放的 OGG** 的完整离线管线。十七首曲子（每首一条自己的
> 旋律与和声骨架）、分层渲染、无缝循环、混音母带、客观质检，
> 全部由代码生成、可复现。
>
> 想了解音乐本身怎么设计 → [docs/设计/音乐/](../../docs/设计/音乐/)；
> 想了解运行时怎么放 → [docs/技术/架构/音乐系统.md](../../docs/技术/架构/音乐系统.md)；
> 想了解怎么跑、为什么这么搭 → [docs/技术/音频/音乐制作管线.md](../../docs/技术/音频/音乐制作管线.md)。

## 快速开始

```bash
# 0) 依赖（必须用 Python 3.12 正式版解释器，见 requirements.txt 顶部的说明）
pip install -r tools/music/requirements.txt

# 1) 一次性：拉渲染引擎与音源（约 515MB，落到仓库 temp/ 下，gitignored）
#    sfizz + FluidSynth + Salamander 钢琴采样 455 个 + GM SoundFont；
#    全部按 tools/music/toolchain_pins.json 的 commit / 内容指纹下载并校验
python tools/music/setup_toolchain.py
python tools/music/setup_toolchain.py --verify     # 校验采样指纹与音源 sha256

# 2) 写谱自检（调外音 / 和声避讳音 / 音区 / 留白，渲染前先跑）
python tools/music/compose/check_melody.py

# 2c) 改了和声骨架之后：把谱面注释里的和弦功能同步过来（否则注释在说谎）
python tools/music/compose/annotate_melody.py --write

# 2b) 管线自检（验证 DSP/响度/循环/导出"算得对"，不是"能跑通"）
python tools/music/selftest.py

# 3) 一键：谱面 → MIDI → 分轨渲染 → 混音 → 母带 → 交付 OGG + 清单
python tools/music/render_all.py

# 4) 质检（客观指标 + 阈值判定）
python tools/music/qa_audio.py           # 出表
python tools/music/qa_audio.py --check   # 有违规即非零退出（可进 CI）

# 5) 试听样带（把分层叠好、编码成能直接双击播放的 MP3，供人听验收）
python tools/music/preview.py
python tools/music/preview.py --cue field_day --tier-cues field_day
python tools/music/melody_reel.py       # 只混"唱旋律的层"串一条（听"每曲是不是不同的曲子"）

# 6) 音色体检（改混音配方前后对比八度带分布，别凭感觉调 EQ）
python tools/music/tone_check.py
python tools/music/tone_check.py --stems interior
python tools/music/tone_check.py --raw C4v10.flac
```

## 复现交付件（可复现性口径）

同参数 ⇒ 同一份音频。渲染是**确定性**的（随机种子固定、引擎与音源版本钉死），
因此"重渲一遍"得到的音频与已交付的 OGG **逐样点相同**（OGG 容器字节可能因编码器
非确定性不同，解码后的 PCM 相同）。实测（`menu_title`，两层）：

| 层 | 样点数 | 与交付件相关性 | 最大样点差 | LUFS（交付 / 重渲） |
| --- | --- | --- | --- | --- |
| piano | 5,585,455 | 1.000000 | −240 dB | −16.972 / −16.972 |
| strings | 5,585,455 | 1.000000 | −240 dB | −20.828 / −20.828 |

复现的前置条件只有**工具链装全**这一条（`setup_toolchain.py`）。它曾在两处让人
"装了也跑不出来"，现在都有明确机制兜住：

- **采样清单不靠 GitHub API 枚举**：匿名限额 60 次/小时，额度用尽时安装直接
  403（`rate limit exceeded`）→ 采样下不了 → 整条管线停摆。现读入库的
  `toolchain_pins.json`（commit + 479 个文件的 git blob 指纹），**不调用 API**，
  下载后逐文件校验内容；上游是浮动分支时也照钉住的 commit 走。
- **GM SoundFont 由脚本下载**：编制声部（弦乐/竖琴/钟琴/木管/定音鼓）全靠它，
  早先只在登记档写了来源、**没有任何脚本会装它**，缺它时 `render_all.py` 直接退出。
  现按 `MuseScore_General.sf3`（MIT，39.9MB）的 URL + sha256 自动装到 `soundfonts/`。

有意升级音源版本时：改 `gen_toolchain_pins.py` 的目标后重跑生成新清单，再跑
`setup_toolchain.py`（旧采样会被指纹校验拦下，需先删）。

## 常用参数

```bash
python tools/music/render_all.py --list                # 列出全部 cue（调性/速度/层）
python tools/music/render_all.py --only field_day      # 只做一首
python tools/music/render_all.py --skip-render         # 只重混音（改混音参数后用，省几十分钟）
python tools/music/render_all.py --ogg-quality 8       # 提高 OGG 码率
python tools/music/qa_audio.py --delivered             # 检查交付的 OGG 而不是母带
```

## 目录

| 路径 | 内容 |
| --- | --- |
| `setup_toolchain.py` | 工具链安装（sfizz / FluidSynth / Salamander 钢琴采样 / GM SoundFont / 清单） |
| `toolchain_pins.json` | **工具链钉版清单**（采样 commit + 逐文件 blob 指纹 + SoundFont sha256），入库 |
| `gen_toolchain_pins.py` | 生成/更新上面那份清单（需 `GITHUB_TOKEN`，只在有意换版本时跑） |
| `selftest.py` | 管线自检（已知答案的输入 → 验证输出） |
| `compose/themes.py` | **旋律库**：14 条原创旋律（级数化谱面 + 自带和声骨架 + 每条乐句带推荐八度） |
| `compose/common.py` | **编曲基因**：骨架条目库（`SKELETONS`）、级数→音高、编曲助手、力度/音区规则 |
| `compose/cues.py` | 十七首曲子的定义（旋律 + 编制 + 分层 + 混音覆盖） |
| `compose/check_melody.py` | **写谱自检**：调外音 / 和声避讳音 / 音区 / 留白（渲染前跑） |
| `compose/annotate_melody.py` | **注释同步**：按骨架重写谱面注释里的和弦功能（换和声后跑） |
| `musiclib/theory.py` | 乐理层：音高/音阶/和弦/级数/声部连接/音型 |
| `musiclib/score.py` | 谱面数据结构 + MIDI 导出 + 人性化（力度/踏板/微时值） |
| `musiclib/render.py` | 分轨离线渲染（sfizz 钢琴 / FluidSynth 编制） |
| `musiclib/dsp.py` | DSP 原语（滤波/压缩/限制/饱和/M-S 展宽） |
| `musiclib/reverb.py` | 程序化合成脉冲响应（IR）+ 卷积混响 |
| `musiclib/mix.py` | 混音配方表 + 总线母带 + 循环尾巴折回 |
| `musiclib/loudness.py` | 客观指标（BS.1770 LUFS / 真峰值 / LRA / 刺耳度 / 接缝 / 单声道） |
| `musiclib/export.py` | OGG 编码 + 引擎清单生成 |
| `render_all.py` | 总编排 |
| `preview.py` | **试听样带**：分层叠好→MP3（全层版/分层同增益对比/串烧/循环三遍验接缝） |
| `melody_reel.py` | **旋律串烧**：只混旋律层串一条，验收"每曲是否真有自己的旋律" |
| `qa_audio.py` | 质检报告与阈值判定 |
| `tone_check.py` | 音色体检（八度带分布 / 频谱斜率 / 有源帧谱质心） |
| `ambience.py` | 环境音层生成（风/鸟/蝉/夜虫/海浪/溪流） |
| `docs/ambience_sources.md` | 环境音层的来源与许可登记 |
| `out/` | 中间产物（MIDI / 分轨 WAV / 母带 WAV / 报告），**gitignored** |

交付件写到 `stick-world/assets/audio/bgm/<cue>/<layer>.ogg` + `music_manifest.json`
（进版本库，游戏直接加载）。

## 改东西时改哪里

| 想改 | 改哪 | 然后 |
| --- | --- | --- |
| 旋律 / 和声 / 织体 | `compose/common.py`、`compose/cues.py` | `render_all.py --only <cue>` |
| 某一层的音色配方（EQ/混响/压缩） | `musiclib/mix.py` 的 `STEM_RECIPES` | `render_all.py --skip-render` |
| 总线的响度 / 限制 / 饱和 | `musiclib/mix.py` 的 `BUS` | `render_all.py --skip-render` |
| 循环折回 / 接缝 | `musiclib/mix.py` 的 `wrap_loop_tail` | 同上 + `qa_audio.py` 看接缝指标 |
| 换钢琴音源 | `setup_toolchain.py` 的下载源，或直接替换 `temp/music_toolchain/sfz/` | 全量重渲 |
| 换 GM 音源 | 把 `.sf2/.sf3` 放进 `temp/music_toolchain/soundfonts/`，或设 `MUSIC_SOUNDFONT` | `render_all.py` |
| 环境音 | `ambience.py` | 重跑该层 |

## 纪律

1. **改完必须跑 `selftest.py` + `qa_audio.py --check`。** 响度、真峰值、循环接缝、
   单声道兼容、刺耳度都有客观阈值；指标不绿一定不通过。
2. **客观指标全绿 ≠ 好听。** 机器只能挡住"明显做坏了"，"是否动人"只能人听。
   别把指标当作品质的全部。
3. **音色调整要看实测频谱**（`tone_check.py`），不要凭乐器成见。
   本项目的钢琴音源本身就偏暗，按"钢琴偏亮"的成见去做高频衰减会把成品压成闷罐。
4. **任何外部素材（采样库/录音）当场登记**到
   `docs/技术/音频/音乐资产登记与来源.md`，并核对许可与署名义务。
