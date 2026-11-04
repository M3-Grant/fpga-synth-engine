# fpga-synth-engine

> 2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 选题二
> 《基于 FPGA 的实时多音色合成电子乐器引擎》
> 平台：高云 **GW2AR-LV18QN88C8/I7**（Sipeed Tang Nano 20K，27 MHz）

**当前状态：`v2.1`（2026-11-04）**

- **可演奏、可听、可看**：12 键 TTP229 触摸演奏 + 6 档音色 + 实时可视化上位机
- **三种合成路线**：多项式波形（三角/方波/锯齿/脉冲）、双弦 Karplus-Strong（钢琴 / 吉他）
- **三个演奏控制通道**：12 键定音高、红外 #1 当延音踏板、红外 #2 预留（遥测里已有独立指示）
- **片内延迟 5.0 ms**，37 ns 量化分辨率，硬件自动统计 min / max / avg / 抖动
- **遥测 103 fps**（576 B/帧，921600 bit/s），上位机 **120 fps** 自适应渲染
- 资源：LUT 5909 / 20736（29%）、Register 2706 / 15750（18%）、DSP 3 / 24

---

## 一分钟上手

| 我想… | 怎么做 |
|---|---|
| **确认代码没错** | `cd code` → `powershell -ExecutionPolicy Bypass -File .\run_sim_all.ps1`，期望 `ALL SIMULATIONS PASSED` |
| **听声音（零接线）** | `cd code\synth` → `.\build.ps1 -Target self_test_12notes -Program sram`，自动循环钢琴十二音 |
| **跑完整整机** | `.\build.ps1 -Target synth_ttp229 -Program sram`（TTP229 版）或 `-Target synth_board12 -Program sram`（12×TTP223 版） |
| **静音调试 / 调上位机** | `.\build.ps1 -Target synth_ttp229_quiet -Program sram`，触摸、延迟、串口全活，喇叭不响 |
| **打开上位机** | 双击桌面 `FPGA电子琴.lnk`，或 `host_ui\electron` 下 `npm i` 后 `npx electron .` |
| **读代码** | `code/rtl/synth_ttp229_top.v` → `synth_top` → `ks_array` / `karplus_strong` / `osc_voice` |

---

## 系统结构

```
   维度 1：音高
   12 键 TTP229（2 线串行，SCL=75 / SDO=76）
        │  ttp229_scan 解串
        ▼
   key_scan ──► note_alloc（4 声部，固定优先级 + 最久未用抢占）
                        │
        ┌───────────────┴────────────────┐
        ▼                                ▼
   oscillator_array ×4              ks_array（Karplus-Strong）
   （三角/方波/锯齿/脉冲）             双弦（仅钢琴）：长度 N / N+1
   + adsr ×4（48 ms 渐弱或立即静音）  钢琴 (a+b)/2 低通、y-(y>>>8)、τ≈0.63 s
        │                           吉他 (a+3b)/4 低通、y-(y>>>5)、τ≈0.07 s
        ▼                           松键且无踏板 y-(y>>>3)≈70 ms
   mix_tree                              │
        └───────────────┬───────────────┘
                        ▼  wave_sel==0..3 走老波形，4/5 走 KS
                    audio_out ──► i2s_tx ──► PCM5102A ──► PAM8403 ──► 喇叭
                        │
   维度 2：延音踏板（IR#1，引脚 85）
        遮挡 = 踩下 → 松键事件被丢弃，声部保持 busy
        抬脚且无按键 → note_alloc.all_off 一次性回收全部声部
                        │
   维度 3：旁路
   latency_meter（37 ns 量化）+ uart_stream（576 B/帧 @ 921600）
                        ▼
                 上位机（Electron，HTTP 8099）
```

