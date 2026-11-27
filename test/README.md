# test/ —— G1 硬门禁：`build_nft` 逐字节一致

v1.1 把 1,985 行 shell 重写成 ucode，**第一风险不是功能少，而是同一个策略生成出不同的规则字节**。
本目录用一条命令把这件事判死：4 组合全等才算过，不等就红，没有"基本一致"。

对应规格：`SPEC.md` §8.1（G1 命令草案）、§5 的 C1、§1 的不变量 I2。

---

## 1. 为什么必须逐字节（不是洁癖）

`nft -c` 只判语法，不判语义等价。真机上这几类改动**语法都合法、字节都不同、行为已经变了**：

| 被"顺手优化"的东西 | 字节变化 | 真机后果 |
|---|---|---|
| `type filter hook forward priority filter + 10;` → `priority 10;` | 一处 | 是三个不同的钩子点；`dot_block` 落到别的规则前后，853 拦截对某些流量失效——用户以为禁了 DoT，其实没禁 |
| `redirect to :53` → `redirect to 53` | 一处 | 端口号语义不同（前者是"本机 53"，后者按 nft 版本解析），可能整段 redirect 报错或落到别的端口 |
| `ether saddr <mac> ... accept` 与 `ip saddr <ADH> ... accept` 顺序颠倒 | 两行换位 | 豁免规则必须排在 `redirect` 之前；一换位，AdGuardHome 自己的出站查询被劫持回自己 → 查询环 → 全屋 DNS 挂 |
| `udp dport 53` 换成 `meta l4proto udp udp dport 53` | 一处 | 语义等价但字节不同：升级瞬间 fw4 里的规则版本与 `/etc/nftables.d/` 里的文本不一致，`snapshot diff` 全是噪声，回滚时无法判断"到底哪一版在跑" |
| 结行多一个尾随空格 / 少一个 `\n` | 1 字节 | 见下 |

最后一行是本目录存在的直接理由：**只有逐字节比较，才能把上面整个类别一次性拦在门外。**
多一个空格在功能上是空的，但它让"用 `cmp` 判断文件是否需要 reload"这个动作失效——v1.0.1 的
`dot_sync` / `purge_dot` / `snapshot` 都建立在"文件内容就是现场状态"这个假设上，
字节对不上之后，每一次判断都退化成猜。

升级瞬间是**规则抖动最贵的时刻**：旧 daemon 还在跑（apk 升级不执行旧 `prerm`，见 SPEC §6.1），
新代码同时写同一个文件、同一批 uci。这时若两版输出有字节差，`fw4 reload` 会把内核里的规则集
在"旧版语义 → 新版语义"之间来回切，而 `mode` 字段还停在中间态。这就是"可能直接断网"的机制。

---

## 2. 文件清单

| 文件 | 作用 | 谁维护 |
|---|---|---|
| `golden/build_nft-v101.sh` | v1.0.1 `build_nft()` 的**原样抽取**（源文件第 556–598 行，43 行，逐字节相同）。只加了注释头、环境变量接线、执行尾 | **不许改**（见 §5） |
| `golden/nft-allow-nomac.nft` | fixture：`dot853=allow`，无 MAC | 只允许 `--regen` 重生成 |
| `golden/nft-allow-mac.nft` | fixture：`dot853=allow`，MAC=`aa:bb:cc:dd:ee:ff` | 同上 |
| `golden/nft-block-nomac.nft` | fixture：`dot853=block`，无 MAC | 同上 |
| `golden/nft-block-mac.nft` | fixture：`dot853=block`，MAC=`aa:bb:cc:dd:ee:ff` | 同上 |
| `nft_golden.sh` | G1 门禁本体：生成 → 比较 → 报差异 → 给退出码 | QA |
| `static_gates.sh` | SPEC §8.6：G0 元检查 + 六条静态门禁，见 §8 | QA |
| `selfcheck.sh` | G0 的实现：每条门禁 1 好 1 坏样本（自洽合成树，不依赖真实源码树） | QA |
| `modules.txt` | 模块清单（一行一个文件名，禁止注释/空行/CRLF）。新模块不登记 → G1-A1 红 | 模块作者 |
| `layers.txt` | 层图数据：`模块 L<层> dep1,dep2`。G3 用它做方向与环检测（白名单已作废） | 后端建、QA 用 |
| `known-large.txt` | 豁免表：`相对路径 <截止阶段>`，最多 2 条，随 `$PHASE` 自动失效 | QA |
| `audit_exports.awk` | A4 的解析器：从 SPEC §3.2 抽出「模块 → 导出名」。独立成文件是为了能单独跑、单独验 | QA |
| `size-watch.txt` | S1 数据：≥250 行的模块 + 计划拆出的目标（`模块 拆出到`），3 行 | 后端建、QA 用 |
| `unit/run_all.sh` | 单测统一 runner：逐套件 rc + 断言数对账 + 隔离模式，见 §9 | QA |
| `unit/*_test.uc` | 四个 L0/L1 模块单测（151 断言） | 后端写、QA 复核 |

