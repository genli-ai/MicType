#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 MicType 自带的 4 个提示音（MicType/Resources/Sounds/*.wav）。

为什么要自带而不是用系统的 Pop / Glass / Basso / Bottle：
1) 系统警告音是"出事了"的语义，语音输入每天要响几十次，太吵、也容易和别的 App 撞车；
2) 用户可以在系统设置里换掉警告音，我们就完全失去了对提示音的控制；
3) 开始音会被自己的麦克风录进去，必须做得又短又轻（这里全部 <= 200ms、峰值约 -14 dBFS）。

只用 Python 3 标准库（wave + math），无 numpy。改了参数就重跑：
    python3 "scripts/generate_sounds.py"
生成的 wav 是仓库里的产物（几十 KB），直接提交。
"""

import math
import os
import struct
import wave

SAMPLE_RATE = 44100
MAX_MS = 200  # 硬上限：每个音都必须比这短，否则开始音会压住用户开口的第一个字


def _blank(ms):
    return [0.0] * int(SAMPLE_RATE * ms / 1000.0)


def _env(i, n, attack_ms, release_ms):
    """两端用升余弦淡入淡出，避免咔哒声（方波边沿）。"""
    a = max(1, int(SAMPLE_RATE * attack_ms / 1000.0))
    r = max(1, int(SAMPLE_RATE * release_ms / 1000.0))
    if i < a:
        return 0.5 - 0.5 * math.cos(math.pi * i / a)
    if i > n - r:
        j = n - i
        return 0.5 - 0.5 * math.cos(math.pi * j / r)
    return 1.0


def tone(buf, start_ms, dur_ms, f0, f1=None, amp=0.2,
         attack_ms=6.0, release_ms=25.0, harmonic=0.0, decay=0.0):
    """把一个（可滑音的）正弦叠加进 buf。

    f1 非 None 时从 f0 线性滑到 f1；harmonic 是二次谐波比例（给一点点亮度，
    纯正弦听起来太"电子"）；decay > 0 时整体再乘一条指数衰减包络。
    """
    n = int(SAMPLE_RATE * dur_ms / 1000.0)
    off = int(SAMPLE_RATE * start_ms / 1000.0)
    if len(buf) < off + n:
        buf.extend([0.0] * (off + n - len(buf)))
    phase = 0.0
    for i in range(n):
        t = i / float(n)
        f = f0 if f1 is None else (f0 + (f1 - f0) * t)
        phase += 2.0 * math.pi * f / SAMPLE_RATE
        s = math.sin(phase) + harmonic * math.sin(2.0 * phase)
        e = _env(i, n, attack_ms, release_ms)
        if decay > 0.0:
            e *= math.exp(-decay * (i / float(SAMPLE_RATE)))
        buf[off + i] += amp * e * s


def write_wav(path, buf, peak=0.22):
    """归一化到目标峰值后写 44.1kHz / 16bit / 单声道。"""
    hi = max((abs(x) for x in buf), default=0.0)
    gain = (peak / hi) if hi > 0 else 0.0
    frames = bytearray()
    for x in buf:
        v = int(max(-1.0, min(1.0, x * gain)) * 32767.0)
        frames += struct.pack('<h', v)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(bytes(frames))
    ms = len(buf) * 1000.0 / SAMPLE_RATE
    assert ms <= MAX_MS + 0.5, '%s too long: %.1fms' % (path, ms)
    print('  %-12s %6.1f ms  %6d bytes' % (os.path.basename(path), ms, len(frames)))


def build_start():
    """开始音：两声上行（E5 -> A5），最短最轻的一个——它一定会被麦克风听见一点。"""
    buf = _blank(150)
    tone(buf, 0, 62, 659.25, amp=0.55, release_ms=22, harmonic=0.10)
    tone(buf, 58, 88, 880.00, amp=0.75, release_ms=40, harmonic=0.08, decay=6.0)
    return buf, 0.20


def build_success():
    """完成音：三声上行小和弦（A5-C#6-E6），轻、带衰减，像轻敲玻璃而不是系统警报。"""
    buf = _blank(200)
    tone(buf, 0, 70, 880.00, amp=0.55, release_ms=30, harmonic=0.12, decay=9.0)
    tone(buf, 52, 78, 1108.73, amp=0.62, release_ms=34, harmonic=0.10, decay=9.0)
    tone(buf, 110, 88, 1318.51, amp=0.70, release_ms=52, harmonic=0.08, decay=8.0)
    return buf, 0.22


def build_error():
    """错误音：两下低而闷的短音（A3），只用基频 + 很少谐波，够醒目但不刺耳。"""
    buf = _blank(200)
    tone(buf, 0, 72, 220.00, amp=0.80, attack_ms=8, release_ms=32, harmonic=0.04, decay=10.0)
    tone(buf, 104, 92, 207.65, amp=0.80, attack_ms=8, release_ms=42, harmonic=0.04, decay=9.0)
    return buf, 0.24


def build_cancel():
    """取消音：一声下滑（F5 -> A#4），语义上"收回去了"，不带任何警告色彩。"""
    buf = _blank(130)
    tone(buf, 0, 126, 698.46, f1=466.16, amp=0.80, attack_ms=6, release_ms=60,
         harmonic=0.06, decay=7.0)
    return buf, 0.20


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(os.path.dirname(here), 'MicType', 'Resources', 'Sounds')
    os.makedirs(out, exist_ok=True)
    print('Writing to %s' % out)
    for name, builder in (('start', build_start), ('success', build_success),
                          ('error', build_error), ('cancel', build_cancel)):
        buf, peak = builder()
        write_wav(os.path.join(out, name + '.wav'), buf, peak=peak)


if __name__ == '__main__':
    main()
