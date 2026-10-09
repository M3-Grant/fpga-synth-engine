# Gowin 烧录指南 —— 把复音合成器烧进 FPGA

> 板卡：Sipeed Tang Nano 20K（GW2AR-LV18QN88C8/I7）
> 顶层：`code/rtl/synth_board_top.v`
> 约束：`code/constraints/synth_board.cst`

---

## ⚠️ 最重要的一条：不要用 STC-ISP

**STC-ISP 是给 STC 单片机（8051 内核）烧 hex 的工具，和 FPGA 完全无关。**

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
```

### 1.2 软件

- **Gowin 云源软件教育版**（含 Programmer）
  下载：https://www.gowinsemi.com.cn/software/3
- 教育版**不需要 License**

### 1.3 确认板子被识别

插上 Type-C 线后，Windows 设备管理器应出现串口设备。
若无反应 → 换数据线；仍无 → 装驱动。

---

## 二、建工程（Gowin 云源软件）

### 2.1 新建工程

```
File → New → FPGA Design Project
  Name        : synth_board
  Create in   : 选一个纯英文路径（不能有中文！）
  Series      : GW2A
  Device      : GW2AR-18
  Package     : QN88
  Speed       : C8/I7
  Device Ver  : C
  → Part Number 应匹配出 GW2AR-LV18QN88C8/I7
```

### 2.2 添加源文件

**必须全部加入**（有依赖关系，缺一个综合会报 Unknown module）：

```
rtl/clk_div.v
rtl/debounce.v
rtl/i2s_tx.v
rtl/note_table.v
rtl/adsr.v
rtl/osc_voice.v
rtl/oscillator_array.v
rtl/note_alloc.v
rtl/mix_tree.v
rtl/synth_top.v
rtl/synth_board_top.v      ← 顶层
```

把 `synth_board_top` 设为 Top Module：
在 Hierarchy 窗口右键 → **Set as Top Module**

### 2.3 添加约束文件

```
constraints/synth_board.cst
```

### 2.4 综合与布线

```
Process 区：
  双击 Synthesize        → 等出现 √
  双击 Place & Route     → 等出现 √
```

**看 Messages 窗口有没有红色 Error**，Warning 可忽略。

---

## 三、生成码流（关键一步）

综合布线完成后，在：

```
impl/pnr/ 目录下会生成 .fs 文件
```

这就是要下载的**码流文件**（不是 hex，不是 bin）。

> 如果没找到 `.fs`，说明 Place & Route 没跑完或报错了。

---

## 四、下载到板卡

### 4.1 打开 Programmer

```
Tools → Programmer
或 Design 窗口右键 Programmer → Run
```

### 4.2 设置

| 项 | 值 |
|---|---|
| **Operation** | `SRAM Program`（临时，断电丢失）<br>`External Flash`（掉电保存） |
| **Device** | 应自动识别到 GW2AR-18 |
| **File** | 选 `impl/pnr/xxx.fs` |
| **USB Cable Setting** | 端口默认 0；识别不到就试 1 |

**调试阶段建议先用 `SRAM Program`** —— 下载快、反复改代码方便、不磨损 Flash。
确认无误后再写 Flash 保存。

### 4.3 下载

点 **Program/Configure** 按钮，等进度条走完。

---

## 五、上板现象与排查

### 5.1 正常现象

| 现象 | 说明 |
|---|---|
| `led[0]` 约 1.6Hz 闪烁 | **逻辑在跑**（最重要的判据） |
| 按 KEY1（引脚 87） | 听到 C4 音（笛声般的方波） |
| 再按 KEY1 | 停声（有短暂余韵） |
| 按 KEY2（引脚 88） | 音阶前进：C→D→E→F→G→A→B→C |
| `led[1]` 亮 | 正在发声 |
| `led[5:3]` | 当前音阶位置（二进制） |

### 5.2 排查顺序（按这个顺序查，别乱猜）

```
① led[0] 不闪？
   → 板子没配置成功。检查：器件型号选错？.fs 选错？下载端口？

② led[0] 闪，但没声音？
   → 逐项查：
     · 喇叭线是否焊到 SPK 焊盘（不是插 J4，实物没有 J4 座子）
     · 万用表测两个 SPK 焊盘之间是否开路、是否误接 GND
     · pa_en（引脚 51）是否为高
     · 按 KEY1 时 led[1] 是否亮（不亮说明按键没检测到）

③ led[1] 亮但没声音？
   → I2S 三根线（54/55/56）是否与约束文件一致
     （板载 MAX98357A 是固定接线，理论上不用管，但确认约束没写错）

④ 有声音但音调不对？
   → FCW 表问题。检查 note_table.v 是否被改动
     （必须用 fs = 52734.375 Hz 生成，不是 48000）

⑤ 声音断续/有杂音？
   → 可能供电不足，或摩托电流干扰。检查 USB 线供电能力
```

### 5.3 常见错误

| 报错 | 原因 |
|---|---|
| `Cable open failed` | 数据线问题 / 驱动未装 / 换 USB 端口 |
| 综合报 `Unknown module type` | 有 `.v` 文件没加入工程 |
| 综合报 `Port not found` | `.cst` 里的信号名与代码不一致 |
| 下载成功但无反应 | 引脚号写错，或下载了旧码流（改过代码要重新综合） |
| `No top module` | 没设顶层模块 |

---

## 六、两个必须记住的坑

### 坑 1：改了 `.cst` 必须重新综合+布线+生成码流

只重新下载旧 `.fs` 是没用的。这是新手最常见的"改了没反应"的原因。

### 坑 2：`.v` 文件不能带 UTF-8 BOM

带 BOM 会让 iverilog 报 `No top level modules`，Gowin 也可能出问题。

用编辑器时确认编码是 **UTF-8**（不是 "UTF-8 with BOM"）。

---

## 七、完整流程速查

```
1. New Project（GW2AR-LV18QN88C8/I7）
2. Add Files → 11 个 .v（含 synth_board_top.v）
3. Set as Top Module → synth_board_top
4. Add Files → synth_board.cst
5. Synthesize → 等 √
6. Place & Route → 等 √
7. Tools → Programmer
8. Operation = SRAM Program，选 impl/pnr/*.fs
9. Program/Configure
10. 看 led[0] 闪 → 按 KEY1/KEY2 听声音
```

---

## 八、想扩展成真正能演奏的电子琴

现在只有 2 个板载按键，用状态机切换音阶演示。

**要真正演奏**，接 8 个按键/触摸到 40pin 扩展口：

1. 在 `synth_board.cst` 里分配 8 个 GPIO
2. 每个按键对应一个 `note_idx`（见 `note_table.v` 的索引）
3. 把 `synth_board_top.v` 里的「2 键状态机」换成「8 路按键扫描」
   —— 接口已经留好，`note_valid/note_on/note_idx` 直接接上即可

交互硬件的接线方案见 `docs/08-交互硬件接线.md`。