固定参数（与 v1.0.1 uci 缺省一致）：`ADH=172.16.1.2`、MAC 取 SPEC §4.3 示例值 `aa:bb:cc:dd:ee:ff`。

fixture 现状（2026-11-24，本机生成 + r68s 交叉验证，**两边 sha256 完全相同**）：

| fixture | 字节 | sha256 |
|---|---|---|
| `nft-allow-nomac.nft` | 511 | `03204e0f0cd740fc7fde70a36962ae7025ebe72430c3f6336bc896de0df90c39` |
| `nft-allow-mac.nft` | 613 | `ca86b3fd1738c9c297948a6845f5da420cdc64080165e3e72b2a712e47a6bd32` |
| `nft-block-nomac.nft` | 702 | `0c723d44c1ea48a4f6cc46345fc71e6d215a61f6bd8e8d9db1eef93d220b45d5` |
| `nft-block-mac.nft` | 908 | `d9838155eef509f8bb5e9f09e643f1fec465389c7b0379b39062dc10fdfafaec` |

---

## 3. 怎么跑

### 3.1 门禁（CI / 任何机器）

```sh
sh test/nft_golden.sh          # rc=0 通过（或 SKIP），rc=1 不一致，rc=2 环境不全
```

判据两条，**都过才 PASS**：

| # | 比什么 | 守什么 | nft.uc 未实现时 |
|---|---|---|---|
| ① | golden shell 输出 == 入库 fixture | golden 没抽歪、fixture 没被污染 | **照常比** |
| ② | ucode `nft.build()` 输出 == golden shell 输出 | 重写后字节不变 | SKIP |

`nft.uc`（`luci-app-dns-switch/root/usr/libexec/dns-switch/nft.uc`）还不存在时，
脚本打印下面这行并 `exit 0`：

```
== 结论：SKIP nft.uc not implemented (P3) —— ① 4/4 通过，② 未执行 ==
```

**SKIP 不等于 PASS。** ①②都绿才是门禁放行；SKIP 只是"② 还没有对象可比"。
CI 里如果长期看到 SKIP，说明 P3 还没交付，不该当成绿灯记账。

### 3.2 不用脚本，手工比（两条命令，任何 Linux/设备）

```sh
DOT853=block ADH=172.16.1.2 MAC=aa:bb:cc:dd:ee:ff NFT_OUT=/tmp/g.nft \
  sh test/golden/build_nft-v101.sh
cmp /tmp/g.nft test/golden/nft-block-mac.nft && echo 一致
```

也可以引用式调用（不落盘也行）：

```sh
. ./test/golden/build_nft-v101.sh
build_nft /tmp/g.nft 'aa:bb:cc:dd:ee:ff'
```

### 3.3 语法校验：fixture 必须包一层 table 壳

`chain dns_hijack { … }` 是**表内片段**，不是完整 nft 文件。裸着喂给 `nft -c` 一定报错：

```
$ nft -c -f test/golden/nft-allow-nomac.nft
… Error: syntax error, unexpected '{', expecting string or last
```

这**不是 fixture 坏了**，而是 v1.0.1 `nft_check()` 本来就是这么做的：用独立表名当壳，
不能用 `inet fw4`（已存在会报错）。照抄它：

```sh
{ echo 'table inet _dnsswitch_chk {'; cat test/golden/nft-block-mac.nft; echo '}'; } \
  | nft -c -f -
```

`nft_golden.sh --regen --force` 会自动做这一步（本机没有 `nft` 时会明确打印
"语法校验未执行"，不假装通过）。

