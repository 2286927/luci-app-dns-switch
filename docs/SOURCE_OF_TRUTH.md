# 唯一权威源声明

> 生效日期：2026-11-14
> 适用范围：luci-app-dns-switch 的全部开发、发版、出厂集成与实机验证

## 一、唯一有效代码基准

**后续所有开发代码提交，一律以本仓库为准：**

| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/2286927/luci-app-dns-switch` |
| 权威分支 | `main` |
| 正式版本 | 以 tag 为准；当前 `v1.0.0` → `181b76e` |
| 可见性 | public / MIT |

**其它任何位置的代码都不再作为开发依据**，包括但不限于：

- 本地工作区 `D:\我的知识库\OpenWrt编译\` 下 `dns-switch-20261109/`、`dns-switch-release-20261112/`、`test-run-2026111*/`、`luci-app-dns-switch/` 里的散落副本
- `2286927/ImmortalWrt-MultiDevice` 的 `feat/dns-switch-factory` 分支（B 线 files/ 覆盖方案）与 `feat/dns-switch-pkg` 分支（早期接线实验）
- 任何 `.bak`、`qa-backup`、`fakeopenwrt`、`repo-check/pulled` 等备份或模拟树

这些位置统一按**历史归档**处理：可用于查证当时的决策，不得据此改代码、不得据此出包。

## 二、版本基线校验值（v1.0.0）

| 文件 | 大小 | md5 |
|---|---|---|
| `luci-app-dns-switch/root/usr/bin/dns-switch` | 65,339 B / 1982 行 | `3ffa3f2aa7173b675d5006b243cb9fda` |
| `luci-app-dns-switch/htdocs/.../overview.js` | 19,107 B / 511 行 | `16948b00b7d08ae4d55b554809cb1eea` |
| Release 产物 `luci-app-dns-switch_1.0.0-r1_r38263.apk` | 31,477 B | sha256 `f35c1587efb99acf3ce8cb49d8829d5bb55b82bc523a26bbf9c3ee43c86d44ab` |

三个运行脚本（`root/usr/bin/dns-switch`、`root/etc/init.d/dns-switch`、`root/etc/uci-defaults/99-dns-switch`）在 git 中的 mode 必须为 `100755`。网页上传会存成 644，而 `luci.mk` 用 `cp -p` 打包会原样带进固件，导致装上去跑不起来；CI 与本地构建前各有一次 `chmod +x` 兜底。

## 三、实机测试基准

**统一以 r68s 为准，其它设备不承担验收职责。**

| 项 | 值 |
|---|---|
| 设备 | FastRhino-R68S（r68s） |
| 地址 | `172.16.1.1` |
| 固件 | ImmortalWrt 25.12-SNAPSHOT，aarch64_generic，apk 包管理 |
| 关联设备 | AdGuardHome `172.16.1.2:3030`（被指向的 DNS，非被测对象） |

装 / 用 / 卸 / 重启 / sysupgrade 的验收记录见 `docs/testing/` 与 `docs/运维手册.md`。

## 四、MD 仓的集成规则

`2286927/ImmortalWrt-MultiDevice`（下称 MD 仓）负责让 r68s 固件出厂自带本包，但**它不是开发源**：

1. MD 仓只允许通过 `git clone --depth 1 --branch <tag> https://github.com/2286927/luci-app-dns-switch.git` 引用本仓，把内层 `luci-app-dns-switch/` 落到 `package/luci-app-dns-switch/`。
2. **禁止**在 MD 仓内复制、存放或修改本包的任何源码、配置、页面、Makefile。
3. 换版本只改 `DNS_SWITCH_REF`，不改代码。
4. 包安装线（`package/` + `CONFIG_PACKAGE_luci-app-dns-switch=y`）与 files/ 覆盖线互斥，**只保留前者**；旧的 B 线 `scripts/common/dns-switch/` 已下线。
5. 接线片段的权威副本在 `integration/immortalwrt-multidevice/diy-part2-dns-switch.snippet.sh`，MD 仓只是它的使用方。

## 五、标准提交流程

```
改代码 → 本仓 main 提交 → bash check.sh（39/39）→ 打 tag → 更新 Release
       → MD 仓改 DNS_SWITCH_REF → 触发 r68s 构建并跑绿
       → r68s 172.16.1.1 实机验收 → 回填 docs/testing/
```

任何一步跳过实机验收，均不视为发版完成。

## 六、已废弃方案

| 方案 | 为何废弃 |
|---|---|
| B 线：`scripts/common/dns-switch/` + `inject.sh` + `payload/` + `verify.sh` 覆盖 `files/` | `apk` 里看不到、不能卸载、与“做成 OpenWrt 软件包”相悖；与包安装线同时开会装两遍 |
| 把源码复制进 MD 仓 `scripts/common/luci-app-dns-switch/` | 会出现“固件里是旧版”这种最难查的错；违反唯一权威源 |
| 用私有仓 + secret 克隆 | 本仓已 public，clone 零 secret，无必要 |

历史文档见 `docs/archive/` 与 `integration/immortalwrt-multidevice/历史*`，仅作决策留痕。
