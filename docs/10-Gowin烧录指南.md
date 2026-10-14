# Gowin 烧录指南 —— 把 12 键电子琴烧进 FPGA

> 板卡：Sipeed Tang Nano 20K（GW2AR-LV18QN88C8/I7）
> 对应版本：**beta.1.01**
> 顶层：`code/rtl/synth_board12_top.v`
> 约束：`code/constraints/synth_board12.cst`

---

## ⚠️ 最重要的一条：不用 STC-ISP

**STC-ISP 是给 STC 单片机烧 hex 的工具，和 FPGA 完全无关。**

| | STC-ISP | Gowin Programmer ✅ |
|---|---|---|
| 目标芯片 | STC 单片机（MCU） | FPGA / CPLD |
| 烧录文件 | `.hex` / `.bin` | **`.fs` 码流** |
| 通信 | 串口 ISP | JTAG |
| 你们需要吗 | **完全不需要** | **用这个** |

本工程是**纯 FPGA 逻辑**，没有 MCU 参与，任何 MCU 烧录工具都用不上。

---

## 一、烧录前的准备

### 1.1 硬件

```
□ Tang Nano 20K 板卡
□ Type-C 数据线（必须支持数据传输，不能是纯充电线）
□ 喇叭：两根线焊到板上 SPK+ / SPK- 焊盘
   ⚠ BTL 桥接输出，两端都不可接地，接错会烧 MAX98357A
   ⚠ 焊接前用万用表确认：两焊盘之间开路、任意一端未碰 GND
□ （可选）12 个 TTP223 触摸模块 + 杜邦线
```

### 1.2 软件

- **Gowin 云源软件教育版**（含 Programmer）
  - 本机已装：`D:\Gowin\Gowin_V1.9.11.03_Education_x64`
  - 启动：`IDE\bin\gw_ide.exe`
  - 教育版**不需要 License**

### 1.3 确认板子被识别

插上 Type-C 线后，Windows 设备管理器应出现串口设备。
若无反应 → 换数据线；仍无 → 装驱动。

---

## 二、新建工程

```
File → New → FPGA Design Project

  Name        : synth12            （纯英文，不能有中文）
  Create in   : 选一个纯英文路径    （路径不能含中文/空格！）
  Series      : GW2A
  Device      : GW2AR-18
  Package     : QN88
  Speed       : C8/I7
  Device Ver  : C
  → Part Number 应自动匹配出 GW2AR-LV18QN88C8/I7
```

> ⚠️ **工程路径不能有中文或空格**，否则 Gowin 会创建失败。

---

## 三、添加源文件（关键步骤）

**必须全部加入**，缺一个综合就会报 `Unknown module type`：

```
code/rtl/clk_div.v             时钟分频
code/rtl/debounce.v            按键消抖
code/rtl/key_scan.v            12 路按键扫描   ← 12 键版新增
code/rtl/i2s_tx.v              I2S 发送机
code/rtl/note_table.v          音符→FCW 表
code/rtl/adsr.v                ADSR 包络
code/rtl/osc_voice.v           单声部振荡器
code/rtl/oscillator_array.v    振荡器阵列
code/rtl/note_alloc.v          音符分配器
code/rtl/mix_tree.v            混音器
code/rtl/synth_top.v           复音合成器顶层
code/rtl/synth_board12_top.v   板级顶层  ← 设为 Top Module
```

**不需要**加入：`pwm.v`、`led_ctrl_top.v`、`synth_board_top.v`、`tone_test_top.v`

### 设为顶层模块

在 **Hierarchy** 窗口右键 `synth_board12_top` → **Set as Top Module**

---

## 四、添加约束文件

```
code/constraints/synth_board12.cst
```

### 引脚说明（已按官方例程核实）

| 信号 | 引脚 | 依据 |
|---|---|---|
| `clk` | 4 | 官方 audio.cst |
| `key[0..5]` | 27, 28, 29, 30, 31, 32 | 官方 RGB LCD 约束 |
| `key[6..7]` | 41, 42 | 官方 RGB LCD 约束 |
| `key[8]` | 48 | 官方 RGB LCD 约束（LCD_DEN） |
| `key[9]` | 77 | 官方 RGB LCD 约束（LCD_CLK） |
| `key[10]` | 79 | 官方 ws2812.cst |
| `key[11]` | 25 | 官方引脚框图（排针 LED_HS） |
| `i2s_din` / `i2s_lrck` / `i2s_bck` | 54 / 55 / 56 | 官方 audio.cst |
| `pa_en` | 51 | 官方 audio.cst |
| `led[0..5]` | 15~20 | 官方 flow_led.cst |

> 这些引脚原本是 RGB LCD / WS2812 接口，**不用 LCD 屏时可作普通 GPIO**。
> 已避开：4（时钟）、15~20（LED）、33~40（HDMI）、51/54/55/56（I2S+功放）、
> 69/70（UART）、**87/88（板载按键，不可占用）**。

---

## 五、综合与布线

```
Process 区：
  双击 Synthesize        → 等出现 √
  双击 Place & Route     → 等出现 √
```

**看 Messages 窗口有没有红色 Error**，Warning 可忽略。