**真机结论（r68s，ImmortalWrt 25.12，nftables v1.1.6，kernel 6.12.116，2026-11-24）**：
4 个 fixture 包壳后 `nft -c` 全部通过；同一份 golden shell 在设备上重新生成的输出与入库
fixture `cmp` 全等；设备 `/usr/bin/dns-switch` 里现成的 `build_nft` 抽出来与
`golden/build_nft-v101.sh` 内的函数体 `cmp` 也全等（`EXTRACT_MATCH=YES`）。

---

## 4. fixture 怎么重新生成

```sh
sh test/nft_golden.sh --regen --force
```

**`--regen` 只是"改 golden 之后修 fixture"的工具，不是"让门禁变绿"的工具。**
防呆：不带 `--force` 直接拒绝（rc=1）。真要用，先回答三个问题：

1. 是 `build_nft-v101.sh` 被改动了吗？→ 那是**查错**，不是重生成：先 `cmp` 出差异，
   确认改动是"从 v1.0.1 重新抽了一遍"，而不是"我顺手优化了一下"。
2. 是 fixture 被污染了吗？→ 用 §2 的 sha256 表定位是哪一组、哪个字节。
3. 是 v1.0.1 升级了吗？→ 那不是本门禁的事：golden 必须钉在 `ebb0e2f` 上，
   v1.0.1 之后的行为变化要新开一条兼容项。

重生成后必须复核：`sha256sum test/golden/*.nft` 与 §2 表对得上才算没搞坏；
对不上就要在提交说明里写清为什么旧值作废。

---

## 5. 不许做的事（每条都能被机器抓到）

| 做法 | 为什么不行 | 谁抓到 |
|---|---|---|
| 改 fixture 让门禁变绿 | 等于把"字节变了"改成"基准变了"，I2 直接失效 | 脚本 ① 会报 `shell ≠ fixture`；`--regen` 要 `--force` |
| 改 `build_nft-v101.sh` 抄近路 | golden 一旦被"优化"，比的就不是 v1.0.1 | §2.3 的 `cmp` 一段 + 设备 `EXTRACT_MATCH` |
| `UCODE=/bin/true` 或指向假 ucode | 比对空转，永远绿 | 用非默认 ucode 时脚本打印 `WARN 使用了非默认 ucode` |
| nft.uc 存在却跑不了 ucode | 会被当成"和 v1.0.1 一致" | 脚本直接 `rc=2`，**不是 SKIP** |
| 把 SKIP 当 PASS 记账 | P3 没交付却显示绿 | 结论行写死"② 未执行" |
| CRLF 检出后不管 | 会伪装成"字节不一致"，浪费半天 | 每组先数 CR，非 0 直接 FAIL |

`golden/build_nft-v101.sh` 的**唯一允许改动**是注释头与环境变量接线；
函数体（第 34 行起那 43 行）与 `luci-app-dns-switch/root/usr/bin/dns-switch` 第 556–598 行
必须永远 `cmp` 全等。复核命令：

```sh
sed -n '/^build_nft()/,/^}/p' luci-app-dns-switch/root/usr/bin/dns-switch > /tmp/a.sh
sed -n '/^build_nft()/,/^}/p' test/golden/build_nft-v101.sh               > /tmp/b.sh
cmp /tmp/a.sh /tmp/b.sh && echo "golden 未被改动"
```

---

## 6. 自测记录（2026-11-24，证明这脚本真会红）

| 自测 | 手法 | 期望 | 实测 |
|---|---|---|---|
| A 抓污染 | 改 `nft-allow-mac.nft` 两处字节（`172.16.1.2`→`.3`、加一个 `!`） | FAIL + 指出组合 + diff | ✅ `FAIL dot=allow mac=aa:bb:…`，`shell=613B fixture=614B`，diff 前 20 行，rc=1 |
| B 抓 ucode 多空格 | 假 `nft.uc` + 假 `ucode`，每份输出多一个尾随空格 | 4 组全 FAIL | ✅ 4/4 FAIL，`511B→512B`，`+ ` 与 `\ No newline at end of file` 都打出来了，rc=1 |
| C 不会假红 | 同一假 ucode 改成原样输出 | PASS | ✅ 4/4 PASS，rc=0 |
| D 缺口 | 删掉 `nft.uc` | SKIP + rc=0 | ✅ 打印 SKIP，① 4/4 通过 |
| E 环境不全 | `nft.uc` 在、`ucode` 不在 | rc=2，**不许当通过** | ✅ `ERROR nft.uc 已存在但找不到 ucode 二进制` |
| F 防瞎重生成 | `--regen` 不带 `--force` | 拒绝，rc=1 | ✅ 拒绝并给出三条自查问题 |
| G 重生成一致 | `--regen --force` 后比 sha256 | 4 个文件字节不变 | ✅ 与原有 fixture 完全一致 |
| I CRLF 污染 | 给一个 fixture 每行加 `\r` | FAIL 并指明 CR 数 | ✅ `FAIL dot=block mac=<无> fixture 含 23 个 CR`，rc=1 |
| H1 busybox 实跑 | 在 r68s（busybox ash）跑整套 | 行为一致 | ✅ ① 4/4 PASS + SKIP，rc=0 |
| H2 设备上真的会红 | 在 r68s 改 `test/golden/nft-block-mac.nft` 一个字符 | rc=1 + 指名组合 | ✅ `broken_rc=1`，`FAIL dot=block mac=aa:bb:…`，diff 出 `reset`→`resett`；恢复后 rc=0 |

