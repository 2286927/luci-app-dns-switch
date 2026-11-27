'use strict';

// ============================================================
// tick.uc —— L4：55 s 周期与降级执行（**不纯半边**）
//
// 死线：**不做任何业务判定**，阈值与决策全在 `switch-tier`；这里只
// "load → 读运行态 → 问 tier → 执行 → 写运行态"。C9 路径走 opts.state_dir，
// 执行走 opts.act（注入**替身**而非开关——关掉的缝等于把代码从覆盖里删掉）。
// ============================================================

import * as config from './config.uc';
import * as state from './state.uc';
import * as tier from './switch-tier.uc';
import * as dnsmasq from './dnsmasq.uc';
import * as nft from './nft.uc';
import { log } from './log.uc';

let fs = require('fs');

const STATE_DIR = '/tmp';
const NAMES = {
	fail: 'dns-switch.fail', succ: 'dns-switch.succ', cooldown: 'dns-switch.cooldown',
	last_check: 'dns-switch.last_check', probe_fail: 'dns-switch.probe-fail'
};

function opt_of(opts, key, dflt) {
	if (opts != null && type(opts) == 'object') {
		let v = opts[key];
		if (type(v) == 'string' && length(v)) return v;
		if (type(v) == 'int') return v;
		if (type(v) == 'bool') return v;
		if (type(v) == 'array') return v;      // 上游列表是数组：漏这条会被降级成 null
	}
	return dflt;
}

// 执行动作：默认真调 dnsmasq；单测传**替身**（recorder），"真切成功后写冷却"
// 那段仍被执行、被检查。不用开关式缝（关掉=把代码从覆盖里删掉）。
function act_of(opts) {
	let a = (opts != null && type(opts) == 'object') ? opts.act : null;
	if (a != null && type(a) == 'object'
		&& type(a.failover) == 'function' && type(a.recover) == 'function') return a;
	return {
		failover: function (list) { return dnsmasq.set_upstream(list); },
		recover: function (list) { return dnsmasq.set_upstream(list); }
	};
}

function dir_of(opts) {
	let d = opt_of(opts, 'state_dir', STATE_DIR);
	return length(d) ? d : STATE_DIR;
}

function path_of(opts, name) { return dir_of(opts) + '/' + NAMES[name]; }

function read_int(opts, name) {
	let t = fs.readfile(path_of(opts, name));
	if (type(t) != 'string') return 0;
	let v = trim(t);
	return (match(v, /^-?[0-9]+$/) != null) ? +v : 0;
}

function write_int(opts, name, v) {
	return fs.writefile(path_of(opts, name), sprintf('%d\n', v)) != null;
}

// 读运行态 → 组装 tier 的 state。只搬运不判定；**内部函数**（导出会踩 A4+G4）。
function read_state(opts) {
	let eff = state.get_opt('dns_switch', 'status', 'effective');
	let chain = opt_of(opts, 'chain_exists', null);
	if (chain == null) chain = nft.present().hijack;

	return {
		now: opt_of(opts, 'now', time()),
		cool_at: read_int(opts, 'cooldown'),
		effective: (eff != null) ? eff : '',
		fail_streak: read_int(opts, 'fail'),
		ok_streak: read_int(opts, 'succ'),
		chain_exists: (chain == true) ? 1 : 0
	};
}

/**
 * 一轮的**决策**：读文件 → 问 tier → 回 {action, why}。不执行任何系统动作。
 * 顺序不能反：`read_state` 经 state.get_opt 读 effective，而 cursor 是
 * `config.load` 建的——先读会拿到上一次的 cursor（可能已 null），
 * effective 变空 → tier 判"不是 on" → 静默 action=none。
 */
export function tick_once(opts) {
	let cfg = config.load(opts);
	if (cfg == null || cfg.ok != true) {
		return {
			ok: false,
			code: (cfg != null && cfg.code != null) ? cfg.code : 'E_INTERNAL',
			message: (cfg != null && cfg.message != null) ? cfg.message : '配置读不到',
			action: 'none', why: ''
		};
	}
	let st = read_state(opts);

	let down = tier.tier_failover(st, cfg);
	if (down.action == 'failover') return { ok: true, action: 'failover', why: down.why };

	let up = tier.tier_on(st, cfg);
	if (up.action == 'reload' || up.action == 'full') return { ok: true, action: up.action, why: up.why };

	return { ok: true, action: 'none', why: (down.why + ' / ' + up.why) };
}

/** 执行一轮：决策 + 落地动作 + 写运行态。 */
export function run(opts) {
	let o = (opts != null && type(opts) == 'object') ? opts : {};
	let d = tick_once(o);
	let now = opt_of(o, 'now', time());
	write_int(o, 'last_check', now);

	if (d.ok != true || d.action == 'none') return d;

	let act = act_of(o);
	let list;

	if (d.action == 'failover') {
		list = opt_of(o, 'isp_list', null);
		if (type(list) != 'array') {
			return { ok: false, code: 'E_INTERNAL', message: '降级需要上游列表', action: d.action };
		}
		let r = act.failover(list);
		if (r == null || r.ok != true) {
			return { ok: false, code: 'E_INTERNAL', message: '降级下发失败', action: d.action };
		}
		// 冷却起点**只在真切成功后写**（写早了会把重试窗口锁死）
		write_int(o, 'cooldown', now);
		write_int(o, 'fail', 0);
		log('ADH 不可用，已降级到运营商 DNS');
		return { ok: true, action: 'failover', why: d.why };
	}

	list = opt_of(o, 'adh_upstream', null);
	if (type(list) != 'array') {
		return { ok: false, code: 'E_INTERNAL', message: '回切需要 ADH 上游', action: d.action };
	}
	let r2 = act.recover(list);
	if (r2 == null || r2.ok != true) {
		return { ok: false, code: 'E_INTERNAL', message: '回切下发失败', action: d.action };
	}
	write_int(o, 'cooldown', now);
	write_int(o, 'succ', 0);
	log('ADH 已恢复，回切到 ADH 上游');
	return { ok: true, action: 'reload', why: d.why };
}
