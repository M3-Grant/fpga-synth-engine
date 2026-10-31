# LabVIEW 上位机 —— 完整操作教程（照着做）

> 目标：李萨如图形 + 实时频谱 + 波形显示 + 状态栏 + 12 键指示
> 硬件：Tang Nano 20K，UART TX = 引脚 69，**115200 8N1**，15 帧/秒
> 你的环境：**LabVIEW 2024（32 位）** 已装

---

# 第 0 步：先解决两个前置条件（不做后面必然卡）

## 0.1 装 NI-VISA（**必须**，现在没装）

我检查过：`C:\Windows\System32\visa32.dll` **不存在**，也没有 `IVI Foundation` 目录。
LabVIEW 的 `VISA Configure Serial Port` / `VISA Read` 全部依赖它，不装就是一堆报错。

**操作：**

1. 开始菜单搜索并打开 **NI Package Manager**
2. 左侧 **Browse Products** → 搜索框输入 `VISA`
3. 勾选 **NI-VISA** → 点 **Install**（约 100~200 MB，免费）
4. 装完**重启 LabVIEW**
5. 装完后用文件管理器确认 `C:\Windows\System32\visa32.dll` 已出现

## 0.2 为什么不能用 Python Node（已确认，不用试了）

- 你的 LabVIEW 是 **32 位**（`C:\Program Files (x86)\...\LabVIEW.exe`，PE 头 x86）
- 本机 Python 是 **64 位 3.12**
- NI 官方要求**位数一致** → 32 位 LabVIEW 只能配 32 位 Python

所以本教程**全部用纯 G 实现**，不依赖 Python。

## 0.3 板子要烧上 beta.2.4（带 UART 的版本）

这版还没烧进去（板子当时没插）。烧好后用下面命令确认**哪个 COM 口在发数据**：

```powershell
foreach ($port in @('COM7','COM8')) {
  try {
    $sp = New-Object System.IO.Ports.SerialPort $port,115200,None,8,One
    $sp.ReadTimeout = 500; $sp.Open()
    $n = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 2) {
      try { if ($sp.ReadByte() -eq 0xA5) { try { if ($sp.ReadByte() -eq 0x5A) { $n++ } } catch {} } } catch {}
    }
    $sp.Close()
    "$port : 2 秒收到 $n 帧"
  } catch { "$port : 打不开" }
}
```

**哪个口能收到约 30 帧，就用哪个口**（正常 15 帧/秒）。

---

# 第 1 步：新建 VI

1. 打开 LabVIEW → **Blank VI**（或 File → New VI）
2. **Ctrl+S** 保存到 `D:\LV\SynthViz.vi`
   ⚠ 路径不要有中文和空格
3. 你会看到两个窗口：**前面板**（灰色）和**程序框图**（白色），用 `Ctrl+E` 互相切换

---

# 第 2 步：前面板放控件

从「控件选板」（`View → Controls Palette`）拖出下面这些：

| # | 控件 | 选板路径 | 设置 |
|---|---|---|---|
| 1 | VISA 资源名 | `I/O → VISA Resource Name` | 标签改成 **串口** |
| 2 | 停止按钮 | `Modern → Boolean → Stop Button` | 标签 **停止** |
| 3 | 波形图 | `Modern → Graph → Waveform Graph` | 标题 **波形显示** |
| 4 | 波形图 | 同上 | 标题 **实时频谱** |
| 5 | XY 图 | `Modern → Graph → XY Graph` | 标题 **李萨如图形** |
| 6 | 字符串指示器 | `Modern → String → String Indicator` | 标签 **音色** |
| 7 | 字符串指示器 | 同上 | 标签 **声部** |

**摆放建议**：1、2 放顶部；3、4、5 横向并排占中间；6、7 放底部。

---

# 第 3 步：里程碑 1 —— 先把串口读通

按 `Ctrl+E` 切到**程序框图**。

