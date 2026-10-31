# -*- coding: utf-8 -*-
"""
十二键电子琴 —— FPGA 实时可视化上位机
================================================================
界面：李萨如图形 / 实时频谱 / 波形显示 + 状态栏 + 钢琴键盘

两种工作模式：
  1) 演示模式（默认）：内部模拟 12 键合成，不接板子也能跑，
     可以直接用来录演示视频 / 截图做 PPT。
  2) 串口模式：从 FPGA 的 UART 读取采样帧（协议见下），实时绘制。

串口数据协议（与 RTL 端 uart_stream.v 配套）：
   每帧 576 字节（与 RTL 的 uart_stream.v 完全对应）：
       [0]  0xA5          帧头1
       [1]  0x5A          帧头2
       [2]  timbre        音色 0..4（三角/方波/锯齿/脉冲/钢琴）
       [3]  keys_lo       12 键状态低 8 位
       [4]  keys_hi       12 键状态高 4 位（bit3..0 = key11..key8）
       [5]  voices        当前活跃声部数
       [6]  flags         bit0 = 已有延迟数据
       [7]  效果开关
       [8..519]  512 个采样，uint8，以 0x80 为中心（偏移二进制）
       [520..523] lat_last      最近一次延迟（clk 周期，1 clk = 37.037 ns）
       [524..527] lat_min       最小延迟（0xFFFFFFFF = 无数据）
       [528..531] lat_max       最大延迟
       [532..535] lat_sum       累计和（32 位回绕）
       [536..537] lat_cnt       样本次数
       [538..539] 预留
       [540..543] scan_period   两次 TTP229 扫描之间的周期（按键采样间隔）
       [544..575] hist[16]      16 个 u16 直方图计数，每格 65536 clk = 2.4271 ms

   串口参数：115200 8N1，帧率 15 fps
   带宽：576 字节 × 15 帧/秒 × 10 bit ≈ 86 kbps < 115200 ✓

命令行：
   python synth_viz.py                 正常启动（演示模式）
   python synth_viz.py --port COM7     直接连串口
   python synth_viz.py --selftest out.png   渲染一帧存图并退出（自查用）
"""

import os
import sys
import math
import time
import ctypes          # 串口读取线程里要用，必须在模块级导入
import argparse
import threading

import numpy as np

import matplotlib
matplotlib.use("TkAgg")
import matplotlib.pyplot as plt
from matplotlib.figure import Figure
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg
from matplotlib.patches import Rectangle
from matplotlib.gridspec import GridSpec, GridSpecFromSubplotSpec

import tkinter as tk
from tkinter import ttk, messagebox

# ----------------------------------------------------------------------------
#  全局观感（对齐参考视频的深色风格）
# ----------------------------------------------------------------------------
C_BG        = "#0d0d10"
C_PANEL     = "#141419"
C_GRID      = "#26262e"
C_WAVE      = "#e8d24a"      # 波形：黄色
C_SPEC      = "#e8d24a"      # 频谱：黄色
C_SPEC_HI   = "#3fb6f0"      # 频谱高亮：蓝色
C_LISS      = "#9a9aa8"
C_TEXT      = "#d8d8e0"
C_DIM       = "#7a7a8a"
C_ACCENT    = "#3fb6f0"
C_KEY_WHITE = "#f2f2f2"
C_KEY_BLACK = "#1a1a20"
C_KEY_ON    = "#3fb6f0"

FS          = 52734.375      # 与 FPGA 设计一致（27MHz/8/64）
N_SAMPLES   = 512            # 显示用样本数
N_FFT       = 512

# 12 键 = C4..B4（与 note_table.v 完全一致）
NOTE_NAMES  = ["C4", "C#4", "D4", "D#4", "E4", "F4", "F#4",
               "G4", "G#4", "A4", "A#4", "B4"]
NOTE_PINS   = [27, 28, 29, 30, 31, 26, 41, 42, 48, 77, 79, 25]
NOTE_HZ     = [261.63, 277.18, 293.66, 311.13, 329.63, 349.23,
               369.99, 392.00, 415.30, 440.00, 466.16, 493.88]
IS_BLACK    = [False, True, False, True, False, False, True,
               False, True, False, True, False]

TIMBRE_NAMES = ["三角波", "方波", "锯齿波", "脉冲波", "钢琴"]
EFFECT_NAMES = ["无", "混响", "延迟", "合唱"]


