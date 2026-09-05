# -*- coding: utf-8 -*-
"""Terraria 音效 XNB 提取器 —— XNA SoundEffectReader 布局 → WAV。

用途：为私有演示版提取参考音效（已在 docs/项目/素材替换清单.md 登记，
公开/上架前替换为无版权资产）。XNB 为未压缩容器（flags=0）。

Terraria XNB 实测布局（Dig_0/Menu_Tick hexdump 验证，字节严丝合缝）：
  "XNB" + platform + version + flags   (6B)
  uint32 文件总长                      ← 非公开规范字段，漏掉它会导致后续全部错位
  7bit readerCount
    每 reader: 7bit 名长 + 名 + int32 版本
  7bit sharedResourceCount (恒 0)
  7bit 对象 readerIndex (恒 1)
  --- SoundEffect 载荷 ---
  int32 fmtSize (=18)
  WAVEFORMATEX fmtSize 字节: tag(i16) ch(i16) rate(i32) avg(i32) block(i16) bits(i16) cbSize(i16)
  uint32 dataLen
  byte[dataLen] PCM
  尾部 4B（duration/loop 元数据，忽略）
avgBytesPerSec 一律不校验（Terraria 历史版本填过非标值）。

用法：python extract_terraria_sfx.py <Sound.xnb> <out.wav> [文件2 wav2 ...]
"""
import struct
import sys
import wave

VALID_RATES = (22050, 44100, 48000, 32000, 11025, 24000)


def _read_7bit(data, pos):
    result = shift = 0
    while True:
        b = data[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7


def parse_xnb(data: bytes) -> int:
    """跳过 XNB 头与 readers，返回 SoundEffect 载荷起点。"""
    if data[:3] != b"XNB":
        raise ValueError("not XNB")
    flags = data[5]
    if flags & 0x80:
        raise ValueError("compressed XNB (LZX) not supported")
    pos = 10
    n_readers, pos = _read_7bit(data, pos)
    for _ in range(n_readers):
        ln, pos = _read_7bit(data, pos)
        pos += ln          # reader 名
        pos += 4           # reader 版本
    n_shared, pos = _read_7bit(data, pos)
    if n_shared != 0:
        raise ValueError("shared resources unexpected")
    reader_idx, pos = _read_7bit(data, pos)   # 对象的 reader 索引（1 基）
    if reader_idx < 1:
        raise ValueError("bad reader index")
    return pos


def extract(xnb_path: str, wav_path: str) -> str:
    data = open(xnb_path, "rb").read()
    pos = parse_xnb(data)
    # fmt 组
    fmt_size = struct.unpack_from("<i", data, pos)[0]
    if not 16 <= fmt_size <= 40:
        raise ValueError("bad fmtSize %d in %s" % (fmt_size, xnb_path))
    (tag, ch, rate, avg, block, bits) = struct.unpack_from("<hhIihh", data, pos + 4)
    if tag != 1 or ch not in (1, 2) or rate not in VALID_RATES:
        raise ValueError("bad fmt: tag=%d ch=%d rate=%d (%s)" % (tag, ch, rate, xnb_path))
    if bits not in (8, 16) or block != ch * bits // 8:
        raise ValueError("bad block/bits: %d/%d (%s)" % (block, bits, xnb_path))
    # PCM
    p = pos + 4 + fmt_size
    size = struct.unpack_from("<i", data, p)[0]
    if size <= 0 or p + 4 + size > len(data):
        raise ValueError("bad dataLen %d (%s)" % (size, xnb_path))
    pcm = data[p + 4: p + 4 + size]
    with wave.open(wav_path, "wb") as f:
        f.setnchannels(ch)
        f.setsampwidth(bits // 8)
        f.setframerate(rate)
        f.writeframes(pcm)
    return "%s: %dch %dHz %dbit %.2fs" % (
        wav_path.replace("\\", "/").split("/")[-1], ch, rate, bits, size / (rate * block))


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) < 2 or len(args) % 2 != 0:
        print(__doc__)
        sys.exit(1)
    for i in range(0, len(args), 2):
        print("[xnb]", extract(args[i], args[i + 1]))
