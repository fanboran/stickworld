# 环境音层（ambience）—— 来源登记与质检

游戏里叠在 BGM 下面的**场景氛围底噪**。8 条，全部 48kHz 立体声 PCM_16、无缝循环，
交付在 `stick-world/assets/audio/ambience/`。生成脚本 `tools/music/ambience.py`
（`--fetch` 拉源材料 / `--only` 单层 / `--verify` 打表）。

环境层与 BGM 是两条独立管线：BGM 走 MIDI → 采样渲染 → 混音（有拍、有调）；
环境层是**无调性的连续噪声场**，没有小节，只有频谱、包络与统计分布，所以直接合成波形。

---

## 一、两条来源路线（都用上了）

**A. 网络采集** —— 只取许可清晰的 **CC0 / Public Domain / CC-BY** 自然环境录音。
逐条核对（CC-BY-SA / 非商业 / 来源不明一律不用），下载后**先做客观体检再决定用途**：
时长是否够、是不是真的那类声音、频谱是否合理。全部登记在 §四。

**B. 程序化合成** —— `numpy + scipy`。核心原语：

| 原语 | 做法 |
| --- | --- |
| `spec_noise` | 随机相位 + 指定幅度谱做 IFFT。得到的噪声**严格以循环长度为周期**，接缝在数学上不存在 |
| `band_noise` | 上述 + 巴特沃斯带通幅度包络（150Hz~16kHz 任意带） |
| `rand_env` | 慢速带限噪声经 tanh 映射到 (0,1)，当"阵风/起伏"包络（周期化） |
| `lfo` | 频率锁定到整数周期的正弦 LFO（颤音用；循环内整数个周期，无相位跳变） |
| 事件合成 | 鸟鸣=滑音音列，蝉=带通噪声×颤音，虫=窄带脉冲串，浪=非对称包络+泡沫，雨/水=带通+随机游走 |
| `circ_reverb` | 环形 FFT 卷积混响（用库里 `musiclib.reverb` 的合成 IR）。尾巴自然绕回开头 |

**融合策略**：录音给"真"的随机性与质感，合成给可控的频谱、密度与节奏。哪层用哪条、
各占多少，写死在 `LAYERS` 配方里（§二）。

---

## 二、无缝循环怎么做到的

三条机制并用，目标是"接缝处波形连续"而不是"听起来还行"：

1. **谱合成天生周期**。凡是 `spec_noise` 线性组合出来的东西（风/溪/雨的底噪、
   所有慢包络）都以 n 为周期，接缝严格不存在。
2. **环形事件缓冲**。鸟/虫/浪/水滴等离散事件用 `circ_add` 落到环形缓冲上，
   跨过末尾的事件自动缠到开头；混响也是环形卷积，尾巴绕回开头。
3. **环形滤波 + 等功率交叉淡化**。真实录音经 `crossfade_loop` 折成循环
   （`out[0]==x[n]`，自然延续）。**关键一手**：所有对整段缓冲的 IIR 滤波
   （EQ/高通/低通）都换成 `circ_apply`——把 `[x;x]` 跑一遍取后半，消除
   `lfilter` 零初态在**第 0 个样本**处的启动瞬态（否则每圈接缝一次"啪"）。

---

## 三、逐层配方（来源 + 参数 + 质检）

### 1. `wind_calm` 平原/草原轻风 · 16.0s
- **路线**：融合。三段柳风录音（PD）叠底 + 谱合成。
- **录音处理**：三段各取最平稳段 → 高通 45Hz / 低通 1500Hz / 高架 −5dB@2.6kHz
  → 等功率折环 → 单声道源右耳微延迟 11ms 去相关 → 平均。
- **合成**：三个带（150–700 / 450–1400 / 25–110Hz）+ 两个慢包络
  （阵风 0.055–0.20Hz 控制幅度与频段交叉，0.05–0.16Hz 控制频谱移动）；末级 −2.5dB@3kHz。
- **质检**：−28.00 LUFS / 真峰 −15.1 dBTP / 2-5k P95 0.007 / 接缝 80.2%（无离群）/ 接缝电平 −51.7dB。

### 2. `birds_day` 白天远处鸟鸣 · 20.0s
- **路线**：融合。破晓鸟鸣录音（CC0）当"远处底" + 合成稀疏叫。
- **录音处理**：低通 3000Hz + 高架 −10dB@2.6kHz → 电平 0.16 → room 混响 25%（远）。
- **合成**：6 种叫型（双音上滑 / 快速颤音 / 长下滑哨 / 两音 pee-wee / 碎语 / 上弯）
  随机排布，间隔 0.55–2.1s（远叫更稀疏）；每叫按"距离"低通 9.5k→3.3kHz、
  高架 −9dB、电平 −24dB×dist；随机 pan。末级 −3dB@5.2kHz。