## 3.1 放 While 循环

1. 函数选板（`View → Functions Palette`）
2. `Programming → Structures → While Loop`
3. 在框图空白处**框一个大矩形**
4. 循环右下角的**条件端子**（红点），把前面板「停止」按钮拖进去接上
5. 在循环边框上右键 → **Add Shift Register**（加**一个**，后面帧同步会用到）

## 3.2 循环外放串口配置

在 While 循环**左边外侧**：

1. `Instrument I/O → Serial → VISA Configure Serial Port`
2. 前面板「串口」控件拖到 **VISA resource name** 接线端
3. 其余接线端右键 → **Create → Constant**：

| 接线端 | 值 |
|---|---|
| baud rate | `115200` |
| data bits | `8` |
| parity | `None` |
| stop bits | `1.0` |
| flow control | `None` |

4. **VISA resource name out** 接到 While 循环边框 → 在边框内侧右键 → **Create → Tunnel**

## 3.3 循环内读 1 个字节

1. `Instrument I/O → Serial → VISA Read`
2. **byte count** → 右键 Create Constant → `1`
3. VISA resource name 接上面进来的隧道
4. 输出 **read buffer** → `String → String/Array/Path Conversion → String to Byte Array`
5. 转出的 **U8 数组** → `Array → Index Array`，索引 `0`
6. 接到**数值指示器**（`Numeric → Numeric Indicator`），标签「读到」

## 3.4 运行验证（关键！）

前面板选你的 COM 口 → 点 ▶ 运行 → 看「读到」：

**它应该快速跳动，并且频繁出现 165（= 0xA5）**

| 现象 | 原因 |
|---|---|
| `VISA: (Hex 0xBFFF001E) 资源无效` | COM 口选错，换另一个 |
| `VISA: (Hex 0xBFFF0072) 资源被占用` | 串口助手或我的脚本占着，关掉 |
| `找不到 VISA 库` | NI-VISA 没装好，回 0.1 |
| 一直是 0 | 板子没烧 beta.2.4，或 UART 不是引脚 69 |

**这步过了，后面都是纯数据处理，不再依赖硬件。** Ctrl+S 保存。

---

# 第 4 步：里程碑 2 —— 帧同步（必须做对）

数据流里 `0xA5 0x5A` 是帧头。**必须先找到帧头再读后面 518 字节**，
否则数据错位，波形看起来像随机噪声。

## 4.1 结构

```
读到字节 ──[Equal? 165]──→ [Case 结构 True/False]
                              ├ True ↓
                              │   VISA Read(1) → ByteArray → Index[0]
                              │        └─[Equal? 90]──→ [内层 Case]
                              │                        ├ True → VISA Read(518) → 518 个 U8
                              │                        └ False → 丢弃
                              └ False → 丢弃
```

## 4.2 具体操作

1. 放 `Programming → Comparison → Equal?`，一端接「读到字节」，一端接常量 `165`
2. 放 `Programming → Structures → Case Structure`，把 `Equal?` 的布尔输出接到**选择端子**
   → 自动变成 **True / False** 两帧
3. **True 帧**里：再放一个 `VISA Read`（count=1）→ `String to Byte Array` → `Index Array[0]`
   → `Equal?` 与常量 `90`（0x5A）
   → 这个 `Equal?` 的输出再驱动一个**内层 Case**
   - 内层 **True**：`VISA Read`，count = **`518`** → `String to Byte Array` → 得到 518 元素 U8 数组
   - 内层 **False**：空
4. **False 帧**：空

## 4.3 把结果送出循环

1. 内层 True 分支里的 518 元素数组 → 接到 While 循环边框（自动成隧道）
2. 右键这个隧道 → **Use Default If Unwired**，默认值给一个**空 U8 数组常量**
3. 循环外接**数组指示器**（`Array → Array Indicator`，元素 U8）

## 4.4 验证

