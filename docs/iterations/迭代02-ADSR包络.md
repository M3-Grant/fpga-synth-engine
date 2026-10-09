# 迭代说明书 02 · ADSR 包络

> 迭代日期：2026-10-08
> 基线：迭代 01（复音 4、固定满幅包络）
> 本次目标：**让声音有起落**，从"硬切"变成有起音与余韵
> 状态：✅ 完成，仿真 11 项全部通过

---

## 一、这次做了什么

### 新增模块

| 模块 | 文件 | 功能 |
|---|---|---|
| **ADSR 包络发生器** | `rtl/adsr.v` | 四段包络状态机，每声部独立一份 |

### 修改模块

| 模块 | 改动 |
|---|---|
| `rtl/synth_top.v` | 把固定满幅 `voice_env` 换成 `generate` 生成的 N 份 ADSR |

### 新增测试

| 测试平台 | 覆盖内容 | 结果 |
|---|---|---|
| `sim/tb_adsr.v` | 复位/ATTACK/DECAY/SUSTAIN/RELEASE/归零 | 11 项 PASS |

---

## 二、四段状态机

```
        trig_pending
 IDLE ──────────────► ATTACK ──env到峰──► DECAY ──env到SUS──► SUSTAIN
   ▲                    │                    │                    │
   │                 rel_pending         rel_pending         rel_pending
   │                    │                    │                    │
   │                    └────────┬───────────┴────────────────────┘
   │                             ▼
   │                         RELEASE ──env到0──► IDLE
   └─────────────────────────────┘
                        ▲
                    trig_pending（余韵中重按 → 回到 ATTACK）
```

### 各阶段行为

| 状态 | 行为 | 转出条件 |
|---|---|---|
| `IDLE` | `env = 0` | 检测到按下 → `ATTACK` |
| `ATTACK` | `env += ATK_STEP` | `env ≥ 255-ATK_STEP` → `DECAY`；松开 → `RELEASE` |
| `DECAY` | `env -= DEC_STEP` | `env ≤ SUS_LEVEL` → `SUSTAIN`；松开 → `RELEASE` |
| `SUSTAIN` | `env = SUS_LEVEL` | 松开或 `gate=0` → `RELEASE` |
| `RELEASE` | `env -= REL_STEP` | `env ≤ REL_STEP` → `IDLE`；重按 → `ATTACK` |

---

## 三、测试结果

```
[检查1] 复位后 env=0、状态=IDLE                    PASS ×2
[检查2] ATTACK 单调递增（峰值 248）                PASS ×2
[检查3] DECAY → SUSTAIN，电平 = 128                PASS ×2
[检查4] SUSTAIN 保持稳定（300 clk 不变）           PASS
[检查5] RELEASE 单调递减                           PASS ×2
[检查6] 回到 IDLE 且 env 归零                      PASS ×2
                                        合计 11 项，0 错误
```

**集成测试（`tb_synth_top`）同时验证了 ADSR 的效果**：

| 指标 | 迭代 01（无包络） | 迭代 02（有包络） | 说明 |
|---|---|---|---|
| 单音峰值 | 2048 | **1160** | 包络在 SUSTAIN 电平（160/255）✅ |
| 复音 4 峰值 | 8192 | **3576** | 按比例下降，未削波 ✅ |
| 释放后 | 立即归零 | **余韵后归零** | 有 RELEASE 尾音 ✅ |

---

## 四、设计决策记录

### 4.1 为什么用"线性步进"而不是指数曲线

**最初**用的是指数逼近：`env <= env + (env >> SHIFT)`，听感更接近真实乐器。

**但踩了坑**：这个写法需要位宽扩展与饱和判断，`{1'b1, {8{1'b1}}}` 这类
拼接常量表达式在 iverilog 下行为不符合预期，导致 env 从 249 **跳变到 25**
（溢出回绕），状态机再也无法到达峰值。

**最终改用线性步进** `env <= env + ATK_STEP`：
- 位宽清晰，无截断风险
- 加减法资源极省
- 听感差异在这个阶段可以接受

> 指数曲线留作后续优化项。真要做，需要用"更宽的临时变量 + 显式饱和"，
> 而不是依赖拼接常量的位宽推断。

### 4.2 为什么需要事件锁存

`note_on` 的跳变可能发生在**任意时刻**，而包络只在 `sample_en`
（每 512 clk）时才更新。若直接在 `sample_en` 里判断边沿，会**漏掉事件**。

```
检测到跳变 → 置位 trig_pending / rel_pending
sample_en 处理完 → 清零
```

这与 `note_alloc` 处理 `note_valid` 的思路完全一致 —— **同一个模式复用**。

### 4.3 参数选择

