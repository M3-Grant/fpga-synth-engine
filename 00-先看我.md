# FPGA 实时多音色合成电子乐器引擎 — 2026-10-08 测试通过代码包

> 竞赛：2026 全国大学生嵌入式芯片与系统设计竞赛 · FPGA 创新设计赛道
> 选题：选题二《基于 FPGA 的实时多音色合成电子乐器引擎》
> 平台：高云 GW2AR-LV18QN88C8/I7（Sipeed Tang Nano 20K）
> 本包状态：**全部代码已通过 Icarus Verilog 仿真验证，0 错误**

---

## 一、这个包里有什么

```
fpga-synth-engine_20261008/
├── 00-先看我.md              ← 你正在看的这个
├── .gitignore
├── code/
│   ├── rtl/                  ← 可综合 RTL（真正下到板子里的代码）
│   │   ├── i2s_tx.v              ★ 标准 I2S 发送机（今天重写，9/9 通过）
│   │   ├── tone_test_top.v       ★ 440Hz 发声顶层（生死线工程）
│   │   ├── note_table.v          音名→频率控制字表（C4~C6，25 个半音）
│   │   ├── led_ctrl_top.v        LED 模式控制顶层（10/10 通过）
│   │   ├── clk_div.v             时钟分频
│   │   ├── debounce.v            按键消抖
│   │   └── pwm.v                 PWM 呼吸灯
│   ├── sim/                  ← 仿真测试台（不上板，只用于验证）
│   │   ├── tb_i2s_tx.v           I2S 时序 + 数据流 6 组向量
│   │   ├── tb_tone_test.v        测实际输出频率
│   │   ├── tb_led_ctrl_top.v     LED 模式机
│   │   └── tb_diag*.v            早期排查用，可忽略
│   ├── constraints/
│   │   ├── tone_test.cst         ★ 发声工程管脚约束（已按 Tang Nano 20K 排好）
│   │   └── led_ctrl.cst          LED 工程管脚约束
│   ├── tools/
│   │   └── gen_fcw.py            生成 note_table.v 的 Python 脚本
│   ├── run_sim_all.bat       ← 双击一键跑完三套仿真
│   └── I2S调试记录.md        ★ 踩坑全记录，答辩时很有用
└── docs/                     ← 全部项目文档（8 篇）
    ├── 07-接线指南.md          ★ 板卡引脚图 / 喇叭怎么焊
    ├── 08-交互硬件接线.md      ★ 触摸、红外、按键怎么接
    ├── 06-追赶排期（10-08起）.md  ★ 现在用的 5 周排期
    └── ...（01~05、README）
```

---

## 二、今天的验证结果（可截图放进答辩 PPT）

| 模块 | 测试项 | 结果 |
|---|---|---|
| `i2s_tx` | BCK 周期 296.3 ns | PASS（实测 296.0 ns） |
| `i2s_tx` | 每 LRCK 周期 BCK 数 = 64 | PASS（实测 64） |
| `i2s_tx` | 采样率 52734.4 Hz | PASS（实测 52734.3 Hz） |
| `i2s_tx` | 串行数据流 6 组向量 | PASS 6/6 |
| `tone_test_top` | 输出 440 Hz 方波 | PASS（实测 **439.86 Hz**，误差 0.03%） |
| `tone_test_top` | I2S 持续输出 | PASS（2216 个样本） |
| `led_ctrl_top` | 按键切模式 / 回绕 / 5 种模式输出 | PASS 10/10 |

**合计 21 项检查，0 错误。**

---

## 三、怎么复现仿真（两条路，选一条）

### 路 A：双击（最省事）
双击 `code/run_sim_all.bat`，会自动找 iverilog 并依次跑三套仿真。
看到三处 `全部通过：0 个错误` 就对了。

### 路 B：手动命令行
```bat
cd code
D:\Tools\iverilog\bin\iverilog.exe -g2005 -o sim_i2s.out    rtl\i2s_tx.v sim\tb_i2s_tx.v
D:\Tools\iverilog\bin\vvp.exe sim_i2s.out

D:\Tools\iverilog\bin\iverilog.exe -g2005 -o sim_tone.out rtl\i2s_tx.v rtl\tone_test_top.v sim\tb_tone_test.v
D:\Tools\iverilog\bin\vvp.exe sim_tone.out
```

> 工具路径说明：
> - iverilog/VVP：`D:\Tools\iverilog\bin`（v14，更严格，优先用这个）
> - GTKWave 看波形：`C:\iverilog\gtkwave\bin\gtkwave.exe`（只有这里有）
>   `gtkwave.exe tb_i2s_tx.vcd`

---

## 四、⚠️ 三个必须记住的坑（今天踩出来的）

### 1. 采样率不是 48000，是 52734.375 Hz
```
fs = 27 MHz / 8 (BCK_HALF) / 64 (BCK per LRCK) = 52734.375 Hz
```
频率控制字必须用 **`FCW = f × 2^32 / 52734.375`**。
如果按 48000 算，A4 440Hz 会变成 **483 Hz**，明显跑调。`note_table.v` 已经用正确值生成，别改。

### 2. 标准 I2S 有"1 位无效位"，不能用左对齐
数据要在 LRCK 跳变后 **延迟 1 个 BCK** 才开始发 MSB。
原来的代码是左对齐（LRCK 边沿立刻发 MSB），会导致 **所有采样值左移一位 = 音量翻倍 + 削波失真**。
`i2s_tx.v` 已改为标准 Philips I2S（1 无效位 + 16 数据位 + 15 填充位）。

### 3. 喇叭不是插 J4，是焊 SPK 焊盘
Tang Nano 20K 板载 **MAX98357A**（I2S DAC + D 类功放），
输出是板上 **两个裸焊盘 SPK+ / SPK−**，没有插座，**必须自己焊线**。
是 BTL 桥接输出，**两边都不能接地**，接反/接地会烧芯片。

---

## 五、下一步：上板让它响（生死线）

`tone_test_top.v` 就是生死线工程，管脚已经全排好：

| 信号 | 管脚 | 说明 |
|---|---|---|
| `clk` | 4 | 板载 27 MHz |
| `i2s_din` | 54 | → MAX98357A DIN |
| `i2s_lrck` | 55 | → MAX98357A LRCK |
| `i2s_bck` | 56 | → MAX98357A BCLK |
| `pa_en` | 51 | 功放使能，已固定为 1 |
| `led[0..5]` | 15~20 | 板载 6 颗 LED |

Gowin 操作流程：
1. 打开 `D:\Tools\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gwide.exe`
2. New Project → 选 `GW2AR-LV18QN88C8/I7` → 加 `code/rtl/i2s_tx.v` + `tone_test_top.v`
3. 导入约束 `code/constraints/tone_test.cst`
4. Synthesize → Place & Route → 双击 Programmer/下载
5. 焊上 8Ω 2W 喇叭到 SPK 焊盘 → 上电应该听到 **440 Hz 的"嘀"**

响了 = 生死线过了，剩下都是锦上添花。

---

## 六、文档速查

| 想干什么 | 看哪篇 |
|---|---|
| 板子引脚怎么接 | `docs/07-接线指南.md` |
| 触摸/红外/按键怎么接 | `docs/08-交互硬件接线.md` |
| 接下来 5 周怎么排 | `docs/06-追赶排期（10-08起）.md` |
| 喇叭买哪款 | `docs/04-硬件采购清单.md` |
| 各模块接口定义 | `docs/05-模块规格与接口定义.md` |
| I2S 到底哪里错了 | `code/I2S调试记录.md` |

截止提交：**2026-11-04**。
