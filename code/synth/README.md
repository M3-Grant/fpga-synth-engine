# 命令行构建与烧录

Tang Nano 20K（`GW2AR-LV18QN88C8/I7`）的全自动构建脚本 —— **不用打开 Gowin IDE 建工程**。

## 用法

```powershell
cd D:\harness\fpga-synth-engine\code\synth

# 只构建（生成 .fs 比特流）
.\build.ps1 -Target tone_test

# 构建 + 烧到 SRAM（掉电即失，安全，适合调试）
.\build.ps1 -Target tone_test -Program sram

# 构建 + 烧到外部 Flash（掉电保持，适合最终交付）
.\build.ps1 -Target synth_board12 -Program flash
```

**可选参数**

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Target` | `tone_test` | `tone_test` \| `synth_board12` |
| `-Program` | `none` | `none` \| `sram` \| `flash` |
| `-GowinHome` | `D:\Gowin\Gowin_V1.9.11.03_Education_x64` | Gowin 安装目录 |

产物位置：`build\<Target>\impl\pnr\<Target>.fs`

---

## ⚠️ 关键坑：引脚 54/55/56 是 SSPI 专用引脚

GW2AR-18 上 **54 / 55 / 56 默认是 SSPI（SPI 配置）专用功能引脚**，直接用它们做 I2S 会被 P&R 拒绝：

```
ERROR (PR2028) : The constrained location is useless in current package
ERROR (PR2017) : 'i2s_din' cannot be placed according to constraint,
                 for the location is a dedicated pin (SSPI)
```

**必须在 Tcl 里显式打开 Dual-Purpose：**

```tcl
set_option -use_sspi_as_gpio 1
```

对应 Gowin IDE 图形界面里的
`Place & Route → Dual-Purpose Pin → Use SSPI as regular IO`。

官方 `audio` 例程的 `.gprj` 里已经勾了这一项，所以它才能用 54/55/56；
我们是命令行裸跑，必须自己加。

> 引脚分配本身没问题 —— 和官方 `vendor-docs/audio/src/audio.cst` 完全一致：
> ```c
> IO_LOC "PA_EN"  51;
> IO_LOC "HP_DIN" 54;
> IO_LOC "HP_WS"  55;
> IO_LOC "HP_BCK" 56;
> IO_LOC "clk"     4;
> ```

---

## 环境要求

| 项 | 值 |
|---|---|
| Gowin 云源 | `D:\Gowin\Gowin_V1.9.11.03_Education_x64` |
| 综合器 | `IDE\bin\gw_sh.exe`（Tcl 命令行） |
| 烧录器 | `Programmer\bin\programmer_cli.exe` |
| 环境变量 | 脚本自动设置 `GOWINHOME` |
| 驱动 | **免驱** —— 板载 BL616 模拟 FTDI FT2232H，Windows 自带 FTDI 驱动 |

## 硬件连接确认

```powershell
# 扫线缆
programmer_cli.exe --scan-cables L

# 扫器件（应输出 GW2AR-18C / ID 0x0000081B）
programmer_cli.exe --scan -d GW2AR-18C
```

设备管理器里应该看到：
- `USB Serial Converter A` / `USB Serial Converter B`（FTDI，ProblemCode = 0）
- `USB Serial Port (COMx)` ×2  ← 这两个是串口，**烧录不用它们**

## 可用的 operation_index

| 值 | 操作 |
|---|---|
| `0` | Read Device Codes |
| `2` | **SRAM Program**（掉电即失） |
| `4` | SRAM Program and Verify |
| `9` | **exFlash Erase,Program,Verify**（掉电保持） |
| `10` | exFlash Bulk Erase |
| `11` | exFlash Verify |

完整列表见 `programmer_cli.exe -h`。
