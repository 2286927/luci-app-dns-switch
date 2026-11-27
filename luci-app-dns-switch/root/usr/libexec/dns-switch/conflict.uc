'use strict';

// ============================================================
// conflict.uc —— L2 领域层：53 端口归属冲突
//
// 为什么必须有：整条劫持链是 `redirect to :53`。一旦 53 的归属变了
// （dnsmasq 被挪到 1745、或本机 AdGuardHome/SmartDNS 抢了 53），redirect 仍然
// "成功"，流量却打到了另一个解析器。故障是静默的：nft 规则在位、uci 写着 ADH、
// 页面亮绿灯，只有客户端解析悄悄走错路。
//
// 三条硬约束：
//   1. `scan()` **不产生 E_\***：失败降级为 `level:'unknown'` + `why`。
//      它的用途是判断与展示，不是执行 —— 报 E_* 会让"没扫到"和"程序坏了"混成一个。
//   2. `cache_read()` 读不到返回 **null**，不许返回空对象：
//      空对象会被上层当成"扫过了，没问题"。
//   3. **`scan()` 不许出现在 status 路径上**（§4.1 写死）：前端 5 s 一 poll，
//      scan 要翻 6k 个 inode，P95 ≤300 ms 必被打穿。status 只读 `cache_read()`，
//      缓存由 switch.tick() 每 55 s 刷一次。
//
// 依赖：sh + log + fsutil + fs
// ============================================================

import * as fsutil from './fsutil.uc';
import { runq } from './sh.uc';
import { log } from './log.uc';

let fs = require('fs');

const PROC = '/proc';
const NETS = [ '/net/udp', '/net/tcp', '/net/udp6', '/net/tcp6' ];
const PORT53 = '0035';           // 53 的十六进制
const FD_CAP = 6000;             // 单次扫描的 fd 上限，别让 tick 被拖住
const CACHE = '/tmp/dns-switch.conflict';

// comm → init 脚本名（拼修复命令用）。名字对不上时退回 comm 本身。
const KNOWN = [
	[ 'AdGuardHome', 'adguardhome' ],
	[ 'adguardhome', 'adguardhome' ],
	[ 'smartdns', 'smartdns' ],
	[ 'mosdns', 'mosdns' ],
	[ 'unbound', 'unbound' ],
	[ 'dnscrypt-proxy', 'dnscrypt-proxy' ],
	[ 'https-dns-proxy', 'https-dns-proxy' ],
	[ 'dnsproxy', 'dnsproxy' ],
	[ 'pdnsd', 'pdnsd' ]
];

function opt_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'string' && length(v)) return v;
	}
	return dflt;
}

function proc_root(opts) {
	return opt_of(opts, 'proc', PROC);
}

function init_of(comm) {
	for (let i = 0; i < length(KNOWN); i++) if (KNOWN[i][0] == comm) return KNOWN[i][1];
	return comm;
}

function is_known_dns(comm) {
	for (let i = 0; i < length(KNOWN); i++) if (KNOWN[i][0] == comm) return true;
	return false;
}

// 注意：ucode 的函数**不提升**（export 与否都一样），被调用的原语必须写在前面。
/**
 * 按空白切字段并**丢掉空元素**。
 * 必须这么做：/proc/net/* 是列对齐的（多空格），而 ucode 的 split("a  b"," ")
 * 会留下空串 → 列号整体错位、inode 取到别的列。
 */
function fields(line) {
	let out = [];
	let raw = split(trim(line), ' ');
	for (let i = 0; i < length(raw); i++) if (length(raw[i])) push(out, raw[i]);
	return out;
}

/** 绑在 53 上的 socket inode（UDP/TCP、v4/v6 全看）。读不到就是空数组。 */
function sock53_inodes(opts) {
	let root = proc_root(opts);
	let out = [];
	for (let n = 0; n < length(NETS); n++) {
		let t = fs.readfile(root + NETS[n]);
		if (type(t) != 'string') continue;
		let lines = split(t, '\n');
		for (let i = 1; i < length(lines); i++) {      // 跳过表头
			let f = fields(lines[i]);
			if (length(f) < 10) continue;
			let hp = split(f[1], ':');
			if (length(hp) < 2 || hp[1] != PORT53) continue;
			let ino = f[9];
			if (length(ino)) push(out, ino);
		}
	}
	return out;
}

/** 某个 pid 持有的 socket inode 集合。 */
function fds_of(root, pid) {
	let out = [];
	let names = fs.lsdir(root + '/' + pid + '/fd');
	if (type(names) != 'array') return out;
	for (let i = 0; i < length(names); i++) {
		let l = fs.readlink(root + '/' + pid + '/fd/' + names[i]);
		if (type(l) != 'string') continue;
		let m = match(l, /^socket:\[([0-9]+)\]$/);
		if (m != null) push(out, m[1]);
	}
	return out;
}

function proc_pids(root) {
	let out = [];
	let names = fs.lsdir(root);
	if (type(names) != 'array') return out;
	for (let i = 0; i < length(names); i++) {
		if (match(names[i], /^[0-9]+$/) != null) push(out, names[i]);
	}
	return out;
}

function comm_of(root, pid) {
	let t = fs.readfile(root + '/' + pid + '/comm');
	if (type(t) != 'string') return '';
	return trim(t);
}

function has(arr, v) {
	for (let i = 0; i < length(arr); i++) if (arr[i] == v) return true;
	return false;
}

/**
 * 53 上的监听者。读不到 /proc 时返回空数组（**不是错误**，调用方由 inodes
 * 是否为空区分"没人监听"和"读不到"）。
 * opts.proc 是单测缝，指到假 proc 树。
 */
