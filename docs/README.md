# FPGA 竞赛项目 · 总目录

> 赛题：高云半导体 · 选题二《基于 FPGA 的实时多音色合成电子乐器引擎》
> 板卡：Sipeed Tang Nano 20K（GW2AR-LV18QN88C8/I7）
> 建立：2026-09-22 ｜ 最近更新：2026-10-08
> **省赛提交：2026-11-04 18:00（剩 27 天）｜ 决赛：2026-11-20 ~ 11-22**
> ⚠️ **原 10 周排期已作废，请以 `06-追赶排期（10-08起）.md` 为准。**

---

## 📁 目录结构

```
FPGA/
├── README.md                       ← 本文件（总导航）
├── 01-总方案与路线图.md              ← 战略、时间表、架构、风险
├── 02-制作周期详细排期.md            ← 每周任务拆到天 + 验收标准
├── 03-项目清单.md                   ← 硬件/软件/代码/文档全清单
├── 04-硬件采购清单.md               ← 型号、价格、购买顺序、避坑
├── 05-模块规格与接口定义.md          ← 每个 Verilog 模块的接口
├── 06-追赶排期（10-08起）.md          ← ★ 当前生效的执行排期
├── 07-接线指南.md                     ← ★ 板载功放 / 外接 DAC 怎么接
├── 08-交互硬件接线.md                 ← ★ 触摸/红外/按键怎么接
│
├── code/                           ← 代码工程
│   ├── I2S调试记录.md               ← I2S 模块调试全过程（重要！）
│   ├── rtl/                        ← 设计源码
│   │   ├── clk_div.v               ✅ 已验证
│   │   ├── debounce.v              ✅ 已验证
│   │   ├── pwm.v                   ✅ 已验证
│   │   ├── led_ctrl_top.v          ✅ 已验证（5 模式 LED 控制器）
│   │   └── i2s_tx.v                ⚠️ 有 1 位偏移，待上板确认
│   ├── sim/                        ← 测试平台
│   │   ├── tb_led_ctrl_top.v       ✅ 6 项全通过
│   │   ├── tb_i2s_tx.v             ⚠️ 数据检查未通过
│   │   ├── tb_diag.v / tb_diag2.v / tb_diag3.v   ← I2S 调试脚本
│   ├── constraints/led_ctrl.cst    ← 引脚约束（真实引脚号）
│   ├── tools/                      ← 待补：波形表/音符表生成脚本
│   └── build/                      ← 待补：构建脚本
│
├── vendor-docs/                    ← 厂商官方资料
│   ├── led/                        ← LED 例程 + .cst 约束
│   ├── hdmi/                       ← HDMI 例程（含 testpattern、video_top）
│   ├── uart/                       ← UART 约束
│   ├── audio/                      ← I2S 音频例程（**I2S 调试可参考**）
│   ├── rgb_lcd/                    ← RGB LCD 例程
│   └── ws2812/                     ← WS2812 例程
│
└── reference/                      ← 参考资料
    └── 七家厂商选题指南逐一分析.md
```

---

## 🎯 当前状态速览

> 更新于 2026-10-08

| 类别 | 状态 |
|---|---|
| 方案与计划文档 | ✅ 完成（6 份） |
| 引脚定义（真实值） | ✅ 完成（Tang Nano 20K） |
| 通用模块（分频/消抖/PWM） | ✅ 仿真验证通过 |
| LED 控制器（练手项目） | ✅ 仿真验证通过 |
| **I2S 发送模块** | ✅ **已重写为标准 Philips I2S，仿真 9/9 通过** |
| **440Hz 验证工程** | ✅ **已写好，仿真实测 439.86 Hz** |
| **音符 FCW 表（C4~C6）** | ✅ 已生成 |
| 硬件采购 | ✅ 已下单 |
| Icarus Verilog 仿真器 | ✅ **已安装**（`D:\Tools\iverilog\bin`） |
| Gowin EDA 安装 | ❌ **今天必须装**（已下载，未安装） |
| **上板出声** | ❌ **生死线，目标 10-11** |

---

## 🚀 今天（10-08）要做的三件事

### 1. 确认板卡型号 ← 不知道这个，后面全白做
免费申请名单里"选题二"对应 **Tang Mega 60K（GW5AT-LV60PG484A）**，
但全套文档和 `.cst` 引脚是按 **Tang Nano 20K（GW2AR-LV18QN88C8/I7）** 写的。
先确认你手上到底是哪块，型号错了器件和引脚全错。
同时确认 DAC 模块型号（是否需 MCLK、是否 3.3V 逻辑）。

### 2. 安装 Gowin 云源软件教育版
- 地址：https://www.gowinsemi.com.cn/software/3 （需登录）
- **云源软件教育版 V1.9.11.03 For Win（422MB）**，安装时**勾选 GW2A/GW2AR 器件库**
- **云源编程器教育版（85MB）**
- 教育版**不需要 License**
- ⚠️ **安装路径和工程路径都不能有中文、空格**

