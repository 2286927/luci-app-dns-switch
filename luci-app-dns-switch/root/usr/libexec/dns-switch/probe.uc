'use strict';

// ============================================================
// probe.uc —— L2 领域层：ADH 探活 / 运营商 DNS / IPv6 探测
//
// 承接 v1.0.1 的 have_curl / probe_adh / probe_dns_only / probe_reason /
// isp_dns / detect_adh_v6 / fb_reach。
//
// 三条硬约束：
//   1. `probe()` 总预算 ≤ 6 s（curl 侧 -m 3，两次各 ≤3 s）
//   2. `via='none'` **必须带 reason**，不许静默返回 false
//   3. 本模块**不产生 E_\***：探测失败是业务结论（ok=false + reason），
//      报 E_* 会让"没探测通"和"程序坏了"混成一个，调用方（switch）自己映射
//      E_PRECOND_GATE
//
// `reason(code, opts)` 是 C11 人话文案的**唯一来源**，别处不许硬编码。
//   （契约写的是 `reason(code)`，但 v1.0.1 的文案里含 $ADH_PORT / $PROBE_DOMAIN，
//     参数化不了就必然丢字，C11 的逐字节 diff 会红。故加可选 opts 承载端口/域名。）
//
// 依赖：config（取 resolved 配置）+ sh（执行 curl/nslookup/ping）
// ============================================================

import * as config from './config.uc';
import { run, runq, quote } from './sh.uc';
import { log } from './log.uc';

let fs = require('fs');

const FLAG = '/tmp/dns-switch.probe-fail';   // drill 用：在有效期内一律判 ADH 失联
const FLAG_TTL = 300;
const RESOLV = '/tmp/resolv.conf.d/resolv.conf.auto';
const CURL = '/usr/bin/curl';
const ISP_FALLBACK = [ '202.103.224.68', '202.103.225.68' ];
const T_DEFAULT = 3;

// 毫秒。clock() 在 ucode 里是 CPU 时间（实测恒 0），不能用；
// /proc/uptime 有 10 ms 精度，且无 exec 开销。
function uptime_ms() {
	let raw = fs.readfile('/proc/uptime');
	if (type(raw) != 'string') return time() * 1000;
	let f = split(trim(raw), ' ');
	if (!length(f)) return time() * 1000;
	return +f[0] * 1000;
}

// ---------- curl 是否真的能跑 ----------
// 不能只看"路径存在"：v1.0.1 踩过 ash 的 hash 缓存——`command -v` 返回旧路径，
// 真 exec 时才 127，于是探活恒失败 → 连降两次 → 全屋降级。这里每个 sh 都是新进程
// 没有 hash 问题，但仍保留"取到路径后再验可执行"的双重判定。
export function have_curl() {
	let r = runq('command -v curl');
	if (r.rc !== 0 || !length(r.out)) return false;
	return runq(sprintf('test -x %s', quote(r.out))).rc === 0;
}

// ---------- 单点探测 ----------
export function probe_web(ip, port, timeout) {
	let t = (type(timeout) == 'int' && timeout > 0) ? timeout : T_DEFAULT;
	let t0 = uptime_ms();
	let cmd = sprintf('%s -s -o /dev/null -m %d -w "%%{http_code}" http://%s:%d/ 2>/dev/null',
		CURL, t, ip, port);
	let r = run(cmd);
	let ms = uptime_ms() - t0;
	let code = trim(r.out);
	let status = (length(code) && match(code, /^[0-9]+$/)) ? +code : 0;
	let ok = (r.rc == 0 && status > 0);
	return {
		ok: ok, rc: r.rc, status: status, ms: ms,
		reason: ok ? 'ok' : 'web-fail'
	};
}

// busybox 的 nslookup **没有超时参数**（实测），所以 timeout 只能记录意图。
// 真实上界由 resolver 的重试策略决定——v1.0.1 也是这样，不是本次引入的。
export function probe_dns(ip, domain, timeout) {
	let t0 = uptime_ms();
	let r = runq(sprintf('nslookup %s %s', quote(domain), quote(ip)));
	let ms = uptime_ms() - t0;
	return { ok: (r.rc == 0), ms: ms, reason: (r.rc == 0) ? 'ok' : 'dns-fail' };
}

