# fpga-synth-engine

> 2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 选题二
> 《基于 FPGA 的实时多音色合成电子乐器引擎》
> 平台：高云 **GW2AR-LV18QN88C8/I7**（Sipeed Tang Nano 20K，27 MHz）

**当前状态：`beta.5`（2026-10-28）**

- **两个独立演奏维度**：12 键选音高 + 红外挥手切音色
- **默认音色为钢琴**：6 次谐波加法合成，每个谐波独立指数衰减（音色由亮变暗）
- **24 个可综合模块 / 14 套回归测试**，仿真与综合全部通过
- **触摸输入支持两代硬件**：12 个 TTP223（并行 12 线）或 1 块 TTP229 钢琴模块（2 线串行）
- 提交截止：**2026-11-04 18:00**

---

## 一分钟上手

| 我想… | 怎么做 |
|---|---|
| **确认代码没错** | `cd code` → `powershell -ExecutionPolicy Bypass -File .\run_sim_all.ps1`，期望 `ALL SIMULATIONS PASSED (14 suites)` |
| **听声音（零接线）** | `cd code\synth` → `.\build.ps1 -Target self_test_12notes -Program sram`，自动循环钢琴十二音 |
| **跑完整整机** | `.\build.ps1 -Target synth_board12 -Program sram`（12×TTP223）或 `-Target synth_ttp229 -Program sram`（TTP229） |
| **读代码** | `code/rtl/synth_board12_top.v` → `synth_top` → `piano_engine` / `osc_voice` |

---

## 系统结构

```
   ┌─ 维度 1：音高 ──────────────────────────────────────────────┐
   │  12× TTP223（并行）─────┐                                   │
   │                         ├──► key_scan ──► 音符事件           │
   │  1× TTP229（2 线串行）──┘   (ttp229_scan 先解串)             │
   └───────────────────────────────┬──────────────────────────────┘
                                   ▼
                              note_alloc（4 声部分配）
                                   │
        ┌──────────────────────────┴──────────────────────────┐
        ▼                                                     ▼
   piano_engine                                        oscillator_array ×4
（6 谐波加法合成 + 衰减包络）                          （三角/方波/锯齿/脉冲）
        │                                                     │
        │                                                 adsr ×4
        │                                                     │
        │                                                 mix_tree
        ▼                                                     ▼
   piano_audio                                          mix_out[15:0]
        └──────────────────────┬──────────────────────────────┘
                               ▼   wave_sel == 3'b100 ? 钢琴 : 老通路
                           audio_out ──► i2s_tx ──► PCM5102A / MAX98357A
                                                          │
   ┌─ 维度 2：音色 ────────────────┐                    喇叭
   │  红外避障模块 ──► ir_gesture ──► wave_sel[2:0]（5 档环形）
   └──────────────────────────────┘
```

- **复音数**：`VOICE_NUM = 4`（改一个参数即可扩）
- **音域**：C4~C6 共 25 个半音；12 键版用 C4~B4 一个完整八度
- **音色**（`wave_sel[2:0]`）：`000` 三角 / `001` 方波 / `010` 锯齿 / `011` 脉冲 / **`100` 钢琴（默认）**
- **钢琴实现**：每声部 6 个谐波振荡器，权重按 1/h^1.5；每谐波独立指数衰减
  （基波 τ=310 ms、6 次谐波 τ=39 ms）；无 sustain，松键后制音器约 75 ms 归零
- **红外手势**：手在传感器前停留 80~1200 ms 算一次有效挥手，环形切换 5 档音色

---

## 构建 + 烧录

```powershell
cd code\synth
.\build.ps1 -Target synth_ttp229 -Program sram
```

| 参数 | 可选值 |
|---|---|
| `-Target` | `synth_board12`（12×TTP223 整机）/ `synth_ttp229`（TTP229 整机）/ `self_test_12notes`（零接线钢琴十二音）/ `self_test_square`（零接线方波对照）/ `ttp229_debug`（触摸位映射调试）/ `chord_demo` / `tone_test` / `synth_board` |
| `-Program` | `none` 只出码流 / `sram`（掉电即失）/ `flash`（掉电保持） |

> ⚠️ 引脚 **54/55/56 是 SSPI 专用脚**，脚本已固定加 `set_option -use_sspi_as_gpio 1`，少了会报 `ERROR (PR2017)`。
> ⚠️ `build.ps1` **必须保持纯 ASCII**：PowerShell 5.1 按 ANSI 读取无 BOM 的 `.ps1`，中文注释会破坏语法。

---

## 资源占用

