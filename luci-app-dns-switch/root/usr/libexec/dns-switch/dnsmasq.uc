'use strict';

// ============================================================
// dnsmasq.uc —— L2 领域层：dnsmasq / DHCP 下发
//
// 承接 v1.0.1 的 strip_opt / set_dhcp_dns / set_dnsmasq_upstream / verify_dns /
// rollback，外加 RDNSS（v1.0.1 在 do_on 里内联的三行）。
//
// **本模块写的不是 dns_switch 包**，是 `dhcp` 包：
//   dhcp.@dnsmasq[0].server / .noresolv / .strictorder / .dns_redirect
//   dhcp.lan.dhcp_option（option 6）/ dhcp.lan.dns（RDNSS）
// 所以每个写操作后面必须 `state.commit('dhcp')`。写死 `commit()`（缺省
// dns_switch）会返回 ok 而 dhcp 一个字节没落盘 —— "看着成功、实际没变"。
//
// 写 uci 一律经 `state.set_opt()` + `state.commit('dhcp')`：
// A5 门禁会扫 `cursor(` 与 `sh.run(... uci ...)` 两种形式：本模块两样都不许有。
// （判据在匹配前会剥掉注释，所以这里可以直呼其名——见 N37：注释里写清楚规则比绕开它更有用。）
//
// 实测（写这一版时踩到的）：
//   * `state.set_opt(..., 数组)` 才是 uci **list**；传字符串是标量覆盖，
//     而 server/dhcp_option/lan.dns 都必须是 list，否则 dnsmasq 只认第一个
//   * 读 list 只能 `get_all(conf,sect)[key]`（三参 get_all 返回 null）
//
// 依赖：state + sh + log（契约写的是 config,state,sh,log，但实现不读配置——
// 上游列表是由调用方算好传进来的。已报架构师，按 A6 单向规则这条只算 WARN）
// ============================================================

import * as state from './state.uc';
import { run, runq, quote } from './sh.uc';
import { log, err } from './log.uc';

const CONF = 'dhcp';
const DM = '@dnsmasq[0]';
const LAN = 'lan';
const VERIFY_TRIES = 3;
const VERIFY_GAP = 2;      // v1.0.1 每轮之间 sleep 2

function fail(code, message) {
	err(message);
	return { ok: false, code: code, message: message, detail: {} };
}

function clean_list(list) {
	let out = [];
	if (type(list) != 'array') return out;
	for (let i = 0; i < length(list); i++) {
		let v = (type(list[i]) == 'string') ? list[i] : ("" + list[i]);
		if (length(v)) push(out, v);
	}
	return out;
}

function same_list(a, b) {
	if (length(a) != length(b)) return false;
	for (let i = 0; i < length(a); i++) if (a[i] !== b[i]) return false;
	return true;
}

function commit_dhcp() {
	let r = state.commit(CONF);
	if (!r.ok) return fail('E_UCI_COMMIT', r.message);
	return { ok: true, changed: true };
}

/**
 * 下发上游列表（第一条为主）+ noresolv/strictorder/dns_redirect。
 * opts.v6 里的地址会追加在后面（IPv6 上游 dnsmasq 走同一个 server list）。
 * 值没变就 changed:false 且**不 commit**（避免无谓写盘 + dnsmasq 重载）。
 */
export function set_upstream(list, opts) {
	let want = clean_list(list);
	if (opts != null && type(opts) == 'object') {
		let extra = clean_list(opts.v6);
		for (let i = 0; i < length(extra); i++) push(want, extra[i]);
	}
	if (!length(want)) return fail('E_ARG', '上游列表为空，拒绝下发（会把 dnsmasq 的上游清空）');

	let have = state.get_list(CONF, DM, 'server');
	let flags_ok = (state.get_opt(CONF, DM, 'noresolv') == '1')
		&& (state.get_opt(CONF, DM, 'strictorder') == '1')
		&& (state.get_opt(CONF, DM, 'dns_redirect') == '0');

	if (same_list(have, want) && flags_ok) return { ok: true, changed: false };

	if (!state.set_opt(CONF, DM, 'server', want)) {
		return fail('E_INTERNAL', '写 dhcp.@dnsmasq[0].server 失败');
	}
	state.set_opt(CONF, DM, 'noresolv', '1');
	state.set_opt(CONF, DM, 'strictorder', '1');
	state.set_opt(CONF, DM, 'dns_redirect', '0');
	return commit_dhcp();
}

/**
 * option 6（DHCP 下发的 IPv4 DNS）。**必须合成单条** `6,a,b`：
 * 多条 option 6 时 dnsmasq 只认第一条（v1.0.1 的注释与实现一致）。
 */
