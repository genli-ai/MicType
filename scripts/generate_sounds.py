#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""5.2.0 提示音家族：重做 MicType/Resources/Sounds/ 下的 4 个 wav。

为什么重做（设计方案 G「声音」）：旧的 4 个音是各自调出来的（滑音、谐波、响度都不一样），
听起来像四个不同的 App。这一版是**一个乐器、一个调（D 大调）**：
  开始 = D5 → A5 上行两音（各 90 ms）   —— "我在听了"
  完成 = A5 → D5 下行两音（各 90 ms）   —— 开始音倒过来，一问一答
  取消 = D5 单音 70 ms                 —— 最短、不带方向
  错误 = D3 两下（各 60 ms，中间空 80 ms）—— 低八度、双击，一听就知道不对
乐器：正弦 + 一点三角波（给一点木质的亮度，纯正弦太"电子"），5 ms 起音、指数衰减，
每个音尾巴再做 3 ms 余弦收口（衰减到这里已经很小，收口只为消掉最后那一下咔哒）。
响度：每个文件峰值统一归一到 -20 dBFS。
时长：全部 ≤ 200 ms——开始音会被自己的麦克风录进去（DictationController.startCueGateSeconds
按 0.35 s 挡回声），不能再长。

只用 Python 3 标准库（wave + math）。可复跑：
    python3 scripts/generate_sounds.py
生成的 wav 是仓库里的产物（几 KB 到二十来 KB），直接提交。
"""

import math
import os
import struct
import wave

SAMPLE_RATE = 48000
PEAK_DBFS = -20.0
TRIANGLE_MIX = 0.18      # 三角波占比：再多就开始像 8-bit 游戏机
ATTACK_MS = 5.0
RELEASE_MS = 3.0
DECAY_TAU_MS = 38.0      # 指数衰减时间常数：90 ms 的音到尾巴约剩 1/10

# D 大调里要用到的几个音（十二平均律，A4 = 440 Hz）
D3 = 146.83
D5 = 587.33
A5 = 880.00


def triangle(phase):
    """相位 0–1 的三角波，幅度 ±1"""
    return 4.0 * abs(phase - math.floor(phase + 0.5)) - 1.0


def note(freq, dur_ms):
    """一个音：正弦 + 少量三角波，5 ms 线性起音 + 指数衰减 + 3 ms 余弦收口"""
    n = int(SAMPLE_RATE * dur_ms / 1000.0)
    attack = max(1, int(SAMPLE_RATE * ATTACK_MS / 1000.0))
    release = max(1, int(SAMPLE_RATE * RELEASE_MS / 1000.0))
    tau = SAMPLE_RATE * DECAY_TAU_MS / 1000.0
    out = []
    for i in range(n):
        t = i / SAMPLE_RATE
        s = (1.0 - TRIANGLE_MIX) * math.sin(2 * math.pi * freq * t) \
            + TRIANGLE_MIX * triangle(freq * t)
        env = math.exp(-i / tau)
        if i < attack:
            env *= i / attack
        if i >= n - release:
            j = n - i
            env *= 0.5 - 0.5 * math.cos(math.pi * j / release)
        out.append(s * env)
    return out


def silence(ms):
    return [0.0] * int(SAMPLE_RATE * ms / 1000.0)


def normalize(samples):
    peak = max(abs(s) for s in samples) or 1.0
    target = 10 ** (PEAK_DBFS / 20.0)
    return [s * target / peak for s in samples]


def write(path, samples):
    samples = normalize(samples)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(
            struct.pack("<h", int(round(max(-1.0, min(1.0, s)) * 32767))) for s in samples))
    print("%-12s %4d ms" % (os.path.basename(path), len(samples) * 1000 // SAMPLE_RATE))


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.normpath(os.path.join(here, "..", "MicType", "Resources", "Sounds"))
    os.makedirs(out_dir, exist_ok=True)
    cues = {
        "start.wav": note(D5, 90) + note(A5, 90),
        "success.wav": note(A5, 90) + note(D5, 90),
        "cancel.wav": note(D5, 70),
        "error.wav": note(D3, 60) + silence(80) + note(D3, 60),
    }
    for name, samples in cues.items():
        assert len(samples) * 1000 // SAMPLE_RATE <= 200, name
        write(os.path.join(out_dir, name), samples)


if __name__ == "__main__":
    main()
