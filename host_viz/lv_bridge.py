# -*- coding: utf-8 -*-
"""
lv_bridge.py —— 给 LabVIEW 用的 Python 后端桥
================================================================
用途：如果 LabVIEW 的 Python Node 能用（LabVIEW 2018+ 支持，
      2024 版一般支持 Python 3.6~3.11），就把本文件的函数直接挂到
      Python Node 上，前面板只负责画图 —— 搭建量非常小。

若 Python Node 用不了（比如你是 Python 3.12），请走"纯 G"路线，
见《LabVIEW搭建指南.md》的方案 A。

设计原则：
  * 所有函数只返回 **简单的数值数组或字符串**，避免 LabVIEW 不认识的类型
  * 帧头信息（音色/键/声部/效果）打包进同一个数组，LabVIEW 里用
    "索引数组" 取前 4 个数，用 "数组子集" 取后面的采样
  * 没有 pyserial 依赖：用 ctypes 直接调 Win32 串口 API

依赖：只用标准库（ctypes） + numpy（算 FFT 用）
================================================================
"""

import ctypes
from ctypes import wintypes
import time

import numpy as np

FS = 52734.375          # 采样率，与 FPGA 的 I2S 一致
FRAME_LEN = 520         # 每帧字节数
N_SAMP = 512            # 每帧采样数
HDR = 8                 # 帧头字节数

HEAD1 = 0xA5
HEAD2 = 0x5A


# ---------------------------------------------------------------------------
#  Win32 串口（最小实现）
# ---------------------------------------------------------------------------
_k32 = ctypes.WinDLL("kernel32", use_last_error=True)


class _DCB(ctypes.Structure):
    _fields_ = [
        ("DCBlength", wintypes.DWORD), ("BaudRate", wintypes.DWORD),
        ("fBinary", wintypes.DWORD, 1), ("fParity", wintypes.DWORD, 1),
        ("fOutxCtsFlow", wintypes.DWORD, 1), ("fOutxDsrFlow", wintypes.DWORD, 1),
        ("fDtrControl", wintypes.DWORD, 2), ("fDsrSensitivity", wintypes.DWORD, 1),
        ("fTXContinueOnXoff", wintypes.DWORD, 1), ("fOutX", wintypes.DWORD, 1),
        ("fInX", wintypes.DWORD, 1), ("fErrorChar", wintypes.DWORD, 1),
        ("fNull", wintypes.DWORD, 1), ("fRtsControl", wintypes.DWORD, 2),
        ("fAbortOnError", wintypes.DWORD, 1), ("fDummy2", wintypes.DWORD, 17),
        ("wReserved", wintypes.WORD), ("XonLim", wintypes.WORD),
        ("XoffLim", wintypes.WORD), ("ByteSize", wintypes.BYTE),
        ("Parity", wintypes.BYTE), ("StopBits", wintypes.BYTE),
        ("XonChar", ctypes.c_char), ("XoffChar", ctypes.c_char),
        ("ErrorChar", ctypes.c_char), ("EofChar", ctypes.c_char),
        ("EvtChar", ctypes.c_char), ("wReserved1", wintypes.WORD),
    ]


class _COMMTIMEOUTS(ctypes.Structure):
    _fields_ = [
        ("ReadIntervalTimeout", wintypes.DWORD),
        ("ReadTotalTimeoutMultiplier", wintypes.DWORD),
        ("ReadTotalTimeoutConstant", wintypes.DWORD),
        ("WriteTotalTimeoutMultiplier", wintypes.DWORD),
        ("WriteTotalTimeoutConstant", wintypes.DWORD),
    ]


def list_ports():
    """列出可用串口名，返回字符串数组（LabVIEW 里可直接喂给下拉框）"""
    import winreg
    ports = []
    try:
        key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                             r"HARDWARE\DEVICEMAP\SERIALCOMM")
        i = 0
        while True:
            try:
                _name, value, _typ = winreg.EnumValue(key, i)
                ports.append(value)
                i += 1
            except OSError:
                break
        winreg.CloseKey(key)
    except OSError:
        pass
    return sorted(set(ports))