### 3. 明天跑通官方点灯例程
用 `vendor-docs/led/blink_led`，走完
`新建工程 → 加 .v → 加 .cst → Synthesize → Place & Route → Program Device`。
看不懂英文界面就查 `../06-Gowin界面中英对照速查表.md`。

**详细到天的排期见 `06-追赶排期（10-08起）.md`。**

---

## 🛠 开发环境（本机已就绪）

| 工具 | 状态 | 位置 |
|---|---|---|
| Icarus Verilog | ✅ 已安装 | `D:\Tools\iverilog\bin` |
| GTKWave（看波形） | ✅ 已安装 | `C:\iverilog\gtkwave\bin` |
| Python | ✅ 已有 | 系统 Python |
| Git | ✅ 已有 | — |
| **Gowin EDA** | ❌ **待手动安装** | https://www.gowinsemi.com.cn/software/3 |

**运行仿真**（以 LED 控制器为例）：
```powershell
cd D:\harness\FPGA\code
D:\Tools\iverilog\bin\iverilog.exe -g2005 -o sim.out rtl\clk_div.v rtl\debounce.v rtl\pwm.v rtl\led_ctrl_top.v sim\tb_led_ctrl_top.v
D:\Tools\iverilog\bin\vvp.exe sim.out
```
**看波形**：
```powershell
C:\iverilog\gtkwave\bin\gtkwave.exe tb_led_ctrl_top.vcd
```

---

## 📌 关键技术要点（必须记住）

| 要点 | 值 |
|---|---|
| **系统时钟** | **27 MHz**（引脚 4），不是 50MHz |
| **LED 极性** | **低电平点亮** → `assign led = ~led_on;` |
| **LED 引脚** | 15, 16, 17, 18, 19, 20 |
| **按键** | 87（用户）、88（复位），按下为高电平 |
| **UART** | RX=70, TX=69 |
| **HDMI** | TMDS 差分，引脚 33–40，`LVDS25` |
| **音频采样率** | 48 kHz（设计目标） |
| **FCW 公式** | `fcw = f × 2^32 / 48000` |

完整引脚表见 `code/constraints/led_ctrl.cst` 和 `05-模块规格与接口定义.md`。

---

## ✅ I2S 模块已修复（2026-10-08）

原模块有两个**真 bug**，一个**假 bug**，全部解决：

| 问题 | 性质 | 处理 |
|---|---|---|
| 是"左对齐"时序不是 I2S（缺 1 位延迟） | 真 bug | 改为标准 Philips I2S 帧结构 |
| 采样率 105 kHz（非标准，DAC 可能锁不上） | 真 bug | 改为 64 BCK/LRCK，fs = **52734.375 Hz** |
| "DIN 左移 1 位" | **假 bug**（testbench 没丢无效位 + 时钟沿改样本竞争） | testbench 重写，9/9 通过 |

**⚠️ 最重要的一条**：`fs` 是 **52734.375**，不是 48000。
所有频率控制字必须按真实 fs 算，否则 A4 会跑成 483 Hz。
音符表已生成在 `code/rtl/note_table.v`，脚本 `code/tools/gen_fcw.py`。

详细调试过程见 `code/I2S调试记录.md`。

---

## 📅 五周追赶目标（2026-10-08 起）

| 周 | 日期 | 目标 | 里程碑 |
|---|---|---|---|
| **W1** | 10-08 ~ 10-11 | 环境 + 点灯 + **I2S 出声** | 🔴 耳机听到 440Hz ← **生死线** |
| **W2** | 10-12 ~ 10-18 | DDS 正弦 + 音符映射 | 频谱显示 440Hz 单峰，按键变音高 |
| **W3** | 10-19 ~ 10-25 | 2 维交互 + ADSR | 能弹旋律，声音有起落 |
| **W4** | 10-26 ~ 11-01 | 复音 4 + 测试模式 + 音色 | 🔴 频谱 4 个独立谱峰 |
| **W5** | 11-02 ~ 11-04 | 文档 + 视频 + **提交** | 省赛交付（11-04 18:00） |

详见 `06-追赶排期（10-08起）.md`（`02-制作周期详细排期.md` 已作废）。

---

## 🔗 常用链接

| 用途 | 地址 |
|---|---|
| 大赛官网 | http://www.fpgachina.cn/ |
| 高云竞赛页 | https://www.gowinsemi.com.cn/university/match2026 |
| 高云软件下载 | https://www.gowinsemi.com.cn/software/3 |
| 高云官方指导群 | QQ 群 **213923272** |
| Tang Nano 20K Wiki | https://wiki.sipeed.com/nano20k |
| 官方例程库 | https://github.com/sipeed/TangNano-20K-example |