// drill 钩子：文件在有效期内 → 一律当 ADH 失联（降级链绝不能绕过它）
function flag_active() {
	if (fs.stat(FLAG) == null) return false;
	let raw = fs.readfile(FLAG);
	let ts = (type(raw) == 'string' && match(trim(raw), /^[0-9]+$/)) ? +trim(raw) : 0;
	let age = time() - ts;
	if (age < FLAG_TTL) return true;
	fs.unlink(FLAG);
	log(sprintf('演练标记已过期（%ds），自动清除', age));
	return false;
}

function arg_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'string' && length(v)) return v;
		if (type(v) == 'int' && v > 0) return v;
	}
	return dflt;
}

/**
 * 探活。opts 是单测缝；生产调用不带 opts → 自己取 config.load() 的 resolved 配置。
 * 返回 { ok, via:'curl'|'dns'|'none', ms, reason }。
 */
export function probe(opts) {
	let ip = arg_of(opts, 'ip', null);
	let port = arg_of(opts, 'port', null);
	let domain = arg_of(opts, 'domain', null);
	let tmo = arg_of(opts, 'timeout', T_DEFAULT);

	if (ip == null || port == null || domain == null) {
		let cfg = config.load();
		if (cfg.ok != true) {
			return { ok: false, via: 'none', ms: 0, reason: 'config-unreadable' };
		}
		let s = cfg.settings;
		if (ip == null) ip = s.adh_ip;
		if (port == null) port = s.adh_port;
		if (domain == null) domain = s.probe_domain;
	}
	port = (type(port) == 'int') ? port : +port;

	let t0 = uptime_ms();
	if (flag_active()) {
		return { ok: false, via: 'none', ms: uptime_ms() - t0, reason: 'drill' };
	}

	// 没装 curl：退化成纯 DNS 探测（缺 curl 不是错误，是降档）
	if (!have_curl()) {
		let d = probe_dns(ip, domain, tmo);
		return {
			ok: d.ok, via: 'dns', ms: uptime_ms() - t0,
			reason: d.ok ? 'nocurl-dns-ok' : 'nocurl-dns-fail'
		};
	}

	let w = probe_web(ip, port, tmo);
	if (w.rc == 127) {          // 有路径但 exec 不起来 → 绝不能判 ADH 挂了
		log('curl 无法执行（rc=127），本次退回仅 DNS 探测');
		let d = probe_dns(ip, domain, tmo);
		return {
			ok: d.ok, via: 'dns', ms: uptime_ms() - t0,
			reason: d.ok ? 'nocurl-dns-ok' : 'nocurl-dns-fail'
		};
	}
	if (!w.ok) return { ok: false, via: 'curl', ms: uptime_ms() - t0, reason: 'web-fail' };

	// 双条件：只测 53 会被"exchange 模式下 dnsmasq 从 1745 顶上来"骗过
	let d = probe_dns(ip, domain, tmo);
	if (!d.ok) return { ok: false, via: 'curl', ms: uptime_ms() - t0, reason: 'dns-fail' };
	return { ok: true, via: 'curl', ms: uptime_ms() - t0, reason: 'ok' };
}

/**
 * 文案（C11 唯一来源）。code 见各分支；opts.port / opts.domain 用于还原
 * v1.0.1 原文里的占位。**未知 code 也要给话**，绝不返回空串。
 */
export function reason(code, opts) {
	let o = (opts != null && type(opts) == 'object') ? opts : {};
	let port = (o.port != null && length("" + o.port)) ? "" + o.port : '3030';
	let dom = (type(o.domain) == 'string' && length(o.domain)) ? o.domain : 'www.baidu.com';

	if (code == 'ok') return '正常';
	if (code == 'web-fail') return sprintf('Web %s 不通（AdGuardHome 未运行或地址不对）', port);
	if (code == 'dns-fail') return 'Web 有响应但解析失败（ADH 上游不可用）';
	if (code == 'nocurl-dns-ok') return sprintf('未安装 curl，仅按 DNS 探测（%s 解析正常）', dom);
	if (code == 'nocurl-dns-fail') return sprintf('未安装 curl，仅按 DNS 探测（%s 解析失败）', dom);
	if (code == 'drill') return '演练标记生效，按 ADH 失联处理';
	if (code == 'config-unreadable') return '配置读不到，无法判断 ADH 状态';
	return sprintf('未知探测结果（%s）', "" + code);
}

