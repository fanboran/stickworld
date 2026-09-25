"""场层公共函数（世界重生成 v2 A1/A2 共用）

fields_build.py（A1 资源丰度/宜居度/进攻成本场）与 culture_build.py（A2 文化场 v2）
共享的底层工具：
  - 路径常量与参数加载
  - 底图 2048 级读取（与 state_expand_lite.load_inputs 逐位同构的抽取）
  - flood-fill cost 底场构造（state_expand_lite.culture_flood 原表达式的等价抽取，
    表达式顺序与 dtype 保持逐位一致——state_expand_lite 全量重跑产物不变的
    确定性论证；k_* 语义见 state_params.json 的 culture_flood / fields_v2.culture 段）
  - 分辨率缩放（块均值下采样 / bilinear 上采样）
  - FBM 值噪声（多倍频、可选脊状，空间自相关——资源场「成带成片」的载体）
  - 热力图 colormap（预览 png 用，无 matplotlib 依赖）

群系标签（biome_generate.py 同源）：
  0海洋 1平原 2森林 3荒漠 4冰原 5源流 6火山
注意：湖泊水体整体划入源流群系（labels[lake]=SOURCE），凡「陆地」语义需要排除
湖泊时须另行叠加 lake 掩膜（见各调用方）。
"""

import json
import os

import numpy as np
from PIL import Image

SIZE = 2048
SIZE_FULL = 8192
HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(os.path.dirname(HERE), "output")
FIELDS_DIR = os.path.join(OUTPUT_DIR, "fields")
GAME_CFG = os.path.normpath(os.path.join(
    HERE, "..", "..", "..", "stick-world", "config", "strategic_map"))
PARAMS_PATH = os.path.join(HERE, "state_params.json")

BI_OCEAN, BI_PLAIN, BI_FOREST, BI_DESERT, BI_ICE, BI_SOURCE, BI_VOLCANIC = range(7)
BI_NAMES = ["海洋", "平原", "森林", "荒漠", "冰原", "源流", "火山"]

# 生计模式枚举（A2 文化源点属性）
LIVELIHOODS = ["农耕", "游牧", "渔猎", "商贸"]
# 地形偏好向量维度（A2；与 terrain_pref 键序一致）
TERRAIN_KEYS = ["plain", "forest", "mountain", "desert", "ice", "coast"]


def load_params():
    with open(PARAMS_PATH, encoding="utf-8") as f:
        return json.load(f)


# ---------- 底图读取（2048 级，与 state_expand_lite.load_inputs 逐位同构） ----------

def load_elev_2048():
    """8192 高程 → 2048 块均值（float32）。与 state_expand_lite 同式。"""
    hm = np.load(os.path.join(OUTPUT_DIR, "fractal_heightmap_8192.npy"))
    k = SIZE_FULL // SIZE
    return hm.reshape(SIZE, k, SIZE, k).mean(axis=(1, 3)).astype(np.float32)


def load_river_2048():
    """8192 河流掩膜 → 2048 NEAREST 缩放 >127（bool）。与 state_expand_lite 同式。"""
    river = np.array(Image.open(
        os.path.join(OUTPUT_DIR, "fractal_river_mask_8192.png")).convert("L"))
    return np.asarray(
        Image.fromarray(river).resize((SIZE, SIZE), Image.NEAREST)) > 127


def build_flood_cost(elev, river, biome, k_slope, k_river, k_desert, k_ice):
    """flood-fill cost 底场（culture_flood / culture_build 共用）。

    base = 1 + k_slope*|∇elev| + k_river*河 + k_desert*荒漠 + k_ice*冰原，
    海洋置 1e6。返回 (base float64, land bool)。
    表达式顺序与 dtype 与 R7 原实现逐位一致（等价抽取，行为不变）。
    """
    gy, gx = np.gradient(elev)
    gradmag = np.sqrt(gy * gy + gx * gx)
    land = biome > 0
    base = (1.0 + k_slope * gradmag + k_river * river
            + k_desert * (biome == BI_DESERT) + k_ice * (biome == BI_ICE))
    base = np.where(land, base, 1e6).astype(np.float64)
    return base, land


# ---------- 分辨率缩放 ----------

def downsample_mean(arr, size_out):
    """块均值下采样（size_out 须整除 arr 边长），float32。"""
    k = arr.shape[0] // size_out
    return arr.reshape(size_out, k, size_out, k).mean(axis=(1, 3)).astype(np.float32)