- **复音数**：`VOICE_NUM = 4`（改一个参数即可扩；双弦铺满 4 声部会超资源，故做 3 双 + 1 单）
- **音域**：C4~C6 共 25 个半音；12 键版用 C4~B4 一个完整八度
- **音色**（`wave_sel[2:0]`）：`000` 三角 / `001` 方波 / `010` 锯齿 / `011` 脉冲 / **`100` 钢琴** / `101` 吉他
- **下行命令**（3 字节，921600 8N1）
  - `A5 01 <wave>` 切音色（0..5）
  - `A5 02 <0|1>` 松键渐弱：1 = 48 ms 渐弱收尾，0 = 立即静音

---

## 串口帧协议（576 字节，921600 8N1）

```
[0]        0xA5          帧头
[1]        0x5A
[2]        timbre        音色 0..5
[3..4]     keys          12 键位图
[5]        voices        活跃声部数（真实 popcount）
[6]        flags         bit0 = 本帧含延迟数据
[7]        eff           时间轴生效标志
[8..519]   512 点波形    8 位有符号
[520..527] lat_last / lat_min      （37 ns 单位）
[528..535] lat_max / lat_sum
[536..537] lat_cnt
[538..539] DECIM         抽取比（1 = 每采样上送）
[544..567] 12 音计数     （不可靠，UI 用 PC 端统计）
[568]      ir_hand       bit0 = IR#1(85)，bit1 = IR#2(73)，1 = 检测到手
[569..571] 挥手 / 过短 / 过长 计数
```

---

## 构建 + 烧录

```powershell
cd code\synth
.\build.ps1 -Target synth_ttp229 -Program sram
```

| 参数 | 可选值 |
|---|---|
| `-Target` | `synth_ttp229`（整机）/ `synth_ttp229_quiet`（静音台架）/ `synth_board12`（12×TTP223）/ `self_test_12notes` / `self_test_square` / `ttp229_debug` / `chord_demo` / `tone_test` / `synth_board` |
| `-Program` | `none` 只出码流 / `sram`（掉电即失）/ `flash`（掉电保持） |