function words(s) {
	let out = [];
	if (type(s) != 'string' || !length(s)) return out;
	let f = split(trim(s), ' ');
	for (let i = 0; i < length(f); i++) if (length(f[i])) push(out, f[i]);
	return out;
}

function push_all(dst, src) {
	for (let i = 0; i < length(src); i++) push(dst, src[i]);
}

/**
 * 运营商/上游 DNS。manual 优先（含旧版单行 isp_list 兜底），否则读
 * resolv.conf.auto 并剔掉本机/ADH/备用地址；都拿不到才用内置兜底。
 */
export function isps(cfg) {
	let s = (cfg != null && cfg.ok == true) ? cfg.settings : null;
	if (s == null) return { v4: [], v6: [], source: 'auto' };

	if (s.upstream_mode == 'manual') {
		let v4 = words(s.isp_list4);
		let v6 = words(s.isp_list6);
		if (!length(v4) && !length(v6)) v4 = words(s.isp_list);   // v1.0.x 遗留单行
		if (length(v4) || length(v6)) return { v4: v4, v6: v6, source: 'manual' };
	}

	let v4 = [];
	let v6 = [];
	let raw = fs.readfile(RESOLV);
	if (type(raw) == 'string') {
		let lines = split(raw, '\n');
		for (let i = 0; i < length(lines); i++) {
			let m = match(lines[i], /^nameserver[ \t]+(\S+)/);
			if (m == null) continue;
			let a = m[1];
			if (match(a, /^127\./) || a == '::1' || a == s.adh_ip || a == s.fallback_dns) continue;
			if (index(a, ':') >= 0) push(v6, a);
			else push(v4, a);
		}
	}
	if (!length(v4) && !length(v6)) push_all(v4, ISP_FALLBACK);
	return { v4: v4, v6: v6, source: 'auto' };
}

/**
 * 自动探测 AdGuardHome 的 IPv6：先把 v4 反查成主机名，再从 odhcpd 的 hosts 表
 * 取它的 v6。优先 ULA（fc/fd，不随 PPPoE 前缀变化），没有再用公网地址。
 * 探测不到返回 ''（与 E_* 无关）。
 */
export function adh_v6(cfg) {
	let s = (cfg != null && cfg.ok == true) ? cfg.settings : null;
	if (s == null) return '';
	let ip = (type(s.adh_ip) == 'string' && length(s.adh_ip)) ? s.adh_ip : '172.16.1.2';

	let r = runq(sprintf('nslookup %s 127.0.0.1', quote(ip)));
	if (r.rc != 0) return '';
	let m = match(r.out, /[Nn]ame:[ \t]*(\S+)/);
	if (m == null) return '';
	let name = replace(m[1], /\.lan$/, '');
	if (!length(name)) return '';

	let ula = '';
	let gua = '';
	let files = [ '/tmp/hosts/odhcpd.hosts.lan', '/tmp/hosts/hosts' ];
	let extra = fs.lsdir('/tmp/hosts');
	if (type(extra) == 'array') {
		for (let i = 0; i < length(extra); i++) {
			if (match(extra[i], /^dhcp\.cfg/) != null) push(files, '/tmp/hosts/' + extra[i]);
		}
	}

	for (let i = 0; i < length(files); i++) {
		let t = fs.readfile(files[i]);
		if (type(t) != 'string') continue;
		let lines = split(t, '\n');
		for (let j = 0; j < length(lines); j++) {
			let f = split(trim(lines[j]), ' ');
			if (length(f) < 2 || f[1] != name) continue;
			let a = f[0];
			if (index(a, ':') < 0) continue;
			if (match(a, /^f[cd]/) != null) { if (!length(ula)) ula = a; }
			else { if (!length(gua)) gua = a; }
		}
	}
	if (length(ula)) return ula;
	if (length(gua)) return gua;
	return '';
}

/** 备用 DNS 是否可达（ping -c1 -W1）。未配置 → false。 */
export function fb_reach(cfg) {
	let s = (cfg != null && cfg.ok == true) ? cfg.settings : null;
	if (s == null) return false;
	let fb = s.fallback_dns;
	if (type(fb) != 'string' || !length(fb)) return false;
	return runq(sprintf('ping -c1 -W1 %s', quote(fb))).rc == 0;
}
