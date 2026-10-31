# 串口协议规格 —— FPGA → 上位机（LabVIEW / Python 通用）

> 对应 RTL：`code/rtl/uart_stream.v` + `code/rtl/uart_tx.v`
> 版本：beta.2.5（2026-10-31，新增延迟统计段，帧长 520 → **576**）

---

## 一、物理层

| 项 | 值 |
|---|---|
| 接口 | USB 虚拟串口（板载 BL616 转出），设备管理器里是 **COM7 / COM8** |
| 波特率 | **115200** |
| 数据位 / 校验 / 停止位 | **8 / None / 1**（8N1） |
| 流控 | 无 |
| FPGA 引脚 | UART TX = **69**（RX = 70，本项目未用 RX） |
| 方向 | FPGA 只发不收 |

> 两个 COM 口里**只有一个**是 FPGA 的 UART。判断方法：用下面第三节的脚本扫一遍，
> 能收到 `A5 5A` 帧头的那个就是。

---

## 二、帧格式（**576** 字节定长，15 帧/秒）

```
偏移   字节数   名称        说明
-----  ------  ---------  --------------------------------------------
  0      1      HEAD1      固定 0xA5
  1      1      HEAD2      固定 0x5A
  2      1      TIMBRE     音色：0=三角 1=方波 2=锯齿 3=脉冲 4=钢琴
  3      1      KEYS_LO    12 键状态低 8 位（bit0 = key[0]）
  4      1      KEYS_HI    bit3..0 = key[11]..key[8]，高 4 位为 0
  5      1      VOICES     当前活跃声部数（0..4）
  6      1      FLAGS      bit0 = 1 表示已有延迟数据
  7      1      EFFECT     效果器：0=无 1=混响 2=延迟 3=合唱
  8    512      SAMPLES    512 个采样，uint8
520      4      LAT_LAST   最近一次延迟（单位：27 MHz 时钟周期）
524      4      LAT_MIN    最小延迟（0xFFFFFFFF = 还没有数据）
528      4      LAT_MAX    最大延迟
532      4      LAT_SUM    累计和（32 位自然回绕）
536      2      LAT_CNT    累计样本次数
538      2      —          预留
540      4      SCAN_PER   两次 TTP229 扫描之间的周期（按键采样间隔）
544     32      HIST[16]   16 个 uint16 直方图计数
```

> 多字节量全部是**小端**（低字节在前）。
>
> **1 个 clk 周期 = 1 / 27 MHz = 37.037 ns**。
> 延迟换算：`ms = 原始值 / 27000.0`（保留 3 位小数足够）。

### 延迟直方图怎么读

每格 **65536 个 clk = 2.4271 ms**，16 格覆盖 **0 ~ 38.8 ms**，
超过 38.8 ms 的全部计入最后一格。

```
第 i 格的中心 = (i + 0.5) × 2.4271 ms
```
- 所有事件挤在第 0~1 格 → 延迟 ≈ 1 ms 量级，**确定性好**
- 摊在第 0~8 格（0~20 ms）→ 说明按键采样周期太长，正在吃"最坏情况"

### 采样数据的编码

**偏移二进制（offset binary）**，不是补码：

```
实际电压值 = (byte - 128) / 128.0      → 范围 -1.0 ~ +0.992
静音时 byte = 0x80 (128)
```

采样率 = **52734.375 Hz**（= 27 MHz / 8 / 64，与板上 I2S 一致）。
所以一帧 512 个采样刚好是 **9.71 ms** 的音频。

### 帧率与带宽

- 帧间隔：**66.7 ms（15 fps）**
- 发送耗时：576 字节 × 10 bit / 115200 = **50.0 ms** < 66.7 ms ✓
- 带宽占用：`576 字节 × 15 × 10 bit = 86 kbps` < 115200 ✓（约 75%）

---

## 三、LabVIEW 端怎么读

### 3.1 前面板需要的控件

| 控件 | 类型 | 连到哪里 |
|---|---|---|
| 串口选择 | `VISA Resource Name` | 选 COM7 / COM8 |
| 波特率 | 常量 115200 | VISA Configure Serial Port |
| 波形图 | `Waveform Graph`（512 点） | 解码后的采样 |
| 频谱图 | `Waveform Graph` / `Intensity Graph` | 对采样做 FFT |
| 李萨如图 | `XY Graph` | x = 采样[i]，y = 采样[i+128] |
| 音色 / 声部 / 键状态 | `String Indicator` / `Boolean Array` | 帧头第 2/5/3/4 字节 |

### 3.2 程序框图（推荐结构）

