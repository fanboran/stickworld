"""
对 smithy_lv1_thatch.png 叠加位置约束：
  y < 380  全保留（纯茅草顶）
  y > 420  全透明（切断木架）
  380~420  线性过渡
"""

import sys
from pathlib import Path

import numpy as np
from PIL import Image

SRC = Path(r"F:\VSCode\game-2\stick-world\modules\old_buildings\assets\smithy_lv1_thatch.png")

Y_KEEP = 380
Y_CUT = 420


def main():
    img = Image.open(SRC).convert("RGBA")
    arr = np.array(img)
    h, w = arr.shape[:2]

    y_idx = np.arange(h)[:, None]
    keep = y_idx < Y_KEEP
    fade = (y_idx >= Y_KEEP) & (y_idx < Y_CUT)
    fade_val = 1.0 - (y_idx[..., 0] - Y_KEEP) / (Y_CUT - Y_KEEP)

    new_alpha = np.where(
        keep, arr[:, :, 3],
        np.where(fade, (arr[:, :, 3] * fade_val[:, None]).astype(np.uint8), 0),
    )
    arr[:, :, 3] = new_alpha

    out = Image.fromarray(arr)
    out.save(SRC, "PNG")

    kept_px = int((new_alpha > 0).sum())
    print(f"[DONE]  {SRC.name}  (前景: {kept_px:,} px  |  切分线: y={Y_KEEP}~{Y_CUT})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