# ----------------------------------------------------------------------------
#  信号合成（在 PC 上复现 FPGA 的算法，用于演示模式）
# ----------------------------------------------------------------------------
def make_wave(timbre, phase):
    """按波形类型生成一个周期内的波形，phase ∈ [0,1)"""
    if timbre == 0:                                  # 三角波
        return 4.0 * np.abs(phase - 0.5) - 1.0
    if timbre == 1:                                  # 方波
        return np.where(phase < 0.5, 1.0, -1.0)
    if timbre == 2:                                  # 锯齿波
        return 2.0 * phase - 1.0
    return np.where(phase < 0.25, 1.0, -1.0)         # 25% 脉冲


def synth_buffer(active, timbre, n=N_SAMPLES, fs=FS, t_offset=0.0):
    """把当前按下的键合成为一个缓冲（与 FPGA 的 mix_tree 思路一致）"""
    t = np.arange(n) / fs + t_offset
    out = np.zeros(n, dtype=np.float64)
    for idx in active:
        f = NOTE_HZ[idx]
        ph = (t * f) % 1.0
        out += make_wave(timbre, ph)
    if active:
        # 除以声部数，保证叠加后峰值不超过 1，波形不会被裁掉
        out = out / float(len(active)) * 0.98
    return out


# ----------------------------------------------------------------------------
#  串口读取（纯 ctypes 实现，不依赖 pyserial）
# ----------------------------------------------------------------------------
class SerialReader(threading.Thread):
    """在后台线程读 COM 口，解析 0xA5 0x5A 帧，把最新样本与状态交给界面"""

    FRAME_LEN = 576
    LAT_OFF   = 520
    HIST_OFF  = 544
    BIN_CLK   = 65536.0          # 每格 65536 个 27 MHz 周期 = 2.4271 ms
    CLK_HZ    = 27_000_000.0

    def __init__(self, port, baud, on_frame):
        super().__init__(daemon=True)
        self.port = port
        self.baud = baud
        self.on_frame = on_frame
        self._stop = False
        self._buf = bytearray()
        self.err = None
        self.ok = False

    # ---- Win32 串口 ----
    def _open(self):
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)

        GENERIC_READ, GENERIC_WRITE = 0x80000000, 0x40000000
        OPEN_EXISTING = 3
        INVALID_HANDLE = ctypes.c_void_p(-1).value

        handle = k32.CreateFileW(
            "\\\\.\\" + self.port, GENERIC_READ | GENERIC_WRITE,
            0, None, OPEN_EXISTING, 0, None)
        if handle == INVALID_HANDLE:
            raise OSError(f"打不开串口 {self.port}（被占用或不存在）")

        # DCB
        class DCB(ctypes.Structure):
            _fields_ = [("DCBlength", wintypes.DWORD), ("BaudRate", wintypes.DWORD),
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
                        ("EvtChar", ctypes.c_char), ("wReserved1", wintypes.WORD)]

        dcb = DCB()
        dcb.DCBlength = ctypes.sizeof(DCB)
        if not k32.GetCommState(handle, ctypes.byref(dcb)):
            k32.CloseHandle(handle)
            raise OSError("GetCommState 失败")
        dcb.BaudRate = self.baud
        dcb.ByteSize = 8
        dcb.Parity   = 0      # NOPARITY
        dcb.StopBits = 0      # ONESTOPBIT
        dcb.fBinary  = 1
        dcb.fParity  = 0
        dcb.fOutxCtsFlow = 0
        dcb.fOutxDsrFlow = 0
        dcb.fDtrControl  = 1  # DTR_CONTROL_ENABLE
        dcb.fDsrSensitivity = 0
        dcb.fOutX = 0
        dcb.fInX  = 0
        dcb.fRtsControl = 1   # RTS_CONTROL_ENABLE
        if not k32.SetCommState(handle, ctypes.byref(dcb)):
            k32.CloseHandle(handle)
            raise OSError("SetCommState 失败")

        class COMMTIMEOUTS(ctypes.Structure):
            _fields_ = [("ReadIntervalTimeout", wintypes.DWORD),
                        ("ReadTotalTimeoutMultiplier", wintypes.DWORD),
                        ("ReadTotalTimeoutConstant", wintypes.DWORD),
                        ("WriteTotalTimeoutMultiplier", wintypes.DWORD),
                        ("WriteTotalTimeoutConstant", wintypes.DWORD)]
        to = COMMTIMEOUTS(50, 0, 50, 0, 0)
        k32.SetCommTimeouts(handle, ctypes.byref(to))

        self._k32 = k32
        self._handle = handle

    def send_cmd(self, payload):
        """向下位机发命令（0xA5 0x01 <wave>）。返回 True 表示写出成功。"""
        if not getattr(self, "_handle", None):
            return False
        data = bytes(payload)
        written = ctypes.c_ulong(0)
        ok = self._k32.WriteFile(self._handle, data, len(data),
                                 ctypes.byref(written), None)
        return bool(ok) and written.value == len(data)

    def run(self):
        try:
            self._open()
            self.ok = True
        except Exception as e:                          # noqa: BLE001
            self.err = str(e)
            return

        buf = ctypes.create_string_buffer(1024)
        nread = ctypes.c_ulong(0)
        while not self._stop:
            ok = self._k32.ReadFile(self._handle, buf, 1024,
                                    ctypes.byref(nread), None)
            if not ok or nread.value == 0:
                time.sleep(0.002)
                continue
            self._buf.extend(buf.raw[:nread.value])
            self._parse()

    def _parse(self):
        while True:
            i = self._buf.find(b"\xA5\x5A")
            if i < 0:
                if len(self._buf) > 4096:
                    self._buf = self._buf[-2:]
                return
            if i > 0:
                del self._buf[:i]
            if len(self._buf) < self.FRAME_LEN:
                return
            f = bytes(self._buf[:self.FRAME_LEN])
            del self._buf[:self.FRAME_LEN]

            timbre = f[2] & 0x07
            keys = f[3] | ((f[4] & 0x0F) << 8)
            voices = f[5]
            eff = f[7] & 0x03
            raw = np.frombuffer(f[8:520], dtype=np.uint8).astype(np.float64)
            samples = (raw - 128.0) / 128.0

            # ---- 延迟统计段 ----
            u32 = lambda o: int.from_bytes(f[o:o + 4], "little")
            lat = {
                "last":  u32(self.LAT_OFF + 0),
                "min":   u32(self.LAT_OFF + 4),
                "max":   u32(self.LAT_OFF + 8),
                "sum":   u32(self.LAT_OFF + 12),
                "cnt":   int.from_bytes(f[self.LAT_OFF + 16:self.LAT_OFF + 18], "little"),
                "scan":  u32(self.LAT_OFF + 20),
                "hist":  np.frombuffer(f[self.HIST_OFF:self.HIST_OFF + 32],
                                       dtype="<u2").astype(np.float64),
                "flag":  bool(f[6] & 0x01),
            }
            self.on_frame(timbre, keys, voices, eff, samples, lat)

    def stop(self):
        self._stop = True
        try:
            if getattr(self, "_handle", None):
                self._k32.CloseHandle(self._handle)
        except Exception:                               # noqa: BLE001
            pass