```
  VISA Configure Serial Port (COMx, 115200, 8, None, 1)
              │
              ▼
  ┌───────────────────────── While Loop ─────────────────────────┐
  │  VISA Read (byte count = 576, timeout = 2000 ms)             │
  │              │                                                │
  │              ▼                                                │
  │  检查 byte[0]=0xA5 且 byte[1]=0x5A ？                          │
  │     否 → 丢弃 1 字节后重新同步（或用 VISA Read 读到 A5 5A 为止） │
  │     是 ↓                                                      │
  │  ┌─ 头部解码 ──────────────────────────────┐                  │
  │  │ timbre = byte[2]                        │                  │
  │  │ keys   = byte[3] OR (byte[4] << 8)      │                  │
  │  │ voices = byte[5]                        │                  │
  │  │ effect = byte[7]                        │                  │
  │  └─────────────────────────────────────────┘                  │
  │  ┌─ 采样解码 ──────────────────────────────┐                  │
  │  │ samples = byte[8..519] 转 I8 → (x-128)/128 │                │
  │  └─────────────────────────────────────────┘                  │
  │              │                                                │
  │      ┌───────┼────────┬─────────────┐                         │
  │      ▼       ▼        ▼             ▼                         │
  │   波形图   FFT→频谱   XY图(李萨如)  状态栏                     │
  └───────────────────────────────────────────────────────────────┘
```

### 3.3 关键注意点（LabVIEW 特有）

1. **帧同步**：连续 `VISA Read` 576 字节，如果中途错位就会一直错。
   稳妥做法：先读到 `0xA5`，再确认下一个是 `0x5A`，然后读剩余 574 字节。
2. **字节序**：`keys` 是高字节在 `byte[4]`，注意 LabVIEW 里做移位时要先转 U16。
3. **uint8 → 浮点**：LabVIEW 的 `U8` 转 `I8` 会按补码解释，这里要做的是
   `(U8 - 128) / 128`，**不要直接转 I8**。
4. **FFT**：512 点 @ 52734.375 Hz → 频率分辨率 **103 Hz**。
   用来区分 C4(261)/E4(330)/G4(392) 没问题；区分相邻半音（如 C4 与 C#4 差 16 Hz）不够。
5. **超时**：设 2000 ms。板子没发数据时 VISA Read 会超时，不要设太短以免误判。

---

## 四、Python 端（已完成，可直接对照实现）

`D:\Date\DeepseekDate\viz\synth_viz.py` 已经按这个协议实现好了，
LabVIEW 端可以直接参照它的解析逻辑：

```python
FRAME_LEN = 576

# 同步
i = buf.find(b"\xA5\x5A")
if i < 0: ...           # 继续等
del buf[:i]
if len(buf) < FRAME_LEN: ...  # 继续等

f = buf[:FRAME_LEN]; del buf[:FRAME_LEN]

timbre = f[2] & 0x07
keys   = f[3] | ((f[4] & 0x0F) << 8)
voices = f[5]
effect = f[7] & 0x03
samples = (np.frombuffer(f[8:520], dtype=np.uint8) - 128.0) / 128.0

# 延迟统计（小端）
u32 = lambda o: int.from_bytes(f[o:o+4], "little")
lat_ms   = u32(520) / 27000.0          # 1 clk = 1/27MHz → ms 换算除数 27000
lat_min  = u32(524) / 27000.0          # 0xFFFFFFFF 表示无数据
lat_max  = u32(528) / 27000.0
lat_cnt  = int.from_bytes(f[536:538], "little")
scan_ms  = u32(540) / 27000.0          # 按键采样间隔
hist     = np.frombuffer(f[544:576], dtype="<u2")   # 16 格，每格 2.4271 ms
```

### 不用 LabVIEW 时，可以用这个脚本快速验证板子有没有在发

```powershell
# 用 PowerShell 读 COM7，找 A5 5A 帧头
$sp = New-Object System.IO.Ports.SerialPort "COM7",115200,None,8,One
$sp.ReadTimeout = 1000
$sp.Open()
$frames = 0
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 3) {
  try { $b = $sp.ReadByte() } catch { continue }
  if ($b -eq 0xA5) {
    try { if ($sp.ReadByte() -eq 0x5A) { $frames++ } } catch {}
  }
}
$sp.Close()
"3 秒内收到帧数: $frames  （正常应约 45）"
```

---

## 五、当前已知限制

| 项 | 说明 |
|---|---|
| 音色字段 | 已接 `wave_sel[2:0]`，红外挥手切音色时该字段会跟着变 |
| 效果器字段 | 固定 0，效果器尚未实现 |
| 位深 | 只取采样高 8 位，量化噪声约 -48 dB，看波形/频谱够用（不影响真正的音频输出） |
| 采样连续性 | 每帧是"最近 512 个采样"的快照，帧与帧之间不连续（可视化的常规做法） |
| 延迟统计 | 只统计**FPGA 内部**（扫描同步 + 消抖 + 帧对齐），不含触摸芯片内部响应、也不含 DAC/功放模拟延迟；后两者分别用 `SCAN_PER` 单独上报和查数据手册 |
| 计数饱和 | `LAT_CNT` 是 16 位，超过 65535 次后回绕；演示时按几十下远达不到 |

---

*beta.2.5 · `uart_tx.v` + `uart_stream.v` + `latency_meter.v` · 引脚 69 · 115200 8N1 · 15 fps · 576 字节/帧*
