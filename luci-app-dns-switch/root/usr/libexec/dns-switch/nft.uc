'use strict';

// ============================================================
// nft.uc —— L2 领域层：nft 规则片段
//
// 承接 v1.0.1 的 build_nft / nft_check / purge_dot / dot_sync。
//
// **build() 是全项目最严的一个签名**（SPEC §8.1 G1 门禁）：
//   * 两个位置参数 ('allow'|'block', 'aa:bb:..'|'')，顺序不可换、不许改 opts
//   * 纯函数：只用入参，不读 config/uci/env，不落盘
//   * 返回完整字符串、**以 \n 结尾**
//   * 输出与 test/golden/nft-{allow,block}-{mac,nomac}.nft **逐字节一致**
//   * **不许过 sh.run()**：它会剥掉尾部换行，908 B → 907 B，G1 直接红
//
// 关于第三个参数 adh：契约写的是 `build(dot853, mac)` 两参，而 v1.0.1 里
// ADH 来自 uci（`adh_ip`，§3.4 允许"换设备"时改）。两参写死就等于
// **用户改了 adh_ip、生成物还是 172.16.1.2**——一个测试抓不到的功能回归
// （4 组 fixture 用的都是默认值）。所以实现成**可选第三参**：
//   build(dot, mac)          → 与契约完全一致，G1 的两参调用逐字节不变
//   build(dot, mac, adh)     → sync() 传 cfg.settings.adh_ip，支持改过的 ADH
// 这条偏差已上报，等架构师裁定：保留第三参，或在 §3.4 明确 adh_ip 不再可改。
//
// 依赖：sh（执行 nft/fw4/sha256sum）+ log，**不依赖 config**（纯度要求）
// ============================================================

import { run, runq, quote } from './sh.uc';
import { log, err } from './log.uc';

let fs = require('fs');

const ADH_DEFAULT = '172.16.1.2';
const NFT = '/usr/sbin/nft';
const FRAG = '/etc/nftables.d/20-dns-hijack.nft';
const NFTDIR = '/etc/nftables.d';
const CHK_TMP = '/tmp/.dns-switch-nft-chk.nft';

function fail(code, message) {
	err(message);
	return { ok: false, code: code, message: message, detail: {} };
}

// 单测缝（N8）：opts.nft / opts.nftdir 只在测试里传，生产调用一律省略。
// 有它的原因很硬：purge 的 force 分支会真的 `nft delete chain`，
// 单测**绝不能**拿真机防火墙试，只能指到一个假 nft 上验逻辑与幂等。
function nft_of(opts) {
	if (opts != null && type(opts) == 'object') {
		if (type(opts.nft) == 'string' && length(opts.nft)) return opts.nft;
	}
	return NFT;
}

function nftdir_of(opts) {
	if (opts != null && type(opts) == 'object') {
		if (type(opts.nftdir) == 'string' && length(opts.nftdir)) return opts.nftdir;
	}
	return NFTDIR;
}

// sync 的落点也做成缝：单测要验"文件变了/没变"的行为，
// 但**绝不能**让它写 /etc/nftables.d（那是现场配置）。
function frag_of(opts) {
	if (opts != null && type(opts) == 'object') {
		if (type(opts.frag) == 'string' && length(opts.frag)) return opts.frag;
	}
	return FRAG;
}

function chain_exists(name, opts) {
	return runq(sprintf('%s list chain inet fw4 %s', nft_of(opts), name)).rc === 0;
}

/**
 * 生成 nft 片段。**纯函数**：只用入参，不落盘。
 * 行序固定：ether 豁免 → ip 豁免 → redirect（调换会让 ADH 自己的出站查询被劫持回自己）。
 */
export function build(dot853, mac, adh) {
	let dot = (dot853 == 'block') ? 'block' : 'allow';
	let m = (type(mac) == 'string') ? mac : '';
	let ip = (type(adh) == 'string' && length(adh)) ? adh : ADH_DEFAULT;

	let L = [];

	push(L, "# 由 dns-switch 生成，请勿手改（改 uci dns_switch 或重跑 dns-switch on）");
	if (dot == 'block') push(L, "# 853（DoT/DoQ）策略：拦截");
	else push(L, "# 853（DoT/DoQ）策略：放行，本文件不产生任何 853 规则");

	push(L, "chain dns_hijack {");
	push(L, "\ttype nat hook prerouting priority -95; policy accept;");
	push(L, "");
	if (length(m)) {
		push(L, sprintf("\tether saddr %s udp dport 53 accept", m));
		push(L, sprintf("\tether saddr %s tcp dport 53 accept", m));
	}
	push(L, sprintf("\tip saddr %s udp dport 53 accept", ip));
	push(L, sprintf("\tip saddr %s tcp dport 53 accept", ip));
	push(L, "");
	push(L, "\tmeta nfproto ipv4 udp dport 53 redirect to :53");
	push(L, "\tmeta nfproto ipv4 tcp dport 53 redirect to :53");
	push(L, "\tmeta nfproto ipv6 udp dport 53 redirect to :53");
	push(L, "\tmeta nfproto ipv6 tcp dport 53 redirect to :53");
	push(L, "}");

	// 853 拦截：加密 DNS 没法像 53 那样 redirect 到明文，只能 reject
	if (dot == 'block') {
		push(L, "");
		push(L, "chain dot_block {");
		push(L, "\ttype filter hook forward priority filter + 10; policy accept;");
		push(L, "");
		if (length(m)) {
			push(L, sprintf("\tether saddr %s tcp dport 853 accept", m));
			push(L, sprintf("\tether saddr %s udp dport 853 accept", m));
		}
		push(L, sprintf("\tip saddr %s tcp dport 853 accept", ip));
		push(L, sprintf("\tip saddr %s udp dport 853 accept", ip));
		push(L, "");
		push(L, "\ttcp dport 853 reject with tcp reset");
		push(L, "\tudp dport 853 reject");
		push(L, "}");
	}

	return join('\n', L) + '\n';
}