运行后数组大小应**稳定在 518**，索引 0（音色）应为 `0`。

> 大小乱跳 → 内层 False 分支没丢弃干净，检查一下。

---

# 第 5 步：里程碑 3 —— 解码成波形

现在手里是一个 **518 元素 U8 数组**，下标对应关系：

| 下标 | 含义 |
|---|---|
| 0 | 音色 |
| 1 | 键状态低 8 位 |
| 2 | 键状态高 4 位 |
| 3 | 声部数 |
| 4 | 保留 |
| 5 | 效果器 |
| **6 ~ 517** | **512 个采样** |

> ⚠ 因为帧头两字节是单独读掉的，所以这里下标**从 0 对应音色**，
> 而不是协议文档里写的 `byte[2]`。这是最容易搞混的地方。

## 5.1 取头信息

`Array → Index Array`，把「索引」接线端向下拖出 3 份，分别填 `0`、`1`、`3`：

- 索引 0 → 音色（先接数值指示器确认）
- 索引 3 → 声部数 → `String → Number to Decimal String` → 字符串指示器
- 索引 1、2 → 键状态：`索引1 + 索引2 × 256`

## 5.2 取 512 个采样

`Array → Array Subset`：输入接 518 数组，**index = `6`**，**length = `512`**

## 5.3 解码（**最关键，别做错**）

采样是**偏移二进制**，不是补码：

```
实际值 = (字节值 − 128) / 128
```

1. `Array Subset` 输出 → `Numeric → Conversion → To Double Precision Float`
   （数组会自动逐元素转换）
2. `Programming → Numeric → Subtract`，另一端常量 `128`
3. `Programming → Numeric → Divide`，另一端常量 `128`
4. 结果（512 个 DBL，范围 −1.0 ~ +1.0）→ 接前面板 **「波形显示」**

> ⚠ **千万不要**直接把 U8 接波形图，也不要用 "To Signed Integer"。
> 那样波形会整体偏移、形状错误。

## 5.4 验证

运行 → 按住板子任意一个键：

- 波形图显示**三角波**（不是噪声、不是直线）
- 松手回到接近 0 的直线

**核心功能通了。** 建议另存为 `SynthViz_M3.vi`。

---

# 第 6 步：里程碑 4 —— 实时频谱

## 6.1 计算 FFT

1. 从 5.3 那个「−128 再 ÷128」后的 512 点 DBL 数组**再接一路**出来
2. `Signal Processing → Transforms → FFT Power Spectrum and PSD`
3. 接线：

| 接线端 | 值 |
|---|---|
| X | 512 点 DBL 数组 |
| sampling freq (Fs) | `52734.375` |
| window | `Hanning` |
| averaging | `1` |

4. 输出 **power spectrum** 是 **256 点**（正半边）

## 6.2 显示

**最简单**：256 点数组直接接「实时频谱」波形图（X 轴是 0~255 序号，形状正确）。

**要真实频率轴**（答辩更好看）：

1. `Programming → Waveform → Build Waveform`
2. **Y** = power spectrum（256 点）
3. **dt** = `52734.375 / 512` = **`103.0`**（每 bin 103 Hz）
4. 输出接波形图 → X 轴 0 ~ 26 kHz

## 6.3 验证

- 不按键：频谱全低
- 按住 **C4**（引脚 27 碰 3.3V）：**261 Hz** 附近一个峰 + 递减谐波
- 同时按 **C4 + E4 + G4**：**3 个峰**在 261 / 330 / 392 Hz

> FFT 分辨率 = 52734.375 / 512 ≈ **103 Hz**，峰位有 ±50 Hz 误差是正常的。

---

# 第 7 步：里程碑 5 —— 李萨如图形

1. 取 5.3 解码后的 512 点数组，复制两份
2. **X 路**：`Array Subset` → index `0`，length `384`
3. **Y 路**：`Array Subset` → index `128`，length `384`（比 X 延迟 128 点）
4. 两路分别接 **「李萨如图形」XY Graph** 的 **X input** / **Y input**

