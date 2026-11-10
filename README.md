# luci-app-dns-switch

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

## 前置条件

- 一台跑着 AdGuardHome 的设备（本插件只管「指过去」，不管「跑起来」）
- 固件带 `nftables`（fw4 的固件都有）
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

## 许可

MIT，见 [LICENSE](LICENSE)。