// ucode 没有内建 sha256（实测 sha256/md5/digest 都未声明），用 sha256sum
function sha256_of(path) {
	let r = runq(sprintf('/usr/bin/sha256sum %s', quote(path)));
	if (r.rc !== 0 || !length(r.out)) return '';
	let f = split(r.out, ' ');
	return (length(f) > 0) ? f[0] : '';
}

/** 唯一落盘点。返回真实字节数（不是字符数——ucode 的 length 本就是字节）。 */
export function write(path, dot853, mac, adh) {
	let text = build(dot853, mac, adh);
	let n = fs.writefile(path, text);
	if (n == null) {
		return fail('E_INTERNAL', sprintf('写入 nft 片段失败：%s（%s）', path, '写不进去'));
	}
	return { ok: true, path: path, bytes: n, sha256: sha256_of(path) };
}

/**
 * nft 预检。**必须包一层 table**：裸片段在 nftables 1.1.6 上必报
 * syntax error（chain 必须在 table 内）。
 */
export function check(path) {
	let raw = fs.readfile(path);
	if (type(raw) != 'string') {
		return fail('E_NFT_INVALID', sprintf('读不到待检片段：%s', path));
	}

	let wrapped = "table inet _dnsswitch_chk {\n" + raw + "\n}\n";
	if (fs.writefile(CHK_TMP, wrapped) == null) {
		return fail('E_INTERNAL', sprintf('预检临时文件写不进去：%s', CHK_TMP));
	}
	let r = run(sprintf('%s -c -f %s 2>&1', NFT, quote(CHK_TMP)));
	fs.unlink(CHK_TMP);

	if (r.rc === 0) return { ok: true, message: '' };
	let why = length(r.out) ? r.out : sprintf('nft -c 退出码 %d', r.rc);
	return { ok: false, code: 'E_NFT_INVALID', message: why, detail: {} };
}

/**
 * 清理 853 拦截链。幂等：本来没有也算 ok（removed=false）。
 * dot853='block' 时不动（那条链是我们自己生成的）；
 * 传 'force'（off / rescue 用）无视策略强制删——沿用 v1.0.1 purge_dot 的口径。
 */
export function purge(dot853, opts) {
	let force = (dot853 == 'force');
	if (!force && dot853 == 'block') return { ok: true, removed: false };

	let nftbin = nft_of(opts);
	let had = chain_exists('dot_block', opts);
	if (had) {
		let r = runq(sprintf('%s delete chain inet fw4 dot_block', nftbin));
		if (r.rc !== 0) {
			return fail('E_INTERNAL', sprintf('删除 853 拦截链失败（rc=%d）', r.rc));
		}
		log('已移除 853 拦截链（策略=放行）');
	}

	// 其它 nftables.d 文件里若还定义着 dot_block，只警告（不替用户改别人的文件）
	let dir = nftdir_of(opts);
	let names = fs.lsdir(dir);
	if (type(names) == 'array') {
		for (let i = 0; i < length(names); i++) {
			let f = dir + '/' + names[i];
			if (f == FRAG) continue;
			let t = fs.readfile(f);
			if (type(t) == 'string' && match(t, /dot_block/)) {
				log(sprintf('警告：%s 里还有 dot_block 定义，需人工清理', f));
			}
		}
	}
	return { ok: true, removed: had };
}

/**
 * 让落盘片段与内核状态跟上策略（漂移修补）。
 * 注意：**改动文件不等于内核生效**——文件变了由调用方决定 fw4 reload；
 * 这里只处理"文件没变但 853 链丢了"这一种漂移。
 */
export function sync(cfg, opts) {
	if (cfg == null || cfg.ok != true) {
		return fail('E_INTERNAL', 'sync 需要已解析的配置（cfg.ok 必须为 true）');
	}
	let s = cfg.settings;
	let dot = s.dot853;
	let path = frag_of(opts);
	let want = build(dot, s.adh_mac, s.adh_ip);
	let have = fs.readfile(path);
	let changed = false;

	if (type(have) == 'string' && have == want) {
		if (dot == 'block' && !chain_exists('dot_block', opts)) {
			runq('/sbin/fw4 reload');
			log('853 拦截链缺失，已按策略重建');
			changed = true;
		}
		return { ok: true, changed: changed, dot: dot };
	}

	let w = write(path, dot, s.adh_mac, s.adh_ip);
	if (!w.ok) return w;
	return { ok: true, changed: true, dot: dot };
}

/**
 * 只读探测（供 status）。读不到一律 false/0，**不报错**——它只用于展示。
 * ether 数 = "ether saddr … udp dport 53" 的行数（每台豁免设备一条 udp 一条 tcp）。
 */
export function present() {
	let hijack = false;
	let ether = 0;
	let r = runq(sprintf('%s list chain inet fw4 dns_hijack', NFT));
	if (r.rc === 0) {
		hijack = true;
		let lines = split(r.out, '\n');
		for (let i = 0; i < length(lines); i++) {
			if (match(lines[i], /ether saddr .* udp dport 53/) != null) ether++;
		}
	}
	return { hijack: hijack, ether: ether, dot_block: chain_exists('dot_block') };
}
