# dns-switch 出厂固化与构建接入

把 `luci-app-dns-switch` 从「手工 scp 四个文件」变成「编译进固件，刷完机就有」。

目标态一句话：**刷完机就是一台普通路由器**（原生 DNS，能上网），ADH 就绪后在「服务 → DNS 网关切换」点一下才切过去；断网风险为零。

---

## 一、接入三步

### 1. 拷目录

```
scripts/common/dns-switch/          ← 整个目录拷进仓库同名路径
  ├── inject.sh
  ├── verify.sh
  └── payload/
      ├── usr/bin/dns-switch
      ├── etc/init.d/dns-switch
      ├── etc/config/dns_switch
      ├── etc/uci-defaults/99-dns-switch
      ├── www/luci-static/resources/view/dns_switch/overview.js
      └── usr/share/luci/menu.d/luci-app-dns-switch.json
```

### 2. 改 `scripts/25.12/diy-part2.sh`

把 `patches/diy-part2-snippet.sh` 的内容插到文件末尾那句
`echo -e "\n===== diy-part2.sh（25.12）执行结束 ====="` **之前**。

它做两件事：判定 `DEVICE_MODEL=r68s`、调用 `inject.sh`。其余 17 条编译线连这个 if 都进不去。

### 3. 改 workflow

把 `patches/workflow-assert-snippet.yml` 作为一个新步骤，插到
`.github/workflows/ImmortalWrt-25.12-r68s.yml` 的「生成编译配置」之后。

这是二次断言——`inject.sh` 里已经验过一遍，这里防的是「后续步骤把 files 树冲掉」。

---

## 二、出厂态长什么样

| 项 | 出厂值 | 为什么 |
|---|---|---|
| `dns_switch.settings.mode` | `off` | 刷完机走路由器原生 DNS，不依赖玩客云在不在线 |
| `/etc/nftables.d/20-dns-hijack.nft` | **不存在** | 规则只能由 `dns-switch on` 运行时生成。预置一份会让「默认 off」变成假象 |
| `/etc/config/dns_switch` | 预置，`mode=off` | 页面一打开就有值可读，不用等脚本生成 |
| `/etc/uci-defaults/99-dns-switch` | 预置 | 首启补齐缺省键、写 sysupgrade 清单、启用守护 |
| 守护服务 | `enable` + `start` | 必须常驻：页面点「启用」靠 procd 的 reload 触发器，没实例就点不动 |
| `/usr/bin/dns-switch` | 0755 | |
| sysupgrade 保留 | 3 条 | `/usr/bin/dns-switch`、`/etc/init.d/dns-switch`、`/etc/config/dns_switch` |

**不预置的**：本机 AdGuardHome 二进制（保持 `INCLUDE_binary=n`）、ADH 配置、任何 DNS 改写规则。
所以 `on` 的闸门探测仍然是必需品——探测不到就拒绝切换，一个字节都不改。

---

## 三、编译期断言（`verify.sh`，39 项）

跑在 `inject.sh` 末尾，任一失败即 `exit 1` 弄红 workflow。

| 组 | 断言 |
|---|---|
| A | 六个运行时文件都落地 |
| B | 三个 shell 文件过 `sh -n`（用 `sh` 不用 `bash`，busybox 更严格） |
| B2 | 三个 shell 文件无 CRLF（`sh -n` 在 bash 下容忍 `\r`，只能字节级查） |
| C | `dns-switch` 与 init 有可执行位 |
| D | 出厂 `mode=off` |
| E | 没预置 `20-dns-hijack.nft` |
| F | payload **恰好 6 个**运行时文件，且不含 `etc/config/uhttpd`、`etc/config/dhcp`、`etc/crontabs/root` |
| L | drill / bundle / timeline / snapshot diff 四个运维命令在位；不得依赖设备上不存在的 `diff` |
| G | 菜单 JSON 可解析、指向 `dns_switch/overview` |
| H | 页面以 `'require view'` 开头、导出 `view.extend`、不含 `cbi-page-actions` |
| I | 冲突检测在位：`conflict_scan`、`who_listens_53`、on/tick/init/status 四处接入、status 有 53 端口一行 |
| J | 页面消费冲突字段、给出修复命令、写 uci 前先 `save()` |
| K | 出厂 `etc/config/dns_switch` 自带 `status` 段与 `conflict` 字段 |

F 组**只查 payload，不查落地树**。2026-11-10 run 42780835113 在这里红过：
`files/` 是整棵覆盖层，diy-part2 自己在「值守升级注入」里就往 `files/etc/crontabs/root`
追加了 autoupdate 行，拿落地树当判据必然误报。而 `inject.sh` 只做
`cp -a "$SRC/." "$DST/"`，payload 里没有的文件根本没机会被覆盖——管住自己这一份就够。

F 组是这三份配置整份覆盖的教训：

- 覆盖 `uhttpd` → 丢掉 workflow 注入的 `ucode_prefix`，LuCI 直接 **403**
- 覆盖 `dhcp` → 冲掉设备相关的 section
- 覆盖 `crontabs/root` → 冲掉 diy-part2 追加的 `40 4 * * * /usr/bin/autoupdate check`

这三个文件一律只能用 `uci set` 改，不能用文件覆盖。

F 组要同时查源和落地树：`files/` 也可能被仓库根目录带进来一份 `uhttpd`，那才是真会炸的场景。

B2 有两个坑，实现上都绕开了：

