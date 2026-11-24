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
| `static_gates.sh` | SPEC §8.6 六条静态门禁（语法/行长/分层/孤儿/emoji/ACL），见 §8 | QA |
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

## 8. 静态门禁 `static_gates.sh`（SPEC §8.6 六条）

```sh
sh test/static_gates.sh            # 日常：FAIL 才算问题，SKIP/WARN 只提示
sh test/static_gates.sh --strict   # 发版前：SKIP 也算失败
```

| # | 门禁 | 判据 |
|---|---|---|
| 1 | 模块语法 | 每个 `.uc` 能被 `ucode -e "import * as m from '<绝对路径>'"` 加载（**不是 `ucode -c`**，见下） |
| 2 | 单文件 ≤300 行 | 计入 `.uc` + rpcd 对象 + sh 入口（I5 说的是「单文件」） |
| 3 | 分层不越界 | `./x.uc` 的层号必须小于当前文件层号；L5 入口不受限；同层命中白名单打 WARN |
| 4 | 无孤儿能力缝 | `export` 无人引用 → FAIL；只有测试引用 → WARN |
| 5 | 无 emoji | 前端（`htdocs/`）命中 → FAIL；非前端 → WARN（I1 保护，见下） |
| 6 | ACL 覆盖 | SPEC §4.1 的 10 个方法必须都在 ACL 的 `read`/`write` 的 ubus 列表里，且不得多出 |

### 8.1 为什么门禁 1 不能用 `ucode -c`

`ucode -c` 把文件当**程序**编译，遇到 `export` 直接 255：

```
$ ucode -c -o /dev/null root/usr/libexec/dns-switch/sh.uc
Syntax error: Exports may only appear at top level of a module
```

`ucode -h` 里没有任何模块开关，13 个模块全是 `export` 写法 → 这条门禁从第一天就 100% 红。
改成 `import` 判据后是**编译 + 链接**，比原来更严（解析不到的依赖也一起抓）。
负向对照已验：破坏语法 → 255 `Unable to compile module`；import 不存在的文件 → 255
`Unable to resolve path for module`。

### 8.2 门禁 5 踩过的坑：**空转的绿色比红色危险**

第一版用 `od -A n -v -t u1` 取字节流。在 r68s 上实测 `od: not found`（busybox 没编这个 applet），
管道输出为空 → awk 扫到 0 个字节 → 门禁打印"没有 emoji"并 **PASS**。
注入 emoji 也照样 PASS —— 门禁自己变成了假绿灯。

修法两层：
1. 取字节流改用 `hexdump -v -e '1/1 "%u\n"'`，没有 `hexdump` 才退回 `od`；
2. **加扫描器自检**：每次运行先扫一个自己造的 `U+1F525`，扫不出来直接 FAIL
   （"扫描器自检失败…不许当作通过"）。两个工具都没有也 FAIL。

反向证明过：把假 `hexdump`（只 `exit 0`）塞进 PATH → 门禁 rc=1 且打印自检失败，
而不是悄悄放行。

### 8.3 emoji 为什么分前端/非前端两档

团队 P0 管的是「emoji 当**功能图标**」。当前 9 处命中全在 v1.0.1 的 CLI 里：
`✓`/`✗` 是 stdout 的终端状态符号，`⚠` 在源码注释里。而 stdout 受不变量 I1
（与 v1.0.1 **逐字节一致**）保护——删掉它们会直接破坏 C2/C6 兼容项。
所以：前端命中判 P0 失败，非前端命中一律 WARN 并把命中点全列出来，由人裁决。
**不是放过，是不许静默。**

### 8.4 当前结论（2026-11-24，r68s）

```
PASS 1/6 模块语法      4 个模块 import 成功
FAIL 2/6 单文件 ≤300    root/usr/bin/dns-switch 1985 行  ← v1.0.1 shim 还没重写
PASS 3/6 分层不越界 + WARN 1（log→sh 同层，SPEC §3.2 已声明）
PASS 4/6 无孤儿 + WARN 8（8 个 export 只有测试引用：消费者模块 P3 才写）
PASS 5/6 无 emoji + WARN 9（非前端符号，I1 保护）
FAIL 6/6 ACL 覆盖      ACL 还没有 ubus 段，10 个方法都没覆盖
== 3 PASS / 2 FAIL / 3 WARN / 1 SKIP ==
```

两条 FAIL 都是**真实状态**，不是误报：

- **2/6**：`root/usr/bin/dns-switch` 还是 v1.0.1 的 1985 行。SPEC §2.1 要求它瘦到 ≈130 行
  （只留 rescue + exec）。在 shim 重写之前这条会一直红——这是事实，不要 `|| true`。
