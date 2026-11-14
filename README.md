# luci-app-dns-switch

> **唯一权威源**：本仓库 `main` 与正式 tag 是后续所有开发代码提交的唯一依据，其它位置的代码一律为历史归档、不再作为开发依据。实机测试统一以 r68s（`172.16.1.1`）为准，r68s 固件出厂自带由 MD 仓按 tag 引用本仓实现。详见 [docs/SOURCE_OF_TRUTH.md](docs/SOURCE_OF_TRUTH.md)、[运维手册](docs/运维手册.md)、[MD 仓接入说明](integration/immortalwrt-multidevice/README.md)。

把全屋 DNS 在 **AdGuardHome** 和 **运营商 DNS** 之间一键切换，并且在 DNS 出任何事的时候自己回到「能解析」的状态。

不是又一个 DNS 开关。它要解决的是这个场景：

> 上个月配好的，今天发现孩子又能刷短视频了。
> 或者：我改了个 DNS，全家上不了网，还得爬起来找网线。

## 它做什么

| 能力 | 说明 |
|---|---|
| 一键切换 | LuCI 页面点一下，全屋设备的 DNS 在 ADH 与运营商之间切换 |
| 切换前探测 | 探测不到 AdGuardHome 就拒绝切换，`/etc/config/dhcp` 一个字节不改 |
| 失败自动回滚 | 改完自检解析，不通就退回原样 |
| 持续对账 | 每 55 秒对一次账，上游被改、nft 链被删、option 6 被覆盖都会自动补回 |
| 自动降级 | ADH 连续失联 2 次自动切到运营商，恢复后连续成功 3 次切回（带 120 秒冷却） |
| 端口冲突检测 | 识别抢占 53 端口的插件并明确报错，不再「看着开了其实没生效」 |
| 逃生命令 | `dns-switch rescue` 不依赖守护、不依赖 LuCI、不依赖 DNS，一条命令复位 |

## 安装

### 方式一：编译安装（推荐）

```sh
cd /path/to/openwrt
echo "src-git dns-switch https://github.com/<owner>/luci-app-dns-switch.git" >> feeds.conf.default
./scripts/feeds update dns-switch
./scripts/feeds install luci-app-dns-switch
make menuconfig     # LuCI → Applications → luci-app-dns-switch
make package/luci-app-dns-switch/compile V=s
```

产物在 `bin/packages/<arch>/dns-switch/luci-app-dns-switch_*.ipk`。

### 编译细节

**本地仓库直接编**（改完就想看效果，不想先 push）：`feeds.conf.default` 里用 `src-link` 指向本地目录即可，`feeds update` 会直接读工作区。

```sh
echo "src-link dns-switch /path/to/luci-app-dns-switch" >> feeds.conf.default
./scripts/feeds update dns-switch && ./scripts/feeds install luci-app-dns-switch
make menuconfig            # LuCI → Applications → luci-app-dns-switch（按 M 或 *）
make package/luci-app-dns-switch/compile V=s
```

- **架构无关**：Makefile 里写的是 `LUCI_PKGARCH:=all`。这个包只有 shell 脚本、JS 页面、JSON 配置和 nft 片段，没有一行要编译的代码，所以**一个包能装在所有架构上**（mipsel / aarch64 / x86_64 通用），不用给每种设备各编一份。
- **依赖只有两个**：`LUCI_DEPENDS:=+luci-base +nftables`。`luci-base` 提供页面框架和 uci/rpcd 接口，`nftables` 提供 `nft` 与 `fw4`。**故意不依赖 `curl`**：缺它只让探测降一档精度（页面会提示），加进依赖会让精简固件白白多拖一个 `libcurl4`。
- `make package/luci-app-dns-switch/compile V=s` 只编这一个包，通常几十秒；`V=s` 是出问题时唯一能看清原因的开关。

### 方式二：直接安装预编译包

到 [Releases](../../releases) 下载对应架构的包，然后：

```sh
opkg install luci-app-dns-switch_*.ipk          # 23.05 / 24.10
apk add --allow-untrusted luci-app-dns-switch*.apk   # 25.12 及以后
```

装完刷新一下 LuCI，菜单在 **服务 → DNS 网关切换**。

## 用起来

页面只有一张卡，一句话告诉你现在是什么状态。技术细节折叠在「高级参数」里。

命令行同样可用：

```sh
dns-switch status              # 当前状态（含 53 端口归属）
dns-switch on                  # 切到 AdGuardHome（含探测与自检）
dns-switch off                 # 切回运营商
dns-switch drill               # 演练：真跑一遍降级与回切
dns-switch rescue              # 逃生：强制复位 DNS，不依赖守护
dns-switch timeline            # 最近的事件（切换/降级/漂移/冲突）
dns-switch bundle              # 生成诊断包，方便交给别人看
dns-switch snapshot list       # 快照列表
dns-switch snapshot diff       # 两次切换改了什么
dns-switch snapshot restore X  # 回滚到某个快照
```

### 关于 `rescue`

