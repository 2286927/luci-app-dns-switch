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
| `nft_golden.sh` | 门禁本体：生成 → 比较 → 报差异 → 给退出码 | QA |

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
