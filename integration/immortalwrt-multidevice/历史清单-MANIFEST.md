# 待上传文件清单（MD 仓 = 2286927/ImmortalWrt-MultiDevice）

> 本地根：`D:\我的知识库\OpenWrt编译`
> 校验：上传后可用 GitHub 网页上的文件内容对比，或本地 `md5sum` 比对。

## 一、包源 → `scripts/common/luci-app-dns-switch/`

本地目录：`luci-app-dns-switch/luci-app-dns-switch/`

| 本地路径 | 仓库目标路径 | md5 |
|---|---|---|
| `Makefile` | `scripts/common/luci-app-dns-switch/Makefile` | `6cc222a953ad9ce0f45892fdb86eb3c7` |
| `root/usr/bin/dns-switch` | 同结构 | `5a9365c0227ed46071938be2a32e243b` |
| `root/etc/init.d/dns-switch` | 同结构 | `23c1caca31c6843448bc9124011b7424` |
| `root/etc/uci-defaults/99-dns-switch` | 同结构 | `212a05bf88c9fe9cacfc1c53de2895ba` |
| `root/etc/config/dns_switch` | 同结构 | `737ca1460bb10ec4dbb156b1b2a9eaa0` |
| `root/usr/share/luci/menu.d/luci-app-dns-switch.json` | 同结构 | `bc357560c2eb51190d669f22f297db28` |
| `root/usr/share/rpcd/acl.d/luci-app-dns-switch.json` | 同结构 | `39a0590fac248d0b27d0529046fa76fe` |
| `htdocs/luci-static/resources/view/dns_switch/overview.js` | 同结构 | `b8c36025c29c105b3831e2a7e95e68dd` |

## 二、出厂断言与 payload（覆盖分支旧版）

本地根：`dns-switch-20261109/factory/scripts/common/dns-switch/`

| 本地路径 | 仓库目标路径 | 说明 |
|---|---|---|
| `verify.sh` | `scripts/common/dns-switch/verify.sh` | 209 行 / 39 项断言；分支上是 192 行旧版 |
| `payload/usr/bin/dns-switch` | `scripts/common/dns-switch/payload/usr/bin/dns-switch` | 分支上 md5 为 `4462fd42`（旧），需换成本地 `5a9365c0` |
| `payload/etc/init.d/dns-switch` | 同结构 | |
| `payload/etc/uci-defaults/99-dns-switch` | 同结构 | |
| `payload/etc/config/dns_switch` | 同结构 | |
| `payload/usr/share/luci/menu.d/luci-app-dns-switch.json` | 同结构 | |
| `payload/www/luci-static/resources/view/dns_switch/overview.js` | 同结构 | |

> 走 A 线（包安装）后，payload 与 `files/` 注入其实可以整体下线；
> 但只要分支上还留着 `diy-part2.sh` 的 inject 调用，就必须让 payload 与包源同版本，
> 否则会出现"固件里的 dns-switch 是旧版"这种最难查的错。

## 三、粘贴片段

| 文件 | 粘到哪 |
|---|---|
| `config-line.conf` | `config/r68s-25.12.config` 末尾 |
| `diy-part2-pkg-snippet.sh` | `scripts/25.12/diy-part2.sh` 的 `执行结束` echo 之前 |
| `apk-collect-step.yml` | `.github/workflows/ImmortalWrt-25.12-r68s.yml` 的「上传 bin」之前 |
| `diy-part2-pkg-snippet-private.sh` | 仅 B 方案（源码留私有）时替换上面第二项 |