def upsample_bilinear(arr, size_out):
    """连续场 bilinear 上采样（PIL 'F' 模式，确定性；返回可写数组）。"""
    img = Image.fromarray(np.asarray(arr, dtype=np.float32))
    return np.array(img.resize((size_out, size_out), Image.BILINEAR),
                    dtype=np.float32)


def resize_grid(grid, shape_hw):
    """小网格 bilinear 放大到任意 (h, w)（FBM 倍频用，保持横纵比）。"""
    h, w = shape_hw
    img = Image.fromarray(np.ascontiguousarray(grid, dtype=np.float32))
    return np.asarray(img.resize((w, h), Image.BILINEAR), dtype=np.float32)


def upsample_nearest(arr, size_out):
    """标签场上采样（np.repeat 块复制，精确最近邻；仅允许整数倍放大）。"""
    if size_out <= arr.shape[0] or size_out % arr.shape[0] != 0:
        raise ValueError(
            "upsample_nearest 只支持整数倍放大（%d -> %d）" % (arr.shape[0], size_out))
    k = size_out // arr.shape[0]
    return np.repeat(np.repeat(arr, k, axis=0), k, axis=1)


def downsample_mask_max(mask, size_out):
    """掩膜 max-pool 下采样（size_out 须整除边长；预览描线用）。"""
    k = mask.shape[0] // size_out
    return mask.reshape(size_out, k, size_out, k).any(axis=(1, 3))


# ---------- FBM 值噪声（资源场空间自相关的载体） ----------

def fbm(shape, rng, spec):
    """多倍频值噪声 FBM ∈ [0,1]（bilinear 上采样，天然空间自相关）。

    spec: base_freq（最低频网格数）/ octaves / gain / lacunarity / ridged。
    每倍频：随机网格（带随机 pan pad + 随机翻转，打散网格对齐痕迹）→
    bilinear 放大 →（可选）脊状变换 1-|2n-1|（矿脉「成带」用）。
    rng 由调用方提供（np.random.Generator），同 seed 逐位确定。
    """
    h, w = shape
    out = np.zeros(shape, dtype=np.float32)
    amp = 1.0
    freq = float(spec["base_freq"])
    norm = 0.0
    for _ in range(int(spec["octaves"])):
        gh = max(2, int(round(freq)))
        gw = max(2, int(round(freq * w / h)))
        pad = 2
        g = rng.random((gh + pad, gw + pad)).astype(np.float32)
        oy = int(rng.integers(0, pad))
        ox = int(rng.integers(0, pad))
        g = g[oy:oy + gh, ox:ox + gw]
        if rng.random() < 0.5:
            g = g[:, ::-1]
        if rng.random() < 0.5:
            g = g[::-1, :]
        up = resize_grid(g, shape)
        if spec.get("ridged", False):
            up = 1.0 - np.abs(2.0 * up - 1.0)
        out += amp * up
        norm += amp
        amp *= float(spec["gain"])
        freq *= float(spec["lacunarity"])
    return out / norm


# ---------- 预览 colormap（无 matplotlib 依赖） ----------

HEAT_STOPS = [  # 宜居度：深蓝→青→绿→黄→米白（rgb 分量 0..1）
    (0.00, (0.04, 0.055, 0.16)), (0.20, (0.12, 0.24, 0.48)),
    (0.40, (0.13, 0.48, 0.46)), (0.60, (0.44, 0.64, 0.24)),
    (0.80, (0.89, 0.71, 0.24)), (1.00, (0.96, 0.94, 0.85)),
]
COST_STOPS = [  # 成本：暗→蓝灰→赭→亮黄（低=易攻，高=难攻）
    (0.00, (0.10, 0.11, 0.17)), (0.25, (0.24, 0.28, 0.44)),
    (0.50, (0.56, 0.36, 0.24)), (0.75, (0.87, 0.60, 0.20)),
    (1.00, (0.98, 0.94, 0.78)),
]


def colormap(values01, stops):
    """values01∈[0,1] → RGB uint8（按 stops 线性插值；stops 的 rgb 分量为 0..1）。"""
    v = np.clip(np.asarray(values01, dtype=np.float64), 0.0, 1.0)
    pos = np.array([s[0] for s in stops], dtype=np.float64)
    rgb = np.empty(v.shape + (3,), dtype=np.uint8)
    for c in range(3):
        chan = np.interp(v, pos, np.array([s[1][c] for s in stops],
                                          dtype=np.float64))
        rgb[..., c] = (np.clip(chan, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    return rgb


def fit_font(size):
    """预览中文字体（微软雅黑，失败退默认点阵）。"""
    from PIL import ImageFont
    try:
        return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)
    except OSError:
        return ImageFont.load_default()