export function set_option6(list) {
	let addrs = clean_list(list);
	let tok = '6';
	for (let i = 0; i < length(addrs); i++) tok = tok + ',' + addrs[i];

	let have = state.get_list(CONF, LAN, 'dhcp_option');
	let keep = [];
	for (let i = 0; i < length(have); i++) {
		// 去掉旧的 option 6 条目（^6 , 或就是 "6"），其余原样保留
		if (match(have[i], /^6(,|$)/) != null) continue;
		push(keep, have[i]);
	}
	push(keep, tok);

	if (same_list(have, keep)) return { ok: true, changed: false };
	if (!state.set_opt(CONF, LAN, 'dhcp_option', keep)) {
		return fail('E_INTERNAL', '写 dhcp.lan.dhcp_option 失败');
	}
	let r = commit_dhcp();
	if (r.ok) log(sprintf('DHCP 下发 DNS → %s', tok));
	return r;
}

/** RDNSS：IPv6 的 DNS 只能走 dhcp.lan.dns（option 6 装不下 v6）。空数组 = 清空。 */
export function set_rdnss(list) {
	let want = clean_list(list);
	let have = state.get_list(CONF, LAN, 'dns');
	if (same_list(have, want)) return { ok: true, changed: false };

	if (!state.set_opt(CONF, LAN, 'dns', want)) {
		return fail('E_INTERNAL', '写 dhcp.lan.dns 失败');
	}
	let r = commit_dhcp();
	if (r.ok && length(want)) log(sprintf('RDNSS 下发 IPv6 DNS → %s', join(' ', want)));
	return r;
}

/**
 * 本机 53 上能否解析。**不产生 E_\***：失败是业务结论，由调用方决定回滚
 * 并映射 E_APPLY_FAILED。
 * 注意 busybox 的 nslookup 没有超时参数，真实上界由 resolver 决定（v1.0.1 同）。
 */
export function verify(domain, opts) {
	let dom = (type(domain) == 'string' && length(domain)) ? domain : 'www.baidu.com';
	let tries = VERIFY_TRIES;
	if (opts != null && type(opts) == 'object' && type(opts.tries) == 'int' && opts.tries > 0) {
		tries = opts.tries;
	}
	let t0 = time();
	for (let i = 0; i < tries; i++) {
		let r = runq(sprintf('nslookup %s 127.0.0.1', quote(dom)));
		if (r.rc == 0) return { ok: true, ms: (time() - t0) * 1000, reason: 'ok' };
		if (i + 1 < tries) runq(sprintf('sleep %d', VERIFY_GAP));
	}
	return { ok: false, ms: (time() - t0) * 1000, reason: 'dns-fail' };
}

/**
 * 回滚到快照。**已经无可退，失败必须响亮**（E_INTERNAL）。
 * snap 由 snapshot.uc 给出的绝对路径：{dhcp_bak, frag_bak}。
 * opts.frag / opts.restart 是测试缝（生产不传）——本函数会重启 dnsmasq、
 * 覆盖 /etc/config/dhcp，单测绝不能对着真机跑。
 */
export function rollback(snap, opts) {
	let o = (opts != null && type(opts) == 'object') ? opts : {};
	log('回滚中…');

	if (snap != null && type(snap) == 'object' && type(snap.dhcp_bak) == 'string'
		&& length(snap.dhcp_bak)) {
		let r = runq(sprintf('cp -f %s /etc/config/dhcp', quote(snap.dhcp_bak)));
		if (r.rc != 0) return fail('E_INTERNAL', sprintf('还原 /etc/config/dhcp 失败（rc=%d）', r.rc));
		let c = state.commit(CONF);
		if (!c.ok) return fail('E_INTERNAL', '还原后 uci commit dhcp 失败');
	}

	runq('/usr/sbin/nft delete table inet dnsmasq');
	if (o.skip_reload != true) {
		runq('/sbin/fw4 reload');
		runq('/etc/init.d/dnsmasq restart');
	}

	if (verify('www.baidu.com', { tries: 1 }).ok) {
		log('回滚完成，解析已恢复');
		return { ok: true };
	}
	return fail('E_INTERNAL', '回滚后仍解析失败，请检查 WAN');
}

/**
 * 只读：dnsmasq 当前的上游第一条与监听端口（供 status）。
 * 读不到 → {'', 0}，**不报错**。
 */
export function pointers() {
	let first = '';
	let port = 0;
	let srv = state.get_list(CONF, DM, 'server');
	if (length(srv)) {
		let f = split(srv[0], '/');
		first = (length(f) > 1) ? f[1] : srv[0];
	}
	let p = state.get_opt(CONF, DM, 'port');
	if (type(p) == 'string' && match(trim(p), /^[0-9]+$/)) port = +trim(p);
	if (port == 0) port = 53;
	return { first: first, port: port };
}
