# fpga-synth-engine

> 2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 选题二
> 《基于 FPGA 的实时多音色合成电子乐器引擎》
> 平台：高云 **GW2AR-LV18QN88C8/I7**（Sipeed Tang Nano 20K，27 MHz）

**当前状态：`beta.2.1` —— 12 键可演奏电子琴，已上板出声，10 套仿真全部通过。**
提交截止：**2026-11-04 18:00**

---

## 一分钟上手

| 我想… | 怎么做 |
|---|---|
| **听声音** | 烧 `prebuilt/synth_board12_beta.2.1.fs`，或按"构建 + 烧录"从源码编 |
| **确认代码没错** | `cd code` → `powershell -ExecutionPolicy Bypass -File .\run_sim_all.ps1`，期望 `ALL SIMULATIONS PASSED (10 suites)` |
| **读代码** | 从 `code/rtl/synth_board12_top.v` 开始，往下追 `synth_top` → `osc_voice` / `adsr` / `mix_tree` |
| **看文档** | `00-先看我.md`（总入口）、`docs/`（14 篇） |

---

## 系统结构

```
                     ┌────────── 交互层（目前只有 1 维：12 键触摸）──────────┐
  12× TTP223 ──► debounce ──► key_scan ──► 音符事件(note_valid / note_on / idx)
                     └──────────────────────────┬────────────────────────────┘
                                                ▼
                                           note_alloc  (4 声部分配)
                                                │
       ┌────────────────────────────────────────┼───────────────────────┐
       ▼                    ▼                   ▼                       ▼
  note_table(FCW)  →  oscillator_array ×4  →  adsr ×4  →  mix_tree  →  audio_out
  (C4~C6, 25 半音)   (osc_voice: DDS + 4 波形)  (ADSR)     (饱和混音)   mix_out[17:2]
                                                                         │
                                                                    i2s_tx（标准 Philips I2S）
                                                                         │
                                                             MAX98357A（板载 DAC + 功放）
                                                                         │
                                                               SPK+ / SPK− 焊盘 → 喇叭
```

- **复音数**：`VOICE_NUM = 4`（改一个参数即可扩到 8/16）
- **音域**：C4~C6，25 个半音；`synth_board12_top` 用前 12 个（C4~B4 完整八度，含半音）
- **波形**：`wave_sel[1:0]` 运行时切换 —— `00` 三角 / `01` 方波 / `10` 锯齿 / `11` 脉冲 25%（当前固定三角波，接口留给第二交互维度）
- **包络**：ADSR 四段，`SUS_LEVEL = 160/255`
- **`pa_en`**：有音符才开功放，静音 155 ms 后自动关（降 MAX98357A 发热）
- **音量**：单声部稳态峰值 ≈ 1930 / 32767；4 声部同相最坏 ≈ 7.7k（23.5% 满量程，余量 12.6 dB，不削波）

---

## 构建 + 烧录（命令行，不需要建 Gowin 工程）

```powershell
cd code\synth
.\build.ps1 -Target synth_board12 -Program sram    # sram = 掉电即失，flash = 掉电保持
```

| 参数 | 可选值 |
|---|---|
| `-Target` | `synth_board12`（正式版）/ `synth_board`（2 键降级验证）/ `chord_demo`（零接线自动演示）/ `tone_test`（440 Hz 生死线） |
| `-Program` | `none` 只出码流 / `sram`（operation_index 2）/ `flash`（operation_index 9） |
| `-GowinHome` | 默认 `D:\Gowin\Gowin_V1.9.11.03_Education_x64`，装在别处要覆盖 |

产物：`build\<Target>\impl\pnr\<Target>.fs`

> ⚠️ 引脚 **54/55/56 是 SSPI 专用脚**，脚本已固定加 `set_option -use_sspi_as_gpio 1`，
> 少了这行布线报 `ERROR (PR2017)`。

---

## 目录结构

```
fpga-synth-engine/
├── 00-先看我.md               ← 总入口（模块清单 / 验证结果 / 引脚表 / 踩坑）
├── prebuilt/                  ← 预编译码流（可直接烧）
├── code/
│   ├── rtl/                   ← 17 个可综合 Verilog 模块
│   ├── sim/                   ← 测试台（10 套回归）
│   ├── constraints/           ← 4 个引脚约束（.cst）
│   ├── synth/build.ps1        ← 命令行综合 + 布线 + 烧录
│   ├── tools/                 ← gen_fcw.py（生成 note_table.v）/ 频谱分析脚本
│   ├── run_sim_all.ps1        ← ✅ 回归入口（真判据：扫描 [FAIL]）
│   ├── run_sim_all.bat        ← 旧入口，已改为转调 .ps1
│   ├── synth_demo*.wav        ← 仿真导出的试听音频
│   └── I2S调试记录.md          ← 踩坑全记录（答辩可用）
├── docs/                      ← 项目文档（接线 / 排期 / 评审 / 发布说明）
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

按 48000 算，A4 440 Hz 会跑成 **483 Hz**，明显跑调。
`note_table.v` 由 `tools/gen_fcw.py` 生成，**不要手改**，改就重新生成。

### 2. I2S 必须用标准 Philips 时序

数据在 LRCK 跳变后**延迟 1 个 BCK** 才发 MSB（1 无效位 + 16 数据位 + 15 填充位）。
左对齐写法会让所有样本左移一位 = 音量翻倍 + 削波失真。

### 3. 喇叭要焊，不能插

板载 **MAX98357A**，输出是两个裸焊盘 **SPK+ / SPK−**。
**BTL 桥接输出，两端都不能接地**，接错会烧芯片。焊前用万用表确认两端开路。

### 4. 仿真通过 ≠ 综合通过

Gowin 的 `EX3791`（位宽截断）能抓出 iverilog 不报的 bug。
**每一版都必须跑一次 `build.ps1 -Program none`，确认 0 Error。**

---

## 当前进度

| 版本 | 内容 | 状态 |
|---|---|---|
| `demo0.0.1` | 单音发声链路（I2S + 波形表） | ✅ |
| `demo0.0.2` | 复音架构（VOICE_NUM=4）+ ADSR | ✅ |
| `beta.1` / `beta.1.01` | 12 键可演奏电子琴 + 编译修复 | ✅ |
| `beta.2` | 三角波、4 波形切换、功放门控、按键丢音修复、首次上板出声 | ✅ |
| `beta.2.1` | 音量 +6 dB（AMP 3/16 → 3/8） | ✅ 已上板 |

| 资源（`synth_board12`） | 占用 |
|---|---|
| Logic | 2061 / 20736（10%） |
| Register | 841 / 15750（6%） |
| DSP | 2 / 24（8%） |
| BSRAM | 0（完全未用，可做 wavetable / 混响） |

### 下一步（最大缺口）

**第二交互维度尚未实现** —— 比赛硬性要求 ≥2 个独立可控演奏维度，目前只有"12 键触摸演奏"这一维。
`osc_voice` 的 `wave_sel[1:0]` 端口已预留，等 `gesture_ctrl` 接上（红外避障模块 → 手势切音色 / 弯音）。
接线方案见 `docs/08-交互硬件接线.md`。

---

## 编码与换行约定

| 规则 | 原因 |
|---|---|
| **所有文件 UTF-8 无 BOM** | `.v` 带 BOM 会让 iverilog 报 `No top level modules` |
| **`.gitattributes` = `* -text`** | 禁止 Git 自动转换换行符 |
| **`.bat` 保持 CRLF** | Windows cmd.exe 要求 |
| **其余文件保持原始字节** | 源码同时喂 iverilog 和 Gowin，任何自动改写都可能引入难查问题 |
