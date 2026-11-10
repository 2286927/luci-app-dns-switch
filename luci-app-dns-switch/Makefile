# SPDX-License-Identifier: MIT
#
# luci-app-dns-switch —— 把全屋 DNS 在 AdGuardHome 与运营商之间一键切换，
# 并保证「DNS 出任何事都能自己回到能解析的状态」。
#
# 构建方式（标准 LuCI 应用）：
#   1) 把本仓库放到 OpenWrt 源码树的 package/ 或 feeds 目录
#   2) make menuconfig → LuCI → Applications → luci-app-dns-switch
#   3) make package/luci-app-dns-switch/compile V=s

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-dns-switch
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=dns-switch contributors

LUCI_TITLE:=LuCI app for DNS gateway switching
LUCI_DESCRIPTION:=One-click switch between AdGuardHome and carrier DNS, with \
	health probing, automatic failover, drift self-healing and a 53-port \
	conflict detector. Ships a pure-shell rescue command that works without \
	the daemon, without LuCI and without DNS itself.
LUCI_DEPENDS:=+luci-base +nftables
LUCI_PKGARCH:=all

# ── 安装后：立刻建配置、清 LuCI 缓存 ───────────────────────────
# 不能只靠 /etc/uci-defaults 在下次开机执行——用户装完包就去点页面，
# 那时配置还不存在，页面会是一张白纸。
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# 用 sh 而不是 . ：这个脚本末尾有 exit 0，source 进来会把 postinst 截断，
	# 后面的清缓存就执行不到了。
	if [ -f /etc/uci-defaults/99-dns-switch ]; then
		sh /etc/uci-defaults/99-dns-switch || true
		rm -f /etc/uci-defaults/99-dns-switch
	fi
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/* 2>/dev/null
	exit 0
}
endef

# 配置文件属于用户资产：卸载包不该顺手删掉他配好的上游和探测域名
define Package/$(PKG_NAME)/conffiles
/etc/config/dns_switch
endef

# ── 卸载前：必须把 DNS 还回去 ─────────────────────────────────
# nft 劫持规则和 dnsmasq 上游都是全局状态。包删了、规则还留着，
# 全屋 DNS 会指向一个已经不存在的东西——用户看到的是"卸个软件把网卸断了"。
# 这一步没得省。
define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	if [ -x /usr/bin/dns-switch ]; then
		/usr/bin/dns-switch restore-original >/dev/null 2>&1 || \
			/usr/bin/dns-switch rescue >/dev/null 2>&1 || \
			/usr/bin/dns-switch off >/dev/null 2>&1
	fi
	exit 0
}
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