- **质检**：−28.50 LUFS / −11.5 dBTP / 2-5k P95 0.842 / 接缝 42.2%。

### 3. `cicada_summer` 夏日远蝉 · 18.0s
- **路线**：融合。三段蝉录音（CC0/PD/CC BY 3.0）当"蝉雾" + 合成三种蝉。
- **录音处理**：高通 500Hz / 低通 7000Hz / 高架 −7dB@5kHz → 电平 0.55 → hall 混响 30%。
- **合成**：アブラゼミ（带 4200±1300Hz，46Hz 颤音，深度 0.55，连续）；
  ミンミン系（4700±850Hz，63Hz，0.72）；ヒグラシ（3400±700Hz，29Hz，0.85，周期起落）。
  颤音频率锁定整数周期。三只分摆 −0.42 / +0.30 / +0.05 并错时。末级低通 8200Hz +
  −6dB@4.8kHz + hall 混响 42% + −2dB@4.5kHz。
- **质检**：−28.00 LUFS / −16.7 dBTP / 2-5k P95 0.720 / 接缝 1.2%。

### 4. `night_insects` 夜晚虫鸣 · 20.0s
- **路线**：融合。合成稀疏清脆鸣为主 + 蟋蟀录音（PD）抠真实鸣声事件点缀。
- **真实事件**：蟋蟀录音带通 3.0–6.5kHz 取最响 0.22s（该录音低频偏重，带通后才见
  30–50Hz 脉冲串）；6 处低电平放置（dist 0.4–0.8）。
- **合成**：3 种蟋蟀（载波 4300/5200/3600Hz，每声 3–5 个窄带脉冲，脉冲率 20–31Hz），
  间隔 0.35–1.6s；铃虫长颤音（4400Hz，30Hz 脉冲率）每 4.5–8s 一条；room 混响 30%；
  高通 700Hz 保"清脆"；夜间空气底（300–1800Hz，极轻）；末级 −3dB@5.2kHz。
- **质检**：−28.50 LUFS / −9.8 dBTP / 2-5k P95 0.866 / 接缝 16.4%。

### 5. `waves_shore` 海浪拍岸 · 18.0s
- **路线**：融合。合成涌浪节奏 + OpenGameArt CC0 真浪。
- **合成**：低频水床（30–130Hz）+ 极轻泡沫底（1.2–5kHz）随慢包络起伏；
  4 组不同周期（4.6/5.5/7.4/8.8s）的涌浪事件非均匀铺排，每组左右两套噪声去相关；
  单次涌浪 = 非对称慢起慢落的水体涌动（50–420Hz）+ 峰值处的泡沫嘶声（850–4.2kHz）。
- **真实**：8 条 CC0 浪（jasinski / transitking）取最响段、高通 40Hz / 低通 5.5kHz，
  取 5 条环形随机落位。末级高通 25Hz + −2dB@4.5kHz。
- **质检**：−27.50 LUFS / −12.8 dBTP / 2-5k P95 0.171 / 接缝 92.7%。

### 6. `stream_water` 小溪流水 · 14.0s
- **路线**：融合。合成多带颗粒 + 溪流录音（CC0 Swale）。
- **合成**：5 个带（420–1100 … 6200–13000Hz）各自一条 4–40Hz 随机游走幅度
  （造"水泡/颗粒"）；咕嘟/水滴事件（阻尼下行短音，间隔 0.18–0.9s）。
- **真实**：Swale 高通 350Hz / 低通 12kHz，单声道源右耳延迟 8ms。末级高通 300Hz + −4dB@5kHz。
- **质检**：−27.50 LUFS / −11.7 dBTP / 2-5k P95 0.441 / 接缝 16.4%。

### 7. `rain_soft` 柔和雨声（加分项）· 16.0s
- **路线**：融合。合成高频雨 + 雨录音（CC0）叠底。
- **合成**：3–15kHz 主带 + 1.2–4kHz 辅带，随 0.04–0.22Hz 慢起伏；偶发水滴点（1.8–5.2kHz）。
- **真实**：露台小雨录音选最平稳段（避开远雷）高通 400Hz / 低通 14kHz。
- **质检**：−28.00 LUFS / −13.7 dBTP / 2-5k P95 0.341 / 接缝 21.0%（雨本来就亮，阈值单列 0.60）。

