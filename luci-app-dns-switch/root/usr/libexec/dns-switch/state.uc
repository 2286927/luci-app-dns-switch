'use strict';

// ============================================================
// state.uc —— L1 状态层：uci 访问与**写入路径**
//
// 从 config.uc 拆出来的（IMPL-NOTES N23：config 超 250 行先拆）。
// 边界：
//   state  = 怎么和 uci 说话（建 cursor、建/修配置、读写、commit）
//   config = 说什么（§3.4 缺省值 resolve、对外视图、签名）
// 所以这里**不许出现任何缺省值**——那是 config 的事，写在这里就等于把
// "默认值藏在执行里"，§3.4 明令禁止。
//
// 对外：
//   open(opts)            → { ok:true } | { ok:false, code, message }
//                           建 cursor（opts.confdir 仅供单测重定向）+ 建出厂配置
//                           + 补建 status 段。任何一步失败都返回 ok:false。
//   get(sect, key)        → string | null     读原始值（sect 为 'settings'/'status'）
//   set_status(key, val)  → bool              写 status 段（不 commit）
//   commit()              → { ok, code, message }
//
// "值不变不写" 留在 set_status 里（v1.0.1 st_set 的语义：少写 flash）。
//
// 依赖：uci + log（不 import 任何上层模块）
// ============================================================

import { log, err } from './log.uc';

let uci = require('uci');
let fs = require('fs');

const PKG = 'dns_switch';
const SECT = 'settings';
const STAT = 'status';
const CONFDIR = '/etc/config';

// 出厂 payload（逐字节照抄 v1.0.1 ensure_config 的 here-doc）
const FACTORY = [
	"",
	"config settings 'settings'",
	"\toption mode 'off'",
	"\toption adh_ip '172.16.1.2'",
	"\toption adh_port '3030'",
	"\toption fallback_dns '172.16.5.5'",
	"\toption fallback_dns6 ''",
	"\toption probe_domain 'www.baidu.com'",
	"\toption adh_mac ''",
	"\toption dot853 'allow'",
	"\toption upstream_mode 'auto'",
	"\toption isp_list4 '202.103.224.68 202.103.225.68'",
	"\toption isp_list6 ''",
	"\toption auto_failover '1'",
	"\toption probe_now '0'",
	"\toption request_at '0'",
	"",
	"config status 'status'",
	"\toption effective 'off'",
	"\toption probe 'unknown'",
	"\toption reason 'factory-default'",
	"\toption dep ''",
	"\toption adh_mac ''",
	"\toption upstream ''",
	"\toption last_change '0'",
	"\toption error ''",
	"\toption conflict 'none'",
	"\toption conflict_by ''",
	"\toption conflict_msg ''",
	"\toption conflict_fix ''",
	""
];

let cur = null;
let dirty = [];      // 有未提交改动的包名列表（多包了，不能再是一个 bool）

function mark_dirty(conf) {
	for (let i = 0; i < length(dirty); i++) if (dirty[i] == conf) return;
	push(dirty, conf);
}

function is_dirty(conf) {
	for (let i = 0; i < length(dirty); i++) if (dirty[i] == conf) return true;
	return false;
}

function clear_dirty(conf) {
	let keep = [];
	for (let i = 0; i < length(dirty); i++) if (dirty[i] != conf) push(keep, dirty[i]);
	dirty = keep;
}

function fail(code, message) {
	err(message);
	return { ok: false, code: code, message: message, detail: {} };
}

function confdir_of(opts) {
	if (opts != null && type(opts) == 'object') {
		if (type(opts.confdir) == 'string' && length(opts.confdir)) return opts.confdir;
	}
	return CONFDIR;
}

// 建出厂配置：写文件 → 让 cursor 重读 → commit（与 v1.0.1 的顺序一致）
function ensure_config(dir) {
	let path = dir + '/' + PKG;
	let n = fs.writefile(path, join('\n', FACTORY));
	if (n == null) return fail('E_UCI_COMMIT', sprintf('无法写入 %s（配置未落盘）', path));

	let loaded = false;
	try {
		loaded = (cur.load(PKG) === true);
	} catch (e) {
		loaded = false;
	}
	if (!loaded) return fail('E_INTERNAL', sprintf('uci 无法解析刚建好的 %s', path));

	if (cur.commit(PKG) !== true) {
		return fail('E_UCI_COMMIT', 'uci commit dns_switch 失败，出厂配置未落盘');
	}
	log('初始化 dns_switch 配置');
	return { ok: true, code: 'OK', message: '' };
}

function ensure_status() {
	let sect = cur.get(PKG, STAT);
	if (type(sect) == 'string' && length(sect)) return { ok: true, code: 'OK', message: '' };

	if (cur.set(PKG, STAT, STAT) !== true) {
		return fail('E_UCI_COMMIT', 'uci set dns_switch.status=status 失败');
	}
	if (cur.commit(PKG) !== true) {
		return fail('E_UCI_COMMIT', 'uci commit dns_switch 失败，status 段未补建');
	}
	log('补建 status 段');
	return { ok: true, code: 'OK', message: '' };
}

