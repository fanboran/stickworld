# -*- coding: utf-8 -*-
"""Terraria 音效 XNB 提取器 —— XNA SoundEffectReader 数据段 → WAV。

用途：为私有演示版提取参考音效（已在 docs/项目/素材替换清单.md 登记，
公开/上架前替换为无版权资产）。XNB 为未压缩容器（flags=0），
SoundEffectReader 数据布局：fmt 组 → data size → PCM → loop(忽略)。
布局存在版本差异，采用"合法字段扫描"策略：在 reader 串后的数据段中找
  formatTag(1=PCM) channels(1/2) sampleRate(合法集) avgBytes blockAlign bits
连续合法的位置作为 fmt 起点。

用法：python extract_terraria_sfx.py <Sound.xnb> <out.wav> [文件2 wav2 ...]
"""
import struct
import sys
import wave

VALID_RATES = (22050, 44100, 48000, 32000, 11025, 24000)


def parse_xnb(data: bytes):
    if data[:3] != b"XNB":
        raise ValueError("not XNB")
    flags = data[6]
    if flags & 0x80:
        raise ValueError("compressed XNB (LZX) not supported")
    # 7-bit 编码读取器数量
    pos = 10
    n_readers, pos = _read_7bit(data, pos)
    for _ in range(n_readers):
        ln, pos = _read_7bit(data, pos)
        pos += ln          # reader 名
        pos += 4           # reader 版本
    n_shared, pos = _read_7bit(data, pos)
    if n_shared != 0:
        raise ValueError("shared resources unexpected")
    return pos


def _read_7bit(data, pos):
    result = shift = 0
    while True:
        b = data[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7


def extract(xnb_path: str, wav_path: str) -> str:
    data = open(xnb_path, "rb").read()
    pos = parse_xnb(data)
    # 在数据段内扫描合法 fmt 组合（最多前 64B 内）
    for off in range(pos, min(pos + 64, len(data) - 24), 1):
        (tag, ch, rate, avg, block, bits) = struct.unpack_from("<hhihhh", data, off)
        if tag != 1 or ch not in (1, 2) or rate not in VALID_RATES:
            continue
        if bits not in (8, 16) or block != ch * bits // 8:
            continue
        if avg != rate * block:
            continue
        size = struct.unpack_from("<i", data, off + 14)[0]
        if size <= 0 or off + 18 + size > len(data):
            continue
        pcm = data[off + 18: off + 18 + size]
        with wave.open(wav_path, "wb") as f:
            f.setnchannels(ch)
            f.setsampwidth(bits // 8)
            f.setframerate(rate)
            f.writeframes(pcm)
        return "%s: %dch %dHz %dbit %.2fs" % (
            wav_path.split("\\")[-1], ch, rate, bits, size / (rate * block))
    raise ValueError("fmt anchor not found in " + xnb_path)


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) < 2 or len(args) % 2 != 0:
        print(__doc__)
        sys.exit(1)
    for i in range(0, len(args), 2):
        print("[xnb]", extract(args[i], args[i + 1]))