1. **不能用 `grep` 找 `\r`**。MSYS/MinGW 的 grep 是文本模式，会把 `\r\n` 当 `\n`，在 Windows 上永远查不出来。改走 `od -An -c` 的字节视图。
2. **不能用 `grep -q`**。脚本开了 `pipefail`，`-q` 命中即退会让 `od` 收到 SIGPIPE（141），整条管道被判失败——结果反而永远显示"干净"。改用 `grep -c`。

---

## 三之二、断言自测（`tools/selftest-verify.sh`）

写断言最危险的失败方式是**它从不失败**。上面那两个坑就是自测抓出来的。

```bash
bash factory/tools/selftest-verify.sh
```

它构造 12 份"坏固件"（mode 被改 on、混入 uhttpd/dhcp/crontabs、预置劫持规则、缺主程序、CRLF、页面不是 view、自绘悬浮条、删掉冲突检测、页面漏 `save()`、出厂缺 `status` 段），逐条确认 `verify.sh` 会红；再加两条正向用例（干净 payload；落地树本来就含 crontabs/uhttpd/dhcp 的真实现场）必须通过。当前 14/14。

临时目录放在脚本同级（`.selftest-tmp`），跑完自动清——不用 `mktemp`，因为 Windows 上它返回带盘符路径，本机删除守卫会拒绝 `rm`，导致"删不掉 → 用例假装没触发"。

---

## 四、不编译固件也能验

### 4.1 同步 + 断言（改完必跑）

`tools/sync-payload.sh` 会把开发副本同步进 payload，并跑一遍 `verify.sh`：

```bash
bash factory/tools/sync-payload.sh
```

它做三件事：去 CRLF 同步四个代码文件 → `sh -n` 三个脚本 → 跑全部断言。
**改了 `dns-switch` 或 `overview.js` 之后必须跑一次再提交**，否则会出现「设备上是新的、固件里是旧的」。

### 4.2 模拟真实注入（含路径解析）

这一步验的是 diy-part2 里那段的 `$MYDIR/../common/` 能不能真的找到脚本——路径写错是接入阶段最常见的翻车点。

```bash
mkdir -p /tmp/sim/scripts/25.12 /tmp/sim/openwrt/files
cp -a scripts/common /tmp/sim/scripts/
# 把 patches/diy-part2-snippet.sh 的内容套上 MYDIR 定义，存成 /tmp/sim/scripts/25.12/diy-part2.sh
cd /tmp/sim/openwrt && DEVICE_MODEL=r68s bash ../scripts/25.12/diy-part2.sh
find files -type f | sort     # 应看到 6 个文件
```

同一份脚本换 `DEVICE_MODEL=onecloud` 再跑一次，`files/` 里应该是 **0 个文件**。

### 4.3 实机验 uci-defaults（不刷机）

把 `99-dns-switch` 推到设备 `/tmp`（**不要**放进 `/etc/uci-defaults`，否则会被系统当首启脚本执行），先 `dns-switch off` 进入安全态，再手工执行。验完记得 `dns-switch on` 复原。

---

### 4.4 已验记录

| 项 | 方法 | 结果 |
|---|---|---|
| payload 断言 | `verify.sh payload` | 39/39 |
| 断言有效性 | `selftest-verify.sh` | 14/14（12 份坏固件全被拦住 + 2 条正向全过） |
| 注入落地 | 模拟 `openwrt/` 为 cwd，`DEVICE_MODEL=r68s` | 6 文件，权限 755/644 正确，断言 34/34 |
| 机型隔离 | 同上，`DEVICE_MODEL=onecloud` | `files/` 里 0 个文件 |
| uci-defaults 实机 | R68S 上 `off` 态执行 | rc=0；假的劫持文件被删；mode 保持 off；sysupgrade 三条到位、两条历史残留被清 |
| uci-defaults 幂等 | 连跑两次 | 配置 md5 未变 |
| uci-defaults 首启态 | `uci delete mode` 后执行 | 自动置 `off` |
| 重启保持 | 设备凌晨 03:00 自动重启，次晨核对 | 开机 6 小时，`mode=on`/上游/option6/RDNSS/劫持链 4 条全部保住 |

---

## 五、回退

| 场景 | 做法 |
|---|---|
| 编译报错，想先跳过 | 删掉 diy-part2 里那个 `if` 块，或临时把 `DEVICE_MODEL` 判断改掉 |
| 已刷机、想彻底去掉 | `dns-switch rescue` 复位 DNS → `/etc/init.d/dns-switch disable` → 删四个文件 |
| 只想停用、不卸载 | `/etc/init.d/dns-switch stop && disable`，DNS 会停在当前状态不再自动降级 |

`rescue` 永远可用：它不依赖守护、不读 uci 配置、不解析 nft，只做四件事把 DNS 拉回原生。

---

## 六、明确不做

| 不做 | 原因 |
|---|---|
| 把 AdGuardHome 二进制打进固件 | 按既定决策保持 `INCLUDE_binary=n`，二进制仍从 `/mnt/AdGuard` 手工提供；所以 `on` 必须先探测 |
| 固化 r68s 的 uhttpd 参数 | 它现在是 `max_requests=50 / script_timeout=3600`，本来就宽。那句「改成 10/60」是**玩客云**线的修法，见 `optional/onecloud-uhttpd-defaults.sh` |
| 禁用本机 `adguardhome` 服务 | 它的 `config.enabled` 出厂就是 `0`，不会抢 53。真抢了由冲突检测（P0-5）报错，不在这里悄悄改别人的服务 |
| 预置 `dhcp` / `crontabs` / `uhttpd` 整份配置 | 见上文断言 F 组 |
