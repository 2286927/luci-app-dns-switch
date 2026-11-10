#!/bin/sh
# 包结构自检。不依赖 OpenWrt 源码树，能在任何 Linux/macOS 上跑。
#
# 为什么要有：Makefile 的 postinst / prerm 是纯文本，写错了要等打包
# 甚至等用户卸载时才炸。这里把能静态查的都查掉，剩下的交给 CI 真编译。
set -u

PKG=luci-app-dns-switch
fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
chk() { if [ "$2" = 1 ]; then ok "$1"; else bad "$1"; fi; }

echo ">>> $PKG 包结构自检"

# ── A. 文件齐全 ──────────────────────────────────────────────
for f in \
	$PKG/Makefile \
	$PKG/root/usr/bin/dns-switch \
	$PKG/root/etc/init.d/dns-switch \
	$PKG/root/etc/config/dns_switch \
	$PKG/root/etc/uci-defaults/99-dns-switch \
	$PKG/root/usr/share/luci/menu.d/luci-app-dns-switch.json \
	$PKG/root/usr/share/rpcd/acl.d/luci-app-dns-switch.json \
	$PKG/htdocs/luci-static/resources/view/dns_switch/overview.js
do
	[ -f "$f" ] && chk "存在 $f" 1 || chk "存在 $f" 0
done

# ── B. shell 语法 ────────────────────────────────────────────
for f in \
	$PKG/root/usr/bin/dns-switch \
	$PKG/root/etc/init.d/dns-switch \
	$PKG/root/etc/uci-defaults/99-dns-switch
do
	if sh -n "$f" 2>/dev/null; then chk "语法 $f" 1; else chk "语法 $f" 0; fi
done

# ── C. 不得有 CRLF ───────────────────────────────────────────
# busybox ash 遇到 \r 会报 "unexpected word (expecting do)"，
# 而 bash 能容忍——所以只能在字节层面查，不能靠 sh -n。
has_cr() {
	n=$(od -An -c "$1" 2>/dev/null | grep -c '\\r' || true)
	[ "${n:-0}" -gt 0 ]
}
for f in \
	$PKG/root/usr/bin/dns-switch \
	$PKG/root/etc/init.d/dns-switch \
	$PKG/root/etc/uci-defaults/99-dns-switch \
	$PKG/root/etc/config/dns_switch
do
	if has_cr "$f"; then chk "无 CRLF $f" 0; else chk "无 CRLF $f" 1; fi
done

# ── D. 可执行位 ──────────────────────────────────────────────
for f in \
	$PKG/root/usr/bin/dns-switch \
	$PKG/root/etc/init.d/dns-switch \
	$PKG/root/etc/uci-defaults/99-dns-switch
do
	[ -x "$f" ] && chk "可执行 $f" 1 || chk "可执行 $f" 0
done

# ── E. Makefile 关键字段 ─────────────────────────────────────
MK=$PKG/Makefile
grep -q 'include \$(TOPDIR)/rules.mk' "$MK"        && chk "Makefile 引入 rules.mk" 1 || chk "Makefile 引入 rules.mk" 0
grep -q 'luci.mk' "$MK"                            && chk "Makefile 使用 luci.mk" 1 || chk "Makefile 使用 luci.mk" 0
grep -q "^PKG_NAME:=$PKG\$" "$MK"                  && chk "PKG_NAME 正确" 1 || chk "PKG_NAME 正确" 0
grep -q '^LUCI_DEPENDS:=.*luci-base' "$MK"         && chk "依赖 luci-base" 1 || chk "依赖 luci-base" 0
grep -q '^LUCI_DEPENDS:=.*nftables' "$MK"          && chk "依赖 nftables" 1 || chk "依赖 nftables" 0

# postinst 必须用 sh 执行而不是 source：uci-defaults 末尾有 exit 0，
# source 会把 postinst 截断，后面的清缓存就跑不到了。
grep -q 'define Package/\$(PKG_NAME)/postinst' "$MK" && chk "有 postinst" 1 || chk "有 postinst" 0
grep -q 'sh /etc/uci-defaults/99-dns-switch' "$MK"   && chk "postinst 用 sh 执行初始化" 1 || chk "postinst 用 sh 执行初始化" 0
if grep -q '( \. /etc/uci-defaults' "$MK"; then
	chk "postinst 未用 source 执行初始化" 0
else
	chk "postinst 未用 source 执行初始化" 1
fi

# prerm 必须还原 DNS：包删了但 nft 规则和 dnsmasq 上游还在，等于断网
grep -q 'define Package/\$(PKG_NAME)/prerm' "$MK"    && chk "有 prerm" 1 || chk "有 prerm" 0
grep -q 'dns-switch restore-original' "$MK"          && chk "prerm 还原 DNS" 1 || chk "prerm 还原 DNS" 0
grep -q 'define Package/\$(PKG_NAME)/conffiles' "$MK" && chk "配置入 conffiles" 1 || chk "配置入 conffiles" 0

# ── F. 主程序关键子命令 ──────────────────────────────────────
BIN=$PKG/root/usr/bin/dns-switch
for cmd in do_on do_off do_rescue do_drill do_bundle do_timeline do_status; do
	grep -q "^$cmd()" "$BIN" && chk "含 $cmd" 1 || chk "含 $cmd" 0
done
# 设备上没有 diff，用了就会静默失效
if grep -q 'diff -u' "$BIN"; then chk "未依赖 diff" 0; else chk "未依赖 diff" 1; fi

# ── G. JSON 合法 ─────────────────────────────────────────────
for j in \
	$PKG/root/usr/share/luci/menu.d/luci-app-dns-switch.json \
	$PKG/root/usr/share/rpcd/acl.d/luci-app-dns-switch.json
do
	if command -v python3 >/dev/null 2>&1; then
		python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$j" 2>/dev/null \
			&& chk "JSON 合法 $j" 1 || chk "JSON 合法 $j" 0
	else
		grep -q '{' "$j" && chk "JSON 合法 $j（降级检查）" 1 || chk "JSON 合法 $j（降级检查）" 0
	fi
done

# ── H. 页面是 LuCI view 形态 ─────────────────────────────────
VIEW=$PKG/htdocs/luci-static/resources/view/dns_switch/overview.js
grep -q "'require view'" "$VIEW"   && chk "页面用 require view" 1 || chk "页面用 require view" 0
grep -q 'return view.extend' "$VIEW" && chk "页面导出 view.extend" 1 || chk "页面导出 view.extend" 0
if grep -q 'cbi-page-actions' "$VIEW"; then chk "页面未自绘悬浮动作条" 0; else chk "页面未自绘悬浮动作条" 1; fi

echo
if [ "$fail" -gt 0 ]; then
	printf '失败 %d 项\n' "$fail"
	exit 1
fi
echo "全部通过"