B 和 C 是成对的：**只测"能红"会写出永远红的脚本，只测"能绿"会写出永远绿的脚本。**
两个方向都钉住，这个比较器才有信息量。

---

## 7. 已知边界

1. **`nft.uc` 落地后第一次跑，可能要先改一行 import。** ucode 侧用
   `import * as nft from '<绝对路径>/nft.uc'`（SPEC §2.1 明确路径 import）。
   `nft_golden.sh` 顶部把这条语句收在 `UC_LOAD` 一个变量里——import 形式若有出入，只改那一行，
   比较逻辑不动。改完必须重跑自测 B（改一个空格必须红）。
2. **只覆盖 `build_nft` 一个函数。** `nft_check` / `purge_dot` / `dot_sync` 会碰 `/etc` 和内核，
   属于功能测试，不在 G1 范围内；它们的回归在 QEMU 断言 A5/A6 里。
3. **只覆盖 4 组合。** 不做 `ADH` 为 IPv6、MAC 非法格式、`dot853` 取第三值这三类——
   前两类在 v1.0.1 里由 `get_mac()` / 调用方先过滤，落到 `build_nft` 时永远是这 4 种形态之一。
   若哪天要在 `build_nft` 里支持 IPv6 上游，本表要同步扩组（扩组会改 C1 口径，记 `DECISIONS.md`）。
4. **本门禁不保证语义正确**，只保证"与 v1.0.1 一致"。v1.0.1 本身的规则如果有问题，
   这里会忠实地把问题一起继承下来——那不是回归，是基线。
5. 设备侧证据一次性采集，不做定时轮询（dropbear 曾在高频连接下被打崩）。

---

## 8. 静态门禁 `static_gates.sh`（SPEC §8.6：G0 元检查 + 六条）

```sh
sh test/static_gates.sh              # 日常：FAIL 才算问题，SKIP/WARN 只提示
sh test/static_gates.sh --strict     # 发版前：SKIP 也算失败
sh test/static_gates.sh --no-g0      # 跳过 G0（自检脚本内部用）
sh test/static_gates.sh --src DIR    # 检查另一棵源码树（自检脚本内部用）
```

| # | 门禁 | 判据 |
|---|---|---|
| **G0** | **元检查** | 调 `test/selfcheck.sh`：每条门禁 1 个好样本 + 1 个坏样本，好样本不红、坏样本必红 |
| 1 | 模块语法 | A1 清单一致性（`test/modules.txt` ↔ 实盘 `*.uc`）+ A2 `ucode -cmodule` 逐模块编译 + B `ucode -c` 编译程序式文件 |
| 2 | 单文件 ≤300 行 | `.uc` + rpcd 对象 + sh 入口（I5 说的是「单文件」） |
| 3 | 分层不越界 | `./x.uc` 的层号必须小于当前层；L5 入口不受限；SPEC 已声明的同层单向依赖打 WARN |
| 4 | 无孤儿能力缝 | 生产代码无人引用 → FAIL；只有测试引用 → WARN |
| 5 | 无 emoji | 前端（`htdocs/`）命中 → FAIL；非前端 → WARN（I1 保护，见 8.3） |
| 6 | ACL 覆盖 | SPEC §4.1 的 10 个方法必须都在 ACL 的 `read`/`write` 的 ubus 列表里，且不得多出 |

### 8.1 门禁 1 为什么是三段，而且判据换过两次