# ----------------------------------------------------------------------------
#  主界面
# ----------------------------------------------------------------------------
class SynthViz:

    def __init__(self, root, port=None, baud=921600):
        self.root = root
        root.title("十二键电子琴 —— FPGA 实时可视化上位机")
        root.configure(bg=C_BG)
        root.geometry("1520x1000")

        # ---- 运行状态 ----
        self.timbre   = 0
        self.effect   = 0
        self.vel      = "轻按"
        self.express  = "无"
        self.active   = set()          # 当前按下的键索引
        self.voices   = 0
        self.t_off    = 0.0
        self.frames   = 0
        self.frame_count = 0
        self.fps      = 0.0
        self.last_fps_t = time.time()
        self.serial   = None
        self._closing = False
        self._after_id = None
        self.lat      = None           # 最近一帧的延迟统计
        self._resize_job = None        # 窗口尺寸变化后的延迟重绘任务
        self._drawn_px = None          # 上一次真正画到屏幕上的 figure 像素尺寸

        # ---- 布局 ----
        fig = Figure(figsize=(12.8, 8.1), dpi=100, facecolor=C_BG)
        gs = GridSpec(4, 3, figure=fig,
                      height_ratios=[1.00, 0.54, 0.20, 0.42],
                      left=0.015, right=0.985, top=0.912, bottom=0.02,
                      hspace=0.40, wspace=0.06)

        self.ax_liss = fig.add_subplot(gs[0, 0])
        self.ax_spec = fig.add_subplot(gs[0, 1])
        self.ax_wave = fig.add_subplot(gs[0, 2])

        # 延迟面板：左 = 大字号读数，右 = 直方图
        gs_lat = GridSpecFromSubplotSpec(1, 2, subplot_spec=gs[1, :],
                                         width_ratios=[1.05, 1.75], wspace=0.10)
        self.ax_latnum  = fig.add_subplot(gs_lat[0, 0])
        self.ax_lathist = fig.add_subplot(gs_lat[0, 1])

        self.ax_stat = fig.add_subplot(gs[2, :])
        self.ax_keys = fig.add_subplot(gs[3, :])

        for ax in (self.ax_liss, self.ax_spec, self.ax_wave, self.ax_lathist):
            ax.set_facecolor(C_PANEL)
            for s in ax.spines.values():
                s.set_color(C_GRID)
            ax.tick_params(colors=C_DIM, labelsize=7)
            ax.grid(True, color=C_GRID, lw=0.5, alpha=0.7)

        fig.suptitle("十二键电子琴   ·   Tang Nano 20K   ·   FPGA 实时可视化",
                     color=C_TEXT, fontsize=12, x=0.008, y=0.995, va="top", ha="left")

        for ax, t in ((self.ax_liss, "李萨如图形"),
                      (self.ax_spec, "实时频谱"),
                      (self.ax_wave, "波形显示")):
            ax.set_title(t, color=C_TEXT, fontsize=10, loc="left", pad=6)

        # ---- 延迟面板 ----
        NB = 16
        self.lat_bin_ms = 65536.0 / 27e6 * 1000.0          # 2.4271 ms / 格
        self.ax_latnum.set_axis_off()
        self.ax_latnum.text(0.0, 1.00, "演奏延迟（FPGA 内部 · 37 ns 分辨率）",
                            fontsize=8.5, color=C_DIM,
                            transform=self.ax_latnum.transAxes, va="top")
        self.lat_big = self.ax_latnum.text(0.0, 0.60, "—— ms", fontsize=26,
                                           color=C_ACCENT, family="monospace",
                                           transform=self.ax_latnum.transAxes, va="center")
        self.lat_sub = self.ax_latnum.text(0.0, 0.30, "", fontsize=8.5, color=C_TEXT,
                                           transform=self.ax_latnum.transAxes, va="center")
        self.lat_sub2 = self.ax_latnum.text(0.0, 0.10, "", fontsize=7.5, color=C_DIM,
                                            transform=self.ax_latnum.transAxes, va="center")

        self.lat_bars = self.ax_lathist.bar(
            (np.arange(NB) + 0.5) * self.lat_bin_ms, np.zeros(NB),
            width=self.lat_bin_ms * 0.80, color=C_ACCENT)
        self.ax_lathist.set_xlim(0, NB * self.lat_bin_ms)
        self.ax_lathist.set_ylim(0, 1.0)
        self.ax_lathist.set_yticks([])
        self.ax_lathist.set_xticks(np.arange(0, NB * self.lat_bin_ms, 5))
        self.ax_lathist.set_xlabel("延迟 ms（每格 2.43 ms）", fontsize=8,
                                   color=C_DIM, labelpad=2)
        # 标题放在坐标轴内部右上角，避免和上面"实时频谱"面板的刻度挤在一起
        self.ax_lathist.text(0.995, 0.93, "延迟分布（连按几十下看抖动）",
                             transform=self.ax_lathist.transAxes,
                             ha="right", va="top", color=C_TEXT, fontsize=9)
        self.ax_lathist.axvline(5.0, color="#5ad48a", ls="--", lw=1.0)
        self.ax_lathist.axvline(10.0, color="#e06060", ls="--", lw=1.2)
        self.ax_lathist.text(5.0, 1.02, "5ms", color="#5ad48a", fontsize=7,
                             va="bottom", ha="left", clip_on=False, zorder=12)
        self.ax_lathist.text(10.0, 1.02, "10ms", color="#e06060", fontsize=7,
                             va="bottom", ha="left", clip_on=False, zorder=12)

        # ---- 线条 ----
        self.ln_wave, = self.ax_wave.plot([], [], color=C_WAVE, lw=1.0)
        self.ax_wave.set_ylim(-1.15, 1.15)
        self.ax_wave.set_xlim(0, N_SAMPLES)
        self.ax_wave.set_yticks([])

        self.spec_bars = self.ax_spec.bar(np.arange(32), np.zeros(32),
                                          width=0.8, color=C_SPEC)
        self.ax_spec.set_xlim(-0.6, 31.6)
        self.ax_spec.set_ylim(0, 1.05)
        self.ax_spec.set_yticks([])

        self.ln_liss, = self.ax_liss.plot([], [], color=C_LISS, lw=0.9)
        self.ax_liss.set_xlim(-1.15, 1.15)
        self.ax_liss.set_ylim(-1.15, 1.15)
        self.ax_liss.set_aspect("equal")
        self.ax_liss.set_xticks([])
        self.ax_liss.set_yticks([])

        # ---- 状态栏 ----
        self.ax_stat.set_facecolor(C_BG)
        self.ax_stat.set_xticks([]); self.ax_stat.set_yticks([])
        for s in self.ax_stat.spines.values():
            s.set_visible(False)
        self.lbl_timbre = self.ax_stat.text(0.004, 0.74, "", color=C_TEXT,
                                            fontsize=11, transform=self.ax_stat.transAxes)
        self.lbl_vel = self.ax_stat.text(0.004, 0.24, "", color=C_TEXT,
                                         fontsize=11, transform=self.ax_stat.transAxes)
        self.lbl_express = self.ax_stat.text(0.20, 0.74, "", color=C_TEXT,
                                             fontsize=11, transform=self.ax_stat.transAxes)
        self.lbl_voices = self.ax_stat.text(0.20, 0.24, "", color=C_TEXT,
                                            fontsize=11, transform=self.ax_stat.transAxes)
        self.lbl_effect = self.ax_stat.text(0.40, 0.74, "", color=C_TEXT,
                                            fontsize=11, transform=self.ax_stat.transAxes)
        self.lbl_mode = self.ax_stat.text(0.72, 0.48, "", color=C_ACCENT,
                                          fontsize=10, transform=self.ax_stat.transAxes)
        self.lbl_fps = self.ax_stat.text(0.995, 0.48, "", color=C_DIM,
                                         fontsize=9, ha="right",
                                         transform=self.ax_stat.transAxes)

        # ---- 键盘 ----
        self.ax_keys.set_facecolor(C_BG)
        self.ax_keys.set_xlim(0, 12)
        self.ax_keys.set_ylim(0, 1)
        self.ax_keys.set_xticks([]); self.ax_keys.set_yticks([])
        for s in self.ax_keys.spines.values():
            s.set_visible(False)
        self._build_keyboard()

        self.fig = fig
        self.canvas = FigureCanvasTkAgg(fig, master=root)

        # ---- 右侧控制栏（tkinter）----
        bar = tk.Frame(root, bg=C_BG)
        bar.pack(side=tk.TOP, fill=tk.X, padx=8, pady=2)
        tk.Label(bar, text="音色", bg=C_BG, fg=C_DIM).pack(side=tk.LEFT)
        self.cmb_timbre = ttk.Combobox(bar, values=TIMBRE_NAMES,
                                       state="readonly", width=8)
        self.cmb_timbre.current(0)
        self.cmb_timbre.pack(side=tk.LEFT, padx=(4, 14))
        self.cmb_timbre.bind("<<ComboboxSelected>>", self._on_timbre)

        # 「音频效果」下拉框已移除：本设计没有效果器，摆着会误导评委。
        # 音色下拉框保留（串口模式下会下发 0xA5 0x01 <wave> 实时切换）。

        tk.Label(bar, text="串口", bg=C_BG, fg=C_DIM).pack(side=tk.LEFT)
        self.ent_port = ttk.Entry(bar, width=8)
        self.ent_port.insert(0, port or "COM7")
        self.ent_port.pack(side=tk.LEFT, padx=4)
        self.btn_conn = ttk.Button(bar, text="连接", command=self.toggle_serial)
        self.btn_conn.pack(side=tk.LEFT)
        self.lbl_conn = tk.Label(bar, text="演示模式", bg=C_BG, fg=C_ACCENT)
        self.lbl_conn.pack(side=tk.LEFT, padx=10)

        self.canvas.get_tk_widget().pack(fill=tk.BOTH, expand=True)
        self.canvas.mpl_connect("button_press_event", self._on_click)
        # ⚠ 不要自己 bind <Configure> 去 set_size_inches！
        #   matplotlib 3.11 的 TkAgg 内置了「窗口变大 → figure 自动跟着变」的逻辑，
        #   我们再插一手会让它内部的重绘判断失效，结果是画布控件虽然变大了，
        #   但贴在上面的那张图片还停在旧尺寸 —— 也就是"放大后只有左上角有画面"。
        self.canvas.draw()          # 先画一次，避免开窗时是空白

        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

        if port:
            self.root.after(300, self.toggle_serial)

        self._tick()

    # ---------------------------------------------------------------- 键盘
    def _build_keyboard(self):
        """按实体模块的钢琴布局画：白键一排为底，黑键插在相邻白键交界处"""
        self.key_patches = []
        self.key_labels = []

        white_idx = [i for i in range(12) if not IS_BLACK[i]]
        n_white = len(white_idx)
        w = 12.0 / n_white
        self._white_w = w

        # 白键
        pos = 0
        for i in range(12):
            if IS_BLACK[i]:
                continue
            r = Rectangle((pos, 0), w * 0.96, 1.0, facecolor=C_KEY_WHITE,
                          edgecolor="#333340", lw=0.8, zorder=2)
            self.ax_keys.add_patch(r)
            self.key_patches.append((i, r))
            self.ax_keys.text(pos + w * 0.48, 0.10, NOTE_NAMES[i],
                              ha="center", va="bottom", fontsize=7,
                              color="#555560", zorder=4)
            self.ax_keys.text(pos + w * 0.48, 0.02, f"k{i} · 实体{i + 1}",
                              ha="center", va="bottom", fontsize=6,
                              color="#8a8a96", zorder=4)
            pos += w

        # 黑键：骑在相邻两个白键的交界处
        bw = w * 0.56
        n_before = 0
        for i in range(12):
            if not IS_BLACK[i]:
                n_before += 1
                continue
            x = n_before * w - bw / 2.0       # 交界处居中
            x = max(0.02, min(12 - bw - 0.02, x))
            r = Rectangle((x, 0.45), bw, 0.55, facecolor=C_KEY_BLACK,
                          edgecolor="#4a4a58", lw=1.0, zorder=3)
            self.ax_keys.add_patch(r)
            self.key_patches.append((i, r))
            self.ax_keys.text(x + bw / 2.0, 0.44, NOTE_NAMES[i],
                              ha="center", va="bottom", fontsize=6,
                              color="#dcdce6", zorder=4)
            self.ax_keys.text(x + bw / 2.0, 0.415, f"k{i}",
                              ha="center", va="bottom", fontsize=5,
                              color="#8a8a96", zorder=4)

    def _paint_keys(self):
        for i, patch in self.key_patches:
            on = i in self.active
            patch.set_facecolor(C_KEY_ON if on else
                                (C_KEY_BLACK if IS_BLACK[i] else C_KEY_WHITE))

    # ---------------------------------------------------------------- 交互
    def _on_click(self, ev):
        if ev.inaxes is not self.ax_keys or ev.xdata is None:
            return
        x, y = ev.xdata, ev.ydata
        hit = None
        # 黑键优先
        for i, patch in self.key_patches:
            if not IS_BLACK[i]:
                continue
            bb = patch.get_bbox()
            if bb.x0 <= x <= bb.x1 and bb.y0 <= y <= bb.y1:
                hit = i
                break
        if hit is None:
            for i, patch in self.key_patches:
                if IS_BLACK[i]:
                    continue
                bb = patch.get_bbox()
                if bb.x0 <= x <= bb.x1 and bb.y0 <= y <= bb.y1:
                    hit = i
                    break
        if hit is None:
            return
        if self.serial and self.serial.ok:
            return                                     # 串口模式下不本地改状态
        if hit in self.active:
            self.active.discard(hit)
        else:
            self.active.add(hit)
        self.voices = len(self.active)
        self._paint_keys()

    def _on_timbre(self, _ev=None):
        sel = self.cmb_timbre.current()
        if sel < 0:
            return
        self.timbre = sel
        # 串口模式下把选择下发给 FPGA（协议：0xA5 0x01 <wave>）
        if self.serial and self.serial.ok:
            self.serial.send_cmd([0xA5, 0x01, sel])

    def _on_effect(self, _ev=None):
        # 效果器未实现，保留空实现以防旧引用报错
        self.effect = 0

    # ---------------------------------------------------------------- 串口
    def toggle_serial(self):
        if self.serial and self.serial.ok:
            self.serial.stop()
            self.serial = None
            self.btn_conn.config(text="连接")
            self.lbl_conn.config(text="演示模式", fg=C_ACCENT)
            return

        port = self.ent_port.get().strip()
        if not port:
            return
        self.serial = SerialReader(port, 115200, self._on_serial_frame)
        self.serial.start()
        time.sleep(0.25)
        if self.serial.ok:
            self.btn_conn.config(text="断开")
            self.lbl_conn.config(text=f"串口 {port}", fg="#5ad48a")
        else:
            msg = self.serial.err or "未知错误"
            self.lbl_conn.config(text="连接失败", fg="#e06060")
            messagebox.showerror("串口", msg)
            self.serial = None

    def _on_serial_frame(self, timbre, keys, voices, eff, samples, lat=None):
        self.timbre = timbre
        self.effect = eff
        self.active = {i for i in range(12) if keys >> i & 1}
        self.voices = voices
        self._serial_samples = samples
        if lat is not None:
            self.lat = lat

    # ---------------------------------------------------------------- 刷新
    def _tick(self):
        if self._closing:
            return
        try:
            self._render()
        except Exception as e:                          # noqa: BLE001
            print("render error:", e)
        if not self._closing:
            self._after_id = self.root.after(33, self._tick)

    def _on_canvas_resize(self, ev):
        """（已停用）保留仅为兼容旧调用，实际交给 matplotlib 内置的自适应"""
        return

    def _fit_figure_to_canvas(self):
        """（已停用）保留仅为兼容旧调用"""
        return False

    def _on_close(self):
        """窗口关闭：先停 tick 和串口，再销毁，避免残留 after 回调"""
        self._closing = True
        if self._after_id is not None:
            try:
                self.root.after_cancel(self._after_id)
            except Exception:                           # noqa: BLE001
                pass
            self._after_id = None
        if self._resize_job is not None:
            try:
                self.root.after_cancel(self._resize_job)
            except Exception:                           # noqa: BLE001
                pass
            self._resize_job = None
        if self.serial:
            try:
                self.serial.stop()
            except Exception:                           # noqa: BLE001
                pass
            self.serial = None
        try:
            self.root.destroy()
        except Exception:                               # noqa: BLE001
            pass

    # ------------------------------------------------------------ 延迟面板
    def _render_latency(self, using_serial):
        CLK = 27_000_000.0
        lat = self.lat
        if (not using_serial) or lat is None or not lat.get("flag"):
            self.lat_big.set_text("—— ms")
            self.lat_big.set_color(C_DIM)
            self.lat_sub.set_text("演示模式（无实测数据）" if not using_serial
                                  else "等待演奏数据…（按一下触摸键）")
            self.lat_sub2.set_text("")
            for b in self.lat_bars:
                b.set_height(0.0)
            self.ax_lathist.set_ylim(0, 1.0)
            return

        last_ms = lat["last"] / CLK * 1e3
        max_ms  = lat["max"] / CLK * 1e3
        cnt     = max(1, lat["cnt"])
        min_ms  = lat["min"] / CLK * 1e3 if lat["min"] != 0xFFFFFFFF else last_ms
        avg_ms  = (lat["sum"] & 0xFFFFFFFF) / CLK * 1e3 / cnt
        scan_ms = lat["scan"] / CLK * 1e3

        self.lat_big.set_text(f"{last_ms:.3f} ms")
        self.lat_big.set_color("#5ad48a" if last_ms <= 5.0
                               else (C_ACCENT if last_ms <= 10.0 else "#e06060"))
        self.lat_sub.set_text(f"min {min_ms:.3f}   avg {avg_ms:.3f}   max {max_ms:.3f}")
        self.lat_sub2.set_text(
            f"抖动 {max_ms - min_ms:.3f} ms · 采样周期 {scan_ms:.2f} ms · "
            f"最坏≈{scan_ms + max_ms:.2f} ms · n={lat['cnt']}")

        hist = np.asarray(lat["hist"], dtype=np.float64)
        tot = float(hist.sum())
        norm = hist / tot if tot > 0 else hist
        for b, bar in enumerate(self.lat_bars):
            bar.set_height(float(norm[b]))
            center = (b + 0.5) * self.lat_bin_ms
            bar.set_color("#e06060" if center > 10.0
                          else ("#5ad48a" if center <= 5.0 else C_ACCENT))
        self.ax_lathist.set_ylim(0, max(0.05, float(norm.max()) * 1.18))

    def _render(self):
        using_serial = bool(self.serial and self.serial.ok)

        if using_serial:
            samples = getattr(self, "_serial_samples", np.zeros(32))
            if len(samples) < N_SAMPLES:
                # 样本不足时线性插值铺满显示区
                xp = np.linspace(0, 1, len(samples))
                xq = np.linspace(0, 1, N_SAMPLES)
                samples = np.interp(xq, xp, samples)
        else:
            self.t_off += N_SAMPLES / FS
            samples = synth_buffer(sorted(self.active), self.timbre,
                                   n=N_SAMPLES, t_offset=self.t_off)

        # 波形
        self.ln_wave.set_data(np.arange(N_SAMPLES), samples)

        # 频谱（32 个对数频带，跳过直流分量）
        win = np.hanning(N_FFT)
        seg = np.zeros(N_FFT)
        m = min(len(samples), N_FFT)
        seg[:m] = samples[:m]
        mag = np.abs(np.fft.rfft(seg * win))
        freqs = np.fft.rfftfreq(N_FFT, 1.0 / FS)
        # 只保留 50 Hz ~ 16 kHz，并去掉直流泄漏
        keep = freqs >= 50.0
        mag, freqs = mag[keep], freqs[keep]
        if mag.size and mag.max() > 1e-9:
            mag = mag / mag.max()
        band_edges = np.logspace(math.log10(60.0), math.log10(16000.0), 33)
        bands = np.zeros(32)
        for b in range(32):
            lo, hi = band_edges[b], band_edges[b + 1]
            sel = (freqs >= lo) & (freqs < hi)
            bands[b] = mag[sel].max() if sel.any() else 0.0
        for b, bar in enumerate(self.spec_bars):
            h = float(bands[b])
            bar.set_height(max(0.02, h))
            bar.set_color(C_SPEC_HI if h > 0.5 else C_SPEC)

        # 李萨如：x = 信号，y = 四分之一周期后的信号（归一化后不会溢出）
        q = max(1, N_SAMPLES // 4)
        x = samples[:-q]
        y = samples[q:]
        pk = max(1e-9, float(np.max(np.abs(samples))))
        self.ln_liss.set_data(x / pk * 0.95, y / pk * 0.95)

        # 状态
        self._paint_keys()
        if self.active:
            note = NOTE_NAMES[max(self.active)]
            self.lbl_vel.set_text(f"| 按键  按下   当前音  {note}")
        else:
            self.lbl_vel.set_text(f"| 按键  松开   当前音  ——")

        self.lbl_timbre.set_text(f"| 音色  {TIMBRE_NAMES[self.timbre]}")
        self.lbl_express.set_text("| 音色源  " + ("上位机" if using_serial else "本地"))
        self.lbl_voices.set_text(f"| 声部  {len(self.active) if not using_serial else self.voices}")
        self.lbl_effect.set_text(f"| 声部数  {self.voices if using_serial else len(self.active)}")
        self.lbl_mode.set_text("串口实时数据" if using_serial else "演示模式（点击键盘试听可视化）")

        self._render_latency(using_serial)

        self.frames += 1
        self.frame_count += 1
        now = time.time()
        if now - self.last_fps_t >= 1.0:
            self.fps = self.frames / (now - self.last_fps_t)
            self.frames = 0
            self.last_fps_t = now
        self.lbl_fps.set_text(f"{self.fps:.0f} fps")

        # ---- 关键：尺寸变了就同步重绘 ----
        # matplotlib 的 draw_idle() 只是把重绘排进「空闲回调」，而窗口最大化
        # 之后那个空闲回调常常不会被执行，结果 tk 画布上的 PhotoImage 还停在
        # 旧尺寸 —— 表现就是「放大之后只有左上角一块有画面，其余全黑」。
        # 所以这里主动比对 figure 的像素尺寸，一变就 canvas.draw() 强制重画。
        px = (int(round(self.fig.get_size_inches()[0] * self.fig.get_dpi())),
              int(round(self.fig.get_size_inches()[1] * self.fig.get_dpi())))
        if px != self._drawn_px:
            self._drawn_px = px
            self.canvas.draw()
        else:
            self.canvas.draw_idle()


# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None, help="串口名，如 COM7")
    ap.add_argument("--selftest", default=None, help="渲染一帧存 PNG 后退出")
    ap.add_argument("--bench", type=int, default=0,
                    help="跑 N 帧动画后自动退出（自测用）")
    ap.add_argument("--zoom", action="store_true", help="启动后直接最大化窗口")
    args = ap.parse_args()

    # 中文字体
    matplotlib.rcParams["font.sans-serif"] = [
        "Microsoft YaHei", "SimHei", "DejaVu Sans"]
    matplotlib.rcParams["axes.unicode_minus"] = False

    # 关键：声明 DPI 感知，否则 Windows 缩放（125%/150%）会把
    # matplotlib 画布放大，导致内容被裁掉
    try:
        import ctypes
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)   # 系统级 DPI 感知
        except Exception:
            ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

    root = tk.Tk()
    app = SynthViz(root, port=args.port)

    if args.zoom:
        root.after(150, lambda: root.state("zoomed"))

    if args.selftest:
        # 预置几个按键，渲染一帧保存，便于自动检查外观
        app.active = {0, 4, 7}      # C4 + E4 + G4
        app.voices = 3
        app.timbre = 0
        app._render()
        app.fig.savefig(args.selftest, facecolor=app.fig.get_facecolor())
        print("saved:", args.selftest)
        root.destroy()
        return

    if args.bench:
        # 跑 N 帧动画验证刷新循环、FFT、绘图都不报错
        app.active = {0, 4, 7, 11}
        app.voices = 4
        frames = {"n": 0}

        def _stop():
            try:
                app.fig.savefig("D:/Date/DeepseekDate/viz/bench.png",
                                facecolor=app.fig.get_facecolor())
            except Exception as e:                      # noqa: BLE001
                print("save fail:", e)
            print(f'bench done: {app.frame_count} frames, fps={app.fps:.1f}', flush=True)
            app._closing = True
            root.quit()

        root.after(33 * args.bench, _stop)
        root.mainloop()
        os._exit(0)

    root.mainloop()


if __name__ == "__main__":
    main()
