"""
归档 preview 文件到 reference/history/ 目录。
用法：python archive_preview.py [preview_thatch.png]
不带参数则归档 reference/ 下所有 preview_*.png
"""
import os
import shutil
import datetime
import glob
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# tools/py → 上两级到 building_gen
BUILDING_GEN = os.path.normpath(os.path.join(SCRIPT_DIR, "..", ".."))
REF_DIR = os.path.join(BUILDING_GEN, "reference")
HISTORY_DIR = os.path.join(REF_DIR, "history")
os.makedirs(HISTORY_DIR, exist_ok=True)

def archive(name):
    src = os.path.join(REF_DIR, name)
    if not os.path.isfile(src):
        return
    # 如果文件名已有 v2 后缀（如 preview_thatch_v2.png），去掉再加时间戳
    base = re.sub(r'_v\d+$', '', os.path.splitext(name)[0])
    ext = os.path.splitext(name)[1]
    ts = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dst_name = f"{base}_{ts}{ext}"
    dst = os.path.join(HISTORY_DIR, dst_name)
    shutil.move(src, dst)
    print(f"  归档: {name} → history/{dst_name}")

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        # 归档指定文件
        for arg in sys.argv[1:]:
            archive(arg)
    else:
        # 归档所有 preview_*.png
        for f in glob.glob(os.path.join(REF_DIR, "preview_*.png")):
            archive(os.path.basename(f))
    print("归档完成")
