'use strict';

// ============================================================
// config.uc —— L1 配置层：uci 的**唯一**出口
//
// 承接 v1.0.1 的 s_opt / t_opt / reload_cfg / need_cfg / ensure_config /
// st_set / st_commit / sig_now。
//
// 铁律（SPEC §3.4）：
//   1. 缺省值只在 load() 里 resolve 一次；其它模块**不许**再写 `?? default`。
//      opt(k, def) 的 def 只留给表外的键——表内键在 load() 已经填好，
//      再传 def 只是重复劳动（真要传，说明 §3.4 该加一行）。
//   2. 配置文件不存在 → 按 v1.0.1 的 ensure_config 逐字节建出来。
//   3. status 段缺失 → 补建并记日志（uci set 不建命名段，缺了所有
//      state_set 都是空写，页面和 status 会永远显示上一次的值）。
//   4. uci commit 失败 → 返回 code=E_UCI_COMMIT，**禁止**静默继续。
//
// 返回值形状：load() 直接返回已解析对象（SPEC §3.2），对象里额外带
//   ok / code / message 三个键做错误通道（配置键里没有同名的，不会撞）。
//   ok=true  → 后续读 cfg.mode 等
//   ok=false → 只有 code/message/detail，调用方按 E_* 处理
//
// 数字一律保持 uci 里的**字符串**（"3030" 不是 3030）：
//   sig() 要与 v1.0.1 的 sig_now 逐字节比对，JSON 侧的数值转换是 status/rpcd 的活。
//
// opts（仅供单测）：load({confdir:"/tmp/x"}) 把 uci 根指到临时目录，
//   生产调用一律 load() / state_set() / commit() / sig() 不带参数。
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

// ---- §3.4 缺省值表：全项目唯一的 resolve 点 ----
const DEFAULTS = {
	mode: 'off',
	dot853: 'allow',
	upstream_mode: 'auto',
	adh_ip: '172.16.1.2',
	adh_port: '3030',
	fallback_dns: '172.16.5.5',
	fallback_dns6: '',
	adh_mac: '',
	probe_domain: 'www.baidu.com',
	isp_list4: '',
	isp_list6: '',
	isp_list: '',        // v1.0.x 遗留单行字段，isp_dns 的 manual 分支还在读
	auto_failover: '1',
	probe_now: '0',
	request_at: '0'
};

// status 段不给"发明出来的缺省值"：v1.0.1 里这些字段空就是空，
// 补默认会改变 status 页面显示（I1）。null → '' 只是归一化。
const STATUS_KEYS = [
	'effective', 'probe', 'reason', 'dep', 'adh_mac', 'upstream',
	'last_change', 'error', 'conflict', 'conflict_by', 'conflict_msg',
	'conflict_fix', 'applied_sig'
];

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

let cur = null;      // uci cursor
let cfg = null;      // 最近一次 load() 的已解析对象
let dirty = false;   // 有没有未提交的 state_set

function confdir_of(opts) {
	if (opts != null && type(opts) == 'object') {
		if (type(opts.confdir) == 'string' && length(opts.confdir)) return opts.confdir;
	}
	return CONFDIR;
}

function fail(code, message) {
	err(message);
	return { ok: false, code: code, message: message, detail: {} };
}

function opt_string(k) {
	let v = cur.get(PKG, SECT, k);
	return (type(v) == 'string') ? v : null;
}

function resolve(k) {
	let v = opt_string(k);
	if (v == null || !length(v)) return DEFAULTS[k];   // 对应 shell 的 ${X:-default}
	return v;
}

// 建出厂配置：写文件 → 让 cursor 重读 → commit（与 v1.0.1 的顺序一致）
function ensure_config(dir) {
	let path = dir + '/' + PKG;
	let n = fs.writefile(path, join('\n', FACTORY));
	if (n == null) {
		return fail('E_UCI_COMMIT', sprintf('无法写入 %s（配置未落盘）', path));
	}

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

/**
 * 读 + 修 + resolve，返回已解析配置对象。
 * 返回对象恒有 ok / code / message；ok=false 时不要继续用其它键。
 */
export function load(opts) {
	let dir = confdir_of(opts);
	let path = dir + '/' + PKG;

	try {
		cur = (dir == CONFDIR) ? uci.cursor() : uci.cursor(dir);
	} catch (e) {
		cur = null;
		return fail('E_INTERNAL', sprintf('无法打开 uci：%s', e));
	}
	dirty = false;

	if (fs.stat(path) == null) {
		let created = ensure_config(dir);
		if (!created.ok) return created;
	}

	let fixed = ensure_status();
	if (!fixed.ok) return fixed;

	let out = {};
	let k;
	for (k in DEFAULTS) out[k] = resolve(k);

	out.status = {};
	for (let i = 0; i < length(STATUS_KEYS); i++) {
		let key = STATUS_KEYS[i];
		let v = cur.get(PKG, STAT, key);
		out.status[key] = (type(v) == 'string') ? v : '';
	}

	out.ok = true;
	out.code = 'OK';
	out.message = '';
	cfg = out;
	return out;
}

/**
 * 取一个配置键。§3.4 表内的键在 load() 已 resolve，def 只对表外的键有意义。
 * 判空用 `=== null`：实测 ucode 的 type(null) 返回 null 本身，不是 "null"。
 */
export function opt(k, def) {
	if (cfg == null) return def;
	let v = cfg[k];
	if (v === null) return def;
	return v;
}

/**
 * 写 status 段的一个字段（不 commit）。值没变就不写——v1.0.1 的
 * st_set 靠这一条少写 flash。返回 true=已是目标值。
 */
export function state_set(k, v) {
	if (cur == null || cfg == null) return false;

	let val = '';
	if (type(v) == 'string') val = v;
	else if (v !== null) val = "" + v;      // type(null) 是 null，不能拿它判空

	let old = cur.get(PKG, STAT, k);
	if (type(old) == 'string' && old == val) return true;

	if (cur.set(PKG, STAT, k, val) !== true) return false;
	cfg.status[k] = val;
	dirty = true;
	return true;
}

/**
 * 提交 status 段的改动。没有未提交改动时是空操作（不碰 flash）。
 * 失败返回 E_UCI_COMMIT（CLI 侧对应 rc=4）。
 */
export function commit() {
	if (cur == null) {
		return { ok: false, code: 'E_INTERNAL', message: 'commit 前必须先成功 load()', detail: {} };
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

/**
 * 关键参数签名，必须与 v1.0.1 sig_now() 逐字节一致：
 *   "$ADH|$ADH_PORT|$FB|$FB6|$DOT853|$MAC_CFG|$UPSTREAM_MODE|isp_list4|isp_list6"
 * 调用前先 load()；load 没成功时返回空串（与"取不到值"同义）。
 */
export function sig() {
	if (cfg == null || cfg.ok != true) return '';
	return sprintf('%s|%s|%s|%s|%s|%s|%s|%s|%s',
		cfg.adh_ip, cfg.adh_port, cfg.fallback_dns, cfg.fallback_dns6,
		cfg.dot853, cfg.adh_mac, cfg.upstream_mode, cfg.isp_list4, cfg.isp_list6);
}