| 写法 | 结论 | 依据 |
|---|---|---|
| `ucode -c` | ❌ 对含 `export` 的模块必 255 | `Exports may only appear at top level of a module` |
| `ucode -e "import …"` | ❌ 能绿能红，但**会执行模块顶层代码** | 现在顶层是纯定义所以无害；P5 起任何顶层 IO 都会让"静态门禁"把程序跑一遍 |
| `ucode -cmodule` | ✅ 只编译，且**连带解析 import** | 把 `'./sh.uc'` 改成 `'./no_such.uc'` → 255 `Unable to resolve path for module` |

`-cmodule` 的**标志必须紧贴** `-c`：写成 `-c module` 会把 `module` 当文件名（`Failed to open "module"`）。
`-o /dev/null` 不能省：否则在 CWD 生成 `uc.out`，CI 从仓库根跑会把它写进源码树。

**四行形态矩阵**（实测，含我补的一行）：

| 文件形态 | `-cmodule` | `-c` |
|---|---|---|
| ① 有 export、无顶层 return（模块） | 0 | 255 |
| ② 无 export、无顶层 return（`main.uc`） | **0（天然假绿）** | 0 |
| ②' 同 ② 但**带 import** | 0 | **0**（2026-11-24 我补测；真实 `main.uc` 一定会 import，这条决定 B 段能不能覆盖它） |
| ③ 无 export、有顶层 return（rpcd 对象） | 255 | 0 |
| ④ 有 export + 仅函数内 return | 0 | 255 |

第 ② 行是 A1 存在的原因：`main.uc` 走 `-cmodule` 也是 0，**它没有自然红灯**，只能靠清单钉死。

### 8.2 `test/modules.txt` 的契约

纯文件名、一行一个，**禁止注释行 / 空行 / CRLF**。A1 用 `cmp` 比，多一行只报
`cmp: EOF on …`，看着像文件被截断 → 所以脚本对格式单独判一条，并在失败提示里直接写明
"新模块忘了登记？"。

未登记 → 红，多登记 → 红，目录里多出未登记文件 → 红。三面都堵住。

### 8.3 门禁 5：**空转的绿色比红色危险**

第一版用 `od -A n -v -t u1` 取字节流。r68s 上 `od: not found`（busybox 没编这个 applet），
而且**命令不存在时退出码是 0**，`2>/dev/null` 一吞 → awk 收到 0 字节 → 判 PASS。
注入 emoji 也照样 PASS。改了两层：

1. 取字节流改用 `hexdump -v -e '1/1 "%u\n"'`，没有 `hexdump` 才退回 `od`；
2. **扫描器自检**：每次先扫一个自造的 `U+1F525`，扫不出来直接 FAIL。两个工具都没有也 FAIL。

反向证明：塞一个只 `exit 0` 的假 `hexdump` 进 PATH → 门禁 rc=1 并报自检失败。

emoji 分两档的原因：9 处命中全在 v1.0.1 的 CLI 里（`✓`/`✗` 在 stdout、`⚠` 在注释），
而 stdout 受不变量 I1（与 v1.0.1 逐字节一致）保护。团队 P0 管的是「emoji 当**功能图标**」，
不是「终端里的状态符号」。所以前端命中判 P0，非前端一律 WARN 并全列出来——**不是放过，是不许静默**。

### 8.4 分层：白名单已作废，改成 `layers.txt` + 环检测

早期实现是"同层依赖逐个特批白名单"。架构师否掉了（U16）：**容忍久了没人记得为什么容忍**——
`log → sh` 就是这样被"转正"的。现在只有数据 + 一条判据：

```
test/layers.txt
  config.uc L1 uci,log,state     ← 模块 层号 依赖(逗号分隔；fs/uci 这类外部依赖不参与层图)
  lock.uc   L0 fs,fsutil
  log.uc    L0 sh
  sh.uc     L0 fs
  fsutil.uc L0 fs
  state.uc  L1 uci,log
```

| 检查 | 判据 |
|---|---|
| 覆盖性 | `layers.txt` 的模块集合 == 实盘 `*.uc`（排除 `main.uc`），两边差一个即红 |
| 跨层 | 只允许 `目标层 < 源层` |
| 同层 | 允许单向；**全图做环检测**，有环即红并打印环路径 |
| 一致性 | 源码里每个 `import` 都必须在 `layers.txt` 声明；声明了但没 import → WARN（过期声明） |

