# 唯一权威源声明

> 生效日期：2026-11-14
> 适用范围：luci-app-dns-switch 的全部开发、发版、出厂集成与实机验证

## 一、唯一有效代码基准

**后续所有开发代码提交，一律以本仓库为准：**

| 项 | 值 |
|---|---|
| 仓库 | `https://github.com/2286927/luci-app-dns-switch` |
| 权威分支 | `main` |
| 正式版本 | 以 tag 为准；当前 `v1.0.1` → `d9c056f`（上一版 `v1.0.0` → `181b76e`） |
| 可见性 | public / MIT |

**其它任何位置的代码都不再作为开发依据**，包括但不限于：

- 本地工作区 `D:\我的知识库\OpenWrt编译\` 下 `dns-switch-20261109/`、`dns-switch-release-20261112/`、`test-run-2026111*/`、`luci-app-dns-switch/` 里的散落副本
- `2286927/ImmortalWrt-MultiDevice` 的 `feat/dns-switch-factory` 分支（B 线 files/ 覆盖方案）与 `feat/dns-switch-pkg` 分支（早期接线实验）
- 任何 `.bak`、`qa-backup`、`fakeopenwrt`、`repo-check/pulled` 等备份或模拟树

这些位置统一按**历史归档**处理：可用于查证当时的决策，不得据此改代码、不得据此出包。

## 二、版本基线校验值（v1.0.1）

| 文件 | 大小 | md5 |
|---|---|---|
| `luci-app-dns-switch/root/usr/bin/dns-switch` | 65,612 B / 1985 行 | `95bde49df4e20a0c02e58fabe3b1f064` |
| `luci-app-dns-switch/htdocs/.../overview.js` | 19,107 B / 511 行 | `16948b00b7d08ae4d55b554809cb1eea`（与 v1.0.0 相同） |
| Release 产物 `luci-app-dns-switch_1.0.1-r1.apk` | 32,018 B | sha256 `6cf107f74dd8b10c4cebabcdbeb9cb23d84afc53004657b6a22b214ab70e619e` |

> v1.0.0 历史基线：主程序 `3ffa3f2aa7173b675d5006b243cb9fda`（65,339 B / 1982 行），
> apk `31,477 B` sha256 `f35c1587efb99acf3ce8cb49d8829d5bb55b82bc523a26bbf9c3ee43c86d44ab`。

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
3. 换版本只改 `DNS_SWITCH_REF`，不改代码。**本仓每发一个 tag，这一行必须同步**（见 §5.1）；MD 仓引用落后于最新 tag，视为发版未完成。
4. 包安装线（`package/` + `CONFIG_PACKAGE_luci-app-dns-switch=y`）与 files/ 覆盖线互斥，**只保留前者**；旧的 B 线 `scripts/common/dns-switch/` 已下线。
5. 接线片段的权威副本在 `integration/immortalwrt-multidevice/diy-part2-dns-switch.snippet.sh`，MD 仓只是它的使用方。

## 五、标准提交流程

```
改代码 → 本仓 main 提交 → bash check.sh（39/39）→ 打 tag → 更新 Release
       → MD 仓改 DNS_SWITCH_REF → 触发 r68s 构建并跑绿
       → r68s 172.16.1.1 实机验收 → 回填 docs/testing/
```

任何一步跳过实机验收，均不视为发版完成。

### 5.1 发版后同步 MD 仓引用（强制，不可跳过）

**规则**：本仓每打一个 tag，MD 仓 `scripts/25.12/diy-part2.sh` 的 `DNS_SWITCH_REF` 默认值必须跟着改。不改 = 下次固件出厂带的是旧版，且不会报错，只会静默落后。

一步检查（读远端权威内容，不依赖本地 clone）：

```sh
# 1) 本仓最新 tag
PKG_TAG=$(git -C integration-20261114/pkg describe --tags --abbrev=0)

# 2) MD 仓当前引用（远端）
MD_REF=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.github.com/repos/2286927/ImmortalWrt-MultiDevice/contents/scripts/25.12/diy-part2.sh?ref=main" \
  | python -c "import sys,json,base64,re;t=base64.b64decode(json.load(sys.stdin)['content']).decode();print(re.search(r'DNS_SWITCH_REF:-([^}]+)\}',t).group(1))")

# 3) 判定
[ "$PKG_TAG" = "$MD_REF" ] && echo "OK  $PKG_TAG" || echo "MISMATCH  包仓=$PKG_TAG  MD=$MD_REF"
```

**改法（重要）**：用 **Contents API 改远端**，不要直接推本地工作区文件。
MD 仓本地 clone 是 `core.autocrlf=true` 的 CRLF 检出，直推会把整文件变成 CRLF，runner 上 `#!/bin/bash\r` 立刻 `bad interpreter`。
操作要点：GET 拿 blob（`sha` + base64 `content`）→ 在**字节层**替换 → 校验 `CRLF==0` → PUT 带原 `sha`。

**历史记录**：

| 日期 | 包仓 tag | MD 引用改为 | MD 提交 |
|---|---|---|---|
| 2026-11-24 | `v1.0.1` | `v1.0.1` | `6835a5ff` |
| 2026-11-14 | `v1.0.0` | `v1.0.0` | `ebc74e21` |

> 本地 `integration-20261114/md` 是浅克隆且有历史分叉，**树对象不完整**，不要指望 `git reset/pull` 能安全同步；改 MD 仓一律走 API 或以远端为准重新 clone。

## 六、已废弃方案

| 方案 | 为何废弃 |
|---|---|
| B 线：`scripts/common/dns-switch/` + `inject.sh` + `payload/` + `verify.sh` 覆盖 `files/` | `apk` 里看不到、不能卸载、与“做成 OpenWrt 软件包”相悖；与包安装线同时开会装两遍 |
| 把源码复制进 MD 仓 `scripts/common/luci-app-dns-switch/` | 会出现“固件里是旧版”这种最难查的错；违反唯一权威源 |
| 用私有仓 + secret 克隆 | 本仓已 public，clone 零 secret，无必要 |

历史文档见 `docs/archive/` 与 `integration/immortalwrt-multidevice/历史*`，仅作决策留痕。
