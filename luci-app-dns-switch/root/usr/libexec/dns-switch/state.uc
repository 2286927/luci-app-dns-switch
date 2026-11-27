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
let dirty = false;

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
	dirty = false;

	if (fs.stat(dir + '/' + PKG) == null) {
		let created = ensure_config(dir);
		if (!created.ok) return created;
	}

	return ensure_status();
}

/** 读原始值。sect 用 'settings' / 'status'；取不到返回 null（不编默认值）。 */
export function get(sect, key) {
	if (cur == null) return null;
	let v = cur.get(PKG, sect, key);
	return (type(v) == 'string') ? v : null;
}

/** 写 status 段的一个字段（不 commit）。值没变就不写 flash。 */
export function set_status(key, val) {
	if (cur == null) return false;

	let v = '';
	if (type(val) == 'string') v = val;
	else if (val !== null) v = "" + val;      // type(null) 是 null，不能拿它判空

	let old = cur.get(PKG, STAT, key);
	if (type(old) == 'string' && old == v) return true;

	if (cur.set(PKG, STAT, key, v) !== true) return false;
	dirty = true;
	return true;
}

/** 提交 status 段的改动。没有未提交改动时是空操作（不碰 flash）。 */
export function commit() {
	if (cur == null) {
		return { ok: false, code: 'E_INTERNAL', message: 'commit 前必须先成功 open()', detail: {} };
	}
	if (!dirty) return { ok: true, code: 'OK', message: '' };

	if (cur.commit(PKG) !== true) {
		err('uci commit dns_switch 失败，状态未落盘');
		return {
			ok: false, code: 'E_UCI_COMMIT',
			message: 'uci commit dns_switch 失败，状态未落盘',
			detail: {}
		};
	}
	dirty = false;
	return { ok: true, code: 'OK', message: '' };
}
