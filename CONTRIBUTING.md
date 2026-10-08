# ============================================================================
#  协作开发指南 —— fpga-synth-engine
#  GitHub 公开仓库 · 多人协作流程
# ============================================================================
#  本文件给所有队员看。第一次拿到仓库的人，从这里开始。
# ============================================================================

## 一、每个人第一次要做的三件事

### 1. 装 Git
下载：https://git-scm.com/download/win （一路默认安装即可）

装完打开 PowerShell 或 CMD，确认：
```bash
git --version
```

### 2. 配置自己的身份（**每个人都必须配，用你自己的名字和邮箱**）

```bash
git config --global user.name "你的名字"
git config --global user.email "你的GitHub邮箱"
```

> ⚠️ **这一步很重要**。如果所有人都用默认身份，提交记录里全是同一个人，
> 评委会认为这是单人作品，影响评分。

### 3. 克隆仓库

```bash
cd D:\          # 或你喜欢的目录
git clone https://github.com/你的账号/fpga-synth-engine.git
cd fpga-synth-engine
```

---

## 二、日常协作流程（每次改代码都这样）

```bash
# 1) 开始工作前：先拉取队友的最新改动（很重要！）
git pull

# 2) 改代码……（写 Verilog、跑仿真）

# 3) 查看自己改了什么
git status
git diff

# 4) 暂存并提交
git add -A
git commit -m "简述你做了什么"

# 5) 推送到远程
git push
```

**关键纪律**：
- **每次开工前先 `git pull`**。不拉就改，很容易冲突。
- **提交信息写清楚**：`fix: 修正 i2s_tx 的 LRCK 相位` 比 `改了一下` 有用得多。
- **小步提交**。不要攒一周的代码才提交一次。

---

## 三、拿不到最新代码？看这里

### 情况 1：`git pull` 报冲突（conflict）

说明你和队友改了**同一个文件的同一处**。

```bash
# 打开冲突的文件，会看到这样的标记：
#   <<<<<<< HEAD
#   你的改动
#   =======
#   队友的改动
#   >>>>>>> origin/main

# 手工改成你想要的样子（删掉那些 <<< >>> 标记），然后：
git add 冲突的文件
git commit -m "merge: 解决冲突"
git push
```

### 情况 2：本地改了东西但还没提交，想先拉队友的

```bash
git stash        # 把本地改动暂时收起来
git pull         # 拉取
git stash pop    # 把改动放回来
```

### 情况 3：改乱了，想放弃本地改动

```bash
git checkout -- 文件名      # 放弃某个文件的改动
git reset --hard HEAD       # 放弃所有未提交改动（⚠️ 慎用）
```

---

## 四、分工建议（避免冲突）

**最容易冲突的做法**：两个人同时改同一个 `.v` 文件。

**推荐做法**：按模块分工，一人一个文件。

| 队员 | 负责文件 | 说明 |
|---|---|---|
| A | `rtl/i2s_tx.v` | I2S 时序，核心且稳定，尽量别动 |
| B | `rtl/note_table.v` + `tools/gen_fcw.py` | 音高表（要改就改脚本重新生成） |
| C | `rtl/adsr.v`（待建） | ADSR 包络 |
| D | `rtl/note_alloc.v`（待建） | 音符分配器 |
| E | `docs/*.md` | 文档 |

**公共文件**（如 `tone_test_top.v` 顶层）改动前先在群里说一声。

---

## 五、绝对不要提交的东西

`.gitignore` 已经帮你们排除了，但手动注意：

| 不要提交 | 原因 |
|---|---|
| `*.vcd` | 仿真波形，几十 MB，可重新生成 |
| `*.out` | 仿真可执行文件 |
| `*.fs` / `impl/` | Gowin 综合产物，每人机器上重新生成 |
| `.vscode/` | 编辑器个人配置 |

如果发现这些进了仓库，用：
```bash
git rm --cached 文件名
```

---

## 六、⚠️ 两个编码红线（踩过坑，别再踩）

### 1. `.v` 文件不能带 UTF-8 BOM

带 BOM 会让 iverilog 报 `No top level modules` 而**编译失败**。

**怎么避免**：用 VSCode / Cursor 时，右下角编码选 **UTF-8**（不是 "UTF-8 with BOM"）。

**怎么检查**：如果队友的代码你拉下来编译不了，先怀疑这个。

### 2. 不要改 `.gitattributes`

仓库里设了 `* -text`（禁止换行符自动转换）。改掉它会让 Git 改写 Verilog 源码字节，
可能引入极难排查的问题。

---

## 七、常用命令速查

| 想干什么 | 命令 |
|---|---|
| 看当前状态 | `git status` |
| 看改了什么 | `git diff` |
| 看提交历史 | `git log --oneline` |
| 看某次提交改了什么 | `git show 提交号` |
| 拉取最新 | `git pull` |
| 推送 | `git push` |
| 看远程地址 | `git remote -v` |
| 撤销未提交的改动 | `git checkout -- 文件名` |
| 看看这个文件谁改的 | `git blame 文件名` |

---

## 八、第一次跑仿真

```bash
cd code
# Windows 双击 run_sim_all.bat，或命令行：
./run_sim_all.bat
```

需要 iverilog。如果队员电脑没有，装一个：
- 下载：http://bleyer.org/icarus/
- 安装后确认：`iverilog -V`

看到三处 `全部通过：0 个错误` 就说明环境正确。

---

## 九、提交截止与分支策略

**截止：2026-11-04 18:00**

**简单策略（推荐给 4~5 人小队）**：
- 所有人直接在 `master` 分支上工作
- 每次 push 前先 pull
- 每天至少 push 一次，避免积压

**如果冲突频繁，再升级到分支策略**：
```bash
git checkout -b feature/adsr      # 建自己的分支
# ...改代码...
git push -u origin feature/adsr   # 推自己的分支
# 然后在 GitHub 上发起 Pull Request，让队友 review 后合并
```

---

## 十、遇到问题怎么办

1. **先别慌**，Git 几乎不会真的丢东西。
2. `git status` 看当前状态，它会告诉你下一步能做什么。
3. 把报错原文发到群里（**别只说"报错了"**）。
4. 实在搞不定：`git stash` 保住你的改动，然后问人。