环检测是 awk 的 DFS（三色标记），实测输出：

```
✗ 依赖成环：log → sh → log
  同层允许单向，但不许绕回来。环上任意一条边都得断。
FAIL  [3/6 分层不越界] 1 处分层/依赖问题
```

**为什么不能把"声明了但没 import"直接判红**：它不是错，是**信号**——当前就抓到一处：
`layers.txt` 声明 `config → log`，但 `config.uc` 只 import `state`（log 的依赖已挪进 `state`）。
要么表过期、要么代码退化，得人看一眼。判成 WARN 就是为了让它可见而不误杀。

### 8.5 豁免机制 `known-large.txt`（fail-closed）

```
root/usr/bin/dns-switch P4                                  ← v1.0.1 shim，P4 要缩到 ≈130 行
root/usr/share/rpcd/acl.d/luci-app-dns-switch.json P4        ← ACL 还没 ubus 段，P4 补
```

| 规则 | 行为 |
|---|---|
| `$PHASE` 未设 | **不豁免，照旧红**（fail-closed：CI 配错时要全部报错，不能变成全部豁免） |
| `$PHASE` 早于截止阶段 | SKIP，**独立计数**，汇总打 `G2: 6 ok / 1 SKIP` |
| `--strict` | SKIP 转 FAIL |
| 条目上限 | 2 条，第 3 条即红（防豁免表变垃圾桶） |
| 到期 | 到截止阶段即红，不给续期 |
| 实现方式 | 只从文件读，**禁止 `case … continue` 硬编码跳过** |

### 8.6 负向对照（G0 自动跑的就是这张表）

`sh test/selfcheck.sh` 在**自洽的合成树**上跑（不复制真实源码树——真实树每天在变，
复制会让 G0 跟着一起红绿，那就不是门禁自检而是源码自检了）。合成树：
`sh.uc(L0) → config.uc(L1) → main.uc(L5)`，export 互相被真实消费。

```
== G0 元检查：每条门禁 1 好样本 + 1 坏样本 ==
  PASS  自检 好样本：6 条门禁全过（无 FAIL）
  PASS  自检 坏样本 模块语法错(export const x = ;) → 门禁 1/6 报红
  PASS  自检 坏样本 清单多一行(ghost_module.uc)     → 门禁 1/6 报红
  PASS  自检 坏样本 目录多模块未登记(zz_new.uc)      → 门禁 1/6 报红
  PASS  自检 坏样本 程序式文件语法错(main.uc)        → 门禁 1/6 报红
  PASS  自检 坏样本 文件 320 行(超 300)             → 门禁 2/6 报红
  PASS  自检 坏样本 import 了未声明的依赖(switch)     → 门禁 3/6 报红
  PASS  自检 坏样本 依赖成环(sh ⇄ config)            → 门禁 3/6 报红
  PASS  自检 坏样本 layers.txt 缺 config 那行         → 门禁 3/6 报红
  PASS  自检 坏样本 孤儿 export(无人引用)             → 门禁 4/6 报红
  PASS  自检 坏样本 前端 js 含 🎉                    → 门禁 5/6 报红
  PASS  自检 坏样本 ACL 缺 version                   → 门禁 6/6 报红
== G0 结论：PASS（12 条自检成对通过）==
```

「好样本必须不红」是**必须的**：只测坏样本会写出"任何输入都 FAIL"的门禁，看起来严格，
实际和第 3 条一样是废的（最后一定被 `|| true` 掉）。
`KEEP=1 sh test/selfcheck.sh` 可保留样本树查明细。

### 8.7 当前结论（2026-11-24，r68s，`PHASE=P3`）

```
PASS  [G0 元检查]     12 条成对自检通过
PASS  [1/6 模块语法]  清单一致 + 6 个模块 -cmodule 通过（state.uc 已登记）
PASS  [2/6 ≤300 行]   6 ok / 1 SKIP（root/usr/bin/dns-switch 1985 行，豁免到 P4）
PASS  [3/6 分层]      5 条依赖边无环、方向合法 + WARN 1（config→log 声明了但没 import）
PASS  [4/6 无孤儿]    + WARN（仅测试引用的 export，消费者模块 P3 才写）
PASS  [5/6 无 emoji]  + WARN 9（非前端符号，I1 保护）
SKIP  [6/6 ACL 覆盖]  豁免到 P4（PHASE=P3）
== 结论：5 PASS / 0 FAIL / 4 WARN / 1 SKIP ==
```

