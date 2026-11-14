# 接入 MD 仓：让 r68s 固件出厂自带本包

> MD 仓 = `2286927/ImmortalWrt-MultiDevice`（public，多设备固件编译仓）
> 目标线 = `.github/workflows/ImmortalWrt-25.12-r68s.yml` + `scripts/25.12/diy-part2.sh`
> 本目录是**接线的权威副本**；MD 仓只是使用方，源码一律来自本仓 tag。

## 一、关系

```
luci-app-dns-switch（本仓，唯一开发源）
        │  git clone --depth 1 --branch v1.0.0
        ▼
MD 仓 diy-part2.sh（仅 r68s）
        │  cp 到 package/luci-app-dns-switch/  +  chmod +x
        │  写 CONFIG_PACKAGE_luci-app-dns-switch=y
        ▼
make world → 固件自带该包（apk 可见、可 apk del、prerm 还原 DNS）
        │
        ▼
r68s 172.16.1.1 实机验收
```

MD 仓内**不存放本包任何源码**。换版本只改 `DNS_SWITCH_REF`。

## 二、文件

| 文件 | 用途 |
|---|---|
| `diy-part2-dns-switch.snippet.sh` | 当前生效接线片段（64 行），插到 `scripts/25.12/diy-part2.sh` 末尾「执行结束」echo 之前 |
| `历史手册-借编译树出包.md` | 11-11 借 MD 仓 SDK 出 apk 的操作手册，历史留痕 |
| `历史清单-MANIFEST.md` | 当年的文件 md5 清单，仅作查证，**不可据此出包** |

## 三、接线要点（片段内已实现）

1. 仅在 `DEVICE_MODEL=r68s` 时执行，其余机型直接跳过。
2. `DNS_SWITCH_REF` 默认 `v1.0.0`；`DNS_SWITCH_REPO` 默认本仓。
3. 仓库根是 `luci-app-dns-switch/` 再套一层同名目录，把**内层**提到 `package/luci-app-dns-switch/`，保证 feeds 能扫到 Makefile。
4. 补三个脚本执行位（网页上传存 644，`cp -p` 会原样进固件）。
5. `.config` 里先删 `not set` 行，再幂等追加 `CONFIG_PACKAGE_luci-app-dns-switch=y`；**必须在 `make defconfig` 之前**，否则选中项会被丢掉。

## 四、为什么不需要改 workflow

包进 `package/` 且 config 选中后，`make world` 就会把它编进固件；workflow 无需为本包新增步骤。若额外想收集 apk 产物，注意现有 `upload_packages_dir` 上传的是 `bin/targets/<t>/packages`，而本包 `PKGARCH:=all` 落在 `bin/packages/<arch>/base|dnsswitch/`，两者不是同一目录——这是 11-11 踩过的坑，需要另加 cp + upload-artifact，但**不做出厂自带的必要条件**。

## 五、两条线路互斥

| 线路 | 状态 |
|---|---|
| **A · 包安装线**（本目录片段） | 采用：固件里能看到、能 `apk del`、卸载走 prerm 不断网 |
| B · files/ 覆盖线（`scripts/common/dns-switch/` + `inject.sh` + `payload/`） | **已下线**：apk 里看不到、不能卸载；与 A 线同开会装两遍、overlay 与 apk 记录打架 |

旧 B 线的说明见 `docs/archive/出厂注入-B线-已废弃.md`。

## 六、验收清单（每次发版必过）

构建日志三行缺一不可：

```
>>> 接入 dns-switch 包源（v1.0.0）
>>> dns-switch 包源已就位: Makefile htdocs root
✅ dns-switch 已选中（CONFIG_PACKAGE_luci-app-dns-switch=y）
```

随后 `conclusion=success`，并在 r68s 上确认：菜单「服务 → DNS 网关切换」、页面状态卡、`dns-switch status` 有输出、`apk info -e luci-app-dns-switch` 打印包名、`apk del` 后解析仍正常。

## 七、编译线的前置条件

MD 仓 r68s 线自 11-10 起因上游 `041-*` rockchip drm backport 补丁失配连续失败（与本包无关）。**接线本身已被 run 34 / run 38 的日志证明有效**，卡点始终是 `target/linux` 编译。修复方式见 `docs/编译线诊断-20261113.md`：在 diy-part2 里整批移除这批显示子系统补丁（路由器无显示输出），待上游 refresh 后再删掉规避段。