class _Port:
    def __init__(self, name, baud=115200):
        self.handle = _k32.CreateFileW(
            "\\\\.\\" + name, 0x80000000 | 0x40000000, 0, None, 3, 0, None)
        if self.handle == ctypes.c_void_p(-1).value:
            raise OSError(f"打不开串口 {name}")
        dcb = _DCB()
        dcb.DCBlength = ctypes.sizeof(_DCB)
        _k32.GetCommState(self.handle, ctypes.byref(dcb))
        dcb.BaudRate = baud
        dcb.ByteSize = 8
        dcb.Parity = 0
        dcb.StopBits = 0
        dcb.fBinary = 1
        dcb.fParity = 0
        dcb.fOutxCtsFlow = 0
        dcb.fOutxDsrFlow = 0
        dcb.fDtrControl = 1
        dcb.fDsrSensitivity = 0
        dcb.fOutX = 0
        dcb.fInX = 0
        dcb.fRtsControl = 1
        _k32.SetCommState(self.handle, ctypes.byref(dcb))
        _k32.SetCommTimeouts(self.handle, ctypes.byref(_COMMTIMEOUTS(50, 0, 50, 0, 0)))

    def read(self, n=1024):
        buf = ctypes.create_string_buffer(n)
        got = ctypes.c_ulong(0)
        ok = _k32.ReadFile(self.handle, buf, n, ctypes.byref(got), None)
        if not ok or got.value == 0:
            return b""
        return buf.raw[:got.value]

    def close(self):
        try:
            _k32.CloseHandle(self.handle)
        except Exception:                                   # noqa: BLE001
            pass


# ---------------------------------------------------------------------------
#  帧解码（纯函数，方便自测）
# ---------------------------------------------------------------------------
def decode_frame(f):
    """把 520 字节帧解成 [timbre, keys, voices, effect, s0..s511]（516 个数）"""
    if len(f) < FRAME_LEN or f[0] != HEAD1 or f[1] != HEAD2:
        return []
    timbre = f[2] & 0x03
    keys = f[3] | ((f[4] & 0x0F) << 8)
    voices = f[5] & 0x0F
    effect = f[7] & 0x03
    raw = np.frombuffer(bytes(f[HDR:FRAME_LEN]), dtype=np.uint8).astype(np.float64)
    samples = (raw - 128.0) / 128.0
    out = [float(timbre), float(keys), float(voices), float(effect)]
    out.extend(samples.tolist())
    return out


def read_frame(port="COM7", timeout_ms=2000):
    """
    从串口读一帧。
    返回 list[516]：前 4 个是 [音色, 键状态, 声部数, 效果器]，后面 512 个采样。
    失败返回空数组 []（LabVIEW 里判断"数组大小 = 0"即可）。
    """
    try:
        p = _Port(port, 115200)
    except OSError:
        return []

    buf = bytearray()
    t0 = time.time()
    try:
        while (time.time() - t0) * 1000 < timeout_ms:
            buf.extend(p.read(1024))
            i = buf.find(b"\xA5\x5A")
            if i < 0:
                if len(buf) > 4096:
                    del buf[:-2]
                continue
            if i > 0:
                del buf[:i]
            if len(buf) < FRAME_LEN:
                continue
            return decode_frame(buf[:FRAME_LEN])
    finally:
        p.close()
    return []