**不设 `PHASE` 时 G2/G6 会红——这是有意的**，验 fail-closed 就用这个姿势：
`sh test/static_gates.sh` 不给 `PHASE` 必须红，给了 `PHASE=P3` 才 SKIP，加 `--strict` 再红。

### 8.8 A4 导出列一致性 / A5 单一 uci 入口

**A4（双向）**：`SPEC §3.2` 的「对外导出」列 ↔ 各模块 `^export` 名单。

| 方向 | 判据 |
|---|---|
| SPEC 有、代码没有 | FAIL（契约写了但没实现） |
| 代码有、SPEC 没有 | FAIL（实现了但契约没登记） |

只比**已实现**的模块；未实现的模块列出来跳过（它们的缺失由 `modules.txt` 管）。

SPEC 表格是手写散文，解析器单独放在 `test/audit_exports.awk`，三个坑写在文件头：
反引号内的竖线会截断整行（`→null|{pid,...}`）、括号注释里会提到非导出名（`adh_ip`、
`ensure_config`）、斜杠组只取到第一个（`log/warn/err`）。规则是「只认三种形态」：
函数调用 `name(...)` / 斜杠组 `a/b/c` / 全大写常量 `KINDS`。

**A5**：`cursor(` 只许出现在 `state.uc`。假红来源两个都处理了：注释行（行首 `*`/`//`/`#`）
跳过、字符串里的（匹配点前双引号个数为奇数）跳过。

### 8.8b A6 / S1 / 标签自检

| 门禁 | 判据 | 为什么要有 |
|---|---|---|
| **A6 内建依赖** | 代码用了 `fs`/`uci` 就必须在 `layers.txt` 声明（FAIL）；声明了没用 → WARN | "撒谎必红，多写只提醒"——强行要求删会逼人删掉冷路径日志 |
| **S1 行数配额** | `wc -l` 出所有 ≥250 行的模块，与 `size-watch.txt` `cmp` | 规则从"绑文件名"改成"绑行数"之后，清单本人立刻又漏了一个——**清单只要没人比对就会漂** |
| **标签自检** | 运行完统计每个标签的**结论行**（PASS/FAIL/SKIP）恰好 1 次 | 本轮栽过三次"少一行/多一行"：`od` 空输入、`grep -c` 双零、G5/G6 重复定义导致 8 PASS（真实 6）。**门禁自己的输出也要被校验** |

标签自检的口径：只数 `PASS/FAIL/SKIP`，**WARN 允许多条**（一个门禁可以既有判决又有若干告警明细）。
第一版把 WARN 一起数，结果 G1/G4/G5 因为"判决 + WARN"被判成两次——自检自己先误报了一次。

### 8.9 设备上没有的命令（一律别用）

r68s 实测缺 `comm`、`diff`、`od`。这三个的共同点是**不存在时退出码也是 0**，
于是 `$(cmd ...)` 静默变成空串，门禁"永远绿"：

| 缺的命令 | 曾经造成的假绿 | 现在的做法 |
|---|---|---|
| `od` | emoji 扫描 0 字节 → 判 PASS | 换 `hexdump` + 扫描器自检 |
| `diff` | `diff && echo IDENTICAL` 的 echo 永不执行（看起来像"不一致"） | 一律 `cmp -s` |
| `comm` | A4 两个差集全空 → 报"双向一致" | 改成 awk 集合运算 |

**这一类已经出现四次**（还有 `grep -P` rc=2 被当"没命中"）。新增门禁时的纪律：
任何外部命令的**缺失**都必须能被发现——要么不用它，要么加运行期自检。

## 9. 汇总器 `unit/run_all.sh`

```sh
sh test/unit/run_all.sh               # 7 个组件：5 个单测 + G1 nft + 静态门禁
sh test/unit/run_all.sh --isolated    # 单测每套件前清空 /tmp/ds-v11（CI 用）
sh test/unit/run_all.sh --selftest    # 只验汇总器自己会不会假绿
sh test/unit/run_all.sh --verbose     # 附每个组件输出
```

### 9.1 判据：必须有结束标记，不是"没看到 FAIL 就算过"