/** 建 cursor 并把配置修好（缺文件就建、缺 status 段就补）。 */
export function open(opts) {
	let dir = confdir_of(opts);

	try {
		cur = (dir == CONFDIR) ? uci.cursor() : uci.cursor(dir);
	} catch (e) {
		cur = null;
		return fail('E_INTERNAL', sprintf('无法打开 uci：%s', e));
	}
	dirty = [];

	if (fs.stat(dir + '/' + PKG) == null) {
		let created = ensure_config(dir);
		if (!created.ok) return created;
	}

	return ensure_status();
}

/** 读任意包的标量。取不到 → null。 */
export function get_opt(conf, sect, key) {
	if (cur == null) return null;
	let v = cur.get(conf, sect, key);
	return (type(v) == 'string') ? v : null;
}

/**
 * 读任意包的 uci **list**。取不到 → 空数组（不是 null：调用方一律按"没有条目"处理）。
 *
 * 实测：ucode-mod-uci 的读取口是 `get_all(conf, sect)` 拿整段再取键，
 * `get_all(conf, sect, key)`（三参）返回 null —— 三参形式不存在。
 */
export function get_list(conf, sect, key) {
	if (cur == null) return [];
	let all = cur.get_all(conf, sect);
	if (type(all) != 'object' || all == null) return [];
	let v = all[key];
	if (type(v) == 'array') return v;
	if (type(v) == 'string' && length(v)) return [ v ];
	return [];
}

/**
 * 读原始值。sect 用 'settings' / 'status'；取不到返回 null（不编默认值）。
 * **注意定义顺序**：ucode 的 `export function` 不提升，糖函数必须写在被它调用的
 * 原语之后，否则运行时 `access to undeclared variable`。
 */
export function get(sect, key) {
	return get_opt(PKG, sect, key);
}

/**
 * 写任意包的任意键（不 commit）。值没变就不写，避免无谓的 flash 写。
 *
 * 为什么参数是 (conf, sect, key, val) 而不是 (key, val)：
 * **同一份代码里有两个包** —— 本模块的 `dns_switch`，和 `dnsmasq.uc` 要写的
 * **`dhcp`**（`@dnsmasq[0].server` / `lan.dhcp_option` / `lan.dns`）。
 * 只认 `dns_switch` 的写法会让 dnsmasq 的调用"看着成功、实际没变"。
 *
 * **val 传数组 = 写 uci list**（实测：`list server 'a'` × N，与 `uci add_list`
 * 逐字节同形）；传字符串 = 写标量 option。两者不能混：dnsmasq 的 `server` /
 * `dhcp_option` / `lan.dns` 都是 list，写成字符串 dnsmasq 只认第一个。
 */
export function set_opt(conf, sect, key, val) {
	if (cur == null) return false;

	let want = val;
	let is_list = (type(val) == 'array');

	if (is_list) {
		let norm = [];
		for (let i = 0; i < length(val); i++) {
			let e = (type(val[i]) == 'string') ? val[i] : ("" + val[i]);
			if (length(e)) push(norm, e);
		}
		want = norm;
	}
	else {
		let v = '';
		if (type(val) == 'string') v = val;
		else if (val !== null) v = "" + val;   // type(null) 是 null，不能拿它判空
		want = v;
	}

	// 值没变就不写盘（list 用 join 比，避免逐元素比较）
	let old = cur.get_all(conf, sect);
	if (type(old) == 'object' && old != null) {
		let o = old[key];
		if (is_list) {
			if (type(o) == 'array' && join('\n', o) == join('\n', want)) return true;
			if (type(o) != 'array' && !length(want) && o === null) return true;
		}
		else if (type(o) == 'string' && o == want) {
			return true;
		}
	}

	// 空数组 = **删除**这个键。实测 `set(key, [])` 是空操作（旧值原样留着），
	// 想清空 list 必须走 delete，否则"清空 RDNSS"会静默不生效。
	if (is_list && !length(want)) {
		if (cur.delete(conf, sect, key) !== true) return false;
		mark_dirty(conf);
		return true;
	}

	if (cur.set(conf, sect, key, want) !== true) return false;
	mark_dirty(conf);
	return true;
}

/** 写 settings 段的一个字段（不 commit）。`set_opt` 的糖，对称于 set_status。 */
export function set_setting(key, val) {
	return set_opt(PKG, SECT, key, val);
}

/** 写 status 段的一个字段（不 commit）。`set_opt` 的糖，语义等价。 */
export function set_status(key, val) {
	return set_opt(PKG, STAT, key, val);
}

/**
 * 提交某个包的改动。**包名不能写死**：写死 dns_switch 时，
 * `set_opt('dhcp', …)` 之后调 `commit()` 会返回 ok 但 dhcp 一个字节没落盘。
 * 没有未提交改动时是空操作（不碰 flash）。
 */
export function commit(conf) {
	let c = (type(conf) == 'string' && length(conf)) ? conf : PKG;

	if (cur == null) {
		return { ok: false, code: 'E_INTERNAL', message: 'commit 前必须先成功 open()', detail: {} };
	}
	if (!is_dirty(c)) return { ok: true, code: 'OK', message: '' };

	if (cur.commit(c) !== true) {
		err(sprintf('uci commit %s 失败，改动未落盘', c));
		return {
			ok: false, code: 'E_UCI_COMMIT',
			message: sprintf('uci commit %s 失败，改动未落盘', c),
			detail: {}
		};
	}
	clear_dirty(c);
	return { ok: true, code: 'OK', message: '' };
}