---

## 六、生成码流

综合布线完成后，在：

```
impl/pnr/ 目录下会生成 .fs 文件
```

这就是要下载的**码流文件**（不是 hex，不是 bin）。

> 如果没找到 `.fs`，说明 Place & Route 没跑完或报错了。

---

## 七、下载到板卡

### 7.1 打开 Programmer

```
Tools → Programmer
或 Design 窗口右键 Programmer → Run
```

### 7.2 设置

| 项 | 值 |
|---|---|
| **Operation** | `SRAM Program`（临时，断电丢失）<br>`External Flash`（掉电保存） |
| **Device** | 应自动识别到 GW2AR-18 |
| **File** | 选 `impl/pnr/*.fs` |
| **USB Cable Setting** | 端口默认 0；识别不到就试 1 |

**调试阶段建议先用 `SRAM Program`** —— 下载快、反复改代码方便、不磨损 Flash。
确认无误后再写 Flash 保存。

### 7.3 下载

点 **Program/Configure** 按钮，等进度条走完。

---

## 八、上板现象与排查

### 8.1 正常现象

| 现象 | 说明 |
|---|---|
| `led[0]` 约 1.6Hz 闪烁 | **逻辑在跑**（最重要的判据） |
| 触摸任一按键 | 听到对应音高 |
| 同时触摸 3 个键 | 听到和弦（最多 4 音同时） |
| `led[1]` 亮 | 有音符在发声 |
| `led[2]` 闪一下 | 收到按键事件 |

### 8.2 排查顺序（按这个顺序查，别乱猜）

```
① led[0] 不闪？
   → 板子没配置成功。检查：器件型号选错？.fs 选错？下载端口？

② led[0] 闪，但没声音？
   → 逐项查：
     · 喇叭线是否焊到 SPK 焊盘（实物没有 J4 座子）
     · 万用表测两个 SPK 焊盘之间是否开路、是否误接 GND
     · 触摸按键时 led[2] 是否闪（不闪说明按键没检测到）
     · 按键是否接到约束里对应的引脚

③ led[2] 闪但没声音？
   → I2S 三根线（54/55/56）是否与约束一致
     （板载 MAX98357A 是固定接线，理论上不用管）

④ 有声音但音调不对？
   → note_table.v 是否被改动
     （必须用 fs = 52734.375 Hz 生成，不是 48000）

⑤ 触摸没反应？
   → TTP223 的 VCC/GND 是否接对
   → I/O 是否接到约束里对应的引脚
   → A/B 焊盘是否都没焊（焊了会改成低有效，与代码不匹配）
```

### 8.3 常见错误

| 报错 | 原因 |
|---|---|
| `Cable open failed` | 数据线问题 / 驱动未装 / 换 USB 端口 |
| 综合报 `Unknown module type` | 有 `.v` 文件没加入工程 |
| 综合报 `Port not found` | `.cst` 里的信号名与代码不一致 |
| 下载成功但无反应 | 引脚号写错，或下载了旧码流（改过代码要重新综合） |
| `No top module` | 没设顶层模块 |

---

## 九、降级验证方案（推荐先做这个）

如果 12 键接线还没弄好，建议**先用简单的工程验证板子和工具链**：

### 方案 A：生死线工程（最先做）

```
顶层     : tone_test_top.v
源文件   : i2s_tx.v, tone_test_top.v
约束     : tone_test.cst
现象     : 上电听到 440Hz 持续单音
```

这个工程只用 I2S 相关引脚，**不用接任何按键**，最适合验证板子和烧录流程是否通。

### 方案 B：2 键版

```
顶层     : synth_board_top.v
源文件   : clk_div.v, debounce.v, i2s_tx.v, note_table.v, adsr.v,
           osc_voice.v, oscillator_array.v, note_alloc.v, mix_tree.v,
           synth_top.v, synth_board_top.v
约束     : synth_board.cst
现象     : KEY1 发声/停声，KEY2 切音阶（板载按键 87/88）
```

用板载 2 个按键就能验证"复音 + 包络 + 发声"，不需要接任何外设。

**建议顺序**：方案 A（验证板子）→ 方案 B（验证复音）→ 12 键版（正式作品）

---

## 十、两个必须记住的坑

### 坑 1：改了 `.cst` 必须重新综合+布线+生成码流

只重新下载旧 `.fs` 是没用的。这是新手最常见的"改了没反应"的原因。

### 坑 2：`.v` 文件不能带 UTF-8 BOM

带 BOM 会让 iverilog 报 `No top level modules`，Gowin 也可能出问题。
编辑器里确认编码是 **UTF-8**（不是 "UTF-8 with BOM"）。

---

## 十一、完整流程速查

```
1. New Project（GW2AR-LV18QN88C8/I7，路径不能有中文）
2. Add Files → 12 个 .v（见第三节清单）
3. Set as Top Module → synth_board12_top
4. Add Files → synth_board12.cst
5. Synthesize → 等 √
6. Place & Route → 等 √
7. Tools → Programmer
8. Operation = SRAM Program，选 impl/pnr/*.fs
9. Program/Configure
10. 看 led[0] 闪 → 触摸按键听声音
```
