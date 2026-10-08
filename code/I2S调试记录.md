# I2S 模块调试记录

> **状态：✅ 已解决（2026-10-08）。** 模块重写为标准 Philips I2S，仿真 9/9 项全部通过，
> 440Hz 验证工程实测 439.86 Hz。下面是完整的过程与结论，供答辩时讲"踩过的坑"。

---

## 一、v1 的三个问题（都已修）

### 问题 1：是"左对齐"时序，不是 I2S（真 bug）

I2S 规定：LRCK 跳变后的**第 1 个 BCK 上升沿是无效位**，数据从第 2 个上升沿开始。
v1 的代码是 LRCK 一跳变就把 MSB 送出去 —— 这是 Left-Justified 模式。

而市面上的 PCM5102A 模块基本都把格式引脚硬接成 I2S，
收到左对齐会表现为**左右声道错位、声音发闷、高频衰减**。

**修法**：帧结构改成 `[1 位延迟] + [16 位数据 MSB-first] + [15 位补零]`，
每声道 32 个 BCK，一个 LRCK 周期共 64 个 BCK。

### 问题 2：采样率 105 kHz（真 bug）

v1 每个声道只有 16 个 BCK（32 BCK/LRCK），
BCK = 3.375 MHz → fs = 105 kHz，不是任何标准音频速率，DAC 可能锁不上。

**修法**：改成 64 BCK/LRCK → **fs = 27000000 / 8 / 64 = 52734.375 Hz**。

### 问题 3："DIN 左移 1 位"（**不是模块的 bug，是 testbench 的 bug**）

仿真采到 `0x091A55E6`，期望 `0x1234ABCD`，看着像整体左移 1 位。
根因有两个，都在 testbench 里：

1. **没丢掉 I2S 的无效位** —— 采集窗口从 LRCK 跳变后第 1 个上升沿就开始采，
   等于从第 0 位之前开始，整个序列自然偏一位。
2. **在时钟沿上改样本** —— `#(CLK_PERIOD * 4000)` 正好落在 clk 上升沿，
   和模块内部 `l_reg <= sample_l` 的锁存打擂台，导致随机错值
   （表现为 T3、T5 偶发失败）。

**修法**：
- 采集时显式 `@(posedge bck)` 丢掉 1 个无效位，再采 16 位，再跳过 15 个补零
- 样本只在 `sample_req` 拉高时更新（模块给出的安全点）
- 整帧收齐后一次性写 `cap_frame`，避免读到"半帧"

---

## 二、v2 时序图（标准 Philips I2S，16bit 数据 / 32bit 帧）

```
LRCK  ____|‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾|________
BCK   _/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\/\_
DIN   X  D15 D14 ... D0  0 0 0 ... 0  X  D15 ... D0  0...
      ↑  ↑                            ↑
  LRCK跳变  ↑                      LRCK跳变
      第1个BCK上升沿=无效位
          第2个BCK上升沿起 = D15..D0（MSB first）
```

`bit_cnt` 0..63 的分配：

| bit_cnt | 动作 |
|---|---|
| 0 | LRCK 拉低（左声道）；锁存 `l_reg`/`r_reg`；DIN=0（无效位） |
| 1 | 输出左声道 MSB |
| 2 ~ 16 | 移位输出左声道 D14..D0 |
| 17 ~ 31 | DIN=0（补零） |
| 32 | LRCK 拉高（右声道）；DIN=0（无效位） |
| 33 | 输出右声道 MSB |
| 34 ~ 48 | 移位输出右声道 D14..D0；**此处发 `sample_req` 请求下一帧** |
| 49 ~ 63 | DIN=0（补零） |

---

## 三、仿真结果（iverilog）

```
[检查1] BCK 周期        实测 296.0 ns   （期望 296.3 ns）   [PASS]
[检查2] LRCK 周期 BCK 数 实测 64 个                          [PASS]
[检查3] 实际采样率       实测 52734.3 Hz（期望 52734.4 Hz）  [PASS]
[检查4] 串行数据流
        T1 L=1234 R=ABCD  [PASS]
        T2 L=FFFF R=0000  [PASS]
        T3 L=8001 R=7FFE  [PASS]
        T4 L=A55A R=5AA5  [PASS]
        T5 L=0001 R=8000  [PASS]
        T6 L=+max R=-max  [PASS]
全部通过：0 个错误
```

**440Hz 验证工程**（`tone_test_top.v`）：实测 439.86 Hz，误差 0.03%，2216 个样本连续输出。

---

## 四、⚠️ 最重要的一条：FCW 必须按 52734.375 算

DDS 输出频率 `f = FCW × fs / 2^32`。
如果沿用文档里的 48000：

```
FCW = 440 × 2^32 / 48000 = 39370534
实际输出 = 39370534 × 52734.375 / 2^32 = 483.4 Hz   ← 跑调约 1.6 个半音
```

**正确值**：`440 × 2^32 / 52734.375 = 35835935`
全部音符表已生成在 `rtl/note_table.v`，生成脚本 `tools/gen_fcw.py`。
改了主时钟或 `BCK_HALF`，必须重跑脚本。

---

## 五、文件位置

```
code/rtl/i2s_tx.v          # I2S 模块（标准 Philips I2S）
code/rtl/tone_test_top.v   # 440Hz 方波验证工程（上板第一件事）
code/rtl/note_table.v      # 音符 → FCW 查找表（C4~C6）
code/sim/tb_i2s_tx.v       # I2S 测试平台（v5）
code/sim/tb_tone_test.v    # 音高验证测试平台
code/constraints/tone_test.cst  # 引脚约束（clk=4, din=54, lrck=55, bck=56）
code/tools/gen_fcw.py      # FCW 生成脚本
```

**运行仿真**：
```powershell
cd D:\Competition\FPGA\FPGA\FPGA\code
D:\Tools\iverilog\bin\iverilog.exe -g2005 -o sim_i2s.out rtl\i2s_tx.v sim\tb_i2s_tx.v
D:\Tools\iverilog\bin\vvp.exe sim_i2s.out
```

---

## 六、上板后如果仍然没声音

按顺序排查，**不要跳步**：

1. 板卡供电灯亮不亮 → 换 Type-C 数据线（必须是数据线）
2. 设备管理器认不认得到串口 → 装 BL616 驱动
3. Programmer 里 Port 换 0 → 1
4. **万用表量 BCK 对地**：有约 1.7V 平均电压才说明时钟真的输出了
5. 逻辑分析仪确认 BCK = 3.375 MHz、LRCK = 52.7 kHz
6. 确认 DAC 的 FMT 引脚是 I2S 模式（问卖家）
7. 尝试 `BCK_HALF = 5`（fs = 42187.5 Hz）—— 有些 DAC 对非标准速率更宽容
8. **降级方案**：PWM 直推蜂鸣器，先验证"逻辑链是通的"，
   再回头解决 I2S。不要让这一项拖死整个项目。