**验证**：单音是较规则的闭合曲线；和弦变成复杂花纹（参考视频里就是这种）。

> 图形挤在角落或超出边界 → 两路各加一个 `Divide`，除以 `Array Max & Min` 的绝对最大值，压到 ±1。

---

# 第 8 步：里程碑 6 —— 状态栏与 12 键指示

## 8.1 音色文字

音色值（0~3）→ `Programming → Comparison → Equals to 0?`（或用 Case 结构）
→ 四个分支输出字符串常量 `"三角波"` / `"方波"` / `"锯齿波"` / `"脉冲波"`
→ `String → Concatenate Strings` 拼成 `"音色: 三角波"` → 接字符串指示器

## 8.2 12 键指示

1. 前面板放 12 个圆形 LED（`Modern → Boolean → Round LED`），横排，标签 `C4` `C#4` … `B4`
2. 键状态（U16）→ `Programming → Numeric → Number to Boolean Array`（喂 U16，别喂 U8）
3. 输出 16 个布尔 → `Array Subset` 取前 12 个 → 逐个接 12 个 LED

**验证**：碰引脚 27（C4）→ 第一个亮；碰引脚 25（B4）→ 最后一个亮。

---

# 第 9 步：收尾

1. While 循环里放 `Programming → Timing → Wait (ms)`，常量 **`60`**
   （必须加，否则空转吃满 CPU、图表刷太快看不清）
2. 循环**外侧**放 `Instrument I/O → Serial → VISA Close`，接隧道出来的 VISA resource name
3. `Ctrl+S` 保存

---

# 常见问题对照表

| 现象 | 原因 / 解决 |
|---|---|
| `VISA: 找不到库` | NI-VISA 没装 → 回 0.1 |
| 读不到任何字节 | COM 口错（试 COM8）/ 板子没烧 beta.2.4 / UART 不是引脚 69 |
| 数组大小不是 518 | 帧同步没做对，或内层 False 没丢弃 |
| 波形是一条直线 | 没按键（正常），或数据没接上 |
| 波形全是正的、形状怪 | **解码错了**，必须 `(x−128)/128` |
| 频谱峰位偏 | FFT 分辨率 103 Hz，正常误差 |
| 图表不刷新 | 忘了 Wait (ms)，或图表接线不在循环内 |
| 运行后马上停 | 停止按钮接线反了 |
| 串口被占用 | 关掉串口助手 / 我的 Python 脚本 |

---

# 验收标准

| 检查项 | 期望 |
|---|---|
| 波形显示 | 三角波，单键 1 个波形，和弦叠加 |
| 实时频谱 | 单音 1 峰，三和弦 3 峰（261/330/392 Hz） |
| 李萨如 | 单音闭合曲线，和弦复杂花纹 |
| 音色 | 显示"三角波"（FPGA 当前固定三角波） |
| 声部 | 按键时 1~4 |
| 12 键 LED | 对应键点亮 |
| 刷新率 | 约 15 fps |

---

# 附：协议速查

| 完整帧偏移 | 内容 | 518 数组下标 |
|---|---|---|
| 0 | `0xA5` | ——（单独读） |
| 1 | `0x5A` | ——（单独读） |
| 2 | 音色 | **0** |
| 3 | 键低 8 位 | **1** |
| 4 | 键高 4 位 | **2** |
| 5 | 声部数 | **3** |
| 6 | 保留 | **4** |
| 7 | 效果器 | **5** |
| 8~519 | 512 个采样 | **6~517** |

采样解码：`实际值 = (字节 − 128) / 128`，采样率 `52734.375 Hz`

---

*配套：`串口协议规格-给LabVIEW.md`*
*FPGA 端：`uart_tx.v` + `uart_stream.v`，引脚 69，115200 8N1，15 fps*