### 8. `village_ambience` 村落远景声（加分项）· 20.0s
- **路线**：融合。合成风 + 木工敲击 + 鸡鸣（CC BY 3.0）/ 羊叫（PD）远处理。
- **合成**：与 `wind_calm` 同源的轻风底（电平 0.60）；木工敲击（阻尼共振 220–520Hz，
  二三下一组，组间隔 3–7.5s，dist 0.55–0.9 处理后低通/高架）。
- **真实**：鸡鸣取最响 0.5s、低通 3.2kHz、高架 −6dB@2.5kHz，3 处低电平；羊叫 dist 0.8 一次。
  hall 混响 45%（"从村子那头飘过来"）。
- **质检**：−29.00 LUFS / −13.0 dBTP / 2-5k P95 0.015 / 接缝 68.7%。

---

## 四、源材料登记表

下载目的地 `temp/ambience/sources/`（gitignored，`--fetch` 可重下）。

| key | 来源 | 许可 | 作者 | 原始格式 / 时长 |
| --- | --- | --- | --- | --- |
| `wind_willows_02` | [Wind willows 02](https://upload.wikimedia.org/wikipedia/commons/3/39/Wind_willows_02_grahame_ap.ogg) | Public Domain | Kenneth Grahame | Ogg Vorbis 44.1k 单 1888.4s |
| `wind_willows_05` | [Wind willows 05](https://upload.wikimedia.org/wikipedia/commons/0/02/Wind_willows_05_grahame_ap.ogg) | Public Domain | Kenneth Grahame | Ogg Vorbis 44.1k 单 2303.7s |
| `wind_willows_09` | [Wind willows 09](https://upload.wikimedia.org/wikipedia/commons/9/90/Wind_willows_09_grahame_ap.ogg) | Public Domain | Kenneth Grahame | Ogg Vorbis 44.1k 单 2382.4s |
| `birds_reveil` | [Réveil des oiseaux](https://upload.wikimedia.org/wikipedia/commons/3/33/R%C3%A9veil_des_oiseaux.ogg) | CC0 | Joseph Sardin | Ogg Vorbis 44.1k 双 174.9s |
| `forest_ambience` | [Forest ambience (Gravity Sound)](https://upload.wikimedia.org/wikipedia/commons/b/be/Forest_ambience_%28Gravity_Sound%29.wav) | CC BY 4.0 | Gravity Sound | WAV 44.1k 双 33.0s（**仅作 `birds_day` 兜底，未进成品**） |
| `cicada_cn` | [蝉鸣](https://upload.wikimedia.org/wikipedia/commons/9/90/%E8%9D%89%E9%B8%A3.ogg) | CC0 | Ngguls | Ogg Vorbis 44.1k 双 33.1s |
| `cicada_nz` | [New Zealand cicada song](https://upload.wikimedia.org/wikipedia/commons/b/b0/New_Zealand_cicada_song.ogg) | Public domain | （作者自释入 PD） | Ogg Vorbis 44.1k 单 25.6s |
| `cicada_florida` | [Florida Cicada Song](https://upload.wikimedia.org/wikipedia/commons/c/c3/Florida_Cicada_Song.ogg) | **CC BY 3.0** | Gatorguy76 | Ogg Vorbis 96k 双 85.7s |
| `cricket_jer` | [Jer-Cricket](https://upload.wikimedia.org/wikipedia/commons/a/a2/Jer-Cricket.ogg) | Public domain | Man vyi | Ogg Vorbis 44k 单 0.8s |
| `stream_swale` | [Swale](https://upload.wikimedia.org/wikipedia/commons/8/84/Swale.ogg) | CC0 | Ksd5 | Ogg Vorbis 48k 单 31.0s |
| `rain_field` | [Light Rain Distant Thunder July 5th 2016](https://upload.wikimedia.org/wikipedia/commons/b/b6/Light_Rain_Distant_Thunder_July_5th_2016.wav) | CC0 | kvgarlic（经 Freesound） | WAV 48k 双 110.1s |
| `sheep` | [Sheep bleating](https://upload.wikimedia.org/wikipedia/commons/1/13/Sheep_bleating.ogg) | Public domain | earthcalling | Ogg Vorbis 44.1k 双 8.2s |
| `village_fowl` | [Chicken Sound Effect](https://opengameart.org/content/chicken-sound-effect) | **CC BY 3.0** | imadeit（OpenGameArt 提交者） | Ogg Vorbis 96k 4ch 3.2s |
| `wave_beach_1..4` | [Beach Ocean Waves](https://opengameart.org/content/beach-ocean-waves) | CC0 | jasinski | FLAC 44.1k 双 4.0/2.5/2.2/3.5s |
| `wave_water_1..4` | [Water Waves](https://opengameart.org/content/water-waves) | CC0 | transitking | FLAC 44.1k 双 1.8/3.2/2.4/2.0s |

---

## 五、CC-BY 署名（上线前必读）

成品中用到 CC-BY 素材的是 **`cicada_summer`** 与 **`village_ambience`**（均经改编：
EQ / 滤波 / 重排 / 与合成层混合）。CC-BY 要求署名并标明做了修改。可直接使用：

> 环境音 `cicada_summer` 与 `village_ambience` 含改编自以下 CC BY 3.0 素材的声音：
> "Florida Cicada Song" by Gatorguy76（Wikimedia Commons）；
> "Chicken Sound Effect" by imadeit（OpenGameArt）。
> 二者均以 CC BY 3.0（https://creativecommons.org/licenses/by/3.0/）提供，已作滤波、
> 均衡、混响与混音改编。

其余素材为 CC0 / Public Domain，无强制署名义务。

---

## 六、体检后淘汰的素材（记录以免重复踩坑）

| 素材 | 许可 | 淘汰原因 |
| --- | --- | --- |
| Rain (1).ogg（ezwa）/ Shallow small river / Medium & Small rooster | PD | **OggPCM**（未压缩 PCM in Ogg，magic `fishead`），libsndfile 1.2 不认 |
| Hemlock stream.ogg | PD | 频谱质心 ≈30Hz，几乎全是 60Hz 以下隆隆声，不是溪流 |
| Крикет.ogg | CC BY 4.0 | 2-5kHz 仅占 0.089、质心 853Hz，低频底噪过重，不适合作蟋蟀床 |
| बारिश.ogg | CC0 | 仅 1.2s，做循环床太短 |
| There's a light breeze.wav | CC0 | 2.7s，同上 |
| En-us-dawn chorus.oga | CC0 | 是"dawn chorus"这个词的**发音**，不是鸟鸣录音 |
| Ambience noise Bengaluru / Sea waves.wav | CC BY-**SA** 4.0 | 许可要求不符合（排除 ShareAlike） |
| Forest ambience (Gravity Sound) | CC BY 4.0 | 2-5k 占比 0.968（高频噪声极强），仅留作兜底 |

archive.org 本机不可达；freesound.org 可达但无 API key，故未取用其素材（未硬来）。

---

## 七、质检总表

`python tools/music/ambience.py --verify` 实测（对写盘后的 WAV 重新计算）：

| layer | LUFS | 真峰 dBTP | 2-5k P95 | 2-5k 均值 | 谱质心 P95 | 接缝分位 | 接缝电平 | 接缝谱通量 | 声道相关 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `wind_calm` | -28.00 | -15.07 | 0.007 | 0.004 | 454 | 80.2% | -51.7 | 0.907 | -0.049 |
| `birds_day` | -28.50 | -11.47 | 0.842 | 0.459 | 3132 | 42.2% | -45.3 | 0.575 | 0.572 |
| `cicada_summer` | -28.00 | -16.69 | 0.720 | 0.590 | 5187 | 1.2% | -60.5 | 0.820 | 0.550 |
| `night_insects` | -28.50 | -9.77 | 0.866 | 0.571 | 4020 | 16.4% | -68.1 | 1.399 | 0.683 |
| `waves_shore` | -27.50 | -12.82 | 0.171 | 0.098 | 1208 | 92.7% | -39.6 | 0.929 | 0.792 |
| `stream_water` | -27.50 | -11.68 | 0.441 | 0.412 | 2667 | 16.4% | -81.5 | 1.022 | 0.003 |
| `rain_soft` | -28.00 | -13.67 | 0.341 | 0.331 | 6212 | 21.0% | -75.7 | 0.957 | 0.008 |
| `village_ambience` | -29.00 | -13.00 | 0.015 | 0.009 | 542 | 68.7% | -42.2 | 1.202 | 0.010 |

（表值由 `--verify` 读回 **写盘后的 PCM_16 WAV** 重算；生成时对 float32 的即时报表
在 `temp/ambience/ambience_report.json`，两者仅因 16bit 量化差零点几个百分点。）

**指标口径**（响度/真峰/谱指标复用 `musiclib.loudness`，ITU-R BS.1770 口径）：

- **LUFS**：积分响度，目标区 −30 ~ −26（环境层是底噪，刻意远低于音乐）。
- **真峰 dBTP**：4× 过采样峰值，上限 −1.5，无一削波。
- **2-5k P95 / 均值**：最响 1 秒帧 / 全程序内 2–5kHz 相对能量（人耳最敏感、刺耳的物理成因）。
- **接缝分位**：`|x[0]−x[n−1]|` 落在**接缝邻域 ±0.5s** 一阶差分分布里的百分位。
  无缝 → 接缝那一步只是行情里的普通一步（≈50）；硬切 → 冲到 ≈100。
  （用局部窗口是因为"这步是否突兀"只跟它周围有关：浪的泡沫迸发里本来就全是大幅步。）
- **接缝电平**：末尾 0.5s 均值 vs 开头 0.5s 均值之差 / RMS（防音量台阶）。
- **接缝谱通量**：`musiclib.loudness.loop_seam_report` 的拼接谱通量 / 段内中位数（≈1 = 无缝）。
- **声道相关**：L/R 皮尔逊相关；=1 表示两声道完全相同（不允许），接近 0 为宽。

**阈值**（默认，单层可在 `LAYERS[...].spec_overrides` 覆写）：

| 指标 | 阈值 | 说明 |
| --- | --- | --- |
| `integrated_lufs` | ∈ [−30, −26] | 硬指标 |
| `true_peak_dbtp` | ≤ −1.5 | 不削波 |
| `band_2_5k_p95` | ≤ 0.30（默认） | 宽频底噪严卡；**鸟/蝉/虫**这类"声源本身就是 2–5kHz"的层放宽到 0.92，雨 0.60、溪 0.55 |
| `band_2_5k_mean` | ≤ 0.65 | 全程序平均占比总闸 |
| `seam_jump_pct` | ≤ 99.9 | 接缝不得是离群步 |
| `seam_level_db` | ≤ −20 | 不得有电平台阶 |
| `seam_flux_ratio` | ≤ 2.0 | 谱通量回到段内水平 |
| `silence_holes` | = 0 | 无 >50ms 静音空洞 |
| `clipped` | = 0 | 无削波样本 |

> 关于 2–5kHz 的说明：鸟叫 / 蝉鸣 / 虫鸣的能量**天然**集中在 2–5kHz，用 0.30 卡它们
> 等于要求毁掉内容。所以这些层用宽闸（0.92），同时仍受"整体 −28 LUFS + 2-5k 均值
> ≤0.65"约束——绝对 2-5k 能量很低。宽带底噪层（风/浪/溪/村）仍按 0.30 严卡。

---

## 八、复现

```bash
PY=C:/Users/fanbo/AppData/Local/Programs/Python/Python312/python.exe
"$PY" tools/music/ambience.py --list              # 看配方
"$PY" tools/music/ambience.py --fetch             # 下源材料（幂等）
"$PY" tools/music/ambience.py                     # 全部生成 + 写盘
"$PY" tools/music/ambience.py --only wind_calm    # 单层
"$PY" tools/music/ambience.py --verify            # 对成品打质检表
```

- 生成是**幂等**的：同 seed 重跑逐字节一致（已用 md5 验证）。
- 输出同时写 `stick-world/assets/audio/ambience/`（交付）与 `temp/ambience/`（临时产物）。
- 缺源材料时自动**纯合成兜底**并照常出片（但那样就不是"融合"了，会少一层真实质感）。

---

## 九、已知不足 / 未能客观验证

- **好不好听、像不像**：无法用代码判断，只做了客观质检（响度/接缝/频谱/无空洞）
  与波形+频谱图人工目检。最终需创始人观感验收。
- **单声道兼容有损**：为满足"左右去相关"，底噪层用了微延迟（8–13ms）去相关，
  折叠单声道会掉约 3–6 LU（耳机/立体声无碍；手机单喇叭会明显变轻）。这是去相关的
  固有代价，如需严格单声道可用 M/S 低频单声道化换取，但会牺牲宽度。
- **`night_insects` 的真实蟋蟀素材很勉强**：唯一可用的蟋蟀录音（0.8s，低频偏重）
  带通后才有脉冲串，只能低电平点缀，主音色来自合成。
- **`waves_shore` 接缝分位 92.7%**：接缝正落在一次泡沫迸发里，该步幅本身在邻域里
  偏大（但仍在随机偏移的零分布内，见 §七 口径），非结构性断裂。
- **`forest_ambience`（CC BY 4.0）只在兜底路径用到**：若日后删掉 CC0 的
  `birds_reveil`，请同步补上 Gravity Sound 的署名。
- **archive.org 不可达、freesound 无 key**：网络路线未覆盖这两处，未使用其素材。