| 参数 | 值 | 效果 |
|---|---|---|
| `SUS_LEVEL` | 160 | 持续电平 0.63 满幅，给混音留余量 |
| `ATK_STEP` | 8 | 起音约 32 个采样周期（0.6ms），干脆 |
| `DEC_STEP` | 2 | 衰减平缓 |
| `REL_STEP` | 3 | 余韵约 43 个采样周期（0.8ms） |

### 4.4 触发与门控逻辑

```verilog
.note_on (voice_trig[g] | voice_busy[g]),
.gate    (voice_busy[g])
```

- `voice_trig[g]`：分配瞬间的单周期脉冲 → 触发 ATTACK
- `voice_busy[g]`：声部占用状态 → gate=1 保持发声
- 声部被释放（busy 落下）→ gate=0 → 进入 RELEASE

---

## 五、踩的坑

| # | 现象 | 根因 | 修正 |
|---|---|---|---|
| 1 | ADSR 的 `env` 从 249 跳到 25 | 指数逼近的饱和判断失效，281 被截断成 25 | 改线性步进，彻底避开位宽陷阱 |
| 2 | `trig_pending` 永远捕获不到 | `note_on` 是单周期脉冲，而 `sample_en` 每 512 clk 一次 | 加事件锁存（同 note_alloc 的做法） |
| 3 | 集成测试"释放后残留 40" | **不是 bug** —— 是 RELEASE 余韵还没走完，测试等太短 | 延长测试等待到 30000 clk |
| 4 | 集成测试幅度断言失败 | **不是 bug** —— 加了包络后幅度本就该下降 | 按 SUSTAIN 电平重算期望值 |

> 坑 3 和 4 值得记住：**测试失败时先怀疑测试，再怀疑代码。**
> 这两次失败恰恰证明 ADSR 在正确工作。

---

## 六、与竞赛要求的对照

| 竞赛要求 | 迭代 01 | 迭代 02 |
|---|---|---|
| 复音 ≥ 4 | ✅ | ✅ |
| 单音实时变调 | ✅ | ✅ |
| **ADSR 包络** | ❌ | ✅ **已达成** |
| 多声部实时混音 | ✅ | ✅ |
| 纯硬件合成 | ✅ | ✅ |
| 延迟 ≤ 10ms | ✅ | ✅ |
| ≥2 维交互 | ❌ | ❌（迭代 3） |
| ≥32 复音（拓展） | ❌ | ❌（架构已支持） |

**基础要求还剩 1 项未达成：≥2 维交互。**

---

## 七、下一步（迭代 03）

**目标：交互层 —— 按键/触摸 → 音符映射**

1. 新建 `rtl/key_scan.v` —— 多路按键/触摸扫描与消抖
2. 建立"物理输入 → 音符索引"的映射表
3. 支持第二个维度（如：力度、滑音、或另一组键位）
4. 顶层加一个可直接上板的 `synth_board_top.v`
   （整合按键、LED 指示、I2S 输出，管脚按 Tang Nano 20K 排好）
5. 测试：验证按键→音符映射正确、无漏键/重复触发

**预期效果**：可以直接上板演奏的完整电子琴。

---

## 八、文件清单（累计）

```
新增（迭代 02）：
  code/rtl/adsr.v               ADSR 包络发生器
  code/sim/tb_adsr.v            包络测试

迭代 01 已交付：
  code/rtl/osc_voice.v          单声部振荡器
  code/rtl/oscillator_array.v   振荡器阵列
  code/rtl/note_alloc.v         音符分配器
  code/rtl/mix_tree.v           混音器
  code/rtl/synth_top.v          复音顶层（本次已集成 ADSR）
  code/sim/tb_note_alloc.v
  code/sim/tb_synth_top.v

沿用（demo0.0.1）：
  code/rtl/i2s_tx.v / note_table.v / clk_div.v / debounce.v
  code/rtl/pwm.v / led_ctrl_top.v / tone_test_top.v
```

---

## 九、复现方式

```powershell
cd D:\harness\fpga-synth-engine\code

# ADSR 单独测试
C:\iverilog\bin\iverilog.exe -g2005 -o sim_adsr.out rtl\adsr.v sim\tb_adsr.v
C:\iverilog\bin\vvp.exe sim_adsr.out

# 完整集成（含 ADSR）
C:\iverilog\bin\iverilog.exe -g2005 -o sim_synth.out `
  rtl\clk_div.v rtl\i2s_tx.v rtl\note_table.v rtl\adsr.v `
  rtl\osc_voice.v rtl\oscillator_array.v rtl\note_alloc.v `
  rtl\mix_tree.v rtl\synth_top.v sim\tb_synth_top.v
C:\iverilog\bin\vvp.exe sim_synth.out
```
