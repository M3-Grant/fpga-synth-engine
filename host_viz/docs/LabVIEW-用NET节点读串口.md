# LabVIEW 用 .NET 节点读串口 —— 绕过 NI-VISA

> 适用：**你现在这个 32 位 LabVIEW 2024**，**不需要 NI-VISA**，不需要升级 LabVIEW
> 原理：LabVIEW 可以调用 .NET Framework 的 `System.IO.Ports.SerialPort`，
> 而 Windows 自带这个类库。功能与 VISA 等价。

---

## 为什么走这条路

| | VISA 路线 | **.NET 路线** |
|---|---|---|
| 需要装 NI-VISA | ✅ 必须（你现在装不上） | ❌ **不需要** |
| 需要升级 LabVIEW | 不需要 | ❌ 不需要 |
| 支持的 LabVIEW | 全部 | 2010+（默认带 .NET 支持） |
| 操作难度 | 简单（拖现成 VI） | 中等（放构造函数/调用节点） |
| 功能 | 完整 | **一样完整** |

**结论：你现在这个 2024 版就能直接干，不用下载任何东西。**

---

## 第 1 步：确认 .NET 支持可用

1. 新建 Blank VI → `Ctrl+E` 到程序框图
2. 函数选板 `Connectivity → .NET`，能看到 **Constructor Node**、**Invoke Node**、**Property Node**
   → 说明 .NET 支持正常

> 如果 `Connectivity` 里没有 `.NET`：`Tools → Options → 其他` 里检查 .NET 未被禁用。

---

## 第 2 步：创建串口对象

1. 放 **Constructor Node**（`Connectivity → .NET → Constructor Node`）
2. 弹出「Select .NET Constructor」对话框：
   - `Assembly` 选 **System**（在 `C:\Windows\Microsoft.NET\Framework\v4.0.30319\System.dll`）
   - `Objects` 选 **System.IO.Ports.SerialPort**
   - `Constructors` 选带 **5 个参数**的那个：
     `SerialPort(String portName, Int32 baudRate, Parity parity, Int32 dataBits, StopBits stopBits)`
3. 确定后节点上出现 5 个输入接线端，分别接常量：

| 接线端 | 常量类型 | 值 |
|---|---|---|
| portName | String | `COM7`（换成你那个能收到数据的口） |
| baudRate | Int32 | `115200` |
| parity | Enum | **None**（右键 → Create → Constant，下拉选 None） |
| dataBits | Int32 | `8` |
| stopBits | Enum | **One** |

4. 把这个节点放在 **While 循环外面**（只创建一次）

---

## 第 3 步：设置超时并打开

### 3.1 设置 ReadTimeout

1. 放 **Property Node**（`Connectivity → .NET → Property Node`）
2. 把它接在 Constructor 输出的**对象引用**后面
3. 点击属性节点 → 选择 **ReadTimeout**
4. 输入常量 `2000`（毫秒）

> ⚠ 不设这个的话，`ReadByte` 在没数据时会**永久阻塞**，VI 就卡死了。

### 3.2 打开串口

1. 放 **Invoke Node**（`Connectivity → .NET → Invoke Node`）
2. 接在 Property Node 后面
3. 方法选 **Open()**
4. 它没有返回值，只把对象引用往下传

### 3.3 把对象引用送进循环

把 Invoke Node 输出的**对象引用**接到 While 循环边框 → 循环内侧自动成隧道。
这样循环里就能反复用。

---

## 第 4 步：循环内读字节

### 4.1 读 1 个字节（帧同步用）

1. 循环里放 **Invoke Node**，对象引用接隧道
2. 方法选 **ReadByte()**
3. 返回值是 **Int32**（0~255；超时会抛异常）
4. 接一个数值指示器

**运行验证**：数值应该快速跳动，**频繁出现 165（0xA5）**。

> 如果一直报异常 → 说明超时了，即**串口没有数据**：检查 COM 口、板子是否烧了 beta.2.4。

### 4.2 读 518 字节（帧体）

用 `Read(Byte[] buffer, Int32 offset, Int32 count)`：