- **6/6**：ACL 现在只有 v1.0.1 的 `uci`/`file` 权限。P4 加 rpcd 对象时必须补 `ubus` 段。

**§3.1 与 §3.2 有互相矛盾之处**（层次图画 `status ──► bundle`，§3.2 表格写 `bundle` 依赖 `status`）。
门禁暂时把两个方向都放进白名单并打 WARN，等架构师统一；统一后白名单要收敛成一条。

### 8.5 静态门禁的负向对照（证明它会红）

在 r68s 上注入验证，逐条：

| 注入 | 期望 | 实测 |
|---|---|---|
| `nft.uc` 里 `import './switch.uc'`（L2→L4） | 分层 FAIL | ✅ 命中 `L2 → L4 违规` |
| `import '../foo.uc'` | 非 `./` 相对 import FAIL | ✅ 命中 |
| 加 `export function never_used_by_anyone()` | 孤儿 FAIL | ✅ 命中 |
| 破坏 `sh.uc` 语法 | 门禁 1 FAIL | ✅ 命中（真 ucode 才验得出） |
| 前端 js 加 emoji | 门禁 5 FAIL | ✅ 命中 |
| 非前端加 `✓` | 只 WARN，前端不红 | ✅ WARN=1 / 前端 FAIL=0 |
| 假 `hexdump`（`exit 0`） | 扫描器自检 FAIL | ✅ rc=1 |
| ACL 补齐 10 方法 | 门禁 6 PASS | ✅ 命中全覆盖 |
| ACL 删 `version` | 报缺 1 | ✅ 命中 |
| ACL 加 `bogus_method` | 报多 1 | ✅ 命中 |
| 全部还原 | 与基线一致 | ✅ 相等；`/tmp/static_gates.*` 残留 0 |

---

## 9. 单测 runner `unit/run_all.sh`

```sh
sh test/unit/run_all.sh              # 逐套件跑，看 rc + 断言数
sh test/unit/run_all.sh --verbose    # 附每个套件的完整输出
sh test/unit/run_all.sh --isolated   # 每个套件前清空 /tmp/ds-v11（CI 用这个）
```

它比"逐个跑一遍看 rc"多查四件事，因为 **rc=0 本身什么都不证明**：

| 检查 | 抓什么 |
|---|---|
| 末行约定 `xxx_test: N passed, M failed` | 有人改了输出格式、或提前 return |
| 自报数 vs 实际 `^PASS`/`^FAIL` 行数 | 少打印几行却声称 100% 通过 |
| 断言数不许为 0 | 空测试 + rc=0（最典型的假绿） |
| `eq()`/`ok()` 调用点 vs 实际执行数 | 条件分支里被静默跳过的断言 → WARN |

### 9.1 `--isolated` 是被真事逼出来的

第一版按字母序跑（config → lock → log → sh），在 r68s 全新镜像上
**`config_test` 直接 FAIL，rc=254**：

```
FAIL  config_test    rc=254
      got =false   want=true        ← load() ok
      got ='E_UCI_COMMIT'  want='OK'
```

根因：`config_test` 用 `fs.mkdir(BASE)` 建 `/tmp/ds-v11/ut-cfg`，而 **`fs.mkdir` 不建父目录**，
干净机器上 `/tmp/ds-v11` 根本不存在 → 写配置失败 → E_UCI_COMMIT；之后收尾里
`fs.rmdir` 又对不存在的路径抛错 → rc 变 254。

更值得记的是它**为什么一直没被发现**：按 `sh→lock→log→config` 的顺序跑时，
`lock_test` 先用 `mkdir_p()` 把 `/tmp/ds-v11` 建了出来，`config_test` 白捡一个父目录，
看起来全绿。**这是套件间的隐式顺序依赖**，只有把每个套件单独丢进空 `/tmp` 才会露出来。

已修（`config_test.uc`）：补 `mkdir_p()`、收尾改用 `rm_if_exists()` 并加三条"确实删干净"的断言。
`--isolated` 就是把这个场景固化下来，CI 必须用它。

诚实记录：这一轮之前我报过「干净起点已验证通过」，那次是在 `sh→lock→log→config` 顺序下跑的，
**证据不足，结论不成立**。是 runner 换了执行顺序才把它暴露出来的。

### 9.2 现状（r68s，2026-11-24）

```
PASS  config_test     55 断言  rc=0
PASS  lock_test       37 断言  rc=0
PASS  log_test        37 断言  rc=0
PASS  sh_test         22 断言  rc=0
== 合计：4 套件 / 151 断言 / 0 套件失败 ==
```

三种模式都验过：默认（干净起点）、连跑两轮（幂等）、`--isolated`（每套件独占空 `/tmp`）。