这是唯一一条**故意不依赖任何东西**的命令：不读 uci、不解析 nft、不调其他函数，只把 dnsmasq 拉回原生再重启。

它救不了接口层故障（netifd 卡死、`ip` 命令挂住）。那种情况它不会假装成功，会明确告诉你去看网络层。

## 装完先改这三项

出厂默认是照着作者的网段写的（`172.16.1.0/24`）。换成你自己的网络，只要改这三项——都在「高级参数」里，改完点**保存参数**：

| 改哪 | 出厂值 | 说明 |
|---|---|---|
| AdGuardHome 地址 | `172.16.1.2` | 跑着 ADH 那台设备在**你家局域网里**的 IPv4。填错的表现是切换被拒绝（探测不过），而不是网络断掉 |
| 管理端口 | `3030` | ADH 的**网页/管理**端口（不是 53）。用来确认 ADH 进程真的活着，不只看 53 通不通 |
| 备用 DNS IPv4 | `172.16.5.5` | ADH 不可用时，DHCP 直接下发给客户端兜底的地址。填你的上游 DNS（运营商或公共 DNS 都行）；留空表示只下发路由器自己 |

另外两个按需：**备用 DNS IPv6**（留空不下发，避免客户端拿到不可达的 v6 DNS 拖慢解析）、**AdGuardHome 网卡 MAC**（留空自动探测，换设备后填上，用于放行 ADH 自己的出站查询）。

改完不用重启：守护每 55 秒重读一次配置，下一次对账就用新值下发。想立刻验证，`dns-switch on` 一次即可。

## 适用前提

- **固件带 fw4 / nftables**，也就是 OpenWrt / ImmortalWrt **22.03 及以后**。fw3（iptables）时代的老固件**不支持**——本插件的劫持、853 策略全靠 nft 链，fw3 上装上去只会「看着成功、其实不生效」。
- **busybox 要带 `flock` applet**。并发锁靠 `flock -n`，缺了它多处同时执行（页面点击 + 守护 tick）就没法互斥。官方固件默认带；自己裁过 busybox 的固件请确认 `busybox --list | grep flock` 有输出。
- **强烈建议装 `curl`**。它只用来探 ADH 的 Web 端口（见「管理端口」那一项），属于精度增强而非硬依赖：缺了它探测降级为只做 DNS 解析验证，切换和自动降级照常工作，主卡片里会显示一条提示，装完自动消失。因此本包**没有**把 `curl` 写进依赖——为了一个探测端口让每个固件都多拖一个 `libcurl4`，不划算。
  ```sh
  apk add curl           # 25.12 及以后
  opkg install curl      # 23.05 / 24.10
  ```
- 一台跑着 AdGuardHome 的设备（本插件只管「指过去」，不管「跑起来」）
- 53 端口归 dnsmasq（如果被本机 AdGuardHome 之类的插件占了，插件会报出来并给出修复命令）

## 兼容性

| 固件 | 状态 |
|---|---|
| ImmortalWrt 23.05 | 构建通过 |
| ImmortalWrt 24.10 / OpenWrt 24.10 | 构建通过 |
| ImmortalWrt 25.12（apk） | 已在该版本实机运行 |

initscript 用 `procd`，配置用 `uci`，规则用 `nftables`——没有用任何版本特有的东西。

## 卸载

`prerm` 会先把 DNS 还原再删文件。不会出现「卸个软件把网卸断了」。

配置文件 `/etc/config/dns_switch` 属于 `conffiles`，卸载时保留。

## 开发

```
luci-app-dns-switch/
├── Makefile                     包定义（含 postinst / prerm / conffiles）
├── htdocs/luci-static/resources/view/dns_switch/overview.js
└── root/
    ├── etc/config/dns_switch         出厂配置
    ├── etc/init.d/dns-switch         procd 守护
    ├── etc/uci-defaults/99-dns-switch 首次安装初始化
    └── usr/
        ├── bin/dns-switch            主程序（POSIX sh，单文件）
        └── share/
            ├── luci/menu.d/          菜单
            └── rpcd/acl.d/           ACL
```

主程序是单文件 POSIX shell，约 1800 行，没有外部依赖（只用 busybox 自带的工具）。改完务必在目标固件上跑一遍 `dns-switch status` 和 `dns-switch drill`——静态检查抓不到 shell 的坑，实测抓到过好几个。

设备上**没有 `diff`**（busybox 未必编译），快照比对用的是 `cmp` + `awk`。

### 本地构建前请补执行位

仓库里的脚本可能带着 644（GitHub 网页上传不保留 mode）。打包用的是 `cp -p`，644 会原样进包，装到设备上 `dns-switch` 会跑不起来。

```sh
chmod +x luci-app-dns-switch/root/usr/bin/dns-switch \
         luci-app-dns-switch/root/etc/init.d/dns-switch \
         luci-app-dns-switch/root/etc/uci-defaults/99-dns-switch
```

CI 里这一步是自动的；本地构建、zip 下载、fork 之后都需要手动补一次。`bash check.sh` 会把这条查出来。

## 许可

MIT，见 [LICENSE](LICENSE)。