# ---------------------------------------------------------------------------
#  后处理（给 LabVIEW 画图用）
# ---------------------------------------------------------------------------
def spectrum(samples, n_bands=32):
    """
    对 512 个采样做 FFT，压成 n_bands 个对数频带（0~1 归一化）。
    LabVIEW 里直接把这个数组喂给柱状图 / 频谱图。
    """
    s = np.asarray(samples, dtype=np.float64)
    if s.size < 8:
        return [0.0] * n_bands
    n = s.size
    win = np.hanning(n)
    mag = np.abs(np.fft.rfft(s * win))
    freqs = np.fft.rfftfreq(n, 1.0 / FS)
    keep = freqs >= 60.0
    mag, freqs = mag[keep], freqs[keep]
    if mag.size and mag.max() > 1e-9:
        mag = mag / mag.max()
    edges = np.logspace(np.log10(60.0), np.log10(16000.0), n_bands + 1)
    out = []
    for b in range(n_bands):
        sel = (freqs >= edges[b]) & (freqs < edges[b + 1])
        out.append(float(mag[sel].max()) if sel.any() else 0.0)
    return out


def lissajous_xy(samples):
    """
    生成李萨如的 XY 数据，返回交错数组 [x0,y0,x1,y1,...]（共 2N 个）。
    LabVIEW 里用"抽取数组"拆成两路，或者每两个取一个。
    """
    s = np.asarray(samples, dtype=np.float64)
    if s.size < 8:
        return []
    q = max(1, s.size // 4)
    x = s[:-q]
    y = s[q:]
    pk = max(1e-9, float(np.max(np.abs(s))))
    x = x / pk * 0.95
    y = y / pk * 0.95
    out = []
    for a, b in zip(x.tolist(), y.tolist()):
        out.append(a)
        out.append(b)
    return out


def note_name(keys):
    """键状态 → 音名（给状态栏用）。返回字符串。"""
    names = ["C4", "C#4", "D4", "D#4", "E4", "F4", "F#4",
             "G4", "G#4", "A4", "A#4", "B4"]
    hit = [names[i] for i in range(12) if (int(keys) >> i) & 1]
    return ",".join(hit) if hit else "——"


def timbre_name(t):
    return ["三角波", "方波", "锯齿波", "脉冲波"][int(t) & 3]


# ---------------------------------------------------------------------------
#  自测（不需要板子）
# ---------------------------------------------------------------------------
def selftest():
    print("=" * 60)
    print(" lv_bridge 自测（用合成帧，不需要板子）")
    print("=" * 60)
    print("可用串口:", list_ports())

    # 造一个 3 音和弦的假帧
    t = np.arange(N_SAMP) / FS
    sig = np.zeros(N_SAMP)
    for f in (261.63, 329.63, 392.00):
        ph = (t * f) % 1.0
        sig += 4.0 * np.abs(ph - 0.5) - 1.0
    sig /= 3.0
    raw = np.clip(sig * 127 + 128, 0, 255).astype(np.uint8)

    keys = (1 << 0) | (1 << 4) | (1 << 7)      # C4 + E4 + G4
    frame = bytes([HEAD1, HEAD2, 0, keys & 0xFF, (keys >> 8) & 0x0F, 3, 0, 0]) + raw.tobytes()
    assert len(frame) == FRAME_LEN

    v = decode_frame(frame)
    print(f"解码结果长度 : {len(v)} （应为 516）")
    print(f"音色={int(v[0])} ({timbre_name(v[0])})  键=0x{int(v[1]):03X} "
          f"({note_name(v[1])})  声部={int(v[2])}  效果={int(v[3])}")

    smp = v[4:]
    print(f"采样范围     : {min(smp):+.3f} ~ {max(smp):+.3f} （应约 -1 ~ +1）")

    sp = spectrum(smp)
    top = sorted(range(len(sp)), key=lambda i: -sp[i])[:3]
    print(f"频谱 {len(sp)} 频带，最强的 3 个: " +
          ", ".join(f"带{i}={sp[i]:.2f}" for i in top))

    xy = lissajous_xy(smp)
    print(f"李萨如数据长度: {len(xy)} （应为 2×{N_SAMP - N_SAMP // 4} = {(N_SAMP - N_SAMP // 4) * 2}）")
    print()
    print("全部自测通过。LabVIEW 里只要调用 read_frame() 就能拿到同样的 516 个数。")


if __name__ == "__main__":
    selftest()
