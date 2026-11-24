#!/bin/sh
# ============================================================================
# build_nft-v101.sh —— v1.0.1 的 build_nft() 原样抽取（G1 门禁 golden）
#
# 来源：luci-app-dns-switch v1.0.1 (ebb0e2f)
#       root/usr/bin/dns-switch 第 556–598 行，共 43 行，逐字节抽出。
# 复核命令：sed -n '/^build_nft()/,/^}/p' root/usr/bin/dns-switch
#
# 本文件只做一件事：把 v1.0.1 的 build_nft 放进一个不依赖整个包的壳里，
# 好让门禁能在任意机器上把它的输出与 ucode 版逐个字节比。
#
# 【QA 新增的只有 3 处，函数体一字未改、未重排、未死代码清理】
#   1) 本注释头
#   2) 环境变量接线（原版取全局变量，这里改从 env 读，缺省值与 v1.0.1 一致）
#   3) 文件末尾的执行尾（仅当 NFT_OUT 非空时调用 build_nft）
#
# 环境变量
#   DOT853   allow | block       缺省 allow（= v1.0.1 uci 缺省 dot853=allow）
#   ADH      AdGuardHome 的 IPv4 缺省 172.16.1.2（= v1.0.1 uci 缺省 adh_ip）
#   MAC      客户端 MAC，可空    缺省空 = 不产生 ether saddr 豁免
#   NFT_OUT  输出文件路径        非空时本脚本生成该文件（供脚本化调用）
#
# 用法
#   脚本式：DOT853=block MAC=aa:bb:cc:dd:ee:ff NFT_OUT=/tmp/g.nft sh build_nft-v101.sh
#   引用式：. ./build_nft-v101.sh; build_nft /tmp/g.nft 'aa:bb:cc:dd:ee:ff'
#
# 为什么必须逐字节一致：见 test/README.md「为什么必须逐字节」
# ============================================================================

DOT853="${DOT853:-allow}"
ADH="${ADH:-172.16.1.2}"

# ---------- 以下为 v1.0.1 第 556–598 行原样内容（勿改） ----------
build_nft() { # $1=输出文件 $2=MAC（可空）
	{
		echo "# 由 dns-switch 生成，请勿手改（改 uci dns_switch 或重跑 dns-switch on）"
		if [ "$DOT853" = "block" ]; then
			echo "# 853（DoT/DoQ）策略：拦截"
		else
			echo "# 853（DoT/DoQ）策略：放行，本文件不产生任何 853 规则"
		fi
		echo "chain dns_hijack {"
		echo "	type nat hook prerouting priority -95; policy accept;"
		echo ""
		if [ -n "$2" ]; then
			echo "	ether saddr $2 udp dport 53 accept"
			echo "	ether saddr $2 tcp dport 53 accept"
		fi
		echo "	ip saddr $ADH udp dport 53 accept"
		echo "	ip saddr $ADH tcp dport 53 accept"
		echo ""
		echo "	meta nfproto ipv4 udp dport 53 redirect to :53"
		echo "	meta nfproto ipv4 tcp dport 53 redirect to :53"
		echo "	meta nfproto ipv6 udp dport 53 redirect to :53"
		echo "	meta nfproto ipv6 tcp dport 53 redirect to :53"
		echo "}"

		# 853 拦截：加密 DNS 没法像 53 那样 redirect 到明文，只能 reject
		if [ "$DOT853" = "block" ]; then
			echo ""
			echo "chain dot_block {"
			echo "	type filter hook forward priority filter + 10; policy accept;"
			echo ""
			if [ -n "$2" ]; then
				echo "	ether saddr $2 tcp dport 853 accept"
				echo "	ether saddr $2 udp dport 853 accept"
			fi
			echo "	ip saddr $ADH tcp dport 853 accept"
			echo "	ip saddr $ADH udp dport 853 accept"
			echo ""
			echo "	tcp dport 853 reject with tcp reset"
			echo "	udp dport 853 reject"
			echo "}"
		fi
	} > "$1"
}
# ---------- 以下为 QA 追加：脚本式调用的执行尾（被 . 引用时不触发） ----------
if [ -n "${NFT_OUT:-}" ]; then
	build_nft "$NFT_OUT" "${MAC:-}"
fi