组件被 kill / 超时 / 提前 exit 时不会有正常输出。若判据写成"PASS 数 ≥ N"或"没有 FAIL 就过"，
就会报成通过。所以每个组件**必须出现自己的结束标记**，没标记直接判失败，不管它输出了多少 PASS：

| 组件 | 结束标记 |
|---|---|
| 单测套件 | 末非空行 `^<name>_test: N passed, M failed$` |
| `nft_golden.sh` | 含 `^== 结论：` |
| `static_gates.sh` | 含 `^== 结论：` |

外加四道对账（针对单测）：自报数 vs 实际 `^PASS`/`^FAIL` 行数、断言数不许为 0、
`eq()/ok()` 调用点 vs 实际执行数（不一致打 WARN）、组件文件必须存在。

### 9.2 汇总器自检：4 个假套件

`--selftest` 造 4 个假套件喂给汇总器，必须只放过第一个：

```
PASS  good_test        3 断言  rc=0
FAIL  killed_test    缺结束标记（被 SIGKILL）
FAIL  silent_test    缺结束标记（一行输出都没有、rc=0）
FAIL  zero_test      0 断言（空测试不许算通过）
== 汇总器自检：PASS（4/4 判断正确，整体 rc=1）==
```

「静默 exit 0」是最危险的一种：没有任何输出 ≠ 一切正常。这条和 `od` 缺失、`grep -P` rc=2
是同一类病，本轮一共踩了三次。

### 9.3 `--isolated` 是被真事逼出来的

按字母序跑（config → fsutil → lock → log → sh）时，`config_test` 在全新 `/tmp` 上直接 FAIL
（rc=254，`load() ok=false E_UCI_COMMIT`）：它用 `fs.mkdir` 建 `/tmp/ds-v11/ut-cfg`，
而 `fs.mkdir` **不建父目录**，干净机器上父目录不存在。

它一直绿的原因：按 `sh→lock→log→config` 顺序跑时，`lock_test` 先用 `mkdir_p()` 把
`/tmp/ds-v11` 建了出来 → `config_test` 白捡一个父目录。**套件间的隐式顺序依赖**，
让"全绿"变成执行顺序的副产品。已修（补 `mkdir_p` + 收尾断言），并由 `--isolated` 固化成门禁。

### 9.4 基线要带条件（否则下一个人会误读）

数字本身不说明覆盖面。当前这套基线里有一类断言**只证明"空壳会显式失败"，不证明功能**：

```
switch_test 里 5 条：off / apply_intent / init / drill 各一条 eq + 一条 message 断言
```

也就是说 `595 断言全绿` ≠ "这四个子命令能用了"，只等于"它们还没实现时**会明确报 E_INTERNAL 而不是假装成功**"。

**引用基线时必须连条件一起引**：

| 说法 | 是否成立 |
|---|---|
| "595 断言全绿" | ✅ 成立 |
| "switch 的 off/init/drill/apply_intent 已实现" | ❌ **不成立**，它们是空壳 |
| "P3 门禁全绿" | ✅ 成立（门禁侧无红） |
| "P3 功能完成" | ❌ 不成立（`main`/rpcd/RESCUE 未做） |

这条和第 6 节"SKIP 不等于通过"是同一个道理：**数量本身不是证据，覆盖到哪才算**。

### 9.4 现状（r68s，2026-11-24，两轮连跑）

```
PASS  config_test     68 断言  rc=0
PASS  fsutil_test     26 断言  rc=0
PASS  lock_test       57 断言  rc=0
PASS  log_test        37 断言  rc=0
PASS  sh_test         22 断言  rc=0
PASS  nft_golden     rc=0
FAIL  static_gates   rc=1   （A4 抓到 3 处导出与 SPEC §3.2 不符，见下）
== 合计：11 组件 / 371 单测断言 / 1 失败 ==
== 结论：PASS（所有组件都有结束标记、rc=0、自报数与实际一致）==
```

两轮 `cmp` **逐字节相同**（`ROUNDS_IDENTICAL=YES`），两轮 rc 都 0，`/tmp/ds-v11` 零残留。

跑法上有一个前提要记住：**汇总器会把环境变量透传给静态门禁**，所以 CI 里这样跑：

```sh
PHASE=P3 sh test/unit/run_all.sh --isolated     # P3 阶段允许 known-large.txt 的豁免
```

不给 `PHASE` 时 G2（shim 1985 行）与 G6（ACL 无 ubus）会红——那是 fail-closed 生效，
不是汇总器坏了。