1. 先准备一个 **518 元素的 U8 数组常量**（`Array → Array Constant`，元素 U8，右键设为 518 个元素、全 0）
   —— 放循环**外**，用移位寄存器传进循环（避免每帧重新分配）
2. 循环里放 **Invoke Node**，方法选 **Read(Byte[], Int32, Int32)**
3. 三个参数：数组 = 那个 518 元素数组；offset = `0`；count = `518`
4. 这个方法的返回值是**实际读到的字节数**（Int32），**不是数组**
5. **数组参数是"按引用传入"的，读完后原数组已经被填充** ——
   所以要把那个数组从移位寄存器取出、经 Invoke Node 传进去，再接出来

> ⚠ .NET 数组在 LabVIEW 里是**引用传递**，`Read` 会把数据写回你传进去的那个数组。
> 这是 .NET 节点最容易搞错的点。

### 4.3 简化方案（如果 4.2 太绕）

**改成循环调 518 次 ReadByte()**：用一个 For 循环（N=518），每次 ReadByte 的结果用
"Build Array" 累积。

- 优点：逻辑简单、不会踩引用传递的坑
- 缺点：慢一点（518 次调用 ≈ 每帧多花几百微秒，15 fps 完全够用）

**建议先用 4.3 跑通，再优化成 4.2。**

---

## 第 5 步：之后的处理和 VISA 路线完全一样

拿到 518 元素 U8 数组后，后面的步骤与《LabVIEW搭建指南.md》**第 5 步开始完全一致**：

| 数组下标 | 内容 |
|---|---|
| 0 | 音色 |
| 1 | 键低 8 位 |
| 2 | 键高 4 位 |
| 3 | 声部数 |
| 4 | 保留 |
| 5 | 效果器 |
| **6~517** | **512 个采样** |

- 采样解码：`(字节 − 128) / 128` → 波形图
- FFT：`Signal Processing → Transforms → FFT Power Spectrum and PSD`，Fs = `52734.375`
- 李萨如：X = 下标 0~383，Y = 下标 128~511 → XY 图

---

## 第 6 步：收尾 —— 必须关闭串口

While 循环**外面右侧**：

1. 放 **Invoke Node**，方法选 **Close()**
2. 接从循环隧道出来的对象引用

> 不关闭的话，下次运行会报"串口被占用"，而且必须重启 LabVIEW 才能释放。

---

## 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| Constructor 里找不到 `System.IO.Ports` | Assembly 没选 `System`，或 .NET 支持被禁用 |
| `ReadByte` 一直抛异常 | 串口没数据（口错了 / 板子没烧 beta.2.4 / 引脚不对） |
| VI 运行后卡住不动 | **忘了设 `ReadTimeout`**，`ReadByte` 永久阻塞 |
| 报"端口被占用" | 上一个 VI 没 `Close()`；关掉串口助手；或重启 LabVIEW |
| `Read` 后数组还是全 0 | .NET 数组是引用传递，要真正把数组接线穿过 Invoke Node |
| 数值跳动但从不出现 165 | 波特率错了（必须是 115200） |

---

## 和 VISA 路线的取舍

| | VISA | .NET |
|---|---|---|
| 你的现状 | 装不上（版本冲突） | **立即可用** |
| 学习成本 | 低 | 中 |
| 稳定性 | 高 | 高 |

**建议**：先用 .NET 路线把 M1（读到 0xA5）跑通。
如果 NI-VISA 后来装好了，也可以随时换回 VISA —— 后面的数据处理部分**一行都不用改**。

---

## 诚实的提醒

这条路我能给你**精确的节点级步骤**，但我**不能替你画**（.vi 是二进制图形格式，
没有文本源码，我也无法用程序生成）。而且我不能远程操作你的 LabVIEW。

如果你觉得 .NET 节点太绕，还有一个选择：
**用我已经做好的 Python 上位机**（`synth_viz.py`），界面效果和参考视频一致，
可以直接录演示视频。比赛要求里并没有规定上位机必须用 LabVIEW。

---

*配套：`LabVIEW搭建指南.md`（VISA 路线）、`串口协议规格-给LabVIEW.md`*