| 配置 | Logic | Register | DSP |
|---|---|---|---|
| `synth_board12`（12×TTP223 + 钢琴 + 老波形） | 5950 / 20736（**29%**） | 2105（14%） | 3 / 24 |
| `synth_ttp229`（TTP229 + 钢琴 + 老波形） | 6035 / 20736（**30%**） | 2162（14%） | 3 / 24 |
| `self_test_12notes`（单声部钢琴自检） | 1304（7%） | 482（4%） | 1 |
| `self_test_square`（纯方波对照） | 235（2%） | 128（<1%） | 0 |
| `ttp229_debug`（触摸位映射调试） | 163（<1%） | — | 0 |

余量充足：BSRAM 完全未用（可做波表 / 混响），Logic 还剩约 70%。

---

## 目录结构

```
fpga-synth-engine/
├── 00-先看我.md               ← 总入口（模块清单 / 验证结果 / 引脚 / 踩坑）
├── prebuilt/                  ← 预编译码流
├── code/
│   ├── rtl/                   ← 24 个可综合 Verilog 模块
│   ├── sim/                   ← 测试台（14 套回归 + 音频导出）
│   ├── constraints/           ← 引脚约束（12 键版 / TTP229 版 / 调试版 / 旧工程）
│   ├── synth/build.ps1        ← 命令行综合 + 布线 + 烧录
│   ├── tools/                 ← gen_fcw.py / verify_piano.py（FFT 谐波验证）/ txt_to_wav.py
│   ├── run_sim_all.ps1        ← ✅ 回归入口（真判据：扫描 [FAIL]）
│   └── I2S调试记录.md          ← 踩坑全记录
├── docs/                      ← 18 篇项目文档（接线指南、审查报告、音色迭代）
├── iterations/                ← 历史迭代快照
└── tools/                     ← 环境初始化脚本
```

---

## ⚠️ 四条关键结论（务必记住）

### 1. 采样率是 52734.375 Hz，不是 48000

```
fs = 27 MHz ÷ 8 (BCK_HALF) ÷ 64 (BCK per LRCK) = 52734.375 Hz
FCW = f × 2^32 ÷ 52734.375
```
按 48000 算，A4 440 Hz 会跑成 **483 Hz**，明显跑调。`note_table.v` 由 `tools/gen_fcw.py` 生成，不要手改。

### 2. I2S 必须用标准 Philips 时序

数据在 LRCK 跳变后**延迟 1 个 BCK** 才发 MSB（1 无效位 + 16 数据位 + 15 填充位）。
左对齐写法会让所有样本左移一位 = 音量翻倍 + 削波失真。

### 3. 喇叭要焊、要带腔体

板载功放输出是 **SPK+ / SPK− 两个裸焊盘**，**BTL 桥接，两端都不能接地**。
外接喇叭**必须有密封后腔**：裸喇叭的低频会被声短路抵消，而钢琴基波（261 Hz）正好在这个坑里，听起来会像"电子琴"而不是钢琴。

### 4. 仿真通过 ≠ 综合通过

Gowin 能抓出 iverilog 不报的位宽问题（`EX3791`、`EX3784`）。
**每一版都必须跑一次 `build.ps1 -Program none` 确认 0 Error。**

---

## 版本演进

| 版本 | 内容 | 状态 |
|---|---|---|
| `demo0.0.1` / `demo0.0.2` | 单音发声链路 → 复音架构 + ADSR | ✅ |
| `beta.1` / `beta.1.01` | 12 键可演奏电子琴 + 编译修复 | ✅ |
| `beta.2` | 三角波、4 波形切换、功放门控、按键丢音修复、首次上板出声 | ✅ |
| `beta.2.1` | 音量 +6 dB（AMP 3/16 → 3/8） | ✅ |
| `beta.3` | 钢琴音色：6 次谐波加法合成 + 每谐波独立衰减 | ✅ |
| `beta.4` | 红外手势切音色（第二演奏维度） | ✅ |
| **`beta.5`** | TTP229 2 线串行触摸输入、零接线自检固件、`piano_engine` 单声部扫描修复、音量标定 | ✅ |

---

## 下一步

1. **硬件迭代**：PCM5102A + PAM8403 独立音频链路（详见 `docs/18-新硬件接线指南.md`）
2. **TTP229 位映射实测**：烧 `ttp229_debug`，逐键读出位号，填入 `synth_ttp229_top.v` 的 `TTP_BIT()` 表
3. 喇叭换 4 Ω 全频 + 密封腔体
4. 钢琴音色进阶：非谐性（inharmonicity）、同音多弦失谐、力度分层

---

## 编码与换行约定

| 规则 | 原因 |
|---|---|
| **所有文件 UTF-8 无 BOM** | `.v` 带 BOM 会让 iverilog 报 `No top level modules` |
| **`.gitattributes` = `* -text`** | 禁止 Git 自动转换换行符 |
| **`.bat` / `.ps1` 保持纯 ASCII** | cmd / PowerShell 5.1 按系统 ANSI 代码页读取，中文会破坏语法 |
| **其余文件保持原始字节** | 源码同时喂 iverilog 和 Gowin |