产物在**仓库根 `build\<target>\impl\pnr\`**（不是 `code/synth/` 下）。

> ⚠️ 引脚 **54/55/56 是 SSPI 专用脚**，脚本已固定加 `set_option -use_sspi_as_gpio 1`，少了会报 `ERROR (PR2017)`。
> ⚠️ `build.ps1` **必须保持纯 ASCII**：PowerShell 5.1 按 ANSI 读取无 BOM 的 `.ps1`，中文注释会破坏语法。
> ⚠️ **配置是 SRAM，掉电即丢**，每次拔插 USB 都要重烧。

---

## 资源占用（v2.1）

| 配置 | Logic | Register | DSP |
|---|---|---|---|
| `synth_ttp229`（整机，双弦 KS，2026-11-04 缺陷修复后） | **6270** / 20736（**30%**） | **2755** / 15750（18%） | 2 / 24 |
| `self_test_12notes`（单声部自检） | 1304（7%） | 482（4%） | 1 |
| `self_test_square`（纯方波对照） | 235（2%） | 128（<1%） | 0 |
| `ttp229_debug`（触摸位映射调试） | 163（<1%） | — | 0 |

BSRAM 完全未用（可做波表 / 混响），Logic 还剩约 70%。

---

## 上位机（Electron）

```
host_ui/
├── electron/            主进程直连 CH340（serialport），内嵌 HTTP 8099
│   ├── main.js          /info、/stream、/cmd 三个端点
│   └── renderer/index.html   单文件 UI，无第三方图表库
└── web_ui/              浏览器版（需 bridge_server.py 转串口）
```

界面：李萨如图（Hilbert 解析信号）、实时频谱、波形、12 音统计、延迟面板、十二键键盘，
header 有「松键渐弱」开关与红外指示（两路亮灯 + 挥手计数）。

**`main.js` 的三个坑**（都踩过）：
1. `ser = await openSerial()` 必须接住返回值，否则 `/info` 永远 `serial_ok: false`
2. `/stream` 必须 `res.flushHeaders()`，否则无数据时响应头被缓冲、UI 无限重连
3. 日志写文件不写 stdout（外部 shell 退出后 stdout 管道关闭 → EPIPE 弹异常框）

---

## ⚠️ 五条关键结论（务必记住）

### 1. 采样率是 52734.375 Hz，不是 48000

```
fs = 27 MHz ÷ 8 (BCK_HALF) ÷ 64 (BCK per LRCK) = 52734.375 Hz
FCW = f × 2^32 ÷ 52734.375
```
按 48000 算，A4 440 Hz 会跑成 **483 Hz**，明显跑调。`note_table.v` 由 `tools/gen_fcw.py` 生成，不要手改。

### 2. I2S 必须用标准 Philips 时序

数据在 LRCK 跳变后**延迟 1 个 BCK** 才发 MSB（1 无效位 + 16 数据位 + 15 填充位）。
左对齐写法会让所有样本左移一位 = 音量翻倍 + 削波失真。

### 3. Karplus-Strong 的延迟线必须**同步读**

写成 `wire x_now = delay[rd];`（异步读）时 Gowin 无法把它映射到 BSRAM，
整块退化成触发器，DFF 从 2706 冲到 18573，直接超 15750 上限。

### 4. 双弦铺满 4 声部会超资源（实测 28648 LUT）

所以只有前 3 声部双弦（长度 N / N+1，约 1.3 Hz 拍频），第 4 声部单弦。

### 5. 仿真通过 ≠ 综合通过，且 **`.v` 文件不能带 BOM**

Gowin 能抓 iverilog 不报的位宽问题（`EX3791`、`EX3784`），每版都要 `-Program none` 确认 0 Error。
反过来，`.v` 带 UTF-8 BOM 会让 iverilog 报 `No top level modules`（Gowin 反而不报），
编辑器的"另存为 UTF-8 with BOM"是常见元凶。

---

## 版本演进

| 版本 | 内容 | 状态 |
|---|---|---|
| `demo0.0.1` / `demo0.0.2` | 单音发声链路 → 复音架构 + ADSR | ✅ |
| `beta.1` ~ `beta.2.1` | 12 键可演奏 + 4 波形切换 + 功放门控 + 按键丢音修复 + 音量标定 | ✅ |
| `beta.3` ~ `beta.5` | 钢琴加法合成（6 谐波）、红外挥手切音色、TTP229 2 线触摸、零接线自检 | ✅ |
| `v1.0.0` | 首次参赛提交：可演奏 12 键电子琴 + 上位机控制 | ✅ |
| `v2.0.0` | 103 fps 遥测、真实李萨如、Electron 上位机、双弦 KS 钢琴/吉他 | ✅ |
| **`v2.1`**（本地） | 松键渐弱开关、红外双路诊断（帧尾 568..571）、延音踏板 all_off 回收、UI 归一化修正 | ✅ 已上板 |

---

## 下一步

1. **红外极性/安装复核**：当前 IR#1 与 IR#2 同时报"有手"，需确认是常遮挡还是极性反了
2. **IR#2 表情控制**：手距映射力度 / 弯音（RTL 位置已留，帧里已有独立指示）
3. 喇叭换 4 Ω 全频 + 密封腔体（板载 SPK+/SPK− 是 BTL，两端都不能接地）
4. 钢琴音色进阶：非谐性（inharmonicity）、锤击滤波、力度分层

---

## 编码与换行约定

| 规则 | 原因 |
|---|---|
| **所有文件 UTF-8 无 BOM** | `.v` 带 BOM 会让 iverilog 报 `No top level modules` |
| **`.gitattributes` = `* -text`** | 禁止 Git 自动转换换行符 |
| **`.bat` / `.ps1` 保持纯 ASCII** | cmd / PowerShell 5.1 按系统 ANSI 代码页读取，中文会破坏语法 |
| **`host_ui` 与 `_uiviz` 的四个 index.html 必须完全一致** | 一份是开发目录、一份是仓库副本，改完要同步 |