export function owners(opts) {
	let root = proc_root(opts);
	let ins = sock53_inodes(opts);
	let out = [];
	if (!length(ins)) return out;

	let pids = proc_pids(root);
	let seen = [];
	let budget = FD_CAP;

	for (let i = 0; i < length(ins); i++) {
		let ino = ins[i];
		let hit = '';
		for (let j = 0; j < length(pids); j++) {
			let pid = pids[j];
			if (has(seen, pid)) continue;
			let fds = fds_of(root, pid);
			budget = budget - length(fds);
			if (budget <= 0) break;           // 兜底：别让一次扫描拖住 tick
			if (has(fds, ino)) { hit = pid; break; }
		}
		if (!length(hit)) continue;
		push(seen, hit);
		let comm = comm_of(root, hit);
		push(out, {
			pid: +hit,
			comm: comm,
			init: init_of(comm),
			addr: ''
		});
	}
	return out;
}

/** 53 上的 socket 是否全部属于 dnsmasq（常态快路径）。 */
export function dnsmasq_owns_53(opts) {
	let root = proc_root(opts);
	let ins = sock53_inodes(opts);
	if (!length(ins)) return false;

	let mine = [];
	let pids = proc_pids(root);
	for (let j = 0; j < length(pids); j++) {
		if (comm_of(root, pids[j]) != 'dnsmasq') continue;
		let fds = fds_of(root, pids[j]);
		for (let k = 0; k < length(fds); k++) push(mine, fds[k]);
	}
	if (!length(mine)) return false;

	for (let i = 0; i < length(ins); i++) {
		if (!has(mine, ins[i])) return false;
	}
	return true;
}

function result(level, by, why, fix) {
	return { level: level, by: by, why: why, fix: fix };
}

// 注意：ucode 的函数不提升，scan_once 必须定义在 scan 之前。
function scan_once(opts) {
	let root = proc_root(opts);
	let readable = false;
	for (let n = 0; n < length(NETS); n++) {
		if (fs.stat(root + NETS[n]) != null) { readable = true; break; }
	}
	if (!readable) {
		return result('unknown', '', sprintf('读不到 %s/net/{udp,tcp}，无法判断 53 归属', root), '');
	}

	let ins = sock53_inodes(opts);
	if (!length(ins)) return result('none', '', '53 上没有监听者', '');

	if (dnsmasq_owns_53(opts)) {
		return result('none', 'dnsmasq', '53 由 dnsmasq 持有（正常）', '');
	}

	let own = owners(opts);
	if (!length(own)) {
		return result('unknown', '', '53 有监听者但定位不到进程（/proc 权限或 fd 上限）',
			'ls -l /proc/*/fd 2>/dev/null | grep 53');
	}

	let first = own[0];
	for (let i = 0; i < length(own); i++) {
		if (is_known_dns(own[i].comm)) { first = own[i]; break; }
	}

	if (is_known_dns(first.comm)) {
		return result('block', first.comm,
			sprintf('53 端口被 %s 占用，切换会失效', first.comm),
			sprintf('/etc/init.d/%s stop（或改它监听的端口）', first.init));
	}
	return result('warn', first.comm,
		sprintf('53 被非 DNS 进程 %s 占用', first.comm), '');
}

/**
 * 扫一次。**永不返回 E_\***；任何读不到的情况都降级为 level:'unknown'。
 * opts.wait = true 时最多重试 3 次（每次 sleep 1），等端口释放。
 */
export function scan(opts) {
	let o = (opts != null && type(opts) == 'object') ? opts : {};
	let tries = (o.wait == true) ? 3 : 1;
	let last = null;

	for (let i = 0; i < tries; i++) {
		last = scan_once(o);
		if (last.level == 'none' || last.level == 'block') return last;
		if (i + 1 < tries) runq('sleep 1');
	}
	return last;
}

/**
 * 写缓存（供 status 读）。写失败静默（不阻断业务），返回 false。
 * 格式：一行 TSV，ts/level/by/why/fix —— 不引 JSON，省一个解析面。
 */
export function cache_write(res, opts) {
	if (res == null || type(res) != 'object') return false;
	let path = opt_of(opts, 'path', CACHE);   // opts.path 是单测缝，生产不传
	let line = sprintf('%d\t%s\t%s\t%s\t%s\n', time(),
		(res.level != null) ? res.level : 'unknown',
		(res.by != null) ? res.by : '',
		(res.why != null) ? res.why : '',
		(res.fix != null) ? res.fix : '');
	if (!fsutil.ensure_dir(fs.dirname(path)).ok) return false;
	if (fs.writefile(path, line) == null) return false;
	return true;
}

/**
 * 读缓存。**读不到返回 null**（不是空对象）——空对象会被当成"扫过了没问题"。
 * opts.path 是单测缝；opts.max_age 超过多少秒视为过期（缺省不限）。
 */
export function cache_read(opts) {
	let path = opt_of(opts, 'path', CACHE);
	let t = fs.readfile(path);
	if (type(t) != 'string' || !length(trim(t))) return null;
	let f = split(trim(t), '\t');
	if (length(f) < 2) return null;

	let ts = +f[0];
	let maxage = 0;
	if (opts != null && type(opts) == 'object' && type(opts.max_age) == 'int') maxage = opts.max_age;
	if (maxage > 0 && (time() - ts) > maxage) return null;

	return {
		level: (length(f) > 1) ? f[1] : 'unknown',
		by: (length(f) > 2) ? f[2] : '',
		why: (length(f) > 3) ? f[3] : '',
		fix: (length(f) > 4) ? f[4] : '',
		ts: ts
	};
}
