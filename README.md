# fpga-synth-engine

> 2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道 · 选题二
> 《基于 FPGA 的实时多音色合成电子乐器引擎》
> 平台：高云 **GW2AR-LV18QN88C8/I7**（Sipeed Tang Nano 20K）

---

## 仓库状态

| 项目 | 值 |
|---|---|
| 首次提交 | `46b5d9e` — feat: 第一代可行性验证完成（21 项仿真全部通过） |
| 分支 | `master` |
| 追踪文件 | 30 个（4012 行） |
| 代码状态 | **全部通过 Icarus Verilog 仿真验证，0 错误** |
| 提交截止 | **2026-11-04 18:00** |

---

## 快速开始

```bash
# 进入代码目录
cd code

# 一键跑完三套仿真（Windows，双击也可以）
run_sim_all.bat
```

看到三处 `全部通过：0 个错误` 即正常。

手动跑单套：
```bat
D:\Tools\iverilog\bin\iverilog.exe -g2005 -o sim_i2s.out rtl\i2s_tx.v sim\tb_i2s_tx.v
D:\Tools\iverilog\bin\vvp.exe sim_i2s.out
```

> 工具路径：iverilog 在 `D:\Tools\iverilog\bin`（v14），或退回到 `C:\iverilog\bin`；
> 波形查看用 `C:\iverilog\gtkwave\bin\gtkwave.exe`。

---

## 目录结构

```
fpga-synth-engine/
├── 00-先看我.md           ← 总入口，先读这个
├── .gitattributes         ← 禁止换行符转换（* -text）
├── .gitignore             ← 排除 *.vcd / *.out / *.fs / impl/ 等产物
│
├── code/
│   ├── rtl/               ← 可综合 RTL
│   │   ├── i2s_tx.v           标准 Philips I2S 发送机
│   │   ├── tone_test_top.v    440Hz 发声顶层（生死线工程）
│   │   ├── note_table.v       音名→频率控制字表（C4~C6，25 个半音）
│   │   ├── led_ctrl_top.v     LED 模式控制顶层
│   │   ├── clk_div.v / debounce.v / pwm.v
│   ├── sim/               ← 仿真测试台
│   ├── constraints/       ← 管脚约束（.cst）
│   ├── tools/gen_fcw.py   ← 生成 note_table.v 的脚本
│   ├── run_sim_all.bat    ← 一键仿真
│   └── I2S调试记录.md      ← 踩坑全记录
│
└── docs/                  ← 8 篇项目文档
    ├── 06-追赶排期（10-08起）.md   ← 当前使用的排期
    ├── 07-接线指南.md             ← 板卡引脚 / 喇叭焊接
    ├── 08-交互硬件接线.md         ← 触摸、红外、按键
    └── 01~05、README
```

---

## ⚠️ 三个关键结论（务必记住）

### 1. 采样率是 52734.375 Hz，不是 48000

```
fs = 27 MHz ÷ 8 (BCK_HALF) ÷ 64 (BCK per LRCK) = 52734.375 Hz
```

频率控制字必须用：
```
FCW = f × 2^32 ÷ 52734.375
```

**若按 48000 计算，A4 440Hz 会变成 483Hz，明显跑调。**
`note_table.v` 已用正确值生成，**不要手改**，要改就改 `tools/gen_fcw.py` 重新生成。

### 2. I2S 必须用标准 Philips 时序

数据在 LRCK 跳变后**延迟 1 个 BCK** 才开始发 MSB（1 个无效位 + 16 数据位 + 15 填充位）。

原左对齐写法会导致**所有采样值左移一位 = 音量翻倍 + 削波失真**。`i2s_tx.v` 已修正。

### 3. 喇叭要焊，不是插

Tang Nano 20K 板载 **MAX98357A**（I2S DAC + D 类功放），输出在板上的 **SPK+ / SPK− 两个裸焊盘**，没有插座。

**必须自己焊线，且是 BTL 桥接输出——两边都不能接地，接反/接地会烧芯片。**

---

## 编码与换行约定（重要，已实测）

| 规则 | 原因 |
|---|---|
| **所有文件 UTF-8 无 BOM** | `.v` 文件若带 BOM，iverilog 会报 `No top level modules` 而**编译失败** |
| **`.gitattributes` 设为 `* -text`** | 禁止 Git 自动转换换行符，避免改动 Verilog 源码字节 |
| **`.bat` 保持 CRLF** | Windows cmd.exe 要求 |
| **其余文件保持原始字节** | 源码要同时给 iverilog 和 Gowin 云源软件用，任何自动改写都可能引入难查问题 |

> 本次建仓时曾尝试给文件加 BOM，实测导致 iverilog 编译失败，已全部回退并记录在此。

---

## 当前进度

**已完成**：选题二可行性验证（I2S 出声链路全部打通，仿真 21 项 0 错误）

**下一步**：上板让它响

| 信号 | 管脚 | 说明 |
|---|---|---|
| `clk` | 4 | 板载 27 MHz |
| `i2s_din` | 54 | → MAX98357A DIN |
| `i2s_lrck` | 55 | → MAX98357A LRCK |
| `i2s_bck` | 56 | → MAX98357A BCLK |
| `pa_en` | 51 | 功放使能（固定为 1） |
| `led[0..5]` | 15~20 | 板载 6 颗 LED |

Gowin 流程：New Project（GW2AR-LV18QN88C8/I7）→ 加 `i2s_tx.v` + `tone_test_top.v`
→ 导入 `constraints/tone_test.cst` → Synthesize → Place & Route → Programmer。

**响 = 生死线过了，剩下都是锦上添花。**

详见 `00-先看我.md` 与 `docs/06-追赶排期（10-08起）.md`。
